#!/usr/bin/env bash
# tests/egpu-tb-fix-replug.sh — regresión de H26 en egpu-tb-fix. Sin root, sin GPU.
#
# Por qué existe y por qué no está en tests/run.sh: `egpu-tb-fix` es el paquete
# principal y es ANTERIOR a la arquitectura hexagonal; su lógica vive en
# packaging/, no en src/, así que no se puede probar con `aorus_use`. En vez de
# dejarlo sin red, se carga el script entero con el `main "$@"` final
# neutralizado y se sustituyen por dobles las tres funciones que tocan hardware
# (egpus, age_of, locate_box) más el reloj.
#
# Lo que se fija aquí es el fallo del 2026-11-07: el túnel Thunderbolt se cayó
# mientras el script esperaba a que la caja se estabilizara, el device PCI salió
# de sysfs, y eso se leyó como "no hay ninguna eGPU conectada". La ejecución
# terminó sin preparar nada y, al abrir la compuerta al salir, borró la que el
# evento del replug acababa de cerrar: la tarjeta reapareció con el autoprobe
# encendido y sin BAR0. Detalle en
# docs/research/reliability-hypothesis-ledger.md (H26).
#
# Nota de diseño del harness: egpus(), age_of() y date() se invocan dentro de
# $(...), o sea en un subshell, así que pueden LEER estado pero no mutarlo. Por
# eso todo se deriva de un reloj falso que avanza únicamente en el `sleep` de
# wait_stable, que sí corre en el shell padre.
# REPLUG_SECS, STABLE_SECS, WAIT_SECS, DRY_RUN y RUN_STARTED los lee el script
# cargado desde lib.sh, no este fichero: para shellcheck parecen sin usar.
# shellcheck disable=SC2034
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/packaging/egpu-tb-fix/usr/sbin/egpu-tb-fix"
[ -r "$SCRIPT" ] || { echo "no encuentro $SCRIPT" >&2; exit 70; }

TMP="$(mktemp -d)" || exit 70
trap 'rm -rf "$TMP"' EXIT

sed 's/^main "\$@"$/: # main neutralizado por el test/' "$SCRIPT" > "$TMP/lib.sh"
# shellcheck source=/dev/null
. "$TMP/lib.sh"
# El script real trae `set -euo pipefail`: con -e, un wait_stable que retorna 1 a
# propósito (caja que no se estabiliza) mataría el test antes de comprobarlo.
set +e

pass=0 fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s — %s\n' "$1" "$2"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "esperaba '$3', obtuve '$2'"; }

# --- dobles -------------------------------------------------------------------
REPLUG_SECS=3; STABLE_SECS=2; WAIT_SECS=30
CLOCK=1000; GONE_FROM=99999; GONE_TO=99999; STABLE_AT=99999; LOGS=""

log()        { LOGS+="$*"$'\n'; }
sleep()      { CLOCK=$((CLOCK+1)); }   # el único que mueve el reloj
date()       { [ "${1:-}" = "+%s" ] && { echo "$CLOCK"; return; }; command date "$@"; }
egpus()      { if [ "$CLOCK" -ge "$GONE_FROM" ] && [ "$CLOCK" -lt "$GONE_TO" ]; then return 0; fi; echo "0000:8d:00.0"; }
age_of()     { if [ "$CLOCK" -ge "$STABLE_AT" ]; then echo 99; else echo 0; fi; }
locate_box() { echo "_ _ box0"; }
reset_()     { CLOCK=1000; LOGS=""; GONE_FROM=99999; GONE_TO=99999; STABLE_AT=99999; }
count()      { grep -c "$1" <<<"$LOGS"; }

echo "== egpu-tb-fix / wait_stable: un replug no es 'estable' =="

# Nunca hubo eGPU: retorna 0 sin inventarse un replug.
reset_; egpus() { return 0; }
wait_stable; is "sin eGPU conectada retorna 0" "$?" "0"
is "sin eGPU no habla de replug" "$(count replug)" "0"
egpus() { if [ "$CLOCK" -ge "$GONE_FROM" ] && [ "$CLOCK" -lt "$GONE_TO" ]; then return 0; fi; echo "0000:8d:00.0"; }

# eGPU presente y caja ya estable: retorna 0 en la primera vuelta.
reset_; STABLE_AT=0
wait_stable; is "caja ya estable retorna 0" "$?" "0"
is "caja estable no habla de replug" "$(count replug)" "0"

# EL FALLO DE H26: caja joven, el device se va 2 s y VUELVE. Antes salía como
# "estable" en el instante mismo en que desaparecía (reloj 1002) sin preparar
# nada; ahora espera a que vuelva (1004) y sigue hasta que la caja está estable.
reset_; GONE_FROM=1002; GONE_TO=1004; STABLE_AT=1004
wait_stable; is "replug: acaba en 0" "$?" "0"
is "replug: esperó a que volviera (reloj)" "$CLOCK" "1004"
is "replug: registra la salida de sysfs"   "$(count 'salió de sysfs')" "1"
is "replug: registra la vuelta"            "$(count 'eGPU volvió tras 2s')" "1"
is "replug: NO la da por desconectada"     "$(count 'doy por desconectada')" "0"

