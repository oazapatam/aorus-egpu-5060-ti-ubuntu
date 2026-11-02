#!/usr/bin/env bash
# ports/thunderbolt.port.sh — CONTRATO del puerto Thunderbolt.
#
# Contrato:
#   tb_available                 -> 0 si hay herramienta/sysfs TB
#   tb_device_uuid               -> imprime el UUID de la caja eGPU
#   tb_is_authorized <uuid>      -> 0 si el túnel está autorizado
#   tb_policy <uuid>             -> imprime auto|manual|iommu
#
# NOTA: autorizar/desautorizar NO está en el contrato de lectura. Las acciones
# que crean o tiran el túnel viven en el paquete aorus-egpu-config (connect/up/
# down), que ya está validado en vivo; duplicarlas aquí sería arriesgado.
#
# shellcheck shell=bash

port_thunderbolt_assert() {
  local f missing=0
  for f in tb_available tb_device_uuid tb_is_authorized tb_policy; do
    declare -F "$f" >/dev/null || {
      printf 'puerto thunderbolt: el adaptador no implementa %s()\n' "$f" >&2; missing=1; }
  done
  return "$missing"
}
