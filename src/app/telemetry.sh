#!/usr/bin/env bash
# app/telemetry.sh — caso de uso: la foto viva de las GPUs para el panel.
#
# Capa APP: orquesta `domain/` + `ports/`. No toca hardware (eso es del
# adaptador) y no decide nada (eso es del dominio). Lo que hace es juntar las
# dos cosas y emitir un informe con un formato estable que `nvidia-oc` parsea.
#
# POR QUÉ ESTO EXISTE EN VEZ DE QUE EL TUI LLAME A nvidia-smi
# -----------------------------------------------------------
# `src/bin/nvidia-oc` tiene prohibido hablar con el hardware: un TUI que
# consultara la tarjeta por su cuenta sería un segundo camino de lectura, con
# su propio parseo de `[N/A]`, sus propios umbrales de temperatura y su propia
# idea de qué significa la máscara de throttling. Dos implementaciones de las
# mismas reglas divergen, y la que divergiera sería la que el operador tiene
# delante mientras decide si aprieta la tarjeta.
#
# ELECCIÓN DE ADAPTADOR: `nvidia-smi`, NO NVML. El panel tiene que funcionar en
# una máquina sin `pynvml` utilizable —que es el caso por defecto en Ubuntu, con
# su binding 12.550.89 incompatible—, porque mirar el estado no debería
# depender de la librería que hace falta para ESCRIBIR offsets. El adaptador
# NVML decora al de nvidia-smi y aquí no aporta nada: ningún campo de
# telemetría viene de NVML.
#
# SOLO LECTURA, y por tanto SIN gate de enlace. Los gates de escritura
# (R4 + enlace + verificación) viven en app/overclock.sh y siguen intactos:
# este fichero no escribe nada, así que bloquearlo con el enlace degradado solo
# cegaría al operador justo cuando más necesita ver el estado. El gate R4 sí se
# usa, pero para lo que vale aquí: ETIQUETAR cada GPU, de modo que el panel
# diga cuál es la externa y cuál la interna en vez de confiar en el orden.

# shellcheck shell=bash

aorus_use domain/target domain/telemetry
aorus_use ports/gpu.port ports/log.port

aorus_adapter gpu adapters/gpu/nvidia-smi
aorus_adapter log adapters/log/stderr

# Ancho de las barras. Vive aquí y no en el dominio porque es una decisión de
# presentación; el dominio solo dice cuántas celdas de N se llenan.
AORUS_TEL_BAR_WIDTH="${AORUS_TEL_BAR_WIDTH:-20}"

# Emite las claves DERIVADAS de un registro ya leído. Separado del bucle para
# que se vea de un golpe todo lo que el dominio decide por cada GPU.
_tel_derived() { # $1=rol ya resuelto; usa las variables TEL_* del registro
  local v pct reasons line

  # El ROL, por el gate R4: 'egpu' | 'internal' | 'other'. El panel no deduce
  # cuál es la externa por el orden en que nvidia-smi las lista —los índices se
  # reordenan entre arranques— sino por el device-id, igual que las escrituras.
  printf 'role=%s\n' "${1:-other}"

  # Ocupación de VRAM: el porcentaje y las dos cifras legibles.
  if pct="$(domain_tel_pct "${TEL_mem_used_mib:-}" "${TEL_mem_total_mib:-}")"; then
    printf 'mem_pct=%s\n' "$pct"
    printf 'mem_bar=%s\n' "$(domain_tel_bar_cells "$pct" "$AORUS_TEL_BAR_WIDTH")"
    printf 'mem_sev=%s\n' "$(domain_tel_sev_fill "$pct")"
    printf 'mem_spark=%s\n' "$(domain_tel_spark_level "$pct" 0 100)"
  fi
  v="$(domain_tel_mib_human "${TEL_mem_used_mib:-}")"  && printf 'mem_used_human=%s\n'  "$v"
  v="$(domain_tel_mib_human "${TEL_mem_total_mib:-}")" && printf 'mem_total_human=%s\n' "$v"

  # Uso del núcleo y del controlador de memoria.
  if pct="$(domain_tel_pct_clamp "${TEL_util_gpu_pct:-}")"; then
    printf 'util_gpu_bar=%s\n' "$(domain_tel_bar_cells "$pct" "$AORUS_TEL_BAR_WIDTH")"
    printf 'util_gpu_sev=%s\n' "$(domain_tel_sev_util "$pct")"
    printf 'util_gpu_spark=%s\n' "$(domain_tel_spark_level "$pct" 0 100)"
  fi
  if pct="$(domain_tel_pct_clamp "${TEL_util_mem_pct:-}")"; then
    printf 'util_mem_bar=%s\n' "$(domain_tel_bar_cells "$pct" "$AORUS_TEL_BAR_WIDTH")"
  fi

  # Potencia: el porcentaje del techo, que es lo que una barra puede dibujar.
  # Si la tarjeta no publica el techo —la interna no lo hace— no hay barra, y
  # eso es correcto: no se puede dibujar una fracción de un total desconocido.
  if pct="$(domain_tel_pct "${TEL_power_draw_w:-}" "${TEL_power_limit_w:-}")"; then
    printf 'power_pct=%s\n' "$pct"
    printf 'power_bar=%s\n' "$(domain_tel_bar_cells "$pct" "$AORUS_TEL_BAR_WIDTH")"
    printf 'power_spark=%s\n' "$(domain_tel_spark_level "$pct" 0 100)"
  fi

  printf 'temp_sev=%s\n' "$(domain_tel_sev_temp "${TEL_temp_c:-}")"
  # El nivel de sparkline se calcula AQUÍ, no en el TUI, y esa es la razón de
  # que exista este campo: el mapeo valor->nivel es una regla del dominio
  # (domain_tel_spark_level, con test), y duplicarla en Python la convertiría en
  # dos definiciones que pueden divergir. El TUI solo acumula los niveles ya
  # resueltos en un búfer y pinta caracteres: el historial es estado de
  # presentación, el mapeo no.
  #
  # La temperatura usa un rango FIJO de 30-90 °C en vez del mínimo y el máximo
  # observados. Con un rango que se autoescala, una tarjeta en reposo oscilando
  # entre 42 y 44 °C pintaría una sierra de amplitud completa, y el operador
  # leería una inestabilidad térmica que no existe.
  v="$(domain_tel_spark_level "${TEL_temp_c:-}" 30 90)" && printf 'temp_spark=%s\n' "$v"

  # Throttling descodificado. Una máscara ilegible NO se traduce a 'ninguno':
  # el campo se omite y el panel lo muestra como desconocido.
  if reasons="$(domain_tel_throttle_decode "${TEL_throttle:-}")"; then
    # Se pegan las razones en una línea con bash, sin `paste`: una razón por
    # línea es el contrato del dominio, pero el panel quiere una sola celda.
    v=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ -n "$v" ] && v="$v; "
      v="$v$line"
    done <<< "$reasons"
    printf 'throttle_text=%s\n' "$v"
    if domain_tel_throttle_active "${TEL_throttle:-}"; then
      printf 'throttle_active=si\n'
    else
      printf 'throttle_active=no\n'
    fi
  fi
}

