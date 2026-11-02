#!/usr/bin/env bash
# ports/gpu.port.sh — CONTRATO del puerto GPU.
#
# Un PUERTO no implementa nada: declara las funciones que un adaptador debe
# ofrecer y da un fallo explícito si falta alguna. Los casos de uso (app/)
# llaman SOLO a estas funciones, nunca a nvidia-smi directamente. Cambiar de
# nvidia-smi a NVML = escribir otro adaptador, sin tocar app/ ni domain/.
#
# Contrato (todo adaptador de este puerto implementa):
#   gpu_available                      -> 0 si la herramienta subyacente existe
#   gpu_find_by_device_id <did>        -> imprime el bus-id (o vacío + rc!=0)
#   gpu_read_vendor_device <busid>     -> imprime "<vendor> <device>"
#   gpu_caps <busid>                   -> imprime "pmin pmax gpumax memmax gpumin memmin"
#                                         (gpumin/memmin pueden venir VACÍOS)
#   gpu_link_gen_max <busid>           -> imprime la generación PCIe MÁXIMA que
#                                         este enlace puede negociar (entero).
#                                         Es la entrada del gate de enlace: la
#                                         instantánea de sysfs no sirve porque
#                                         en reposo siempre marca Gen1.
#   gpu_state <busid>                  -> imprime "op=valor" por línea
#   gpu_set_power_limit <busid> <w>
#   gpu_set_gpu_clock <busid> <lo> <hi>
#   gpu_set_mem_clock <busid> <mhz>
#   gpu_reset_all <busid>              -> relojes Y power limit a fábrica
#   gpu_set_clock_offset <busid> <mhz> -> OPCIONAL; rc 3 = no soportado
#
# shellcheck shell=bash

port_gpu_assert() {
  local f missing=0
  for f in gpu_available gpu_find_by_device_id gpu_read_vendor_device gpu_caps \
           gpu_link_gen_max gpu_state gpu_set_power_limit gpu_set_gpu_clock \
           gpu_set_mem_clock gpu_reset_all; do
    if ! declare -F "$f" >/dev/null; then
      printf 'puerto gpu: el adaptador no implementa %s()\n' "$f" >&2; missing=1
    fi
  done
  return "$missing"
}

# Default del método opcional: declarar "no soportado" es más honesto que
# omitirlo y que el caso de uso descubra el hueco por un error de bash.
gpu_set_clock_offset() { return 3; }
