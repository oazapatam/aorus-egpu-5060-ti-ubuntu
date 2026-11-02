#!/usr/bin/env bash
# adapters/pci/fake.sh — doble de test del puerto PCI.
#
# Se selecciona con AORUS_ADAPTER_PCI=adapters/pci/fake. Acompaña a
# adapters/gpu/fake.sh: el gate de enlace necesita el WIDTH, que viene de este
# puerto, así que sin un doble de los dos no se puede construir el escenario
# 'dead' (width 0 = el túnel no está entrenado).
#
# Mandos:
#   AORUS_FAKE_BDF        BDF que devuelve la búsqueda (default 0000:b4:00.0)
#   AORUS_FAKE_IDS        "<vendor> <device>" (default la eGPU 0x10de 0x2d04)
#   AORUS_FAKE_LINK       "<speed>|<width>"; width 0 => el gate ve 'dead'
#   AORUS_FAKE_BEHIND_TB  1 = cuelga de Thunderbolt (gate R4 topológico)
#   AORUS_FAKE_FIND_BDF_RC rc de pci_find_by_device_id
# shellcheck shell=bash

: "${AORUS_FAKE_BDF:=0000:b4:00.0}"
: "${AORUS_FAKE_IDS:=0x10de 0x2d04}"
: "${AORUS_FAKE_LINK:=8.0 GT/s PCIe|4}"
: "${AORUS_FAKE_BEHIND_TB:=1}"
: "${AORUS_FAKE_FIND_BDF_RC:=0}"

pci_find_by_device_id() {
  [ "$AORUS_FAKE_FIND_BDF_RC" -eq 0 ] || return "$AORUS_FAKE_FIND_BDF_RC"
  printf '%s' "$AORUS_FAKE_BDF"
}
pci_read_ids()  { printf '%s' "$AORUS_FAKE_IDS"; }
pci_read_link() { printf '%s' "$AORUS_FAKE_LINK"; }
pci_parent()    { printf '0000:b3:00.0'; }
pci_is_behind_thunderbolt() { [ "$AORUS_FAKE_BEHIND_TB" = "1" ]; }
