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
aorus_use domain/target domain/link domain/overclock domain/display domain/health

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

echo "== domain/display: quién pinta el escritorio =="
yes_ "i915 es integrada"        domain_display_is_integrated i915
yes_ "xe es integrada"          domain_display_is_integrated xe
no_  "nvidia NO es integrada"   domain_display_is_integrated nvidia
yes_ "nvidia es de cómputo"     domain_display_is_compute nvidia
no_  "i915 no es de cómputo"    domain_display_is_compute i915

# El gate de seguridad. MEDIDO en esta máquina el 2026-11-02: tras mover el
# monitor externo de HDMI (card1, NVIDIA interna) a USB-C/Thunderbolt (card2,
# Intel DP-1), la iGPU tiene 2 salidas conectadas (eDP-1 + DP-1) y las dos
# NVIDIA ninguna. Ese es el caso 'ok'.
is "iGPU con 2 pantallas, NVIDIA con 0" "$(domain_display_release_verdict 2 0)" "ok"
is "iGPU con 1 pantalla, NVIDIA con 0"  "$(domain_display_release_verdict 1 0)" "ok"
# El caso que NO se puede descubrir reiniciando: dejaría la máquina ciega.
is "iGPU sin pantalla = bloquea"        "$(domain_display_release_verdict 0 1)" "no-display"
is "iGPU sin pantalla, NVIDIA tampoco"  "$(domain_display_release_verdict 0 0)" "no-display"
# El estado ANTERIOR de esta máquina: el HDMI colgaba de la NVIDIA interna.
is "pantalla en NVIDIA = se apagaría"   "$(domain_display_release_verdict 2 1)" "nvidia-outputs-lost"
# Recuentos inutilizables: no se afirma que sea seguro.
is "recuento vacío = unknown"           "$(domain_display_release_verdict '' 0)" "unknown"
is "recuento con basura = unknown"      "$(domain_display_release_verdict 2 'dos')" "unknown"

yes_ "2/0 se autoriza sin preguntar"    domain_display_release_allowed 2 0
no_  "0/0 NO se autoriza"               domain_display_release_allowed 0 0
no_  "2/1 NO se autoriza sin --force"   domain_display_release_allowed 2 1
no_  "unknown NO se autoriza"           domain_display_release_allowed '' 0

# El orden de descarga importa: nvidia_drm depende de nvidia_modeset y los dos
# de nvidia. Al revés, `modprobe -r` falla con "Module in use".
is "nvidia_drm va primero"  "$(domain_display_unload_order | head -1)" "nvidia_drm"
is "nvidia va al final"     "$(domain_display_unload_order | tail -1)" "nvidia"
is "son cuatro módulos"     "$(domain_display_unload_order | wc -l)" "4"

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

echo "== domain/health: clasificar lo que dice el kernel =="
# Las líneas son LITERALES del incidente del 2026-11-02 13:31:52-53, copiadas
# del journal. Si NVIDIA o el kernel cambian la redacción, estos asserts fallan
# y hay que actualizar los patrones -que es exactamente lo que se quiere, en vez
# de un detector que calla porque dejó de reconocer el mensaje.
XID79='NVRM: Xid (PCI:0000:b4:00): 79, GPU has fallen off the bus.'
XID154='NVRM: Xid (PCI:0000:b4:00): 154, GPU recovery action changed from 0x0 (None) to 0x1 (GPU Reset Required)'
USBDIS='usb 6-2: USB disconnect, device number 2'
LINKDN='pcieport 0000:89:03.0: pciehp: Slot(3): Link Down'
CARDGO='pcieport 0000:89:03.0: pciehp: Slot(3): Card not present'
TBDIS='thunderbolt 1-3: device disconnected'
TBCON='thunderbolt 1-3: new device found, vendor=0xed device=0x41cd'
LINKUP='pcieport 0000:89:03.0: pciehp: Slot(3): Link Up'
GPULOST='NVRM: nvCheckOkFailedNoLog: Check failed: GPU lost from the bus [NV_ERR_GPU_IS_LOST] (0x0000000F)'

