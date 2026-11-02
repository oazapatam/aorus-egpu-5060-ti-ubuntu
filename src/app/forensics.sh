#!/usr/bin/env bash
# app/forensics.sh — casos de uso para depurar los CUELGUES de la eGPU.
#
# EL PROBLEMA: probar la eGPU congela el host a veces. Sin Xid, sin panic, sin
# oops. Al reiniciar no queda nada: el buffer de journald vivía en RAM y el
# kernel nunca llegó a volcarlo. Resultado: imposible saber qué paso lo mató.
#
# LA ESTRATEGIA, en capas, de la más fiable a la que más cosas captura:
#
#   1. MIGAS DE PAN en disco con fsync (adapters/trace/durable.sh).
#      No depende de que el kernel sobreviva ni de que journald sincronice.
#      Si la máquina muere, la última miga escrita ES el paso culpable.
#      Funciona HOY, sin reiniciar y sin configuración previa.
#
#   2. MUESTREADOR periódico (forensics_watch). Un bucle que graba estado de
#      enlace/potencia cada N segundos con fsync. Tras el cuelgue tenemos la
#      foto del hardware en el último instante vivo.
#
#   3. ramoops/pstore + lockup->panic (paquete aorus-egpu-forensics, requiere
#      reiniciar). Preserva el dmesg del kernel a través del reinicio. Captura
#      mucho más, pero solo si el kernel llega a hacer panic.
#
# La capa 1 y 2 son las que cubren el peor caso (cuelgue total sin panic), y por
# eso son las que no requieren nada instalado.

# shellcheck shell=bash

aorus_use domain/target domain/link
aorus_use ports/pci.port ports/log.port ports/trace.port
aorus_adapter pci   adapters/pci/sysfs
aorus_adapter log   adapters/log/stderr
aorus_adapter trace adapters/trace/durable

# El contrato se verifica al cargar (ver la misma nota en app/overclock.sh).
# Se escribe como `if ! { ... }` y no como `a && b && c || { ... }`: con la
# cadena, shellcheck avisa (SC2015) de que el bloque del `||` también corre si
# falla b o c — que aquí es justo lo que queremos, pero la forma negada lo dice
# sin ambigüedad y aguanta mejor añadir un cuarto puerto.
#
# shellcheck disable=SC2317  # `exit 70` SÍ se alcanza: `return` solo es válido
# cuando este fichero se carga con `.`; si alguien lo EJECUTA, el `return` falla
# y la ejecución cae al `exit`. shellcheck no puede ver ese segundo escenario.
if ! { port_pci_assert && port_log_assert && port_trace_assert; }; then
  printf 'aorus: contrato de puerto incumplido; abortando.\n' >&2
  return 70 2>/dev/null || exit 70
fi

AORUS_PSTORE_ARCHIVE="${AORUS_PSTORE_ARCHIVE:-/var/log/aorus-egpu/pstore}"

