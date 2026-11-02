#!/usr/bin/env bash
# domain/link.sh — veredicto de salud del enlace PCIe/Thunderbolt.
#
# Capa de DOMINIO: puro. Recibe lo que sysfs ya reportó (speed/width) y decide.
#
# Por qué importa: el enlace de esta caja entrena a veces a Gen1 2.5GT/s. Con el
# enlace marginal, bindear la eGPU o apretarla ha CONGELADO el host entero
# (hard-hang sin Xid ni panic, 2026-06-27). La regla del proyecto es que
# "no bindea" es aceptable y "bindea y congela" no lo es, así que cualquier
# acción intrusiva (overclock incluido) se cierra tras este gate.

# shellcheck shell=bash

# Mínimos para considerar el enlace apto para acciones intrusivas. Gen3 es el
# umbral que ya usa keep-resident: por debajo, el GSP no re-inicializa de forma
# fiable (RmInitAdapter failed 0x62:0x40:2192).
readonly AORUS_LINK_MIN_GEN=3
readonly AORUS_LINK_MIN_WIDTH=1

# "8.0 GT/s PCIe" -> 3 ; "2.5 GT/s PCIe" -> 1 ; "Unknown" -> 0
domain_link_gen_from_speed() { # $1=current_link_speed
  case "${1:-}" in
    2.5*) printf '1' ;;
    5.0*) printf '2' ;;
    8.0*) printf '3' ;;
    16.0*) printf '4' ;;
    32.0*) printf '5' ;;
    64.0*) printf '6' ;;
    *)    printf '0' ;;
  esac
}

# Veredicto. Imprime healthy|degraded|dead y devuelve 0 solo si healthy.
#   dead     = sin width o width 0: el túnel no existe; expulsar, no insistir.
#   degraded = enlace vivo pero por debajo del mínimo (el caso Gen1 marginal):
#              se puede leer, pero NADA intrusivo.
#   healthy  = apto para bind, persistence y overclock.
domain_link_verdict() { # $1=speed $2=width
  local speed="${1:-}" width="${2:-}" gen
  if [ -z "$width" ] || [ "$width" = "0" ]; then
    printf 'dead'; return 1
  fi
  gen="$(domain_link_gen_from_speed "$speed")"
  if [ "$gen" -lt "$AORUS_LINK_MIN_GEN" ] || [ "$width" -lt "$AORUS_LINK_MIN_WIDTH" ]; then
    printf 'degraded'; return 1
  fi
  printf 'healthy'; return 0
}

# ¿Se permite una acción intrusiva (escritura en el hardware) con este enlace?
domain_link_allows_tuning() { # $1=speed $2=width
  [ "$(domain_link_verdict "$1" "$2")" = "healthy" ]
}