is "Xid 79 se clasifica"        "$(domain_health_classify "$XID79")"   "xid_fallen_off_bus"
is "Xid 154 se clasifica"       "$(domain_health_classify "$XID154")"  "xid_recovery_required"
is "USB disconnect"             "$(domain_health_classify "$USBDIS")"  "usb_disconnect"
is "Link Down"                  "$(domain_health_classify "$LINKDN")"  "pcie_link_down"
is "Card not present"           "$(domain_health_classify "$CARDGO")"  "pcie_card_gone"
is "TB disconnect"              "$(domain_health_classify "$TBDIS")"   "tb_disconnect"
is "TB connect"                 "$(domain_health_classify "$TBCON")"   "tb_connect"
is "Link Up"                    "$(domain_health_classify "$LINKUP")"  "pcie_link_up"
is "GPU lost from the bus"      "$(domain_health_classify "$GPULOST")" "gpu_lost"
is "una linea cualquiera"       "$(domain_health_classify 'usb 1-1: new high-speed USB device')" "none"
is "linea vacia"               "$(domain_health_classify '')"         "none"
# El orden del case importa: "fallen off the bus" contiene "Xid" y debe ganar
# al patrón genérico, o el Xid 79 se degradaría a xid_other.
is "Xid 79 NO cae en xid_other" "$(domain_health_classify "$XID79")"   "xid_fallen_off_bus"
is "un Xid sin patron propio"   "$(domain_health_classify 'NVRM: Xid (PCI:0000:b4:00): 13, Graphics SM Warp Exception')" "xid_other"

echo "== domain/health: severidad =="
is "Xid 79 es critical"    "$(domain_health_severity xid_fallen_off_bus)" "critical"
is "Link Down es critical" "$(domain_health_severity pcie_link_down)"     "critical"
is "TB connect es info"    "$(domain_health_severity tb_connect)"         "info"
is "gpu_lost es warning"   "$(domain_health_severity gpu_lost)"           "warning"
is "clase none"            "$(domain_health_severity none)"               "none"

echo "== domain/health: extraer Xid y BDF =="
is "numero de Xid 79"      "$(domain_health_xid_number "$XID79")"  "79"
is "numero de Xid 154"     "$(domain_health_xid_number "$XID154")" "154"
no_ "sin Xid no hay numero" domain_health_xid_number "$USBDIS"
# El journal da "0000:b4:00" sin función; sysfs la necesita.
is "BDF normaliza la funcion" "$(domain_health_xid_bdf "$XID79")" "0000:b4:00.0"
no_ "sin Xid no hay BDF"      domain_health_xid_bdf "$LINKDN"
yes_ "79 es perdida de dispositivo"  domain_health_xid_is_device_loss 79
yes_ "154 es perdida de dispositivo" domain_health_xid_is_device_loss 154
no_  "13 NO es perdida"              domain_health_xid_is_device_loss 13

echo "== domain/health: veredicto de incidente (la regla que importa) =="
# La secuencia REAL del 2026-11-02, en el orden exacto en que ocurrio.
is "la secuencia real = perdida del dispositivo TB" \
   "$(domain_health_incident_verdict usb_disconnect pcie_link_down pcie_card_gone tb_disconnect xid_fallen_off_bus tb_connect pcie_link_up)" \
   "tb_device_loss"
# Sin USB, la caida es solo de la rama PCIe de la GPU.
is "link down sin USB = perdida del enlace PCIe" \
   "$(domain_health_incident_verdict pcie_link_down xid_fallen_off_bus)" \
   "pcie_link_loss"
# Xid con el bus INTACTO: eso si seria culpa de la GPU o del driver.
is "Xid sin caida de enlace = fallo de GPU" \
   "$(domain_health_incident_verdict xid_fallen_off_bus gpu_lost)" \
   "gpu_fault"
