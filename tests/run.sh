#!/usr/bin/env bash
# tests/run.sh — tests del DOMINIO. Sin root, sin GPU, sin tocar hardware.
#
# Esto es lo que compra la arquitectura hexagonal: las reglas que importan
# (el gate R4 y el gate de enlace) se verifican en milisegundos, en cualquier
# máquina, sin una eGPU conectada. Antes vivían enterradas en un script de 423
# líneas que solo se podía probar enchufando la caja y cruzando los dedos.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AORUS_LIB_ROOT="$ROOT/src"; export AORUS_LIB_ROOT
. "$ROOT/src/bootstrap.sh"
aorus_use domain/target domain/link domain/overclock

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s — %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "esperaba '$3', obtuve '$2'"; }
yes_() { if "${@:2}"; then ok "$1"; else bad "$1" "esperaba éxito"; fi; }
no_()  { if "${@:2}"; then bad "$1" "esperaba fallo"; else ok "$1"; fi; }

echo "== domain/target: gate R4 =="
yes_ "la eGPU 2d04 es target válido"      domain_target_is_egpu 0x10de 0x2d04
no_  "la interna 2c39 NO es target"       domain_target_is_egpu 0x10de 0x2c39
yes_ "la interna se reconoce como interna" domain_target_is_internal 0x10de 0x2c39
no_  "una AMD no es target"               domain_target_is_egpu 0x1002 0x2d04
is   "veredicto eGPU"     "$(domain_target_verdict 0x10de 0x2d04)" "egpu"
is   "veredicto interna"  "$(domain_target_verdict 0x10de 0x2c39)" "internal"
is   "veredicto otro"     "$(domain_target_verdict 0x8086 0x1234)" "other"
# Mayúsculas/minúsculas y prefijo: nvidia-smi devuelve 0x2D04, sysfs 0x2d04.
yes_ "id en mayúsculas normaliza"         domain_target_is_egpu 0x10DE 0x2D04
yes_ "id sin prefijo 0x normaliza"        domain_target_is_egpu 10de 2d04

echo "== domain/link: gate de enlace =="
is "Gen3 -> 3"   "$(domain_link_gen_from_speed '8.0 GT/s PCIe')"  "3"
is "Gen1 -> 1"   "$(domain_link_gen_from_speed '2.5 GT/s PCIe')"  "1"
is "Gen5 -> 5"   "$(domain_link_gen_from_speed '32.0 GT/s PCIe')" "5"
is "basura -> 0" "$(domain_link_gen_from_speed 'Unknown')"        "0"
# Veredicto INSTANTÁNEO: descriptivo. 'degraded' aquí NO significa avería; en
# reposo es el estado normal, porque el enlace baja de velocidad solo.
is "Gen3 x4 sano"        "$(domain_link_verdict '8.0 GT/s PCIe' 4)"  "healthy"
is "Gen1 x4 degradado"   "$(domain_link_verdict '2.5 GT/s PCIe' 4)"  "degraded"
is "width 0 = muerto"    "$(domain_link_verdict '8.0 GT/s PCIe' 0)"  "dead"
is "sin width = muerto"  "$(domain_link_verdict '8.0 GT/s PCIe' '')" "dead"

echo "== domain/link: gate por CAPACIDAD (el que autoriza el tuning) =="
# MEDIDO en esta máquina el 2026-11-02 con la eGPU funcionando:
#   pcie.link.gen.max   = 3   (capacidad negociada: Gen3, el tope de egpu-tb-fix)
#   current_link_speed  = 2.5 GT/s en reposo -> 8.0 bajo carga -> 2.5 otra vez
#   ancho de banda real = 3.06 GB/s H2D / 3.38 GB/s D2H (túnel TB saturado)
# Es decir: el enlace está SANO aunque la instantánea diga Gen1. El gate tiene
# que autorizar este caso; antes lo rechazaba y dejaba --force como único
# camino, que es apagar la propia protección.
is "cap Gen3 x4 sano"        "$(domain_link_cap_verdict 3 4)"  "healthy"
is "cap Gen4 x4 sano"        "$(domain_link_cap_verdict 4 4)"  "healthy"
is "cap Gen1 x4 degradado"   "$(domain_link_cap_verdict 1 4)"  "degraded"
is "cap Gen2 x4 degradado"   "$(domain_link_cap_verdict 2 4)"  "degraded"
is "cap sin width = muerto"  "$(domain_link_cap_verdict 3 '')" "dead"
is "cap width 0 = muerto"    "$(domain_link_cap_verdict 3 0)"  "dead"
is "cap vacía = unknown"     "$(domain_link_cap_verdict '' 4)" "unknown"
is "cap 0 = unknown"         "$(domain_link_cap_verdict 0 4)"  "unknown"
# Guardia de mal uso: pasar una cadena de velocidad donde se espera una
# generación debe CERRAR el gate, no reventar dentro de una subshell.
is "cap mal usada = unknown" "$(domain_link_cap_verdict '2.5 GT/s PCIe' 4)" "unknown"

