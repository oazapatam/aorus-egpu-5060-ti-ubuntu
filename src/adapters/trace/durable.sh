#!/usr/bin/env bash
# adapters/trace/durable.sh — traza forense que sobrevive a un cuelgue duro.
#
# Tres destinos a la vez, porque cada uno falla de una forma distinta:
#   1. FICHERO en disco con fsync   -> sobrevive al cuelgue. Es el que importa.
#   2. journald (systemd-cat)       -> correlaciona con los mensajes del kernel
#                                      (se pierde si no llegó a disco).
#   3. /dev/kmsg                    -> entra en el buffer del kernel, así que
#                                      lo recoge ramoops/pstore si hay panic.
#
# El punto 3 es lo que hace que la traza aparezca TAMBIÉN en el volcado de
# pstore tras el reinicio, sin depender de que journald haya sincronizado.

# shellcheck shell=bash

AORUS_TRACE_ROOT="${AORUS_TRACE_ROOT:-/var/log/aorus-egpu/traces}"
AORUS_TRACE_DIR=""

# Escribe en el buffer del kernel, que es lo que recoge ramoops/pstore si hay
# panic. Requiere root: sin privilegios se omite en silencio (las migas en
# disco, que son la garantía principal, no dependen de esto).
#
# El `2>/dev/null` va ANTES del redirect a propósito: bash procesa las
# redirecciones de izquierda a derecha, así que al revés el error de abrir
# /dev/kmsg se imprimiría antes de silenciarse.
_kmsg() {
  [ -w /dev/kmsg ] || return 0
  printf '%s\n' "$*" 2>/dev/null > /dev/kmsg || true
}

# IMPORTANTE: exporta AORUS_TRACE_DIR, así que NO puede llamarse en subshell.
# Ver la nota en ports/trace.port.sh.
trace_begin() { # $1=nombre de sesión -> imprime el directorio de la traza
  local name="${1:-probe}" stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  AORUS_TRACE_DIR="$AORUS_TRACE_ROOT/${stamp}-${name}"
  mkdir -p "$AORUS_TRACE_DIR"

  {
    printf 'sesion:   %s\n' "$name"
    printf 'inicio:   %s\n' "$(date -Is)"
    printf 'kernel:   %s\n' "$(uname -r)"
    printf 'cmdline:  %s\n' "$(cat /proc/cmdline)"
    printf 'boot_id:  %s\n' "$(cat /proc/sys/kernel/random/boot_id)"
    printf 'driver:   %s\n' "$(head -1 /proc/driver/nvidia/version 2>/dev/null)"
  } > "$AORUS_TRACE_DIR/00-meta.txt"
  sync "$AORUS_TRACE_DIR/00-meta.txt" 2>/dev/null || sync

  # Marca el punto de partida en el buffer del kernel: permite recortar
  # exactamente el tramo relevante en el postmortem.
  _kmsg "AORUS-TRACE BEGIN $name $stamp"
  printf '%s' "$AORUS_TRACE_DIR"
}

# El corazón del adaptador. NO retorna hasta que el dato está en disco.
trace_mark() { # $1=paso $2=detalle opcional
  local step="${1:-?}" detail="${2:-}" line
  [ -n "$AORUS_TRACE_DIR" ] || return 0
  line="$(date -Is) | $(awk '{printf "%.3f", $1}' /proc/uptime) | $step | $detail"
  printf '%s\n' "$line" >> "$AORUS_TRACE_DIR/10-breadcrumbs.log"
  # fsync del fichero concreto; si coreutils no soporta `sync FILE`, sync global
  # (más lento, igual de seguro).
  sync "$AORUS_TRACE_DIR/10-breadcrumbs.log" 2>/dev/null || sync
  _kmsg "AORUS-TRACE $step $detail"
  if command -v systemd-cat >/dev/null 2>&1; then
    printf '%s\n' "$step $detail" | systemd-cat -t aorus-egpu-trace 2>/dev/null || true
  fi
  return 0
}

# Estado del hardware en un instante concreto. Solo lecturas baratas: un
# `lspci -vv` completo sobre un bus medio roto puede colgarse, y colgarse
# DENTRO de la herramienta de diagnóstico es el peor resultado posible.
trace_snapshot() { # $1=nombre del snapshot
  local name="${1:-snap}" out bdf d
  [ -n "$AORUS_TRACE_DIR" ] || return 0
  out="$AORUS_TRACE_DIR/20-snapshot-$name.txt"
  {
    printf '== %s @ %s (uptime %s) ==\n' "$name" "$(date -Is)" "$(cut -d' ' -f1 /proc/uptime)"
    for bdf in /sys/bus/pci/devices/*; do
      [ "$(cat "$bdf/vendor" 2>/dev/null)" = "0x10de" ] || continue
      printf -- '-- %s --\n' "$(basename "$bdf")"
      printf '  device=%s driver=%s\n' \
        "$(cat "$bdf/device" 2>/dev/null)" \
        "$(basename "$(readlink -f "$bdf/driver" 2>/dev/null)" 2>/dev/null)"
      printf '  link=%s x%s  power=%s  runtime=%s\n' \
        "$(cat "$bdf/current_link_speed" 2>/dev/null)" \
        "$(cat "$bdf/current_link_width" 2>/dev/null)" \
        "$(cat "$bdf/power/control" 2>/dev/null)" \
        "$(cat "$bdf/power/runtime_status" 2>/dev/null)"
    done
    printf -- '-- thunderbolt --\n'
    for d in /sys/bus/thunderbolt/devices/*; do
      [ -r "$d/authorized" ] || continue
      printf '  %s authorized=%s\n' "$(basename "$d")" "$(cat "$d/authorized")"
    done
  } > "$out" 2>&1
  sync "$out" 2>/dev/null || sync
  return 0
}

trace_end() { # $1=estado
  [ -n "$AORUS_TRACE_DIR" ] || return 0
  {
    printf 'fin:      %s\n' "$(date -Is)"
    printf 'estado:   %s\n' "${1:-desconocido}"
  } >> "$AORUS_TRACE_DIR/00-meta.txt"
  sync "$AORUS_TRACE_DIR/00-meta.txt" 2>/dev/null || sync
  _kmsg "AORUS-TRACE END ${1:-?}"
  # journald a disco: si el cuelgue llega después, el journal ya está salvado.
  if command -v journalctl >/dev/null 2>&1; then journalctl --sync 2>/dev/null || true; fi
  return 0
}