# El device se va y NO vuelve: se rinde tras REPLUG_SECS en vez de bloquear la
# compuerta durante los WAIT_SECS enteros.
reset_; GONE_FROM=1002
wait_stable; is "sin vuelta: retorna 0" "$?" "0"
is "sin vuelta: esperó REPLUG_SECS (reloj)" "$CLOCK" "1005"
is "sin vuelta: la da por desconectada"     "$(count 'doy por desconectada')" "1"
is "sin vuelta: no dice que volvió"         "$(count 'eGPU volvió tras')" "0"

# Caja que nunca se estabiliza: retorna 1, que es lo que deja las pendientes
# retenidas sin driver. "No bindea" es aceptable; "bindea y congela", no.
reset_; WAIT_SECS=5
wait_stable; is "caja inestable retorna 1" "$?" "1"
WAIT_SECS=30

echo "== egpu-tb-fix / open_gate: no pisar la compuerta de un evento posterior =="
AUTOPROBE="$TMP/autoprobe"; GATE_FILE="$TMP/gate"; DRY_RUN=0
removable_devices() { :; }
gate_state() { [ -e "$GATE_FILE" ] && echo existe || echo borrada; }

# Compuerta propia (cerrada antes de arrancar esta instancia): se abre.
RUN_STARTED=5000; echo 4000 > "$GATE_FILE"; echo 0 > "$AUTOPROBE"; LOGS=""
open_gate
is "compuerta propia: se borra"        "$(gate_state)" "borrada"
is "compuerta propia: autoprobe a 1"   "$(<"$AUTOPROBE")" "1"

# EL FALLO DE H26: compuerta posterior (la del replug). Debe respetarse, o la
# eGPU reaparece con el autoprobe encendido y nvidia la toma sin BAR0.
RUN_STARTED=5000; echo 6000 > "$GATE_FILE"; echo 0 > "$AUTOPROBE"; LOGS=""
open_gate
is "compuerta posterior: se respeta"      "$(gate_state)" "existe"
is "compuerta posterior: autoprobe a 0"   "$(<"$AUTOPROBE")" "0"
is "compuerta posterior: lo registra"     "$(count 'evento posterior')" "1"

# force: abre igualmente. Es la red de `open-gate` y del ExecStopPost del servicio.
RUN_STARTED=5000; echo 6000 > "$GATE_FILE"; echo 0 > "$AUTOPROBE"; LOGS=""
open_gate force
is "force: abre aunque sea posterior"  "$(gate_state)" "borrada"
is "force: autoprobe a 1"              "$(<"$AUTOPROBE")" "1"

# Marca ilegible: no debe dejar la compuerta cerrada para siempre.
RUN_STARTED=5000; echo "basura" > "$GATE_FILE"; echo 0 > "$AUTOPROBE"; LOGS=""
open_gate
is "marca ilegible: abre" "$(<"$AUTOPROBE")" "1"

# Sin RUN_STARTED (open_gate llamado fuera de main): conducta de siempre, abre.
RUN_STARTED=0; echo 6000 > "$GATE_FILE"; echo 0 > "$AUTOPROBE"; LOGS=""
open_gate
is "sin RUN_STARTED: abre" "$(<"$AUTOPROBE")" "1"

echo "== egpu-tb-fix / ungate: la eGPU sin BAR0 se atiende sin compuerta =="
rm -f "$GATE_FILE"
STARTED=no
systemctl() { case "$*" in *"start --no-block egpu-tb-fix.service"*) STARTED=si ;; esac; return 0; }
pending_egpus() { :; }

# EL FALLO DE H26: la compuerta ya no está porque la ejecución anterior la
# borró, pero hay una eGPU sin BAR0 y nadie más va a arreglarla.
broken_egpus() { echo "0000:8d:00.0"; }
STARTED=no; LOGS=""; ungate
is "eGPU sin BAR0 y sin compuerta: lanza el servicio" "$STARTED" "si"

# Nada roto y sin compuerta: no actúa.
broken_egpus() { :; }
STARTED=no; LOGS=""; ungate
is "sin compuerta y sin nada roto: no actúa" "$STARTED" "no"

# Con compuerta y una pendiente sin driver: lanza el servicio (conducta previa).
echo 6000 > "$GATE_FILE"; pending_egpus() { echo "0000:8d:00.0"; }
STARTED=no; LOGS=""; ungate
is "con compuerta y pendiente: lanza el servicio" "$STARTED" "si"

echo
echo "$pass asserts ok, $fail fallos"
[ "$fail" -eq 0 ]