yes_ "cap Gen3 permite tuning"       domain_link_allows_tuning 3 4
no_  "cap Gen1 NO permite tuning"    domain_link_allows_tuning 1 4
no_  "cap unknown NO permite tuning" domain_link_allows_tuning '' 4
no_  "cap dead NO permite tuning"    domain_link_allows_tuning 3 0
# El estado REAL de la máquina al 2026-11-02 (Gen3 negociado, 2.5 GT/s en
# reposo) debe AUTORIZAR el tuning sin necesidad de --force.
yes_ "estado real actual (cap Gen3, reposo 2.5) autorizado" domain_link_allows_tuning 3 4

echo "== domain/overclock: clamping y plan =="
is "clamp dentro"  "$(domain_oc_clamp 165 150 180)" "165"
is "clamp abajo"   "$(domain_oc_clamp 100 150 180)" "150"
is "clamp arriba"  "$(domain_oc_clamp 250 150 180)" "180"
yes_ "entero válido"    domain_oc_is_uint 180
no_  "negativo inválido" domain_oc_is_uint -5
no_  "texto inválido"   domain_oc_is_uint abc
yes_ "clave conocida"   domain_oc_key_is_valid power_limit_w
no_  "clave inventada"  domain_oc_key_is_valid turbo_boost_please

# El plan acota contra las capacidades REALES de la RTX 5060 Ti: 150-180 W,
# 3090 MHz gráfico, 14001 MHz memoria.
#
# Las OC_* de aquí abajo parecen "sin usar" a shellcheck (SC2034) porque el
# dominio las lee del ENTORNO del shell, no por parámetro, y shellcheck no sigue
# a través de `aorus_use`. Son la entrada real de domain_oc_plan/
# domain_oc_validate: ponerlas es el test. No se exportan a propósito — las
# funciones corren en este mismo shell o en `$(...)`, que ya hereda las
# variables, y exportarlas las filtraría a awk/grep sin ninguna necesidad.
# shellcheck disable=SC2034
OC_profile=test OC_power_limit_w=250 OC_gpu_clock_max_mhz=9999 OC_mem_clock_mhz=99999
plan="$(domain_oc_plan 150 180 3090 14001)"
is "plan acota potencia a 180" "$(printf '%s' "$plan" | awk -F'\t' '/power_limit/{print $2}')" "180"
is "plan acota reloj a 3090"   "$(printf '%s' "$plan" | awk -F'\t' '/gpu_clock/{print $3}')"   "3090"
is "plan acota memoria a 14001" "$(printf '%s' "$plan" | awk -F'\t' '/mem_clock/{print $2}')"  "14001"

OC_profile=stock
is "perfil stock = reset" "$(domain_oc_plan 150 180 3090 14001 | tr '\t' ' ')" "reset all"

# Los offsets de +MHz deben RECHAZARSE, no aplicarse en silencio.
unset OC_power_limit_w OC_gpu_clock_max_mhz OC_mem_clock_mhz
# shellcheck disable=SC2034  # entrada por entorno del dominio; ver nota arriba.
OC_profile=oc OC_gpu_clock_offset_mhz=200
no_ "offset de reloj se rechaza" domain_oc_validate 150 180 3090 14001

# min > max es un error del usuario y debe abortar antes de escribir nada.
unset OC_gpu_clock_offset_mhz
# shellcheck disable=SC2034  # entrada por entorno del dominio; ver nota arriba.
OC_gpu_clock_min_mhz=3000 OC_gpu_clock_max_mhz=1000
no_ "min>max se rechaza" domain_oc_validate 150 180 3090 14001

