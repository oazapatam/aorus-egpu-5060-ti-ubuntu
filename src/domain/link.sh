#!/usr/bin/env bash
# domain/link.sh — veredicto de salud del enlace PCIe/Thunderbolt.
#
# Capa de DOMINIO: puro. Recibe lo que el adaptador ya leyó y decide.
#
# Por qué importa: con el enlace marginal, bindear la eGPU o apretarla ha
# CONGELADO el host entero (hard-hang sin Xid ni panic, 2026-06-27). La regla
# del proyecto es que "no bindea" es aceptable y "bindea y congela" no lo es,
# así que cualquier acción intrusiva (overclock incluido) se cierra tras el gate.
#
# ------------------------------------------------------------------------------
# LA DISTINCIÓN QUE ESTE FICHERO TIENE QUE SOSTENER (y que antes no sostenía)
#
# Hay DOS lecturas del enlace y confundirlas rompe el gate en direcciones
# opuestas:
#
#   - INSTANTÁNEA (`current_link_speed` de sysfs): a qué velocidad está
#     entrenado el enlace AHORA MISMO. En reposo marca 2.5 GT/s SIEMPRE, porque
#     el enlace baja de velocidad solo y vuelve a subir cuando hay tráfico
#     (medido en esta máquina: 2.5 en reposo -> 8.0 bajo carga -> 2.5 otra vez).
#     Es información útil para un informe y una base INSERVIBLE para un gate.
#
#   - CAPACIDAD NEGOCIADA (`pcie.link.gen.max` de nvidia-smi): la generación
#     máxima que ESTE enlace puede negociar. En esta máquina vale 3 (Gen3), que
#     es exactamente el tope que aplica egpu-tb-fix, y NO baja en reposo.
#
# Usar la instantánea como gate hacía que el overclock se rechazara siempre en
# reposo, dejando `--force` -es decir, apagar el gate- como único camino para
# usar el paquete. Era además el error que docs/what-actually-works.md ya
# documenta como cometido una vez en este repo: leer `current_link_speed` con la
# GPU en reposo y concluir "degradado".
#
# Por qué no se arregla "generando tráfico antes de leer": MEDIDO, no funciona.
# Un bucle de `nvidia-smi -q` no reentrena el enlace (sigue en 2.5 GT/s), así
# que un gate así daría el mismo falso negativo con más complejidad.
#
# Por qué no se usa `max_link_speed` de sysfs: en el endpoint anuncia la
# capacidad de la TARJETA (32 GT/s), no la del enlace; y en los puentes del
# túnel Thunderbolt los registros están VIRTUALIZADOS y anuncian 2.5 GT/s sea
# cual sea la capacidad real (b2:00.0 marca max=2.5 GT/s en esta máquina). Las
# dos lecturas mienten, cada una en un sentido distinto.
# ------------------------------------------------------------------------------

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

# Veredicto INSTANTÁNEO — descriptivo, para informes. NO es un gate.
# Imprime healthy|degraded|dead y devuelve 0 solo si healthy.
#   dead     = sin width o width 0: el túnel no existe; expulsar, no insistir.
#   degraded = enlace vivo pero entrenado por debajo del mínimo. OJO: en reposo
#              esto es lo NORMAL, no una avería (ver la cabecera).
#   healthy  = entrenado a Gen3 o mejor en el instante de la lectura.
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

# Veredicto por CAPACIDAD NEGOCIADA — este SÍ es el gate de las acciones
# intrusivas. Recibe la generación máxima que el enlace puede negociar (entero,
# de `pcie.link.gen.max`) y el width actual.
#
# Imprime healthy|degraded|dead|unknown y devuelve 0 solo si healthy.
#   dead     = sin width o width 0: el túnel no existe.
#   unknown  = no hay lectura de capacidad utilizable (vacía, 0, o no numérica).
#              NO autoriza: sin la lectura no se puede afirmar que sea seguro.
#   degraded = el enlace solo puede negociar por debajo de Gen3. Este es el caso
#              real del 2026-06-27, el que congeló el host.
#   healthy  = puede negociar Gen3 o mejor, aunque ahora mismo esté en reposo
#              a 2.5 GT/s.
domain_link_cap_verdict() { # $1=gen_max (entero) $2=width
  local gen_max="${1:-}" width="${2:-}"
  if [ -z "$width" ] || [ "$width" = "0" ]; then
    printf 'dead'; return 1
  fi
  # Guardia de mal uso, a propósito RUIDOSA en vez de silenciosa: si alguien
  # pasa aquí una cadena de velocidad ("2.5 GT/s PCIe") en vez de una
  # generación, el veredicto es 'unknown' y el gate CIERRA, en lugar de que
  # `[ -lt ]` falle y el error se trague una subshell.
  case "$gen_max" in
    ''|*[!0-9]*) printf 'unknown'; return 1 ;;
  esac
  if [ "$gen_max" -eq 0 ]; then
    printf 'unknown'; return 1
  fi
  if [ "$width" -lt "$AORUS_LINK_MIN_WIDTH" ]; then
    printf 'degraded'; return 1
  fi
  if [ "$gen_max" -lt "$AORUS_LINK_MIN_GEN" ]; then
    printf 'degraded'; return 1
  fi
  printf 'healthy'; return 0
}

# ¿Se permite una acción intrusiva (escritura en el hardware) con este enlace?
# Toma la CAPACIDAD, no la instantánea: ver la cabecera de este fichero.
domain_link_allows_tuning() { # $1=gen_max (entero) $2=width
  [ "$(domain_link_cap_verdict "$1" "$2")" = "healthy" ]
}
