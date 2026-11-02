#!/usr/bin/env bash
# ports/pci.port.sh — CONTRATO del puerto PCI (topología y enlace).
#
# Contrato:
#   pci_find_by_device_id <did>    -> imprime el BDF (0000:bb:dd.f)
#   pci_read_ids <bdf>             -> imprime "<vendor> <device>"
#   pci_read_link <bdf>            -> imprime "<current_link_speed>|<width>"
#   pci_is_behind_thunderbolt <bdf> -> 0 si cuelga de un controlador TB/USB4
#   pci_parent <bdf>               -> imprime el BDF del bridge padre
#
# shellcheck shell=bash

port_pci_assert() {
  local f missing=0
  for f in pci_find_by_device_id pci_read_ids pci_read_link \
           pci_is_behind_thunderbolt pci_parent; do
    declare -F "$f" >/dev/null || {
      printf 'puerto pci: el adaptador no implementa %s()\n' "$f" >&2; missing=1; }
  done
  return "$missing"
}
