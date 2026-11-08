#!/usr/bin/env bash
# app/overclock.sh — CASOS DE USO del tuning de la eGPU.
#
# Esta capa ORQUESTA: resuelve el target, aplica los gates de seguridad, pide el
# plan al dominio y manda al adaptador ejecutarlo. No contiene reglas de negocio
# (están en domain/) ni detalles de herramienta (están en adapters/).
#
# Orden de los gates — cada uno existe por un incidente real documentado:
#   1. R4   : el target DEBE ser la eGPU externa. Tocar la interna dio Xid 79.
#   2. topo : debe colgar de un controlador TB/USB4. Segunda confirmación de R4.
#   3. smi  : si nvidia-smi se cuelga (rc 124), ABORTAR sin reintentar.
#   4. link : el enlace debe poder NEGOCIAR Gen>=3. Apretar la tarjeta con el
#             enlace Gen1 marginal congeló el host entero el 2026-06-27.
#   5. verif: un offset de reloj POSITIVO no se da por bueno hasta que un
#             verificador numérico ha comprobado que la GPU sigue calculando
#             bien. Ver el bloque "GATE DE VERIFICACIÓN" más abajo.
# Ningún gate se puede saltar con un flag: --force solo relaja el gate de enlace
# y lo deja registrado, porque es el único cuyo riesgo es del usuario y no un bug.
#
# GATE DE VERIFICACIÓN (offsets positivos) — las cuatro reglas, con su motivo:
#
#   a. Sin verificador disponible, el gate CIERRA. Misma filosofía que el
#      'unknown' del gate de enlace: sin evidencia no se escribe.
#
#   b. --force NO lo abre. Y no es una preferencia de estilo: un enlace
#      degradado es un riesgo que el operador puede EVALUAR y asumir, mientras
#      que un número mal calculado no lo puede ni detectar, así que no puede
#      consentirlo. Es el mismo precedente que ya está en el código para
#      'dead'/'unknown' en el gate de enlace.
#
#   c. Un offset positivo NUNCA se aplica de forma DESATENDIDA (udev o la unit
#      systemd). Si el gate falla en un arranque nadie lo va a leer, y la
#      máquina quedaría calculando mal sin testigo.
#
#   d. Secuencia OBLIGATORIA: aplicar -> verificar -> si falla, revertir a
#      stock AHORA, NO persistir el state file (un perfil que calcula mal no
#      debe sobrevivir a un reinicio del servicio) y dejarlo registrado en
#      /var/log/aorus-egpu/oc-verify.log. Si el verificador devuelve 124
#      (colgado) NO se revierte: revertir son dos escrituras más contra una
#      tarjeta que ya no responde, y martillear un eGPU semi-roto lo deja
#      wedged en estado-D. Es el mismo criterio que el gpu_state post-apply.
#
# El gate de enlace va DESPUÉS del de nvidia-smi porque su entrada
# (`pcie.link.gen.max`) la da nvidia-smi: es la capacidad negociada del enlace,
# no la instantánea de sysfs. Usar la instantánea rechazaba el tuning SIEMPRE,
# porque en reposo el enlace baja a 2.5 GT/s por diseño; ver la cabecera de
# domain/link.sh. Los gates R4 (1 y 2) siguen primero y no dependen de nada
# externo: la GPU interna se descarta antes de hablar con ninguna herramienta.

# shellcheck shell=bash

aorus_use domain/target domain/link domain/overclock
aorus_use ports/gpu.port ports/pci.port ports/log.port ports/verify.port
# El adaptador por defecto del puerto gpu es NVML, que es nvidia-smi MÁS los
# offsets de reloj (ver la cabecera de adapters/gpu/nvml.sh). Degrada
# honestamente: sin pynvml, gpu_supports_clock_offset dice "no soportado", el
# dominio rechaza los perfiles con offsets y el resto sigue por nvidia-smi.
aorus_adapter gpu adapters/gpu/nvml
aorus_adapter pci adapters/pci/sysfs
aorus_adapter log adapters/log/stderr
aorus_adapter verify adapters/verify/torch-gemm

