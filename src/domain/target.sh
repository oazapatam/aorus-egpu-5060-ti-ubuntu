#!/usr/bin/env bash
# domain/target.sh — QUÉ es "la eGPU" y qué NUNCA hay que tocar (regla R4).
#
# Capa de DOMINIO: funciones PURAS. Reciben datos ya leídos y deciden; no abren
# sysfs, no invocan nvidia-smi, no escriben logs. Eso vive en adapters/.
# Por eso esta regla —la más crítica del proyecto— se puede testear sin GPU.
#
# R4 (invariante del proyecto): ninguna palanca puede actuar sobre la GPU
# INTERNA. Tocarla ya rompió la máquina una vez (aorus12 -> Xid 79 en 10de:2c39
# durante un resume RTD3/GC6 normal). Toda acción se confina a la eGPU externa.

# shellcheck shell=bash

readonly AORUS_VENDOR_NVIDIA=0x10de
readonly AORUS_EGPU_DEVICE=0x2d04      # AORUS RTX 5060 Ti  (externa, Thunderbolt)
readonly AORUS_INTERNAL_DEVICE=0x2c39  # RTX PRO 4000 Blackwell (INTERNA - prohibida)

# Normaliza un id PCI a la forma 0xNNNN minúscula: sysfs da "0x2d04",
# nvidia-smi da "0x2D04" y lspci da "2d04". Las tres deben comparar igual.
#
# Se usa la expansión ${var,,} de bash en vez de `tr 'A-Z' 'a-z'`: es el MISMO
# resultado para un id hex ASCII, pero sin fork — y este predicado se llama una
# vez por cada device del bus en pci_find_by_device_id. De paso desaparecen
# SC2018/SC2019 (que recomiendan [:upper:]/[:lower:] por los acentos, algo que
# a un id hexadecimal no le aporta nada).
domain_norm_id() { # $1=id
  local id="${1:-}"
  id="${id#0x}"; id="${id#0X}"
  printf '0x%s' "${id,,}"
}

# ¿Es la eGPU externa? Único predicado autorizado para habilitar una acción.
domain_target_is_egpu() { # $1=vendor $2=device
  [ "$(domain_norm_id "${1:-}")" = "$AORUS_VENDOR_NVIDIA" ] &&
  [ "$(domain_norm_id "${2:-}")" = "$AORUS_EGPU_DEVICE" ]
}

# ¿Es la GPU interna? Predicado explícito para ABORTAR, no para actuar.
# Se comprueba por separado a propósito: "no es la eGPU" y "es la interna" son
# cosas distintas y la segunda merece un mensaje de error propio.
domain_target_is_internal() { # $1=vendor $2=device
  [ "$(domain_norm_id "${1:-}")" = "$AORUS_VENDOR_NVIDIA" ] &&
  [ "$(domain_norm_id "${2:-}")" = "$AORUS_INTERNAL_DEVICE" ]
}

# Veredicto R4 completo sobre un device. Imprime el motivo y devuelve:
#   0 = eGPU, actuar permitido
#   1 = no es la eGPU, ignorar en silencio
#   2 = ES LA INTERNA, abortar ruidosamente (bug de targeting)
domain_target_verdict() { # $1=vendor $2=device
  if domain_target_is_egpu "$1" "$2"; then
    printf 'egpu'; return 0
  elif domain_target_is_internal "$1" "$2"; then
    printf 'internal'; return 2
  fi
  printf 'other'; return 1
}