is "solo avisos = degradado"  "$(domain_health_incident_verdict gpu_lost xid_other)" "degraded"
is "nada = sano"              "$(domain_health_incident_verdict)"                    "healthy"
is "solo ruido = sano"        "$(domain_health_incident_verdict none none)"          "healthy"
# El arranque normal: la caja se conecta y el enlace sube, sin caida previa.
# Esto salia 'degraded' y llenaba el registro de falsos positivos.
is "solo conexion (arranque) = sano" \
   "$(domain_health_incident_verdict tb_connect pcie_card_present pcie_link_up)" "healthy"
# USB solo, sin PCIe ni tunel detras: NO se puede atribuir a la caja -podria
# ser cualquier pendrive-, asi que no se reporta. Ver la limitacion documentada
# en domain/health.sh: 6 casos ajenos en 13 dias de journal frente a 0 caidas
# reales de la caja sin Link Down.
is "USB suelto no se atribuye a la eGPU" \
   "$(domain_health_incident_verdict usb_disconnect)"     "healthy"
# El USB manda aunque solo haya tb_disconnect y ningun Link Down.
is "USB + TB disconnect = perdida del dispositivo" \
   "$(domain_health_incident_verdict usb_disconnect tb_disconnect)" "tb_device_loss"

echo "== domain/health: recuperacion =="
yes_ "con TB connect hubo recuperacion" \
     domain_health_incident_recovered usb_disconnect pcie_link_down tb_connect
no_  "sin reconexion no hubo recuperacion" \
     domain_health_incident_recovered usb_disconnect pcie_link_down xid_fallen_off_bus

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

echo "== app/overclock: los gates de seguridad (con dobles de puerto) =="
# Estos asserts existen porque la auditoria del 2026-11-02 encontro TRES huecos
# de seguridad en app/, no en el dominio, y ningun test podia verlos: hacen
# falta un enlace roto y un nvidia-smi colgado, que con hardware real no se
# provocan a voluntad. Con los dobles es trivial.
AORUS_ADAPTER_GPU=adapters/gpu/fake; export AORUS_ADAPTER_GPU
AORUS_ADAPTER_PCI=adapters/pci/fake; export AORUS_ADAPTER_PCI
AORUS_OC_STATE="$TD/oc.state"; export AORUS_OC_STATE
aorus_use app/overclock

# Devuelve solo el rc de oc_resolve_target, callando su salida.
oc_rc() { oc_resolve_target >/dev/null 2>&1; printf '%s' "$?"; }

# Enlace sano: Gen3 x4 es exactamente lo que mide esta maquina.
is "enlace Gen3 x4 -> resolve OK" \
   "$(AORUS_FAKE_GEN_MAX=3 AORUS_FAKE_LINK='8.0 GT/s PCIe|4' oc_rc)" "0"

# degraded: por debajo de Gen3. El gate cierra, y --force SI puede abrirlo.
is "Gen1 -> gate CIERRA" \
   "$(AORUS_FAKE_GEN_MAX=1 AORUS_FAKE_LINK='2.5 GT/s PCIe|4' oc_rc)" "2"
is "Gen1 + --force -> abre (riesgo asumible)" \
   "$(AORUS_OC_FORCE=1 AORUS_FAKE_GEN_MAX=1 AORUS_FAKE_LINK='2.5 GT/s PCIe|4' oc_rc)" "0"

# unknown: capacidad ilegible. CLAUDE.md: el gate CIERRA. --force NO lo abre.
is "capacidad ilegible -> gate CIERRA" \
   "$(AORUS_FAKE_GEN_MAX='' AORUS_FAKE_LINK='8.0 GT/s PCIe|4' oc_rc)" "2"