# Nota: /etc/aorus-egpu/overclock.conf NO se lee aquí a propósito — lo consume
# systemd con EnvironmentFile= y nos pasa el perfil como argumento. Declararlo
# en esta capa sería una segunda fuente de verdad.
AORUS_OC_PROFILE_DIR="${AORUS_OC_PROFILE_DIR:-/etc/aorus-egpu/profiles}"
AORUS_OC_STATE="${AORUS_OC_STATE:-/run/aorus-egpu/overclock.state}"
# El registro de verificaciones va a /var/log (no a /run) a propósito: es la
# evidencia de que un offset se midió, o de que se rechazó, y tiene que
# sobrevivir al reinicio igual que el registro de incidentes de health.
AORUS_OC_VERIFY_LOG="${AORUS_OC_VERIFY_LOG:-/var/log/aorus-egpu/oc-verify.log}"
# Presupuesto de tiempo de la verificación. 25 s da para llenar y releer buena
# parte de la VRAM y varias iteraciones de GEMM sobre este túnel.
AORUS_OC_VERIFY_SECONDS="${AORUS_OC_VERIFY_SECONDS:-25}"

# --- carga de perfil ----------------------------------------------------------
# Parser deliberadamente tonto (key=value, sin `source`): un fichero de config
# NO debe poder ejecutar código. `source` sobre /etc/... convertiría un typo en
# ejecución arbitraria como root.
oc_load_profile() { # $1=nombre de perfil
  local name="$1" file key val line
  file="$AORUS_OC_PROFILE_DIR/$name.profile"
  [ -r "$file" ] || { log_err "perfil desconocido: $name (no existe $file)"; return 2; }
  # shellcheck disable=SC2034  # OC_profile NO está sin usar: junto con el resto
  # de OC_* es la ENTRADA de domain_oc_plan/domain_oc_validate, que las leen del
  # entorno del shell (ver el comentario de domain_oc_plan). shellcheck no sigue
  # a través de `aorus_use`, así que no puede ver esa lectura.
  OC_profile="$name"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    key="${line%%=*}"; val="${line#*=}"
    if ! domain_oc_key_is_valid "$key"; then
      log_err "perfil $name: clave desconocida '$key'"; return 2
    fi
    # Asignación por nombre con declare -g: la clave ya está en la allowlist y
    # el valor NUNCA se evalúa como código (nada de `eval`/`source` aquí).
    declare -g "OC_$key=$val"
  done < "$file"
  return 0
}

