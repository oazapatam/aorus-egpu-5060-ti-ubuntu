#!/usr/bin/env bash
# app/health.sh — detectar y REGISTRAR los incidentes de salud de la eGPU.
#
# EL PROBLEMA QUE RESUELVE: el 2026-11-02 a las 13:31:53 la eGPU sufrió un
# Xid 79 ("GPU has fallen off the bus") y NADA avisó. Se descubrió a mano
# rebuscando en `dmesg`, dos horas después. Con una carga servida encima
# (vLLM), eso son dos horas sirviendo errores sin saber por qué.
#
# Y la pregunta que de verdad importaba —¿falló la GPU, o se cayó la caja
# entera?— exigió correlacionar timestamps de USB, PCIe, Thunderbolt y NVRM a
# ojo. Esa correlación es la regla de domain/health.sh; aquí se orquesta:
# leer (puerto kevents) -> clasificar (domain) -> agrupar -> registrar.
#
# AGRUPAR ES LO QUE LO HACE LEGIBLE: el incidente real emitió 237 mensajes
# NVRM en 200 ms. Reportarlos uno a uno es el ruido del que veníamos. Un
# incidente = una línea con un veredicto.

# shellcheck shell=bash

aorus_use domain/health domain/target
aorus_use ports/kevents.port ports/log.port
aorus_adapter kevents adapters/kevents/journalctl
aorus_adapter log     adapters/log/stderr

: "${AORUS_HEALTH_DIR:=/var/log/aorus-egpu/health}"
# Ventana de agrupación. El incidente real duró 1,1 s desde el USB disconnect
# hasta la última reasignación de BAR, y egpu-tb-fix cerró la recuperación 16 s
# después. 30 s captura el incidente COMPLETO, recuperación incluida.
: "${AORUS_HEALTH_WINDOW:=30}"
# Cada cuánto despierta el modo watch cuando no llega nada. Acota lo que tarda
# en cerrarse un incidente cuyo último evento ya pasó: sin esto, un incidente
# quedaría abierto hasta el SIGUIENTE evento del kernel, que puede no llegar en
# horas, y el aviso no saldría.
: "${AORUS_HEALTH_TICK:=5}"

# ---------------------------------------------------------------------------
# Acumulador de incidente.
#
# Lo comparten `health_scan` (lee el pasado) y `health_watch` (sigue el
# presente). Vive aquí, en una sola copia, porque es la misma regla: si cada
# modo agrupara a su manera, el registro histórico y el aviso en vivo podrían
# contradecirse sobre el MISMO incidente.
#
# El estado es GLOBAL y se muta en el proceso actual a propósito. Ver el
# comentario de _health_acc_emit: hacerlo con sustitución de comandos fue un
# bug real que corrompió todos los veredictos.
# ---------------------------------------------------------------------------
_HEALTH_CLASSES=() _HEALTH_START="" _HEALTH_LAST="" _HEALTH_BDF="" _HEALTH_LINE=""

_health_acc_reset() { _HEALTH_CLASSES=(); _HEALTH_START=""; _HEALTH_BDF=""; }

_health_acc_open() { [ "${#_HEALTH_CLASSES[@]}" -gt 0 ]; }

# ¿La ventana del grupo abierto ya se cerró respecto a <ahora>?
_health_acc_expired() { # $1=ahora $2=ventana
  _health_acc_open || return 1
  [ $(( ${1:-0} - _HEALTH_LAST )) -gt "${2:-$AORUS_HEALTH_WINDOW}" ]
}

_health_acc_add() { # $1=segundos $2=clase $3=mensaje
  [ -n "$_HEALTH_START" ] || _HEALTH_START="$1"
  _HEALTH_LAST="$1"
  _HEALTH_CLASSES+=("$2")
  # El BDF solo viene en las líneas de Xid; se guarda el primero que aparezca.
  if [ -z "$_HEALTH_BDF" ]; then
    _HEALTH_BDF="$(domain_health_xid_bdf "$3" 2>/dev/null || true)"
  fi
}

