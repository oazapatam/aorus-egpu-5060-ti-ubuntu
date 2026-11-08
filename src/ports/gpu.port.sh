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
# TELEMETRÍA para el panel vivo (nvidia-oc). Solo LECTURA:
#   gpu_telemetry_all                -> un registro por GPU, cada uno abierto
#                                       por una línea '--' y seguido de
#                                       'clave=valor'. Claves declaradas:
#                                         bus_id vendor_id device_id name
#                                         util_gpu_pct util_mem_pct
#                                         mem_used_mib mem_total_mib
#                                         temp_c power_draw_w power_limit_w
#                                         gpu_clock_mhz mem_clock_mhz
#                                         fan_pct pstate throttle
#                                         link_gen_cur link_width_cur
#   gpu_processes_all                -> 'bus_id<TAB>pid<TAB>mem_mib<TAB>nombre'
#                                       por proceso con una GPU abierta. Sin
#                                       procesos: salida VACÍA y rc 0.
#
# Las dos enumeran TODAS las GPUs NVIDIA, no solo la eGPU, porque el panel
# muestra las dos: ver una carga aterrizar en la GPU equivocada es justo lo que
# un monitor tiene que delatar. Eso NO relaja el gate R4, que gobierna las
# ESCRITURAS y sigue resolviendo un único target por device-id.
#
# Un valor que la tarjeta no publique se emite TAL CUAL ('[N/A]'), sin
# traducirlo a 0: la decisión de qué hacer con un hueco es del dominio
# (domain_tel_field), no del adaptador. En esta máquina no es hipotético — la
# GPU interna devuelve '[N/A]' en power.limit y en fan.speed.
#
# shellcheck shell=bash

port_gpu_assert() {
  local f missing=0
  for f in gpu_available gpu_find_by_device_id gpu_read_vendor_device gpu_caps \
           gpu_link_gen_max gpu_state gpu_set_power_limit gpu_set_gpu_clock \
           gpu_set_mem_clock gpu_reset_all \
           gpu_supports_clock_offset gpu_offset_window gpu_set_clock_offset \
           gpu_telemetry_all gpu_processes_all; do
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

# Defaults de telemetría. Un adaptador que no la implemente devuelve "no hay
# nada que mostrar" (rc 3) en vez de un error de bash, y el panel lo presenta
# como lo que es: sin datos. No hay default que INVENTE un registro.
gpu_telemetry_all()  { return 3; }
gpu_processes_all()  { return 3; }
