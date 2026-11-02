#!/usr/bin/env bash
# ci/run.sh — orquestador del CI local.
#
# Ejecuta las etapas ci/NN-*.sh en orden numérico y resume. Diseño:
#
#  - ORDEN POR NÚMERO, no alfabético: hay dependencias reales (lintian necesita
#    los .deb construidos, así que 60-lintian va después de 40-build).
#  - NO para en el primer fallo por defecto: en un CI local interesa ver TODO lo
#    que está mal de una pasada. `--fail-fast` para lo contrario.
#  - Distingue OMITIDA (77) de FALLO (1): un entorno sin shellcheck o sin
#    lintian no debe dar un falso rojo, pero sí debe decirse en el resumen.
#  - Cada etapa corre en su propio proceso: una etapa que muera no se lleva al
#    orquestador, y los contadores no se contaminan entre etapas.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' B=$'\033[1m' Z=$'\033[0m'
else
  R='' G='' Y='' B='' Z=''
fi

FAIL_FAST=0
declare -a WANT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fail-fast) FAIL_FAST=1 ;;
    -l|--list)
      for s in ci/[0-9][0-9]-*.sh; do [ -f "$s" ] && printf '%s\n' "$(basename "$s" .sh)"; done
      exit 0 ;;
    -h|--help)
      cat <<-USAGE
	ci/run.sh — CI local de este repo

	Uso:
	  ci/run.sh                    todas las etapas
	  ci/run.sh 10 30              solo las etapas que empiezan por 10 y 30
	  ci/run.sh shellcheck         por nombre parcial
	  ci/run.sh --list             lista las etapas
	  ci/run.sh --fail-fast        para en el primer fallo

	Códigos de salida: 0 todo bien, 1 algún fallo.
	Una etapa omitida (falta una herramienta) NO cuenta como fallo.
	USAGE
      exit 0 ;;
    -*) printf 'opción desconocida: %s\n' "$1" >&2; exit 2 ;;
    *)  WANT+=("$1") ;;
  esac
  shift
done

declare -a STAGES=()
for s in ci/[0-9][0-9]-*.sh; do
  [ -f "$s" ] || continue
  if [ "${#WANT[@]}" -gt 0 ]; then
    keep=0
    for w in "${WANT[@]}"; do case "$(basename "$s")" in *"$w"*) keep=1 ;; esac; done
    [ "$keep" -eq 1 ] || continue
  fi
  STAGES+=("$s")
done

if [ "${#STAGES[@]}" -eq 0 ]; then
  printf '%sno hay etapas que coincidan.%s Usa --list.\n' "$R" "$Z" >&2
  exit 2
fi

declare -a R_PASS=() R_FAILED=() R_SKIP=()
t0=$SECONDS

for s in "${STAGES[@]}"; do
  name="$(basename "$s" .sh)"
  printf '\n%s┌─ %s %s%s\n' "$B" "$name" "$(printf '─%.0s' $(seq 1 $((60 - ${#name})) ) )" "$Z"
  if [ ! -x "$s" ]; then
    printf '%s  etapa no ejecutable; la arreglo con chmod +x%s\n' "$Y" "$Z"
    chmod +x "$s" 2>/dev/null || true
  fi
  "$s"; rc=$?
  case "$rc" in
    0)  R_PASS+=("$name") ;;
    77) R_SKIP+=("$name") ;;
    *)  R_FAILED+=("$name")
        if [ "$FAIL_FAST" -eq 1 ]; then
          printf '\n%s--fail-fast: paro en %s%s\n' "$R" "$name" "$Z"
          break
        fi ;;
  esac
done

dt=$((SECONDS - t0))
printf '\n%s══ resumen del CI ══%s  (%ds)\n' "$B" "$Z" "$dt"
[ "${#R_PASS[@]}"   -gt 0 ] && printf '  %spasan%s    %s\n' "$G" "$Z" "${R_PASS[*]}"
[ "${#R_SKIP[@]}"   -gt 0 ] && printf '  %somitidas%s %s\n' "$Y" "$Z" "${R_SKIP[*]}"
[ "${#R_FAILED[@]}" -gt 0 ] && printf '  %sFALLAN%s   %s\n' "$R" "$Z" "${R_FAILED[*]}"

if [ "${#R_FAILED[@]}" -gt 0 ]; then
  printf '\n%sCI EN ROJO%s — %d etapa(s) con fallos\n' "$R" "$Z" "${#R_FAILED[@]}"
  exit 1
fi
printf '\n%sCI EN VERDE%s\n' "$G" "$Z"
exit 0