# Colapsa clases repetidas conservando el ORDEN de primera aparición y el
# conteo: "gpu_lost x25". El incidente real emitió 237 mensajes NVRM en 200 ms
# y listarlos uno a uno es exactamente el ruido del que veníamos. El orden
# importa porque el PRIMER evento es la pista de la causa raíz.
_health_squash() { # $@=clases en orden
  local c prev="" n=0 out=""
  for c in "$@"; do
    if [ "$c" = "$prev" ]; then
      n=$((n + 1))
    else
      if [ -n "$prev" ]; then
        if [ "$n" -gt 1 ]; then out="$out$prev x$n,"; else out="$out$prev,"; fi
      fi
      prev="$c"; n=1
    fi
  done
  if [ -n "$prev" ]; then
    if [ "$n" -gt 1 ]; then out="$out$prev x$n,"; else out="$out$prev,"; fi
  fi
  printf '%s' "${out%,}"
}

# Cierra el incidente acumulado: deja la línea en _HEALTH_LINE y resetea.
# Devuelve 0 si hay incidente que reportar, 1 si no.
#
# ASIGNA EN VEZ DE IMPRIMIR, y no es una optimización. Capturar su salida con
# una sustitución de comandos la ejecutaba en un SUBSHELL, así que el
# `_health_acc_reset` de dentro nunca llegaba al proceso padre y el acumulador
# no se vaciaba jamás. Medido el 2026-11-02 sobre 13 días de journal: los 13
# incidentes salían con el MISMO instante de inicio, `dur` creciendo hasta
# 929465 s, el BDF de la GPU INTERNA pegado del primer evento de la serie, y
# 5 `tb_device_loss` donde solo hay 2.
#
# Un veredicto 'healthy' -ventana de solo eventos de conexión, el arranque
# normal- no se reporta, para que el recuento de incidentes no mienta.
_health_acc_emit() { # -> _HEALTH_LINE
  _HEALTH_LINE=""
  _health_acc_open || return 1
  local verdict rec stamp
  verdict="$(domain_health_incident_verdict "${_HEALTH_CLASSES[@]}")"
  if [ "$verdict" = healthy ]; then _health_acc_reset; return 1; fi
  if domain_health_incident_recovered "${_HEALTH_CLASSES[@]}"; then rec=si; else rec=no; fi
  stamp="$(date -d "@$_HEALTH_START" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
           || printf '@%s' "$_HEALTH_START")"
  _HEALTH_LINE="$stamp | dur=$(( _HEALTH_LAST - _HEALTH_START ))s | veredicto=$verdict"
  _HEALTH_LINE="$_HEALTH_LINE | recuperado=$rec | bdf=${_HEALTH_BDF:-n/a}"
  _HEALTH_LINE="$_HEALTH_LINE | eventos=$(_health_squash "${_HEALTH_CLASSES[@]}")"
  _health_acc_reset
}

# ---------------------------------------------------------------------------
# Persistencia y explicación
# ---------------------------------------------------------------------------

# Escribe una línea en el registro persistente, con fsync.
# Sin fsync no sirve de nada: el caso que queremos registrar es justo el que
# puede acabar en un cuelgue duro, y entonces el buffer se pierde.
health_record() { # $1=linea
  local f="$AORUS_HEALTH_DIR/incidents.log"
  mkdir -p "$AORUS_HEALTH_DIR" 2>/dev/null || return 1
  printf '%s\n' "$1" >> "$f" || return 1
  sync -f "$f" 2>/dev/null || sync
}

# Explica un veredicto en una línea. Lo que hace el registro accionable:
# "tb_device_loss" no le dice nada a nadie a las 3 de la mañana.
health_explain() { # $1=veredicto
  case "${1:-}" in
    tb_device_loss)
      printf 'el dispositivo Thunderbolt ENTERO desapareció (USB y PCIe a la vez); la GPU es la víctima. Mirar túnel, energía, cable y ASPM/runtime PM del camino, NO la GPU.' ;;
    pcie_link_loss)
      printf 'cayó la rama PCIe de la eGPU pero el USB de la caja siguió vivo; mirar el puente/puerto de esa rama.' ;;
    gpu_fault)
      printf 'Xid de pérdida con el bus INTACTO: la GPU o el driver fallaron por su cuenta.' ;;
    degraded)
      printf 'avisos sin pérdida del dispositivo; vigilar, no actuar.' ;;
    healthy)
      printf 'sin incidentes.' ;;
    *)
      printf 'veredicto desconocido.' ;;
  esac
}

# Extrae el veredicto de una línea de registro. Existe para que watch y
# scan_and_record no repitan el parseo cada uno a su manera.
health_line_verdict() { # $1=linea
  local v="${1#*veredicto=}"; printf '%s' "${v%% *}"
}