# --- resolución del target con los gates R4 -----------------------------------
# Imprime "<bus-id><TAB><veredicto de enlace>". Se devuelven JUNTOS porque el
# resolver corre en una subshell `$(...)` y una variable global no propagaría.
# rc: 0 ok, 1 ausente, 2 violación R4, 124 colgado.
oc_resolve_target() {
  local bdf ids vendor device r4_verdict bus speed width link
  bdf="$(pci_find_by_device_id "$AORUS_EGPU_DEVICE")" || {
    log_err "la eGPU (device $AORUS_EGPU_DEVICE) no está en el bus PCI."; return 1; }

  ids="$(pci_read_ids "$bdf")" || { log_err "no puedo leer los ids de $bdf"; return 1; }
  read -r vendor device <<< "$ids"
  r4_verdict="$(domain_target_verdict "$vendor" "$device")"
  case "$r4_verdict" in
    egpu) : ;;
    internal) log_err "GATE R4: $bdf es la GPU INTERNA. Abortando (esto sería un bug de targeting)."; return 2 ;;
    *) log_err "GATE R4: $bdf no es la eGPU ($vendor:$device, $r4_verdict). Abortando."; return 2 ;;
  esac

  if ! pci_is_behind_thunderbolt "$bdf"; then
    log_err "GATE R4: $bdf no cuelga de un controlador Thunderbolt/USB4. Abortando."
    return 2
  fi

  # La instantánea se lee solo para INFORMAR. No decide nada: en reposo marca
  # 2.5 GT/s siempre, porque el enlace baja de velocidad solo.
  link="$(pci_read_link "$bdf")"; speed="${link%%|*}"; width="${link##*|}"

  bus="$(gpu_find_by_device_id "$AORUS_EGPU_DEVICE")"; local rc=$?
  [ "$rc" -eq 124 ] && { log_err "nvidia-smi se colgó; ABORTO sin reintentar."; return 124; }
  [ "$rc" -ne 0 ] && { log_err "la eGPU está en PCI ($bdf) pero nvidia no la publica."; return 1; }

  # GATE de enlace, por CAPACIDAD negociada (ver cabecera y domain/link.sh).
  local gen_max link_verdict info
  gen_max="$(gpu_link_gen_max "$bus")"; rc=$?
  [ "$rc" -eq 124 ] && { log_err "nvidia-smi se colgó leyendo el enlace; ABORTO sin reintentar."; return 124; }
  link_verdict="$(domain_link_cap_verdict "$gen_max" "$width")"
  info="Gen${gen_max:-?} negociado, ${speed:-?} x${width:-?} ahora mismo"
  if [ "$link_verdict" != "healthy" ]; then
    if [ "${AORUS_OC_READONLY:-0}" = "1" ]; then
      log_warn "enlace $link_verdict ($info); sigo porque esta operación es de SOLO LECTURA."
    elif [ "${AORUS_OC_FORCE:-0}" = "1" ] && [ "$link_verdict" = "degraded" ]; then
      # --force relaja SOLO 'degraded': un enlace entrenado por debajo de Gen3
      # es un riesgo que el operador puede decidir asumir.
      #
      # NUNCA relaja 'dead' ni 'unknown', y esto es el invariante de CLAUDE.md,
      # no una preferencia: "Si la capacidad no se puede leer el veredicto es
      # unknown y el gate CIERRA". Con 'dead' el túnel no existe, y con
      # 'unknown' nadie puede afirmar en qué estado está. Antes la condición
      # era solo `AORUS_OC_FORCE=1`, así que --force escribía igual en los dos
      # casos; con H23 abierto -el dispositivo TB entero se cae cada ~6,5 h-
      # eso es exactamente escribir justo después de una caída.
      log_warn "enlace $link_verdict ($info) y --force activo: continúo BAJO TU RIESGO."
    else
      log_err "GATE de enlace: enlace $link_verdict ($info)."
      case "$link_verdict" in
        unknown)
          log_err "No he podido leer la capacidad del enlace, así que no puedo afirmar que sea seguro."
          log_err "--force NO abre este caso: sin capacidad legible no hay riesgo que puedas asumir." ;;
        dead)
          log_err "El enlace no está entrenado: el túnel Thunderbolt no existe ahora mismo."
          log_err "--force NO abre este caso. Comprueba la conexión y vuelve a intentarlo." ;;
        *)
          log_err "Apretar la eGPU con el enlace degradado ha congelado el host. Usa --force si lo asumes." ;;
      esac
      return 2
    fi
  fi
  printf '%s\t%s\t%s' "$bus" "$link_verdict" "$info"
}

# --- capacidad de offsets: preguntar al adaptador y pasarlo como DATO --------
# Imprime lo que el dominio espera en su 7º argumento: "si <gmin> <gmax> <mmin>
# <mmax>" o "no". Devuelve 124 si la herramienta se colgó, para que el caso de
# uso aborte sin reintentar en vez de interpretar el cuelgue como un "no".
#
# Esto es lo que saca la creencia del dominio: antes domain_oc_validate
# afirmaba "requiere Xorg+Coolbits", que es un hecho del ENTORNO -y además ya
# era falso-. Ahora el entorno lo dice, y el dominio solo aplica la regla.
_oc_offcap() { # $1=busid
  local rc win
  gpu_supports_clock_offset "$1"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  if [ "$rc" -ne 0 ]; then printf 'no'; return 0; fi
  win="$(gpu_offset_window "$1")"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  if [ "$rc" -ne 0 ] || [ -z "$win" ]; then printf 'no'; return 0; fi
  printf 'si %s' "$win"
}

# ¿Estamos corriendo DESATENDIDOS (udev / unit systemd)? Un offset positivo no
# se aplica así: si el gate de verificación falla en un arranque, nadie lee el
# error y la máquina se queda calculando mal sin testigo.
#
# Se detecta por dos vías a propósito: la unit declara AORUS_OC_UNATTENDED=1
# (explícito), e INVOCATION_ID lo pone systemd en TODA unit (red de seguridad
# para cualquier otra que se añada mañana y se olvide de declararlo).
_oc_is_unattended() {
  [ "${AORUS_OC_UNATTENDED:-0}" = "1" ] && return 0
  [ -n "${INVOCATION_ID:-}" ] && return 0
  return 1
}

