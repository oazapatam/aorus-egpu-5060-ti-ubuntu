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
# shellcheck shell=bash

: "${AORUS_FAKE_BUS:=00000000:B4:00.0}"
: "${AORUS_FAKE_GEN_MAX:=3}"
: "${AORUS_FAKE_CAPS:=150 180 3090 14001 180 405}"
: "${AORUS_FAKE_FIND_RC:=0}"
: "${AORUS_FAKE_GENMAX_RC:=0}"
: "${AORUS_FAKE_STATE_RC:=0}"
: "${AORUS_FAKE_WRITE_RC:=0}"
: "${AORUS_FAKE_WRITELOG:=}"

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