is "capacidad ilegible + --force -> SIGUE CERRADO" \
   "$(AORUS_OC_FORCE=1 AORUS_FAKE_GEN_MAX='' AORUS_FAKE_LINK='8.0 GT/s PCIe|4' oc_rc)" "2"

# dead: el tunel no esta entrenado (width 0). --force tampoco lo abre.
is "enlace muerto -> gate CIERRA" \
   "$(AORUS_FAKE_GEN_MAX=3 AORUS_FAKE_LINK='2.5 GT/s PCIe|0' oc_rc)" "2"
is "enlace muerto + --force -> SIGUE CERRADO" \
   "$(AORUS_OC_FORCE=1 AORUS_FAKE_GEN_MAX=3 AORUS_FAKE_LINK='2.5 GT/s PCIe|0' oc_rc)" "2"

# Solo lectura sigue permitida con el enlace roto: no escribe nada.
is "solo lectura pasa con enlace muerto" \
   "$(AORUS_OC_READONLY=1 AORUS_FAKE_GEN_MAX=3 AORUS_FAKE_LINK='2.5 GT/s PCIe|0' oc_rc)" "0"

# nvidia-smi colgado al resolver: 124 se propaga, no se degrada a fallo generico.
is "nvidia-smi colgado -> 124" "$(AORUS_FAKE_FIND_RC=124 oc_rc)" "124"
is "colgado leyendo el enlace -> 124" "$(AORUS_FAKE_GENMAX_RC=124 oc_rc)" "124"

echo "== app/overclock: rc=124 en una escritura ABORTA el plan =="
# El hueco era este: un 124 se trataba como fallo generico y el ejecutor
# SEGUIA con las dos escrituras siguientes. Tres escrituras de 12 s contra una
# tarjeta en estado-D es el martilleo que CLAUDE.md prohibe.
WL="$TD/writes.log"
: > "$WL"
plan_3ops() {
  printf 'power_limit\t180\n'
  printf 'gpu_clock\t1800\t3090\n'
  printf 'mem_clock\t14001\n'
}
# Caso sano: las tres escrituras se intentan.
plan_3ops | AORUS_FAKE_WRITELOG="$WL" AORUS_FAKE_WRITE_RC=0 oc_execute_plan 00000000:B4:00.0 >/dev/null 2>&1
is "plan sano: se intentan las 3 escrituras" "$(grep -c . "$WL")" "3"

: > "$WL"
plan_3ops | AORUS_FAKE_WRITELOG="$WL" AORUS_FAKE_WRITE_RC=124 oc_execute_plan 00000000:B4:00.0 >/dev/null 2>&1
rc_plan=$?
is "colgado en la 1a: solo UNA escritura intentada" "$(grep -c . "$WL")" "1"
is "y el ejecutor devuelve 124"                     "$rc_plan"              "124"

: > "$WL"
plan_3ops | AORUS_FAKE_WRITELOG="$WL" AORUS_FAKE_WRITE_RC=1 oc_execute_plan 00000000:B4:00.0 >/dev/null 2>&1
rc_plan=$?
# Un fallo NORMAL no aborta: se intentan las tres y se reporta error al final.
is "fallo normal: no aborta el plan"  "$(grep -c . "$WL")" "3"
is "y el ejecutor devuelve 1"         "$rc_plan"           "1"

echo "== app/health: el acumulador (orquestacion, no reglas) =="
# Estos asserts existen por un BUG REAL: _health_acc_emit se llamaba con
# sustitucion de comandos, o sea en un SUBSHELL, asi que su _health_acc_reset
# no llegaba al proceso padre y el acumulador NO se vaciaba nunca. Sobre 13
# dias de journal daba 13 incidentes con el mismo instante de inicio, dur
# creciendo hasta 929465 s, el BDF de la GPU INTERNA pegado del primer evento,
# y 5 tb_device_loss donde solo hay 2. El dominio estaba correcto; lo roto era
# la orquestacion, que ningun test del dominio podia ver.
AORUS_ADAPTER_KEVENTS=adapters/kevents/fake; export AORUS_ADAPTER_KEVENTS
AORUS_HEALTH_DIR="$TD/health"; export AORUS_HEALTH_DIR
AORUS_KEVENTS_FIXTURE="$TD/kevents.txt"; export AORUS_KEVENTS_FIXTURE
aorus_use app/health
# health_scan imprime los incidentes; al pasarlo a un assert hay que callarlo o
# ensucia la salida del runner.
quiet() { "$@" >/dev/null 2>&1; }