# Registro de verificaciones. Nunca falla la operación por no poder escribirlo
# (en un dry-run o como usuario normal /var/log no es escribible), pero sí se
# intenta siempre: un rechazo del gate es tan registrable como un fallo.
#
# EL ORDEN DE LAS REDIRECCIONES NO ES COSMÉTICO. Antes esto era
#   printf ... >> "$AORUS_OC_VERIFY_LOG" 2>/dev/null || true
# y el `2>/dev/null` NO silenciaba nada, porque bash procesa las redirecciones
# de izquierda a derecha: cuando el `>>` falla al abrir el fichero, el error lo
# imprime el propio shell en el stderr que hubiera EN ESE MOMENTO, que todavía
# era el terminal. Medido el 2026-11-07: un `aorus-egpu-oc verify` como usuario
# normal terminaba con rc 0 y la verificación correcta, pero escupiendo
#   app/overclock.sh: line 213: /var/log/aorus-egpu/oc-verify.log: Permission denied
# justo debajo del "VERIFICACIÓN OK". Con el `2>/dev/null` PRIMERO, el stderr ya
# está redirigido cuando se intenta abrir el fichero y el fallo es silencioso.
#
# Y si no se pudo registrar, se DICE. El registro existe para ser la evidencia
# de que algo se midió; perderla en silencio deja al operador creyendo que hay
# una traza que no existe, y en este repo la traza es media herramienta.
_oc_verify_log() { # $@ = texto
  local dir
  dir="$(dirname "$AORUS_OC_VERIFY_LOG")"
  mkdir -p "$dir" 2>/dev/null || true
  # Comando SIMPLE, no un `{ ...; }`: con un compuesto bash se come el fallo de
  # la redirección y devuelve 0, así que la rama de aviso sería código muerto.
  # Comprobado el 2026-11-07 en esta máquina con el log de root y un usuario
  # normal: la forma `{ printf; } 2>/dev/null >> fichero` dice rc 0 y no
  # escribe nada; `printf 2>/dev/null >> fichero` devuelve rc != 0.
  local stamp
  stamp="$(date -Is 2>/dev/null || date)"
  if ! printf '%s\t%s\n' "$stamp" "$*" 2>/dev/null >> "$AORUS_OC_VERIFY_LOG"; then
    log_info "sin registrar en $AORUS_OC_VERIFY_LOG (hace falta root): esta medición no queda en el histórico."
    return 0
  fi
}

# Pone los offsets a 0 si la tarjeta los soporta. Es parte de la
# REVERSIBILIDAD: gpu_reset_all devuelve relojes y potencia a fábrica, pero un
# offset NVML no es ninguna de las dos cosas y sobreviviría al reset. Sin esto,
# `apt remove` dejaría la tarjeta con el offset puesto.
_oc_zero_offsets() { # $1=busid
  local bus="$1" rc
  gpu_supports_clock_offset "$bus"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && return 0   # no los soporta: nada que deshacer
  local which failed=0
  for which in gpu mem; do
    gpu_set_clock_offset "$bus" "$which" 0; rc=$?
    if [ "$rc" -eq 124 ]; then
      log_err "  nvml se colgó poniendo el offset de $which a 0; no sigo."
      return 124
    fi
    [ "$rc" -eq 0 ] || { log_err "  no pude poner el offset de $which a 0"; failed=1; }
  done
  return "$failed"
}

# Vuelta a stock inmediata: relojes, potencia y offsets. Y se borra el state
# file, porque el perfil ya no está aplicado.
_oc_revert_to_stock() { # $1=busid
  local bus="$1" rc
  gpu_reset_all "$bus"; rc=$?
  if [ "$rc" -eq 124 ]; then
    log_err "  el reset de emergencia se colgó; NO insisto."
    return 124
  fi
  [ "$rc" -eq 0 ] || log_err "  el reset de emergencia falló (rc=$rc)."
  _oc_zero_offsets "$bus" || true
  rm -f "$AORUS_OC_STATE" 2>/dev/null || true
  return 0
}

# --- ejecutor del plan --------------------------------------------------------
# Una escritura del plan. Devuelve 124 tal cual si nvidia-smi se colgó, para
# que el ejecutor pueda abortar en vez de pasar a la siguiente operación.
_oc_write() { # $1=etiqueta $2..=comando
  local label="$1"; shift
  local wrc
  "$@"; wrc=$?
  if [ "$wrc" -eq 124 ]; then
    log_err "  nvidia-smi se COLGÓ escribiendo $label (rc=124)."
    return 124
  fi
  [ "$wrc" -eq 0 ] || log_err "  falló $label"
  return "$wrc"
}

