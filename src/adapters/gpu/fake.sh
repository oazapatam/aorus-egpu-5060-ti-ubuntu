#!/usr/bin/env bash
# adapters/gpu/fake.sh — doble de test del puerto GPU.
#
# Se selecciona con AORUS_ADAPTER_GPU=adapters/gpu/fake (ver aorus_adapter en
# bootstrap.sh). NO se empaqueta: vive en src/ porque los tests cargan el
# núcleo desde ahí, pero scripts/lib/bundle.sh solo copia lo que el paquete
# declara.
#
# POR QUÉ EXISTE: los gates de seguridad del overclock viven en app/, y sin un
# doble no había forma de probarlos sin una eGPU con el enlace roto a mano.
# Los tres huecos que cubre esto se encontraron por auditoría, no por test:
#   - --force abría el gate también con 'dead' y 'unknown', contra el
#     invariante de CLAUDE.md.
#   - un rc=124 en una escritura se degradaba a fallo genérico y el ejecutor
#     SEGUÍA con las dos escrituras siguientes.
#   - el revert de emergencia añadía dos invocaciones más sobre una tarjeta
#     que ya no respondía.
# Simular un nvidia-smi colgado es trivial aquí e imposible con hardware real.
#
# Mandos (todos por entorno):
#   AORUS_FAKE_BUS        bus-id que publica (default 00000000:B4:00.0)
#   AORUS_FAKE_GEN_MAX    generación máxima; vacío => el gate ve 'unknown'
#   AORUS_FAKE_CAPS       "pmin pmax gpumax memmax gpumin memmin"
#   AORUS_FAKE_FIND_RC    rc de gpu_find_by_device_id (124 = colgado)
#   AORUS_FAKE_GENMAX_RC  rc de gpu_link_gen_max
#   AORUS_FAKE_STATE_RC   rc de gpu_state
#   AORUS_FAKE_WRITE_RC   rc de TODAS las escrituras (124 = colgado)
#   AORUS_FAKE_WRITELOG   fichero donde se anota cada escritura intentada
#   AORUS_FAKE_OFFSET_SUPPORTED  1 = la GPU soporta offsets de reloj (el
#                         defecto, porque es lo MEDIDO en esta tarjeta);
#                         0 = no los soporta y el dominio debe rechazarlos
#   AORUS_FAKE_OFFSET_WINDOW  "gmin gmax mmin mmax"; vacío => sin ventana
#                         legible, que para el dominio es "no soportado"
# shellcheck shell=bash

: "${AORUS_FAKE_BUS:=00000000:B4:00.0}"
: "${AORUS_FAKE_GEN_MAX:=3}"
: "${AORUS_FAKE_CAPS:=150 180 3090 14001 180 405}"
: "${AORUS_FAKE_FIND_RC:=0}"
: "${AORUS_FAKE_GENMAX_RC:=0}"
: "${AORUS_FAKE_STATE_RC:=0}"
: "${AORUS_FAKE_WRITE_RC:=0}"
: "${AORUS_FAKE_WRITELOG:=}"
: "${AORUS_FAKE_OFFSET_SUPPORTED:=1}"
# Las ventanas MEDIDAS el 2026-11-02 en esta tarjeta con nvidia-ml-py:
# GPC (-1000,1000) y MEM (-2000,6000). El doble miente lo mínimo posible.
: "${AORUS_FAKE_OFFSET_WINDOW:=-1000 1000 -2000 6000}"

gpu_available() { return 0; }

gpu_find_by_device_id() { # $1=device id
  [ "$AORUS_FAKE_FIND_RC" -eq 0 ] || return "$AORUS_FAKE_FIND_RC"
  printf '%s' "$AORUS_FAKE_BUS"
}

gpu_read_vendor_device() { printf '0x10de 0x2d04'; }

gpu_caps() { printf '%s' "$AORUS_FAKE_CAPS"; }

gpu_link_gen_max() { # $1=busid
  [ "$AORUS_FAKE_GENMAX_RC" -eq 0 ] || return "$AORUS_FAKE_GENMAX_RC"
  printf '%s' "$AORUS_FAKE_GEN_MAX"
}

gpu_state() { # $1=busid
  [ "$AORUS_FAKE_STATE_RC" -eq 0 ] || return "$AORUS_FAKE_STATE_RC"
  printf 'power_limit=180\nclocks_gr=3090\n'
}

