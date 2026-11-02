#!/usr/bin/env bash
# ci/lib/report.sh — contrato común de las etapas de CI.
#
# CONTRATO DE UNA ETAPA (ci/NN-nombre.sh):
#   - se ejecuta desde la RAÍZ del repo;
#   - empieza con `set -uo pipefail` (NO `-e`: una etapa recoge TODOS los
#     fallos y los reporta juntos, en vez de morir en el primero);
#   - carga esta librería y termina con `ci_summary`;
#   - códigos de salida:  0 = pasa   1 = falla   77 = omitida (falta una
#     herramienta; no es un fallo del código).
#
# El orquestador ci/run.sh distingue 77 de 1 para que un entorno al que le
# falte alguna herramienta (shellcheck, lintian) no dé un falso rojo.
#
# OJO al escribir comentarios aquí: una línea cuya primera palabra tras '#' sea
# "shellcheck" se interpreta como DIRECTIVA y rompe el análisis del fichero
# completo (SC1072/SC1073), y entonces toda etapa que cargue esta librería
# reporta "Parsing of sourced file failed". Ya pasó una vez.

# shellcheck shell=bash

CI_OK=0 CI_FAIL=0 CI_WARN=0 CI_SKIP=0
CI_STAGE="${CI_STAGE:-$(basename "${BASH_SOURCE[1]:-ci}" .sh)}"

# Color solo si hay terminal: en un hook de git o en un log no sirve de nada.
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  _C_R=$'\033[31m' _C_G=$'\033[32m' _C_Y=$'\033[33m' _C_B=$'\033[1m' _C_0=$'\033[0m'
else
  _C_R='' _C_G='' _C_Y='' _C_B='' _C_0=''
fi

ci_section() { printf '\n%s== %s ==%s\n' "$_C_B" "$*" "$_C_0"; }
ci_ok()      { CI_OK=$((CI_OK+1));   printf '  %sok%s    %s\n' "$_C_G" "$_C_0" "$*"; }
ci_warn()    { CI_WARN=$((CI_WARN+1)); printf '  %sWARN%s  %s\n' "$_C_Y" "$_C_0" "$*"; }
ci_skip()    { CI_SKIP=$((CI_SKIP+1)); printf '  %sskip%s  %s\n' "$_C_Y" "$_C_0" "$*"; }

# ci_fail / ci_warn NUNCA leen stdin, y el detalle va en ARGUMENTOS.
#
# Dos bugs reales motivan este diseño, los dos verificados en vivo:
#
#  1. La primera versión hacía `[ ! -t 0 ] && sed ...` para recoger detalle por
#     tubería, y SE COLGABA: en un pipeline o en un hook de git, stdin no es un
#     tty pero tampoco trae datos ni se cierra, así que `sed` esperaba para
#     siempre. Un CI colgado es peor que un CI en rojo.
#
#  2. La variante `cmd | ci_fail_detail "..."` era PEOR todavía: el lado
#     derecho de una tubería corre en una SUBSHELL, así que el incremento de
#     CI_FAIL se perdía y `ci_summary` podía devolver VERDE después de haber
#     impreso FAIL. Un CI falso-verde es el fallo más caro posible.
#
# Uso correcto: captura la salida en una variable y pásala como 2º argumento.
#     out="$(shellcheck ... 2>&1)"
#     [ -n "$out" ] && ci_fail "shellcheck encontró problemas" "$out"
# Las cadenas multilínea se indentan línea a línea.
_ci_detail() { # $@=bloques de texto, posiblemente multilínea
  local block line
  for block in "$@"; do
    [ -n "$block" ] || continue
    while IFS= read -r line; do printf '          %s\n' "$line"; done <<< "$block"
  done
}

ci_fail() { # $1=titulo  [$2..=detalle]
  CI_FAIL=$((CI_FAIL+1))
  printf '  %sFAIL%s  %s\n' "$_C_R" "$_C_0" "$1"
  shift || true
  _ci_detail "$@"
}

ci_warn_with() { # $1=titulo  [$2..=detalle]  (ci_warn a secas sigue existiendo)
  CI_WARN=$((CI_WARN+1))
  printf '  %sWARN%s  %s\n' "$_C_Y" "$_C_0" "$1"
  shift || true
  _ci_detail "$@"
}

# Herramienta obligatoria ausente -> la etapa se OMITE (77), no falla.
# Se restauró tras haberse perdido en una reescritura de ci_fail: las etapas la
# usan para degradar con elegancia cuando falta shellcheck, lintian o similares.
ci_need() { # $1=binario  $2=cómo instalarlo
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  ci_skip "falta '$1' — instálalo con: $2"
  return 1
}

ci_summary() {
  printf '\n%s[%s]%s %d ok, %d fallos, %d avisos, %d omitidos\n' \
    "$_C_B" "$CI_STAGE" "$_C_0" "$CI_OK" "$CI_FAIL" "$CI_WARN" "$CI_SKIP"
  [ "$CI_FAIL" -gt 0 ] && return 1
  # Todo omitido y nada ejecutado: la etapa no pudo correr.
  [ "$CI_OK" -eq 0 ] && [ "$CI_SKIP" -gt 0 ] && return 77
  return 0
}