oc_execute_plan() { # $1=busid; plan por stdin
  local bus="$1" op a b rc=0 wrc
  while IFS=$'\t' read -r op a b; do
    # Si una escritura anterior se colgó, no se toca más la tarjeta. El bucle
    # sigue consumiendo stdin para no romper la tubería, pero sin escribir:
    # martillear un eGPU semi-roto lo deja wedged en estado-D (CLAUDE.md).
    if [ "$rc" -eq 124 ]; then continue; fi
    case "$op" in
      power_limit) log_info "  power limit -> ${a} W"
                   _oc_write "power limit" gpu_set_power_limit "$bus" "$a"
                   wrc=$?; [ "$wrc" -eq 0 ] || rc=$wrc ;;
      gpu_clock)   log_info "  reloj gráfico -> ${a}-${b} MHz"
                   _oc_write "lock de reloj gráfico" gpu_set_gpu_clock "$bus" "$a" "$b"
                   wrc=$?; [ "$wrc" -eq 0 ] || rc=$wrc ;;
      mem_clock)   log_info "  reloj memoria -> ${a} MHz"
                   _oc_write "lock de reloj memoria" gpu_set_mem_clock "$bus" "$a"
                   wrc=$?; [ "$wrc" -eq 0 ] || rc=$wrc ;;
      reset)       log_info "  reset a valores de fábrica"
                   _oc_write "el reset" gpu_reset_all "$bus"
                   wrc=$?; [ "$wrc" -eq 0 ] || rc=$wrc ;;
      '')          : ;;
      clock_offset) log_info "  offset de reloj ${a} -> ${b} MHz"
                   _oc_write "offset de reloj $a" gpu_set_clock_offset "$bus" "$a" "$b"
                   wrc=$?
                   # rc 3 = el adaptador no soporta offsets. No debería llegar
                   # aquí (el dominio rechaza antes el perfil con la capacidad
                   # que le pasó app/), así que si pasa es un bug de
                   # orquestación y se dice como tal en vez de callarlo.
                   [ "$wrc" -eq 3 ] && log_err "  el adaptador declara NO soportar offsets: el plan no debería haberlo emitido"
                   [ "$wrc" -eq 0 ] || rc=$wrc ;;
      *)           if domain_oc_op_is_valid "$op"; then
                     log_err "  operación '$op' válida pero sin implementar en el ejecutor"
                   else
                     log_err "  operación desconocida en el plan: $op"
                   fi
                   rc=1 ;;
    esac
  done
  [ "$rc" -eq 124 ] && log_err "  plan ABORTADO tras el cuelgue; no se reintenta."
  return "$rc"
}