# Cada escritura se ANOTA antes de devolver el rc configurado. Es lo que
# permite afirmar que un plan se abortó: se cuenta cuántas llegaron a
# intentarse, no solo el rc final.
_fake_write() { # $@=descripcion
  [ -n "$AORUS_FAKE_WRITELOG" ] && printf '%s\n' "$*" >> "$AORUS_FAKE_WRITELOG"
  return "$AORUS_FAKE_WRITE_RC"
}

gpu_set_power_limit() { _fake_write "power_limit $2"; }
gpu_set_gpu_clock()   { _fake_write "gpu_clock $2 $3"; }
gpu_set_mem_clock()   { _fake_write "mem_clock $2"; }
gpu_reset_all()       { _fake_write "reset"; }

# --- offsets de reloj ---------------------------------------------------------
# rc 3 = no soportado, igual que el default del puerto: un adaptador que dice
# "no" tiene que decirlo con el MISMO código que el resto, o el caso de uso
# trataría el doble distinto que la realidad.
gpu_supports_clock_offset() { # $1=busid
  [ "$AORUS_FAKE_OFFSET_SUPPORTED" = "1" ] || return 3
  return 0
}

gpu_offset_window() { # $1=busid -> "gmin gmax mmin mmax"
  [ "$AORUS_FAKE_OFFSET_SUPPORTED" = "1" ] || return 3
  [ -n "$AORUS_FAKE_OFFSET_WINDOW" ] || return 3
  printf '%s' "$AORUS_FAKE_OFFSET_WINDOW"
}

# La escritura del offset se ANOTA en el writelog como cualquier otra. Es lo
# que permite afirmar en un test que una op NO se emitió: se cuenta lo que
# llegó a intentarse, no solo el rc final.
gpu_set_clock_offset() { # $1=busid $2=gpu|mem $3=mhz
  _fake_write "clock_offset $2 $3"
}

# --- telemetría ---------------------------------------------------------------
#
# Dos GPUs, como la máquina real: la eGPU (2d04) y la interna (2c39). La interna
# publica '[N/A]' en power_limit_w y fan_pct porque es EXACTAMENTE lo que hace
# el hardware de verdad —medido el 2026-11-07—, y es el caso que obliga al
# dominio a propagar el hueco en vez de rellenarlo con un 0.
#
# Mandos:
#   AORUS_FAKE_TELEMETRY_RC  rc de gpu_telemetry_all (124 = colgado)
#   AORUS_FAKE_PROCS         líneas de proceso ya formateadas, separadas por
#                            ';' — vacío = ningún proceso (el caso que
#                            autoriza a tirar del cable, H28)
#   AORUS_FAKE_PROCS_RC      rc de gpu_processes_all
AORUS_FAKE_TELEMETRY_RC="${AORUS_FAKE_TELEMETRY_RC:-0}"
AORUS_FAKE_PROCS="${AORUS_FAKE_PROCS:-}"
AORUS_FAKE_PROCS_RC="${AORUS_FAKE_PROCS_RC:-0}"

gpu_telemetry_all() {
  [ "$AORUS_FAKE_TELEMETRY_RC" -eq 0 ] || return "$AORUS_FAKE_TELEMETRY_RC"
  cat <<'REC'
--
bus_id=00000000:8D:00.0
vendor_id=0x10de
device_id=0x2d04
util_gpu_pct=62
util_mem_pct=18
mem_used_mib=6700
mem_total_mib=16311
temp_c=65
power_draw_w=143.52
power_limit_w=180.00
gpu_clock_mhz=2887
mem_clock_mhz=14001
fan_pct=48
pstate=P0
throttle=0x0000000000000004
link_gen_cur=3
link_width_cur=4
link_gen_max=3
link_width_max=8
name=NVIDIA GeForce RTX 5060 Ti
--
bus_id=00000000:01:00.0
vendor_id=0x10de
device_id=0x2c39
util_gpu_pct=0
util_mem_pct=0
mem_used_mib=0
mem_total_mib=16303
temp_c=53
power_draw_w=7.53
power_limit_w=[N/A]
gpu_clock_mhz=180
mem_clock_mhz=405
fan_pct=[N/A]
pstate=P8
throttle=0x0000000000000000
link_gen_cur=1
link_width_cur=16
link_gen_max=5
link_width_max=16
name=NVIDIA RTX PRO 4000 Blackwell Generation Laptop GPU
REC
  return 0
}

gpu_processes_all() {
  [ "$AORUS_FAKE_PROCS_RC" -eq 0 ] || return "$AORUS_FAKE_PROCS_RC"
  [ -n "$AORUS_FAKE_PROCS" ] || return 0
  printf '%s\n' "${AORUS_FAKE_PROCS//;/$'\n'}"
  return 0
}
