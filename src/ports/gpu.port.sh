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
#
# OFFSETS de reloj (+MHz sobre stock). Los tres van JUNTOS o no van:
#   gpu_supports_clock_offset <busid>  -> 0 soportado, 3 NO soportado, 124 colgado
#   gpu_offset_window <busid>          -> imprime "gmin gmax mmin mmax"
#                                         (las CUATRO ventanas, en MHz, con
#                                         signo); rc 3 si no se pueden afirmar
#   gpu_set_clock_offset <busid> <gpu|mem> <mhz>
#                                      -> escribe UN offset; rc 3 no soportado,
#                                         124 colgado
#
# Por qué los tres juntos: un adaptador que implementase la ESCRITURA sin la
# ventana dejaría a app/ escribiendo un valor que nadie puede comprobar, y la
# capacidad de offsets es precisamente la que falla calculando mal en vez de
# cayéndose. Por eso los tres están en la lista obligatoria de port_gpu_assert,
# aunque este puerto dé defaults: si un día se quita un default, la etapa de
# tests lo dice en vez de que lo descubra un `command not found` como root.
#
# shellcheck shell=bash

port_gpu_assert() {
  local f missing=0
  for f in gpu_available gpu_find_by_device_id gpu_read_vendor_device gpu_caps \
           gpu_link_gen_max gpu_state gpu_set_power_limit gpu_set_gpu_clock \
           gpu_set_mem_clock gpu_reset_all \
           gpu_supports_clock_offset gpu_offset_window gpu_set_clock_offset; do
    if ! declare -F "$f" >/dev/null; then
      printf 'puerto gpu: el adaptador no implementa %s()\n' "$f" >&2; missing=1
    fi
  done
  return "$missing"
}

# Defaults de la capacidad OPCIONAL de offsets: declarar "no soportado" es más
# honesto que omitirla y que el caso de uso descubra el hueco por un error de
# bash. Un adaptador que no los implemente hereda así un "no" explícito, y el
# dominio rechaza el perfil que los pida en vez de fingir que se aplicaron.
gpu_supports_clock_offset() { return 3; }
gpu_offset_window()         { return 3; }
gpu_set_clock_offset()      { return 3; }
