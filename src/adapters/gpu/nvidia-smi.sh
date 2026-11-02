#!/usr/bin/env bash
# adapters/gpu/nvidia-smi.sh — implementación del puerto GPU sobre nvidia-smi.
#
# Es el adaptador por defecto: `nvidia-smi` funciona headless y bajo Wayland,
# a diferencia de nvidia-settings (que necesita Xorg + Coolbits).
#
# DEFENSIVO a propósito (lección de la v0.5.4 del paquete: un eGPU semi-roto
# cuelga a nvidia-smi en estado-D y martillearlo lo dejaba wedged):
#   - CADA invocación va acotada por `timeout`;
#   - exit 124 (colgado) se propaga como rc 124 y el caso de uso ABORTA, no
#     reintenta;
#   - toda escritura se dirige con `-i <bus-id>`, nunca al índice de GPU (los
#     índices se reordenan entre arranques; apuntar por índice es exactamente
#     cómo se acabaría tocando la GPU interna y violando R4).

# shellcheck shell=bash

AORUS_SMI_TIMEOUT="${AORUS_SMI_TIMEOUT:-12}"

_smi() { timeout "$AORUS_SMI_TIMEOUT" nvidia-smi "$@"; }

gpu_available() { command -v nvidia-smi >/dev/null 2>&1; }

# nvidia-smi reporta pci.device_id como 0xDDDDVVVV: el DEVICE en la parte ALTA y
# el vendor en la baja (p. ej. 0x2D0410DE = device 2d04, vendor 10de). Hay que
# extraer la mitad alta; normalizar los 8 dígitos enteros no casa con nada.
# ${v,,} en vez de `tr 'A-Z' 'a-z'`: mismo resultado para hex ASCII y sin fork
# (ver la nota en domain/target.sh::domain_norm_id).
_smi_device_of() { # $1=0xDDDDVVVV -> 0xdddd
  local v="${1// /}"; v="${v#0x}"; v="${v#0X}"
  v="${v:0:4}"
  printf '0x%s' "${v,,}"
}

# Busca la GPU por device-id consultando a nvidia-smi (no sysfs): así el bus-id
# que devolvemos es EXACTAMENTE la cadena que nvidia-smi acepta en `-i`.
gpu_find_by_device_id() { # $1=device id (0x2d04)
  local want bus did rc out
  want="$(domain_norm_id "${1:-}")"
  out="$(_smi --query-gpu=pci.bus_id,pci.device_id --format=csv,noheader 2>/dev/null)"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && return 1
  while IFS=, read -r bus did; do
    bus="${bus// /}"; did="${did// /}"
    [ -z "$bus" ] && continue
    if [ "$(_smi_device_of "$did")" = "$want" ]; then printf '%s' "$bus"; return 0; fi
  done <<< "$out"
  return 1
}

gpu_read_vendor_device() { # $1=busid -> "<vendor> <device>"
  local out rc vendor
  out="$(_smi -i "$1" --query-gpu=pci.device_id --format=csv,noheader 2>/dev/null)"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && return 1
  # 0xDDDDVVVV -> "<vendor> <device>" (el contrato del puerto pide ese orden).
  out="${out// /}"; out="${out#0x}"
  vendor="${out:4:4}"
  printf '0x%s %s' "${vendor,,}" "$(_smi_device_of "0x$out")"
}

# Capacidades reales de ESTA tarjeta: "pmin pmax gpumax memmax".
# Se leen del hardware en vez de hardcodearse para que el dominio acote contra
# los límites verdaderos (en la RTX 5060 Ti: 150-180 W, 3090 MHz, 14001 MHz).
gpu_caps() { # $1=busid
  local out rc pmin pmax gmax mmax
  out="$(_smi -i "$1" --query-gpu=power.min_limit,power.max_limit,clocks.max.gr,clocks.max.mem \
        --format=csv,noheader,nounits 2>/dev/null)"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && return 1
  IFS=, read -r pmin pmax gmax mmax <<< "$out"
  # power.*_limit vienen con decimales ("150.00"); el dominio trabaja en enteros.
  printf '%s %s %s %s' "${pmin%%.*}" "${pmax%%.*}" "${gmax// /}" "${mmax// /}"
}

# Generación PCIe MÁXIMA que este enlace puede negociar, como entero.
#
# POR QUÉ ESTA LECTURA Y NO OTRA (es la entrada del gate de enlace):
#   - `pcie.link.gen.max` es la capacidad del ENLACE. En esta máquina vale 3,
#     que es el tope Gen3 que aplica egpu-tb-fix, y NO baja en reposo.
#   - `pcie.link.gen.current` baja a 1 en reposo: no sirve de gate (era el bug).
#   - `pcie.link.gen.gpumax` es la capacidad de la TARJETA (5 aquí), no la del
#     enlace: autorizaría un enlace degradado.
#   - `pcie.link.gen.hostmax` devuelve "[Unknown Error]" en esta máquina.
# Verificado el 2026-11-02 sobre la eGPU b4:00.0 con la tarjeta funcionando.
#
# Si la lectura no es un entero utilizable devolvemos rc 1 SIN imprimir, y el
# dominio lo traduce a 'unknown' -> el gate CIERRA. Ante la duda, no se escribe.
gpu_link_gen_max() { # $1=busid -> entero (3 = Gen3)
  local out rc
  out="$(_smi -i "$1" --query-gpu=pcie.link.gen.max --format=csv,noheader 2>/dev/null)"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && return 1
  out="${out// /}"
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$out"
}

gpu_state() { # $1=busid -> "clave=valor" por línea
  local out rc pl gc mc
  out="$(_smi -i "$1" --query-gpu=power.limit,clocks.gr,clocks.mem,persistence_mode \
        --format=csv,noheader,nounits 2>/dev/null)"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && return 1
  IFS=, read -r pl gc mc _ <<< "$out"
  printf 'power_limit_w=%s\ngpu_clock_mhz=%s\nmem_clock_mhz=%s\n' \
         "${pl%%.*}" "${gc// /}" "${mc// /}"
}

gpu_set_power_limit() { _smi -i "$1" -pl "$2" >/dev/null; }
gpu_set_gpu_clock()   { _smi -i "$1" -lgc "$2,$3" >/dev/null; }
gpu_set_mem_clock()   { _smi -i "$1" -lmc "$2" >/dev/null; }

# Reset completo: relojes a default. El power limit se devuelve a su máximo por
# defecto, que es el estado de fábrica de esta tarjeta.
gpu_reset_clocks() { # $1=busid
  local rc=0
  _smi -i "$1" -rgc >/dev/null 2>&1 || rc=1
  _smi -i "$1" -rmc >/dev/null 2>&1 || rc=1
  return "$rc"
}