# --- caso de uso: aplicar -----------------------------------------------------
oc_apply() { # $1=perfil
  local profile="${1:-}" bus caps pmin pmax gmax mmax gmin mmin plan rc
  [ -n "$profile" ] || { log_err "falta el nombre del perfil"; return 2; }

  oc_load_profile "$profile" || return $?
  local resolved link_verdict link_info
  resolved="$(oc_resolve_target)" || return $?
  IFS=$'\t' read -r bus link_verdict link_info <<< "$resolved"

  caps="$(gpu_caps "$bus")"; rc=$?
  [ "$rc" -eq 124 ] && { log_err "nvidia-smi se colgó leyendo capacidades; ABORTO."; return 124; }
  [ "$rc" -ne 0 ] && { log_err "no puedo leer las capacidades de la eGPU."; return 1; }
  read -r pmin pmax gmax mmax gmin mmin <<< "$caps"

  # La capacidad de OFFSETS se consulta al adaptador y se pasa al dominio como
  # un dato más. El dominio decide; aquí solo se informa de lo que hay.
  local offcap
  offcap="$(_oc_offcap "$bus")"; rc=$?
  [ "$rc" -eq 124 ] && { log_err "la consulta de offsets se colgó; ABORTO sin reintentar."; return 124; }

  # Validación: los avisos se muestran, los errores abortan ANTES de escribir.
  local msgs
  msgs="$(domain_oc_validate "$pmin" "$pmax" "$gmax" "$mmax" "$gmin" "$mmin" "$offcap")"; rc=$?
  [ -n "$msgs" ] && printf '%s\n' "$msgs" | while IFS= read -r m; do log_warn "$m"; done
  [ "$rc" -ne 0 ] && { log_err "perfil '$profile' inválido; no se ha tocado nada."; return 2; }

  plan="$(domain_oc_plan "$pmin" "$pmax" "$gmax" "$mmax" "$gmin" "$mmin" "$offcap")"
  [ -z "$plan" ] && { log_info "perfil '$profile': nada que aplicar."; return 0; }

  # --- GATE DE VERIFICACIÓN, ANTES de escribir nada --------------------------
  # Se comprueba aquí y no después de aplicar a propósito: descubrir que no hay
  # verificador CON el offset ya puesto dejaría la tarjeta en un estado que
  # nadie puede afirmar que sea correcto.
  local verify_mode
  verify_mode="$(domain_oc_verify_required)"
  if [ "$verify_mode" = "gemm" ] && [ "${AORUS_OC_DRYRUN:-0}" != "1" ]; then
    if _oc_is_unattended; then
      log_err "GATE de verificación: '$profile' pide offsets POSITIVOS y esta es una ejecución DESATENDIDA (udev/servicio)."
      log_err "Un offset positivo exige medir que la GPU sigue calculando bien, y en un arranque nadie leería el resultado."
      log_err "Aplícalo a mano:  sudo aorus-egpu-oc apply $profile"
      _oc_verify_log "profile=$profile bus=$bus gate=desatendido veredicto=rechazado"
      return 2
    fi
    if ! verify_available; then
      log_err "GATE de verificación: no hay verificador numérico disponible (falta torch/CUDA en \$AORUS_VERIFY_PYTHON)."
      log_err "Sin evidencia no se escribe: un offset positivo falla CALCULANDO MAL, no cayéndose."
      log_err "--force NO abre este gate. Un enlace degradado es un riesgo que puedes evaluar y asumir;"
      log_err "un número mal calculado no lo puedes ni detectar, así que no lo puedes consentir."
      _oc_verify_log "profile=$profile bus=$bus gate=verificador-ausente veredicto=rechazado"
      return 2
    fi
  fi

  log_info "aplicando perfil '$profile' a la eGPU $bus (enlace $link_verdict: $link_info):"
  if [ "${AORUS_OC_DRYRUN:-0}" = "1" ]; then
    printf '%s\n' "$plan" | while IFS=$'\t' read -r op a b; do
      log_info "  [dry-run] $op ${a:-} ${b:-}"; done
    return 0
  fi

  printf '%s\n' "$plan" | oc_execute_plan "$bus"; rc=$?

  # Verificación post-aplicación: si la eGPU dejó de responder, revertir. Un
  # perfil que tumba la tarjeta no debe sobrevivir a un reinicio del servicio.
  # Prueba de vida tras aplicar. OJO con el rc: un 124 significa que nvidia-smi
  # se colgó, y entonces un "revert de emergencia" son DOS invocaciones más
  # contra una tarjeta que ya no responde — el martilleo que CLAUDE.md prohíbe
  # y que deja el dispositivo wedged en estado-D. Antes se revertía en los dos
  # casos por usar `if ! gpu_state ...`, que no distingue 124 de "respondió
  # mal".
  local srefresh_rc
  gpu_state "$bus" >/dev/null 2>&1; srefresh_rc=$?
  if [ "$srefresh_rc" -eq 124 ] || [ "$rc" -eq 124 ]; then
    log_err "nvidia-smi está colgado; NO reverto para no seguir martilleando la tarjeta."
    log_err "El perfil puede haber quedado a medias. Revisa con 'aorus-egpu-oc status'"
    log_err "cuando la tarjeta responda, y usa 'aorus-egpu-oc reset' entonces."
    return 124
  fi
  if [ "$srefresh_rc" -ne 0 ]; then
    log_err "la eGPU no responde tras aplicar el perfil; REVIRTIENDO a fábrica."
    _oc_revert_to_stock "$bus" || log_err "el reset de emergencia también falló."
    return 1
  fi

  # --- verificación numérica: aplicar -> VERIFICAR -> revertir si falla -------
  # El state file se escribe DESPUÉS de esto, nunca antes: un perfil que no ha
  # pasado la verificación no puede sobrevivir a un reinicio del servicio.
  if [ "$verify_mode" = "gemm" ]; then
    local vout vrc
    log_info "verificando integridad numérica (${AORUS_OC_VERIFY_SECONDS}s de GEMM bit-exacto + patrón en VRAM)..."
    vout="$(verify_numeric_integrity "$bus" "$AORUS_OC_VERIFY_SECONDS")"; vrc=$?
    case "$vrc" in
      0)
        log_info "  verificación OK ($vout)."
        _oc_verify_log "profile=$profile bus=$bus verify=gemm veredicto=pasa $vout" ;;
      124)
        # NO se revierte. Revertir son dos escrituras más contra una tarjeta
        # que ya no responde: martillear un eGPU semi-roto lo deja wedged en
        # estado-D. Mismo criterio que el gpu_state post-apply de arriba.
        log_err "el verificador se COLGÓ (rc=124). NO reverto para no seguir martilleando la tarjeta."
        log_err "El offset puede estar aplicado. Cuando la tarjeta responda: 'sudo aorus-egpu-oc reset'."
        _oc_verify_log "profile=$profile bus=$bus verify=gemm veredicto=colgado sin-revertir"
        return 124 ;;
      *)
        # rc 1 = calculó mal; rc 2 = el verificador dejó de estar disponible a
        # mitad. En los dos casos falta la evidencia que autorizaba el offset,
        # así que se vuelve a stock YA y no se persiste nada.
        log_err "VERIFICACIÓN FALLIDA (rc=$vrc, $vout): revirtiendo a stock AHORA."
        _oc_verify_log "profile=$profile bus=$bus verify=gemm veredicto=falla rc=$vrc $vout"
        _oc_revert_to_stock "$bus"
        log_err "el perfil '$profile' NO se ha persistido: no sobrevivirá a un reinicio del servicio."
        log_err "Detalle en $AORUS_OC_VERIFY_LOG"
        return 1 ;;
    esac
  fi

  mkdir -p "$(dirname "$AORUS_OC_STATE")" 2>/dev/null || true
  printf 'profile=%s\nbus=%s\napplied=%s\nverify=%s\n' \
    "$profile" "$bus" "$(date -Is)" "$verify_mode" \
    > "$AORUS_OC_STATE" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then
    log_info "perfil '$profile' aplicado."
  else
    log_warn "perfil aplicado con errores."
  fi
  return "$rc"
}

