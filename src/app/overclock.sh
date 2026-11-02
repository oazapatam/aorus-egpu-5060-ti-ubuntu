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
#   3. link : el enlace debe estar SANO (Gen>=3). Apretar la tarjeta con el
#             enlace Gen1 marginal congeló el host entero el 2026-06-27.
#   4. smi  : si nvidia-smi se cuelga (rc 124), ABORTAR sin reintentar.
# Ningún gate se puede saltar con un flag: --force solo relaja el gate de enlace
# y lo deja registrado, porque es el único cuyo riesgo es del usuario y no un bug.

# shellcheck shell=bash

aorus_use domain/target domain/link domain/overclock
aorus_use ports/gpu.port ports/pci.port ports/log.port
aorus_adapter gpu adapters/gpu/nvidia-smi
aorus_adapter pci adapters/pci/sysfs
aorus_adapter log adapters/log/stderr

# Nota: /etc/aorus-egpu/overclock.conf NO se lee aquí a propósito — lo consume
# systemd con EnvironmentFile= y nos pasa el perfil como argumento. Declararlo
# en esta capa sería una segunda fuente de verdad.
AORUS_OC_PROFILE_DIR="${AORUS_OC_PROFILE_DIR:-/etc/aorus-egpu/profiles}"
AORUS_OC_STATE="${AORUS_OC_STATE:-/run/aorus-egpu/overclock.state}"

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

  link="$(pci_read_link "$bdf")"; speed="${link%%|*}"; width="${link##*|}"
  local link_verdict; link_verdict="$(domain_link_verdict "$speed" "$width")"
  if [ "$link_verdict" != "healthy" ]; then
    if [ "${AORUS_OC_FORCE:-0}" = "1" ]; then
      log_warn "enlace $link_verdict (${speed:-?} x${width:-?}) y --force activo: continúo BAJO TU RIESGO."
    else
      log_err "GATE de enlace: enlace $link_verdict (${speed:-?} x${width:-?})."
      log_err "Apretar la eGPU con el enlace degradado ha congelado el host. Usa --force si lo asumes."
      return 2
    fi
  fi

  bus="$(gpu_find_by_device_id "$AORUS_EGPU_DEVICE")"; local rc=$?
  [ "$rc" -eq 124 ] && { log_err "nvidia-smi se colgó; ABORTO sin reintentar."; return 124; }
  [ "$rc" -ne 0 ] && { log_err "la eGPU está en PCI ($bdf) pero nvidia no la publica."; return 1; }
  printf '%s\t%s' "$bus" "$link_verdict"
}

# --- ejecutor del plan --------------------------------------------------------
oc_execute_plan() { # $1=busid; plan por stdin
  local bus="$1" op a b rc=0
  while IFS=$'\t' read -r op a b; do
    case "$op" in
      power_limit) log_info "  power limit -> ${a} W"
                   gpu_set_power_limit "$bus" "$a" || { log_err "  falló power limit"; rc=1; } ;;
      gpu_clock)   log_info "  reloj gráfico -> ${a}-${b} MHz"
                   gpu_set_gpu_clock "$bus" "$a" "$b" || { log_err "  falló lock de reloj gráfico"; rc=1; } ;;
      mem_clock)   log_info "  reloj memoria -> ${a} MHz"
                   gpu_set_mem_clock "$bus" "$a" || { log_err "  falló lock de reloj memoria"; rc=1; } ;;
      reset)       log_info "  reset a valores de fábrica"
                   gpu_reset_clocks "$bus" || { log_err "  falló el reset"; rc=1; } ;;
      '')          : ;;
      clock_offset) log_err "  clock_offset no tiene adaptador en este sistema"; rc=1 ;;
      *)           if domain_oc_op_is_valid "$op"; then
                     log_err "  operación '$op' válida pero sin implementar en el ejecutor"
                   else
                     log_err "  operación desconocida en el plan: $op"
                   fi
                   rc=1 ;;
    esac
  done
  return "$rc"
}