# El informe completo. Formato: secciones '[gpu]', '[proc]' y '[summary]', y
# dentro de cada una 'clave=valor' por línea. Se eligió sobre JSON porque el
# resto del paquete ya habla este dialecto (gpu_state, oc_status) y porque un
# panel que se refresca cada segundo no debería necesitar un parser.
tel_report() {
  local tel procs line key val n_egpu=0 bus pid mem name v role egpu_bus=""
  tel="$(gpu_telemetry_all)"
  case $? in
    124) log_err "nvidia-smi se ha colgado leyendo la telemetría; abortando sin reintentar."
         return 124 ;;
    3)   log_err "el adaptador de GPU no ofrece telemetría."; return 3 ;;
    0)   : ;;
    *)   log_err "no he podido leer la telemetría de las GPUs."; return 1 ;;
  esac

  # Los procesos se leen ANTES de emitir nada, porque el recuento por eGPU
  # entra en el resumen y el resumen va al final: así el panel puede pintar el
  # veredicto de H28 sin una segunda invocación.
  procs="$(gpu_processes_all)"
  case $? in
    124) log_err "nvidia-smi se ha colgado leyendo los procesos; abortando sin reintentar."
         return 124 ;;
    0|3) : ;;
    *)   procs="" ;;
  esac

  # --- las GPUs -------------------------------------------------------------
  # El registro se acumula en variables TEL_<clave> y se vuelca al encontrar el
  # separador siguiente (o al terminar), porque las claves derivadas necesitan
  # el registro COMPLETO: el porcentaje de VRAM no se puede calcular hasta
  # haber leído used y total.
  local -a pending=()
  _tel_flush() {
    [ "${#pending[@]}" -gt 0 ] || return 0
    role="$(domain_target_verdict "${TEL_vendor_id:-}" "${TEL_device_id:-}")"
    # El bus de la eGPU se descubre AQUÍ, por device-id, y es el que luego
    # filtra los procesos para el veredicto de H28. Sin esto el recuento sería
    # siempre 0 y el panel diría 'seguro' con un proceso CUDA vivo, que es
    # justo el consejo que cuelga el host.
    [ "$role" = "egpu" ] && egpu_bus="${TEL_bus_id:-}"
    printf '[gpu]\n'
    printf '%s\n' "${pending[@]}"
    _tel_derived "$role"
    pending=()
    # Las TEL_* se limpian para que un campo ausente en el registro siguiente
    # no herede el valor del anterior, que es la clase de error que hace que un
    # panel muestre la temperatura de otra tarjeta.
    unset "${!TEL_@}" 2>/dev/null || true
  }

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "--" ]; then _tel_flush; continue; fi
    [ -n "$line" ] || continue
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      ''|*[!a-z_]*) continue ;;   # clave que no es una clave: se ignora
    esac
    pending+=("$line")
    declare -g "TEL_$key=$val"
  done <<< "$tel"
  _tel_flush

  # --- los procesos ---------------------------------------------------------
  if [ -n "$procs" ]; then
    while IFS=$'\t' read -r bus pid mem name; do
      [ -n "$bus" ] || continue
      # Una fila sin PID numérico no es un proceso: la tarjeta en
      # `requires reset` anuncia su bus-id con el resto en hueco. Ver
      # domain_tel_proc_is_real.
      domain_tel_proc_is_real "$pid" || continue
      printf '[proc]\nbus_id=%s\npid=%s\nmem_mib=%s\nname=%s\n' \
             "$bus" "$pid" "$mem" "$name"
      v="$(domain_tel_mib_human "$mem")" && printf 'mem_human=%s\n' "$v"
      # Solo cuentan los de la eGPU: es su desconexión la que provoca el Oops
      # de H28, no la de la interna (que no se desconecta).
      if [ -n "$egpu_bus" ] && [ "$bus" = "$egpu_bus" ]; then n_egpu=$((n_egpu+1)); fi
    done <<< "$procs"
  fi

  # --- el resumen -----------------------------------------------------------
  printf '[summary]\n'
  printf 'egpu_bus=%s\n' "$egpu_bus"
  printf 'egpu_open_procs=%s\n' "$n_egpu"
  printf 'unplug=%s\n' "$(domain_tel_unplug_verdict "$n_egpu")"
  return 0
}