# ¿Este veredicto es crítico? Único sitio donde se decide, para que la sonda
# (`check`), el servicio (`watch`) y el listado (`scan`) no discrepen.
health_verdict_is_critical() { # $1=veredicto
  case "${1:-}" in
    tb_device_loss|pcie_link_loss|gpu_fault) return 0 ;;
    *) return 1 ;;
  esac
}

# Registra + avisa una línea ya formada. Devuelve 1 si es crítica.
health_report_line() { # $1=linea
  local verdict; verdict="$(health_line_verdict "$1")"
  health_record "$1"
  if health_verdict_is_critical "$verdict"; then
    log_err "incidente eGPU: $1"
    log_err "  -> $(health_explain "$verdict")"
    return 1
  fi
  log_warn "eGPU degradada: $1"
  return 0
}

# ---------------------------------------------------------------------------
# Casos de uso
# ---------------------------------------------------------------------------

# Recorre los eventos desde <desde> y emite un incidente por grupo.
# Imprime una línea por incidente; devuelve 1 si hubo alguno CRÍTICO.
health_scan() { # $1=desde [$2=ventana]
  local since="${1:-boot}" window="${2:-$AORUS_HEALTH_WINDOW}"
  local epoch msg class sec found_critical=0
  _health_acc_reset; _HEALTH_LAST=""
  while IFS=$'\t' read -r epoch msg; do
    domain_health_classify_var "$msg"; class="$AORUS_HEALTH_CLASS"
    [ "$class" = none ] && continue
    sec="${epoch%.*}"
    if _health_acc_expired "$sec" "$window"; then
      if _health_acc_emit; then
        printf '%s\n' "$_HEALTH_LINE"
        health_verdict_is_critical "$(health_line_verdict "$_HEALTH_LINE")" \
          && found_critical=1
      fi
    fi
    _health_acc_add "$sec" "$class" "$msg"
  done < <(kevents_read "$since")
  if _health_acc_emit; then
    printf '%s\n' "$_HEALTH_LINE"
    health_verdict_is_critical "$(health_line_verdict "$_HEALTH_LINE")" \
      && found_critical=1
  fi
  return "$found_critical"
}

# Igual que health_scan pero registrando en disco y avisando por el puerto log.
health_scan_and_record() { # $1=desde
  local reported rc=0
  while IFS= read -r reported; do
    [ -n "$reported" ] || continue
    health_report_line "$reported" || rc=1
  done < <(health_scan "${1:-boot}")
  return "$rc"
}

# Sigue el journal y registra cada incidente en cuanto se cierra su ventana.
# BLOQUEANTE: es el modo del servicio systemd.
#
# El `read -t` es lo que hace que un incidente se cierre a tiempo. Sin
# timeout, el último incidente quedaría abierto hasta el siguiente evento del
# kernel —que puede tardar horas— y el aviso llegaría cuando ya no sirve.
health_watch() { # [$1=ventana]
  local window="${1:-$AORUS_HEALTH_WINDOW}"
  local epoch msg class sec now rc
  _health_acc_reset; _HEALTH_LAST=""
  log_info "aorus-egpu-health: vigilando (ventana ${window}s, tick ${AORUS_HEALTH_TICK}s)"
  while :; do
    if IFS=$'\t' read -r -t "$AORUS_HEALTH_TICK" epoch msg; then
      domain_health_classify_var "$msg"; class="$AORUS_HEALTH_CLASS"
      [ "$class" = none ] && continue
      sec="${epoch%.*}"
      if _health_acc_expired "$sec" "$window"; then
        _health_acc_emit && health_report_line "$_HEALTH_LINE"
      fi
      _health_acc_add "$sec" "$class" "$msg"
    else
      rc=$?
      # read falla por TIMEOUT (rc>128) o porque la tubería se cerró.
      # Distinguirlos importa: si journalctl muere, el servicio debe terminar
      # para que systemd lo reinicie, no girar en vacío creyendo que todo está
      # en calma y dejar de vigilar en silencio.
      if [ "$rc" -gt 128 ]; then
        now="$(date +%s)"
        if _health_acc_expired "$now" "$window"; then
          _health_acc_emit && health_report_line "$_HEALTH_LINE"
        fi
      else
        log_warn "la fuente de eventos se cerró; terminando para que systemd reinicie"
        return 75
      fi
    fi
  done < <(kevents_follow)
}