# --- caso de uso: aplicar -----------------------------------------------------
oc_apply() { # $1=perfil
  local profile="${1:-}" bus caps pmin pmax gmax mmax plan rc
  [ -n "$profile" ] || { log_err "falta el nombre del perfil"; return 2; }

  oc_load_profile "$profile" || return $?
  local resolved link_verdict
  resolved="$(oc_resolve_target)" || return $?
  bus="${resolved%%$'\t'*}"; link_verdict="${resolved##*$'\t'}"

  caps="$(gpu_caps "$bus")"; rc=$?
  [ "$rc" -eq 124 ] && { log_err "nvidia-smi se colgó leyendo capacidades; ABORTO."; return 124; }
  [ "$rc" -ne 0 ] && { log_err "no puedo leer las capacidades de la eGPU."; return 1; }
  read -r pmin pmax gmax mmax <<< "$caps"

  # Validación: los avisos se muestran, los errores abortan ANTES de escribir.
  local msgs
  msgs="$(domain_oc_validate "$pmin" "$pmax" "$gmax" "$mmax")"; rc=$?
  [ -n "$msgs" ] && printf '%s\n' "$msgs" | while IFS= read -r m; do log_warn "$m"; done
  [ "$rc" -ne 0 ] && { log_err "perfil '$profile' inválido; no se ha tocado nada."; return 2; }

  plan="$(domain_oc_plan "$pmin" "$pmax" "$gmax" "$mmax")"
  [ -z "$plan" ] && { log_info "perfil '$profile': nada que aplicar."; return 0; }

  log_info "aplicando perfil '$profile' a la eGPU $bus (enlace $link_verdict):"
  if [ "${AORUS_OC_DRYRUN:-0}" = "1" ]; then
    printf '%s\n' "$plan" | while IFS=$'\t' read -r op a b; do
      log_info "  [dry-run] $op ${a:-} ${b:-}"; done
    return 0
  fi

  printf '%s\n' "$plan" | oc_execute_plan "$bus"; rc=$?

  # Verificación post-aplicación: si la eGPU dejó de responder, revertir. Un
  # perfil que tumba la tarjeta no debe sobrevivir a un reinicio del servicio.
  if ! gpu_state "$bus" >/dev/null 2>&1; then
    log_err "la eGPU no responde tras aplicar el perfil; REVIRTIENDO a fábrica."
    gpu_reset_clocks "$bus" || log_err "el reset de emergencia también falló."
    return 1
  fi

  mkdir -p "$(dirname "$AORUS_OC_STATE")" 2>/dev/null || true
  printf 'profile=%s\nbus=%s\napplied=%s\n' "$profile" "$bus" "$(date -Is)" \
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
  local bus resolved
  resolved="$(oc_resolve_target)" || return $?
  bus="${resolved%%$'\t'*}"
  log_info "reseteando la eGPU $bus a valores de fábrica"
  gpu_reset_clocks "$bus" || { log_err "el reset falló."; return 1; }
  rm -f "$AORUS_OC_STATE" 2>/dev/null || true
  log_info "hecho."
}

# --- caso de uso: status ------------------------------------------------------
oc_status() {
  local bus caps pmin pmax gmax mmax resolved link_verdict
  # --force implícito: `status` es solo lectura y debe informar del estado
  # incluso (sobre todo) cuando el enlace está degradado.
  resolved="$(AORUS_OC_FORCE=1 oc_resolve_target)" || return $?
  bus="${resolved%%$'\t'*}"; link_verdict="${resolved##*$'\t'}"
  caps="$(gpu_caps "$bus")" || { log_err "no puedo leer capacidades."; return 1; }
  read -r pmin pmax gmax mmax <<< "$caps"
  log_info "eGPU:            $bus"
  log_info "enlace:          $link_verdict"
  log_info "power limit:     ${pmin}-${pmax} W (rango soportado)"
  log_info "reloj máx:       ${gmax} MHz gráfico / ${mmax} MHz memoria"
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
