#!/usr/bin/env bash
# ports/kmod.port.sh — CONTRATO del puerto de módulos del kernel.
#
# Existe para que el caso de uso pueda decir "suelta el driver NVIDIA" sin saber
# nada de lsmod, modprobe, systemd ni /proc.
#
# Contrato:
#   kmod_available                 -> 0 si se puede operar con módulos
#   kmod_loaded <mod>              -> 0 si el módulo está cargado
#   kmod_refcount <mod>            -> imprime el refcount, o vacío
#   kmod_users <mod>               -> imprime los módulos que lo usan
#   kmod_unload <mod>              -> descarga; rc!=0 si no se puede
#   kmod_load <mod>                -> carga
#   kmod_node_holders              -> imprime "<pid> <comando>" por cada proceso
#                                     con un nodo /dev/nvidia* abierto
#   kmod_service_active <unidad>   -> 0 si la unidad systemd está activa
#   kmod_service_stop <unidad>     -> la para
#
# shellcheck shell=bash

port_kmod_assert() {
  local f missing=0
  for f in kmod_available kmod_loaded kmod_refcount kmod_users kmod_unload \
           kmod_load kmod_node_holders kmod_service_active kmod_service_stop; do
    if ! declare -F "$f" >/dev/null; then
      printf 'puerto kmod: el adaptador no implementa %s()\n' "$f" >&2; missing=1
    fi
  done
  return "$missing"
}