# --- caso de uso: reset -------------------------------------------------------
oc_reset() {
  local bus resolved rc
  resolved="$(oc_resolve_target)" || return $?
  bus="${resolved%%$'\t'*}"   # primer campo: el bus-id
  log_info "reseteando la eGPU $bus a valores de fábrica"
  gpu_reset_all "$bus"; rc=$?
  [ "$rc" -eq 124 ] && { log_err "nvidia-smi se colgó durante el reset; ABORTO sin reintentar."; return 124; }
  [ "$rc" -ne 0 ] && { log_err "el reset falló."; return 1; }
  # Los offsets NVML no son relojes bloqueados ni power limit, así que
  # gpu_reset_all no los toca: sin esto, un `apt remove` (que llama a este
  # mismo reset desde el prerm) dejaría la tarjeta con el offset puesto.
  _oc_zero_offsets "$bus"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && { log_err "los relojes volvieron a fábrica pero los offsets NO."; return 1; }
  rm -f "$AORUS_OC_STATE" 2>/dev/null || true
  log_info "hecho."
}

# --- caso de uso: verify ------------------------------------------------------
# Mide la integridad numérica de la eGPU TAL COMO ESTÁ ahora, sin cambiar nada.
#
# OJO: esto NO pasa por el gate en modo solo-lectura. Un GEMM sostenido más un
# llenado de la VRAM es la carga más intrusiva que genera este paquete, así que
# con el enlace degradado, muerto o ilegible el gate tiene que cerrar igual que
# para una escritura. 'status' sí es solo lectura; esto no.
oc_verify() { # $1=segundos (opcional)
  local secs="${1:-$AORUS_OC_VERIFY_SECONDS}" resolved bus out rc
  if ! domain_oc_is_uint "$secs" || [ "$secs" -le 0 ]; then
    log_err "los segundos de verificación deben ser un entero positivo (recibí '$secs')."
    return 2
  fi
  resolved="$(oc_resolve_target)" || return $?
  bus="${resolved%%$'\t'*}"
  if ! verify_available; then
    log_err "no hay verificador numérico disponible."
    log_err "Necesita un python con torch+CUDA; indícalo con AORUS_VERIFY_PYTHON si vive en un venv:"
    log_err "  sudo AORUS_VERIFY_PYTHON=~/.venvs/egpu-torch-test/bin/python aorus-egpu-oc verify"
    return 2
  fi
  log_info "verificando la eGPU $bus durante ${secs}s (GEMM bit-exacto + patrón en VRAM)..."
  out="$(verify_numeric_integrity "$bus" "$secs")"; rc=$?
  case "$rc" in
    0)   log_info "VERIFICACIÓN OK ($out): la GPU calcula bien."
         _oc_verify_log "bus=$bus verify=manual veredicto=pasa $out" ;;
    124) log_err "el verificador se COLGÓ (rc=124). No reintento."
         _oc_verify_log "bus=$bus verify=manual veredicto=colgado" ;;
    2)   log_err "el verificador dejó de estar disponible a mitad; sin evidencia."
         _oc_verify_log "bus=$bus verify=manual veredicto=no-disponible" ;;
    *)   log_err "VERIFICACIÓN FALLIDA ($out): la GPU está calculando MAL."
         log_err "Si tienes un perfil con offsets aplicado, quítalo: sudo aorus-egpu-oc reset"
         _oc_verify_log "bus=$bus verify=manual veredicto=falla $out" ;;
  esac
  return "$rc"
}

