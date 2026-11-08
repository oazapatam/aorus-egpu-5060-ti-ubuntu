#!/usr/bin/env bash
# ci/30-unit-tests.sh — tests del dominio + smoke tests de las CLIs.
#
# Dos bloques con propósitos distintos:
#
#  1. tests/run.sh: los asserts del dominio (gate R4, gate de enlace, clamping,
#     durabilidad de la traza, conformidad de cada adaptador con su puerto).
#     Puros: sin root, sin GPU, milisegundos.
#
#  2. SMOKE de los entrypoints: ejecuta cada CLI por sus rutas SEGURAS (--help,
#     comando desconocido, falta de argumentos) y comprueba el código de salida.
#     Existe porque los bugs que de verdad aparecieron en este repo estaban en
#     rutas que nunca se habían ejecutado: un re-exec con sudo mal entrecomillado
#     y un `timeout` que devolvía 124 en el caso de ÉXITO. `bash -n` no los ve;
#     ejecutarlos, sí.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ci/lib/report.sh
CI_STAGE=30-unit-tests

export AORUS_LIB_ROOT="$PWD/src"

# --- 1) dominio ---------------------------------------------------------------
ci_section "tests del dominio"
if [ ! -x tests/run.sh ] && [ ! -f tests/run.sh ]; then
  ci_fail "no existe tests/run.sh"
else
  out="$(bash tests/run.sh 2>&1)"; rc=$?
  resumen="$(printf '%s' "$out" | tail -1)"
  if [ "$rc" -eq 0 ]; then
    ci_ok "tests/run.sh — $resumen"
  else
    ci_fail "tests/run.sh falló ($resumen)" "$(printf '%s' "$out" | grep -E 'FAIL' || printf '%s' "$out")"
  fi
fi

# --- 1b) regresión de egpu-tb-fix (script legacy, fuera de src/) --------------
# `egpu-tb-fix` es anterior a la arquitectura hexagonal: su lógica vive en
# packaging/, así que tests/run.sh no la alcanza. Este test carga el script con
# el `main` neutralizado y dobles para sysfs y el reloj. Fija H26: un replug del
# túnel a media preparación dejaba la eGPU sin BAR0 y sin driver.
ci_section "regresión de egpu-tb-fix (H26: replug del túnel)"
if [ ! -f tests/egpu-tb-fix-replug.sh ]; then
  ci_fail "no existe tests/egpu-tb-fix-replug.sh"
else
  out="$(bash tests/egpu-tb-fix-replug.sh 2>&1)"; rc=$?
  resumen="$(printf '%s' "$out" | tail -1)"
  if [ "$rc" -eq 0 ]; then
    ci_ok "tests/egpu-tb-fix-replug.sh — $resumen"
  else
    ci_fail "tests/egpu-tb-fix-replug.sh falló ($resumen)" "$(printf '%s' "$out" | grep -E 'FAIL' || printf '%s' "$out")"
  fi
fi

# --- 2) smoke de los entrypoints ----------------------------------------------
# Convención de códigos de salida que se comprueba aquí:
#   0  = ok            2  = error de uso (opción/comando/argumento)
#   69 = falta una herramienta externa      70 = fallo interno de carga
ci_section "smoke de las CLIs (rutas seguras)"

smoke() { # $1=descripción  $2=rc esperado  $3..=comando
  local desc="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    ci_ok "$desc (rc=$rc)"
  else
    ci_fail "$desc: esperaba rc=$want, obtuve rc=$rc" "$out"
  fi
}

for cli in src/bin/aorus-egpu-oc src/bin/aorus-egpu-probe src/bin/aorus-egpu-postmortem; do
  if [ ! -x "$cli" ]; then ci_fail "no ejecutable: $cli"; continue; fi
  name="$(basename "$cli")"
  smoke "$name --help" 0 "$cli" --help
  smoke "$name con opción inválida" 2 "$cli" --no-existe
done

# Comando desconocido: solo las CLIs que tienen subcomandos.
smoke "aorus-egpu-oc comando desconocido" 2 src/bin/aorus-egpu-oc no-existe
smoke "aorus-egpu-probe comando desconocido" 2 src/bin/aorus-egpu-probe no-existe
# `run` sin comando tras -- es un error de uso, no un cuelgue.
smoke "aorus-egpu-probe run sin comando" 2 src/bin/aorus-egpu-probe run

# `list` del OC no toca hardware: debe funcionar como usuario normal.
smoke "aorus-egpu-oc list" 0 env \
  AORUS_OC_PROFILE_DIR=packaging/aorus-egpu-overclock/etc/aorus-egpu/profiles \
  src/bin/aorus-egpu-oc list

# --- 3) el bootstrap debe fallar CLARO si falta una capa ----------------------
ci_section "robustez del cargador"
out="$(AORUS_LIB_ROOT=/tmp/no-existe-aorus bash -c '. src/bootstrap.sh 2>&1; aorus_use domain/target' 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ci_ok "aorus_use falla con rc=$rc si el módulo no existe"
else
  ci_fail "aorus_use NO falló con una raíz inexistente" "$out"
fi

ci_summary
