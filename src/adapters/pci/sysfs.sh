#!/usr/bin/env bash
# adapters/pci/sysfs.sh — implementación del puerto PCI leyendo /sys.
#
# SOLO LECTURA. Las operaciones destructivas de bus (remove/rescan/SBR) NO están
# aquí a propósito: viven en aorus-egpu-fix-bar0, que está validado en vivo y
# serializado con flock. Un adaptador de lectura no debe poder congelar el host.

# shellcheck shell=bash

AORUS_PCI_ROOT="${AORUS_PCI_ROOT:-/sys/bus/pci/devices}"

pci_find_by_device_id() { # $1=device id (0x2d04) -> BDF
  local want d
  want="$(domain_norm_id "${1:-}")"
  for d in "$AORUS_PCI_ROOT"/*; do
    [ -r "$d/device" ] || continue
    [ "$(domain_norm_id "$(cat "$d/device")")" = "$want" ] || continue
    printf '%s' "$(basename "$d")"; return 0
  done
  return 1
}

pci_read_ids() { # $1=BDF -> "<vendor> <device>"
  local p="$AORUS_PCI_ROOT/$1"
  [ -r "$p/vendor" ] && [ -r "$p/device" ] || return 1
  printf '%s %s' "$(cat "$p/vendor")" "$(cat "$p/device")"
}

pci_read_link() { # $1=BDF -> "<speed>|<width>"
  local p="$AORUS_PCI_ROOT/$1"
  printf '%s|%s' "$(cat "$p/current_link_speed" 2>/dev/null)" \
                 "$(cat "$p/current_link_width" 2>/dev/null)"
}

pci_parent() { # $1=BDF -> BDF del bridge padre
  local real parent
  real="$(readlink -f "$AORUS_PCI_ROOT/$1" 2>/dev/null)" || return 1
  parent="$(basename "$(dirname "$real")")"
  case "$parent" in 0000:*) printf '%s' "$parent"; return 0 ;; esac
  return 1
}

# ¿Cuelga de un controlador Thunderbolt/USB4? Es la mitad topológica del gate R4:
# la eGPU está SIEMPRE detrás de TB, la interna NUNCA.
#
# NO se puede resolver subiendo el árbol buscando el driver `thunderbolt`: el
# túnel PCIe se presenta como una cadena de `pcieport` normales y el controlador
# TB (NHI) es un HERMANO, no un ancestro. En esta máquina la eGPU cuelga de
# 80:1b.4 -> 88:00.0 -> 89:03.0 -> b2:00.0 -> b3:00.0, y el NHI está en 8a:00.0,
# fuera de esa rama. Buscar hacia arriba da un falso negativo.
#
# La señal correcta es `removable`, la misma que usa la regla udev de
# egpu-tb-fix: el kernel marca "removable" los endpoints tras un puerto
# hot-pluggable (TB/USB4). La GPU interna NO TIENE ese fichero siquiera, así que
# el discriminador es nítido en ambos sentidos.
pci_is_behind_thunderbolt() { # $1=BDF
  local p="$AORUS_PCI_ROOT/$1"
  [ "$(cat "$p/removable" 2>/dev/null)" = "removable" ] && return 0
  # Respaldo: la MISMA señal `removable`, pero buscada hacia arriba en los
  # bridges padres. Cubre el caso de un kernel que marque el puerto hotplug
  # pero no el endpoint. No usa `is_hotplug_bridge`: no está expuesto en sysfs.
  local cur="$1" real hops=0
  while [ "$hops" -lt 12 ]; do
    cur="$(pci_parent "$cur")" || return 1
    real="$(readlink -f "$AORUS_PCI_ROOT/$cur" 2>/dev/null)" || return 1
    [ "$(cat "$real/removable" 2>/dev/null)" = "removable" ] && return 0
    hops=$((hops + 1))
  done
  return 1
}
