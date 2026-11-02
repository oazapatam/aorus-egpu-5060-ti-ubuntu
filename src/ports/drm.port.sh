#!/usr/bin/env bash
# ports/drm.port.sh — CONTRATO del puerto DRM.
#
# Un PUERTO no implementa nada: declara lo que un adaptador debe ofrecer y falla
# explícitamente si falta algo. Los casos de uso llaman SOLO a estas funciones,
# nunca a /sys/class/drm directamente.
#
# Contrato:
#   drm_available                  -> 0 si se puede consultar DRM
#   drm_cards                      -> imprime "cardN" por línea, ordenado
#   drm_card_driver <card>         -> imprime el driver DRM (i915, nvidia, ...)
#   drm_card_bdf <card>            -> imprime el BDF PCI, o vacío
#   drm_card_connected <card>      -> imprime cuántas salidas tiene CONECTADAS
#   drm_card_outputs <card>        -> imprime "<conector> <status> <enabled>"
#                                     por línea
#
# shellcheck shell=bash

port_drm_assert() {
  local f missing=0
  for f in drm_available drm_cards drm_card_driver drm_card_bdf \
           drm_card_connected drm_card_outputs; do
    if ! declare -F "$f" >/dev/null; then
      printf 'puerto drm: el adaptador no implementa %s()\n' "$f" >&2; missing=1
    fi
  done
  return "$missing"
}
