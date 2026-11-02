#!/usr/bin/env bash
# adapters/drm/sysfs.sh — implementación del puerto DRM sobre /sys/class/drm.
#
# Es el único sitio de esta capacidad que hace I/O. Todo lo que decide está en
# domain/display.sh.
#
# Nota de lectura: un conector DRM aparece como card<N>-<CONECTOR> (por ejemplo
# card2-eDP-1), y su fichero `status` dice connected|disconnected|unknown. El
# `enabled` dice si el compositor le ha puesto un modo. Para el gate sólo
# importa `status`: una salida conectada es una pantalla que el usuario ve.

# shellcheck shell=bash

AORUS_DRM_ROOT="${AORUS_DRM_ROOT:-/sys/class/drm}"

drm_available() { [ -d "$AORUS_DRM_ROOT" ]; }

# Sólo las tarjetas (cardN), no los conectores (cardN-XXX) ni los render nodes.
drm_cards() {
  local p n
  for p in "$AORUS_DRM_ROOT"/card[0-9] "$AORUS_DRM_ROOT"/card[0-9][0-9]; do
    [ -d "$p" ] || continue
    n="$(basename "$p")"
    printf '%s\n' "$n"
  done | sort -V
}

drm_card_driver() { # $1=cardN
  local link
  link="$(readlink -f "$AORUS_DRM_ROOT/$1/device/driver" 2>/dev/null)" || return 1
  [ -n "$link" ] || return 1
  basename "$link"
}

drm_card_bdf() { # $1=cardN
  local link
  link="$(readlink -f "$AORUS_DRM_ROOT/$1/device" 2>/dev/null)" || return 1
  case "$link" in
    *:*:*) basename "$link" ;;
    *) return 1 ;;
  esac
}

# Un conector por línea: "<nombre> <status> <enabled>".
drm_card_outputs() { # $1=cardN
  local c name
  for c in "$AORUS_DRM_ROOT/$1"-*; do
    [ -r "$c/status" ] || continue
    name="$(basename "$c")"
    printf '%s %s %s\n' "${name#"$1"-}" \
      "$(cat "$c/status" 2>/dev/null || echo unknown)" \
      "$(cat "$c/enabled" 2>/dev/null || echo unknown)"
  done
}

# Cuántas salidas CONECTADAS tiene. Es la entrada del gate de domain/display,
# así que ante cualquier duda imprime algo que el dominio pueda rechazar en vez
# de un cero tranquilizador: si no se puede leer, no imprime nada y el dominio
# lo traduce a 'unknown'.
drm_card_connected() { # $1=cardN
  [ -d "$AORUS_DRM_ROOT/$1" ] || return 1
  drm_card_outputs "$1" | awk '$2 == "connected"' | wc -l
}