# --- caso de uso: status ------------------------------------------------------
oc_status() {
  local bus caps pmin pmax gmax mmax gmin mmin resolved link_verdict link_info
  # `status` es SOLO LECTURA y debe informar del estado incluso -sobre todo-
  # cuando el enlace no está sano. Se marca como tal en vez de simular un
  # --force: antes el mensaje decía "--force activo: continúo BAJO TU RIESGO"
  # a quien no había pasado ningún flag y no corría ningún riesgo.
  resolved="$(AORUS_OC_READONLY=1 oc_resolve_target)" || return $?
  IFS=$'\t' read -r bus link_verdict link_info <<< "$resolved"
  caps="$(gpu_caps "$bus")" || { log_err "no puedo leer capacidades."; return 1; }
  read -r pmin pmax gmax mmax gmin mmin <<< "$caps"
  log_info "eGPU:            $bus"
  log_info "enlace:          $link_verdict ($link_info)"
  log_info "power limit:     ${pmin}-${pmax} W (rango soportado)"
  log_info "reloj máx:       ${gmax} MHz gráfico / ${mmax} MHz memoria"
  log_info "reloj mín:       ${gmin:-?} MHz gráfico / ${mmin:-?} MHz memoria"
  # La capacidad de offsets se INFORMA, no se promete: lo que diga aquí el
  # adaptador es lo mismo que decidirá si un perfil con offsets se acepta.
  local offcap ocg ocm
  offcap="$(_oc_offcap "$bus")"
  if domain_oc_offcap_supported "$offcap"; then
    ocg="$(domain_oc_offcap_window "$offcap" gpu)"
    ocm="$(domain_oc_offcap_window "$offcap" mem)"
    log_info "offsets:         sí (NVML) — ventana gráfico [${ocg// /,}] MHz / memoria [${ocm// /,}] MHz"
  else
    log_info "offsets:         no disponibles con este adaptador (perfiles con offset se rechazan)"
  fi
  log_info "--- estado actual ---"
  gpu_state "$bus" | while IFS= read -r l; do log_info "$l"; done
  if [ -r "$AORUS_OC_STATE" ]; then
    log_info "--- perfil aplicado ---"
    while IFS= read -r l; do log_info "$l"; done < "$AORUS_OC_STATE"
  else
    log_info "perfil aplicado: ninguno (valores de fábrica)"
  fi
}

oc_list_profiles() {
  local f n
  log_info "perfiles disponibles en $AORUS_OC_PROFILE_DIR:"
  shopt -s nullglob
  for f in "$AORUS_OC_PROFILE_DIR"/*.profile; do
    n="$(basename "$f" .profile)"
    log_info "  $n — $(sed -n 's/^#[[:space:]]*desc:[[:space:]]*//p' "$f" | head -1)"
  done
  shopt -u nullglob
}
