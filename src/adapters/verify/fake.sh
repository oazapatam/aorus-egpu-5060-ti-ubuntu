#!/usr/bin/env bash
# adapters/verify/fake.sh — doble de test del puerto `verify`.
#
# Se selecciona con AORUS_ADAPTER_VERIFY=adapters/verify/fake. NO se empaqueta
# (scripts/lib/bundle.sh borra todo fake.sh del payload) y por un motivo muy
# concreto: un doble del VERIFICADOR instalado en el sistema sería la forma más
# directa de obtener un "verificación OK" sin haber medido nada, que es
# exactamente el falso éxito contra el que existe este puerto.
#
# POR QUÉ EXISTE: las reglas que gobiernan los offsets positivos viven en app/
# y ninguna se puede provocar con hardware real a voluntad —hacen falta una GPU
# que calcule MAL, un verificador ausente y un verificador colgado—. Con este
# doble son tres variables de entorno.
#
# Mandos:
#   AORUS_FAKE_VERIFY_RC   rc de verify_numeric_integrity:
#                            0   pasa
#                            1   FALLA (errores numéricos)
#                            2   no disponible (y verify_available dice "no")
#                            124 colgado
#   AORUS_FAKE_WRITELOG    el mismo fichero que usa adapters/gpu/fake.sh. La
#                          llamada al verificador se anota ahí para poder
#                          afirmar el ORDEN: aplicar -> verificar -> revertir.
# shellcheck shell=bash

: "${AORUS_FAKE_VERIFY_RC:=0}"
: "${AORUS_FAKE_WRITELOG:=}"

# rc 2 significa "no disponible", así que el mismo mando gobierna las dos
# funciones: un verificador que no está no puede decir que esté.
verify_available() { [ "$AORUS_FAKE_VERIFY_RC" -ne 2 ]; }

verify_numeric_integrity() { # $1=busid $2=segundos
  [ -n "$AORUS_FAKE_WRITELOG" ] && printf 'verify %s %s\n' "${1:-}" "${2:-}" >> "$AORUS_FAKE_WRITELOG"
  case "$AORUS_FAKE_VERIFY_RC" in
    1) printf 'errors=7 iters=3' ;;
    *) printf 'errors=0 iters=3' ;;
  esac
  return "$AORUS_FAKE_VERIFY_RC"
}