# --- muestreador en segundo plano ---------------------------------------------
# Cada tick escribe y hace fsync. Barato (solo lecturas de sysfs) y es lo único
# que sobrevive a un cuelgue sin panic.
# Una sola pasada de muestreo. Separada del bucle para poder escribir la
# primera muestra de forma SINCRÓNICA antes de pasar a segundo plano: si no, una
# prueba muy corta mata al muestreador antes de que escriba y el log sale vacío.
forensics_watch_sample() { # $1=fichero
  local f="$1" bdf
  for bdf in /sys/bus/pci/devices/*; do
      [ "$(cat "$bdf/vendor" 2>/dev/null)" = "0x10de" ] || continue
      printf '%s | %s | %s | %s | %s | %s | %s\n' \
        "$(date -Is)" "$(cut -d' ' -f1 /proc/uptime)" "$(basename "$bdf")" \
        "$(cat "$bdf/current_link_speed" 2>/dev/null)" \
        "$(cat "$bdf/current_link_width" 2>/dev/null)" \
        "$(basename "$(readlink -f "$bdf/driver" 2>/dev/null)" 2>/dev/null)" \
        "$(cat "$bdf/power/runtime_status" 2>/dev/null)" >> "$f"
  done
  sync "$f" 2>/dev/null || sync
}

forensics_watch() { # $1=intervalo s $2=dir de traza
  local interval="${1:-2}" dir="${2:-$AORUS_TRACE_DIR}" f
  [ -n "$dir" ] || return 1
  f="$dir/30-watch.log"
  printf '# ts | uptime | bdf | link | width | driver | runtime_pm\n' > "$f"
  forensics_watch_sample "$f"
  while :; do
    sleep "$interval"
    forensics_watch_sample "$f"
  done
}

# --- caso de uso: ejecutar algo arriesgado con traza completa -----------------
forensics_probe() { # $1=nombre de sesión; $2..=comando a ejecutar
  local name="$1"; shift
  local dir rc watch_pid=0

  # SIN subshell: trace_begin exporta AORUS_TRACE_DIR y en `$(...)` se perdería
  # (y entonces trace_mark no escribiría nada).
  trace_begin "$name" >/dev/null
  dir="$AORUS_TRACE_DIR"
  log_info "traza: $dir"
  trace_mark "SESSION_START" "$name: $*"

  # Estado del hardware ANTES. Si el cuelgue ocurre durante el comando, este
  # snapshot es la referencia para saber qué cambió.
  trace_mark "SNAPSHOT_PRE" "capturando estado previo"
  trace_snapshot "pre"

  # Resolver el target con el gate R4, pero SIN abortar: aquí estamos
  # diagnosticando, y querer una traza de un sistema roto es legítimo.
  local bdf ids vendor device link speed width verdict
  if bdf="$(pci_find_by_device_id "$AORUS_EGPU_DEVICE")"; then
    ids="$(pci_read_ids "$bdf")"; read -r vendor device <<< "$ids"
    verdict="$(domain_target_verdict "$vendor" "$device")" || true
    link="$(pci_read_link "$bdf")"; speed="${link%%|*}"; width="${link##*|}"
    trace_mark "TARGET" "$bdf verdict=$verdict link=$speed x$width -> $(domain_link_verdict "$speed" "$width")"
  else
    trace_mark "TARGET" "la eGPU NO está en el bus PCI"
  fi

  # Muestreador en paralelo durante toda la ejecución.
  # Primera muestra sincrónica, y el bucle a segundo plano.
  printf '# ts | uptime | bdf | link | width | driver | runtime_pm\n' > "$dir/30-watch.log"
  forensics_watch_sample "$dir/30-watch.log"
  ( while :; do sleep "${AORUS_WATCH_INTERVAL:-2}"; \
      forensics_watch_sample "$dir/30-watch.log"; done ) &
  watch_pid=$!
  trace_mark "WATCH_START" "pid=$watch_pid intervalo=${AORUS_WATCH_INTERVAL:-2}s"

  # Punto de no retorno: la siguiente miga es la última si la máquina muere.
  trace_mark "RISKY_BEGIN" "ejecutando: $*"
  "$@" > "$dir/40-command-stdout.log" 2> "$dir/41-command-stderr.log"
  rc=$?
  trace_mark "RISKY_END" "rc=$rc"

  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  trace_mark "WATCH_STOP" ""

  trace_mark "SNAPSHOT_POST" "capturando estado posterior"
  trace_snapshot "post"

  # dmesg del tramo: las marcas AORUS-TRACE en /dev/kmsg delimitan la ventana.
  #
  # SC2024 ("sudo no afecta a la redirección") no aplica aquí: lo que necesita
  # privilegio es LEER el buffer del kernel (kernel.dmesg_restrict), no escribir
  # el fichero. $dir lo acaba de crear trace_begin bajo /var/log/aorus-egpu, así
  # que el shell que redirige ya tiene permiso sobre él; pasar a `| sudo tee`
  # añadiría una tubería y perdería el rc directo sin arreglar nada.
  # shellcheck disable=SC2024
  if dmesg -T > "$dir/50-dmesg.log" 2>/dev/null; then
    trace_mark "DMESG" "guardado"
  elif sudo -n dmesg -T > "$dir/50-dmesg.log" 2>/dev/null; then
    trace_mark "DMESG" "guardado (sudo)"
  else
    trace_mark "DMESG" "NO accesible (hace falta root)"
  fi

  trace_end "rc=$rc"
  log_info ""
  log_info "rc=$rc — traza completa en: $dir"
  log_info "Si el host se CONGELA en la próxima prueba, tras reiniciar ejecuta:"
  log_info "  aorus-egpu-postmortem"
  return "$rc"
}

# --- caso de uso: postmortem tras un cuelgue ----------------------------------
# Se ejecuta DESPUÉS de reiniciar. Junta en un solo directorio todo lo que
# sobrevivió, para no tener que recordar dónde mira cada cosa.
forensics_postmortem() {
  local out stamp last_trace
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out="/var/log/aorus-egpu/postmortem/$stamp"
  mkdir -p "$out" || { log_err "no puedo crear $out (¿hace falta root?)"; return 1; }

  log_info "postmortem -> $out"

  # 1. La última traza: su ÚLTIMA miga de pan es el paso que mató la máquina.
  last_trace="$(find /var/log/aorus-egpu/traces -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)"
  if [ -n "$last_trace" ]; then
    cp -a "$last_trace" "$out/ultima-traza" 2>/dev/null || true
    {
      printf '== última traza: %s ==\n\n' "$(basename "$last_trace")"
      printf -- '-- meta --\n'; cat "$last_trace/00-meta.txt" 2>/dev/null
      printf -- '\n-- ÚLTIMAS 15 MIGAS (la última es el paso sospechoso) --\n'
      tail -15 "$last_trace/10-breadcrumbs.log" 2>/dev/null
      printf -- '\n-- ÚLTIMAS 20 muestras de hardware --\n'
      tail -20 "$last_trace/30-watch.log" 2>/dev/null
    } > "$out/00-RESUMEN.txt"
    log_info "  última traza: $(basename "$last_trace")"
  else
    printf 'no hay trazas previas en /var/log/aorus-egpu/traces\n' > "$out/00-RESUMEN.txt"
    log_warn "  no hay trazas previas (¿se ejecutó aorus-egpu-probe antes del cuelgue?)"
  fi

  # 2. pstore: el dmesg del kernel preservado a través del reinicio. Solo existe
  # si hubo panic Y ramoops está configurado (paquete aorus-egpu-forensics).
  if compgen -G "$AORUS_PSTORE_ARCHIVE/*" >/dev/null 2>&1; then
    cp -a "$AORUS_PSTORE_ARCHIVE" "$out/pstore-archivado" 2>/dev/null || true
    log_info "  pstore archivado: sí"
  elif compgen -G "/sys/fs/pstore/*" >/dev/null 2>&1; then
    mkdir -p "$out/pstore-vivo"
    cp -a /sys/fs/pstore/* "$out/pstore-vivo/" 2>/dev/null || true
    log_info "  pstore vivo: encontrado (cópialo antes de que se pierda)"
  else
    printf 'pstore vacío: no hubo panic, o ramoops no está configurado.\n%s\n' \
      "Instala aorus-egpu-forensics y reinicia para habilitarlo." \
      > "$out/pstore-AUSENTE.txt"
    log_warn "  pstore: vacío (sin panic registrado o ramoops no configurado)"
  fi

  # 3. Journal del arranque ANTERIOR. Es lo que journald alcanzó a sincronizar.
  if journalctl -b -1 --no-pager > "$out/10-journal-boot-anterior.log" 2>/dev/null; then
    log_info "  journal del arranque anterior: guardado"
  else
    log_warn "  journal del arranque anterior: no disponible"
  fi
  journalctl -b -1 -k --no-pager > "$out/11-kernel-boot-anterior.log" 2>/dev/null || true
  journalctl -b -1 -t egpu-tb-fix -t aorus-egpu-trace --no-pager \
    > "$out/12-egpu-boot-anterior.log" 2>/dev/null || true

  # 4. Contexto del arranque actual.
  {
    printf 'cmdline: %s\n' "$(cat /proc/cmdline)"
    printf 'kernel:  %s\n' "$(uname -r)"
    printf 'uptime:  %s\n' "$(uptime -p)"
    printf 'arranques registrados:\n'; journalctl --list-boots --no-pager 2>/dev/null | tail -8
  } > "$out/20-contexto-actual.txt" 2>&1

  sync
  log_info ""
  log_info "Empieza por:  $out/00-RESUMEN.txt"
  # La ruta NO se imprime por stdout: el entrypoint no debe tener que
  # silenciarnos para quedarse solo con ella (y silenciarnos se llevaba todos
  # los log_info por delante). Queda en AORUS_POSTMORTEM_DIR para quien la use.
  #
  # shellcheck disable=SC2034  # NO está sin usar: es la salida documentada de
  # este caso de uso, la lee quien nos llama (bin/, o un test). No se exporta a
  # propósito: no hace falta en un hijo y exportarla cambiaría el contrato.
  AORUS_POSTMORTEM_DIR="$out"
}