echo "== domain/overclock: allowlist de operaciones del plan =="
yes_ "power_limit es op válida"   domain_oc_op_is_valid power_limit
yes_ "reset es op válida"         domain_oc_op_is_valid reset
no_  "op inventada se rechaza"    domain_oc_op_is_valid overvolt_now

echo "== ports: todo adaptador cumple su contrato =="
aorus_use ports/gpu.port ports/pci.port ports/log.port ports/thunderbolt.port ports/trace.port
( aorus_use adapters/gpu/nvidia-smi        && port_gpu_assert ) >/dev/null 2>&1 \
  && ok "adaptador gpu/nvidia-smi cumple el puerto" \
  || bad "adaptador gpu/nvidia-smi cumple el puerto" "falta alguna función"
( aorus_use adapters/pci/sysfs             && port_pci_assert ) >/dev/null 2>&1 \
  && ok "adaptador pci/sysfs cumple el puerto" \
  || bad "adaptador pci/sysfs cumple el puerto" "falta alguna función"
( aorus_use adapters/log/stderr            && port_log_assert ) >/dev/null 2>&1 \
  && ok "adaptador log/stderr cumple el puerto" \
  || bad "adaptador log/stderr cumple el puerto" "falta alguna función"
( aorus_use adapters/thunderbolt/boltctl   && port_thunderbolt_assert ) >/dev/null 2>&1 \
  && ok "adaptador thunderbolt/boltctl cumple el puerto" \
  || bad "adaptador thunderbolt/boltctl cumple el puerto" "falta alguna función"
( aorus_use adapters/trace/durable         && port_trace_assert ) >/dev/null 2>&1 \
  && ok "adaptador trace/durable cumple el puerto" \
  || bad "adaptador trace/durable cumple el puerto" "falta alguna función"

echo "== adapters/trace: la traza TIENE que sobrevivir =="
# Es la garantía de la que depende depurar un cuelgue: si trace_mark no deja el
# dato en disco antes de volver, no sirve de nada. Se prueba en un directorio
# temporal, sin root y sin tocar /var/log.
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
# shellcheck disable=SC2034  # la lee adapters/trace/durable.sh, que se carga en
# la línea siguiente con `aorus_use` (ruta dinámica: shellcheck no la sigue).
AORUS_TRACE_ROOT="$TD"
aorus_use adapters/trace/durable
# OJO: sin subshell — trace_begin exporta AORUS_TRACE_DIR (ver el puerto).
trace_begin "autotest" >/dev/null
is "trace_begin crea el directorio" "$([ -d "$AORUS_TRACE_DIR" ] && echo si || echo no)" "si"
is "trace_begin escribe 00-meta"    "$([ -s "$AORUS_TRACE_DIR/00-meta.txt" ] && echo si || echo no)" "si"
trace_mark "PASO_UNO" "detalle libre"
is "trace_mark crea el log"         "$([ -s "$AORUS_TRACE_DIR/10-breadcrumbs.log" ] && echo si || echo no)" "si"
is "la miga contiene el paso"       "$(grep -c 'PASO_UNO' "$AORUS_TRACE_DIR/10-breadcrumbs.log")" "1"
is "la miga contiene el detalle"    "$(grep -c 'detalle libre' "$AORUS_TRACE_DIR/10-breadcrumbs.log")" "1"
trace_mark "PASO_DOS" ""
is "las migas se acumulan en orden" "$(awk -F'|' 'END{print $3}' "$AORUS_TRACE_DIR/10-breadcrumbs.log" | tr -d ' ')" "PASO_DOS"
trace_snapshot "autotest"
is "trace_snapshot escribe fichero" "$([ -s "$AORUS_TRACE_DIR/20-snapshot-autotest.txt" ] && echo si || echo no)" "si"
trace_end "ok"
is "trace_end cierra el meta"       "$(grep -c '^estado:' "$AORUS_TRACE_DIR/00-meta.txt")" "1"
# Sin traza abierta, trace_mark no debe explotar ni escribir fuera de sitio.
AORUS_TRACE_DIR=""
yes_ "trace_mark sin traza abierta no falla" trace_mark "HUERFANO" ""

printf '\n%d pasados, %d fallados\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