# DOS incidentes separados por mas de la ventana (30 s por defecto):
#  - el primero a las 1000, solo avisos de la GPU interna -> degraded
#  - el segundo a las 2000, la secuencia real de perdida del dispositivo
{
  printf '1000.100\tNVRM: Xid (PCI:0000:01:00): 13, Graphics SM Warp Exception\n'
  printf '2000.903\tusb 6-2: USB disconnect, device number 2\n'
  printf '2000.906\tpcieport 0000:89:03.0: pciehp: Slot(3): Link Down\n'
  printf '2000.907\tthunderbolt 1-3: device disconnected\n'
  printf '2001.213\tNVRM: Xid (PCI:0000:b4:00): 79, GPU has fallen off the bus.\n'
} > "$AORUS_KEVENTS_FIXTURE"

out="$(health_scan whatever)"
is "el acumulador separa 2 incidentes"  "$(printf '%s\n' "$out" | grep -c 'veredicto=')" "2"
is "el 1o es degraded"                  "$(printf '%s\n' "$out" | sed -n '1s/.*veredicto=\([a-z_]*\).*/\1/p')" "degraded"
is "el 2o es perdida del dispositivo"   "$(printf '%s\n' "$out" | sed -n '2s/.*veredicto=\([a-z_]*\).*/\1/p')" "tb_device_loss"
# El sintoma mas claro del bug: el BDF del primer evento se quedaba pegado a
# TODOS los incidentes siguientes, atribuyendo la caida a la GPU interna.
is "cada incidente lleva SU bdf"        "$(printf '%s\n' "$out" | sed -n '2s/.*bdf=\([^ ]*\).*/\1/p')" "0000:b4:00.0"
is "el 1o NO contamina al 2o"           "$(printf '%s\n' "$out" | sed -n '1s/.*bdf=\([^ ]*\).*/\1/p')" "0000:01:00.0"
# Con el bug, dur era la distancia al PRIMER evento de todo el barrido.
is "la duracion es la del incidente"    "$(printf '%s\n' "$out" | sed -n '2s/.*dur=\([0-9]*\)s.*/\1/p')" "1"
no_ "health_scan devuelve 1 si hay critico" quiet health_scan whatever

# El acumulador queda vacio tras emitir: si no, el siguiente barrido arrastra.
_health_acc_reset
no_ "tras reset el acumulador esta cerrado" _health_acc_open

# Una ventana de solo conexion (el arranque) no se reporta como incidente.
printf '3000.100\tthunderbolt 1-3: new device found, vendor=0xed\n' > "$AORUS_KEVENTS_FIXTURE"
is "el arranque no genera incidente" "$(health_scan whatever | grep -c 'veredicto=')" "0"

# Y el registro persistente recibe lo mismo que se reporto.
{
  printf '4000.903\tusb 6-2: USB disconnect, device number 2\n'
  printf '4000.906\tpcieport 0000:89:03.0: pciehp: Slot(3): Link Down\n'
} > "$AORUS_KEVENTS_FIXTURE"
health_scan_and_record whatever >/dev/null 2>&1
is "health_record escribe el incidente" \
   "$(grep -c 'tb_device_loss' "$AORUS_HEALTH_DIR/incidents.log" 2>/dev/null)" "1"

printf '\n%d pasados, %d fallados\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
