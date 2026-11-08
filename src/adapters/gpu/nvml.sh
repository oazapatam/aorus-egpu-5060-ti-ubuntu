#!/usr/bin/env bash
# adapters/gpu/nvml.sh — adaptador del puerto GPU que AÑADE los offsets de
# reloj (NVML) a todo lo que ya hace el adaptador nvidia-smi.
#
# POR QUÉ ESTE ADAPTADOR SE APOYA EN OTRO (y por qué eso NO rompe la regla de
# dependencias de CLAUDE.md):
#
#   La regla dice que un adaptador puede depender del PUERTO que implementa y
#   de domain/, y nunca de "otros adaptadores". Lo que esa regla protege es que
#   una capacidad no alcance de lado la I/O de OTRO puerto —que el adaptador de
#   GPU no se ponga a leer sysfs del puerto PCI, por ejemplo—. Aquí no pasa
#   eso: nvidia-smi.sh y este fichero son dos implementaciones del MISMO puerto
#   (gpu), y esto es un DECORADOR de aquél: reutiliza su mitad y sustituye solo
#   las tres funciones de offset. Es la O de SOLID aplicada con lo que da bash:
#   extender sin modificar el adaptador que ya está validado.
#
#   La alternativa -reimplementar aquí -pl/-lgc/-lmc/caps/state sobre NVML-
#   sería DUPLICAR la lógica defensiva de nvidia-smi.sh (el `timeout`, el 124
#   que aborta, el targeting por bus-id) en un segundo sitio donde podría
#   divergir. Y la otra alternativa -cargar dos adaptadores del mismo puerto
#   desde app/- deja el resultado a merced del ORDEN de carga: con
#   AORUS_ADAPTER_GPU=fake, un `aorus_use adapters/gpu/nvml` posterior pisaría
#   las funciones del doble con escrituras NVML REALES. Eso es un falso
#   positivo con la tarjeta de verdad delante, y no se puede aceptar.
#
# POR QUÉ ES EL ADAPTADOR POR DEFECTO de app/overclock.sh: degrada honestamente.
# Si no hay python3 o no se puede importar pynvml, gpu_supports_clock_offset
# devuelve 3 ("no soportado"), el dominio rechaza los perfiles con offsets y
# TODO lo demás (power limit, locks, caps, estado, reset) sigue funcionando por
# nvidia-smi exactamente igual que antes.
#
# ESTADO MEDIDO (2026-11-02, eGPU 0000:B4:00.0, nvidia-ml-py 13.615.71):
#   nvmlDeviceGetGpcClkVfOffset = 0,  ventana (-1000, 1000) MHz
#   nvmlDeviceGetMemClkVfOffset = 0,  ventana (-2000, 6000) MHz
# Se usa esa API (GpcClk/MemClk VfOffset) y NO `nvmlDeviceGetClockOffsets` (la
# de driver 555+): el binding expone la función pero no el struct
# c_nvmlClockOffset_v1_t, así que hoy no es usable.
#
# `nvidia-settings` queda descartado para siempre en esta máquina: necesita
# NV-CONTROL sobre un servidor X y la sesión es Wayland.

# shellcheck shell=bash

aorus_use adapters/gpu/nvidia-smi

# El intérprete es configurable porque pynvml NO está en el python3 del
# sistema de esta máquina (comprobado: ModuleNotFoundError), y sí en el venv
# del laboratorio. El paquete recomienda python3-pynvml para el caso general:
#   AORUS_NVML_PYTHON=~/.venvs/egpu-torch-test/bin/python aorus-egpu-oc status
AORUS_NVML_PYTHON="${AORUS_NVML_PYTHON:-python3}"
AORUS_NVML_TIMEOUT="${AORUS_NVML_TIMEOUT:-20}"
aorus_use domain/proc
AORUS_NVML_KILL_GRACE="$(domain_proc_kill_grace "$AORUS_NVML_TIMEOUT")"
AORUS_NVML_HELPER="${AORUS_NVML_HELPER:-${AORUS_LIB_ROOT:-/usr/lib/aorus-egpu}/adapters/gpu/nvml-offsets.py}"

# TODA invocación va acotada por `timeout -k`, igual que nvidia-smi y por el
# mismo motivo: NVML habla con el mismo driver, y con la tarjeta semi-rota se
# queda esperando igual de indefinidamente. Un 124 se propaga tal cual para que
# el caso de uso ABORTE sin reintentar.
# `-k` NO es decorativo, y su ausencia fue un defecto real (2026-11-07): sin él
# `timeout` manda el SIGTERM al agotar el presupuesto y **se queda esperando al
# hijo**. Un proceso que no muere con TERM —y uno atascado hablando con un eGPU
# semi-roto no muere— cuelga a `timeout` con él, así que el 124 que el caso de
# uso espera para ABORTAR no llega nunca y con él se pierde la reversión, el
# registro y el aviso. Con `-k` llega el SIGKILL tras una gracia, y la gracia la
# decide domain/proc.sh. Se calcula UNA vez, al cargar el adaptador, porque esto
# se invoca docenas de veces y no va a forkear una subshell en cada llamada.
#
# `-I` (modo aislado) no es decorativo: esto corre como root, y sin él python
# añadiría el directorio del script y el site-packages del usuario al
# sys.path, de modo que un `pynvml.py` plantado al lado se ejecutaría con
# privilegios. Verificado que el venv sigue funcionando con -I.
_nvml() { # $@ = argumentos del helper
  timeout -k "$AORUS_NVML_KILL_GRACE" "$AORUS_NVML_TIMEOUT" \
    "$AORUS_NVML_PYTHON" -I "$AORUS_NVML_HELPER" "$@" 2>/dev/null
}

# Salida de `caps` (exactamente dos líneas):
#   supported=yes|no
#   window=<gmin> <gmax> <mmin> <mmax>
_nvml_caps() { # $1=busid
  [ -r "$AORUS_NVML_HELPER" ] || return 3
  command -v "$AORUS_NVML_PYTHON" >/dev/null 2>&1 || return 3
  _nvml caps "$1"
}

gpu_supports_clock_offset() { # $1=busid
  local out rc
  out="$(_nvml_caps "$1")"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && return 3
  case "$out" in
    *supported=yes*) return 0 ;;
  esac
  return 3
}

gpu_offset_window() { # $1=busid -> "gmin gmax mmin mmax"
  local out rc win
  out="$(_nvml_caps "$1")"; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -ne 0 ] && return 3
  win="$(printf '%s\n' "$out" | sed -n 's/^window=//p' | head -1)"
  # Si la ventana no se puede afirmar se devuelve rc 3 SIN imprimir: el
  # dominio lo traduce a "no soportado" y rechaza el perfil. Nunca se inventa
  # una ventana por defecto — escribiríamos un offset que nadie ha comprobado
  # que la tarjeta acepte.
  [ -n "$win" ] || return 3
  printf '%s' "$win"
}

# Escribe UN offset. El gate R4 se vuelve a aplicar DENTRO del helper (confirma
# el device-id 0x2d04 por el handle que NVML resuelve del bus-id, y aborta si
# es la interna) en vez de confiar en que la capa de arriba ya lo hizo: es la
# única función de todo el repo que escribe relojes por encima de stock, y la
# duplicación de un gate de seguridad en el punto de escritura es deliberada.
gpu_set_clock_offset() { # $1=busid $2=gpu|mem $3=mhz
  local rc
  [ -r "$AORUS_NVML_HELPER" ] || return 3
  command -v "$AORUS_NVML_PYTHON" >/dev/null 2>&1 || return 3
  _nvml set "$1" "$2" "$3" >/dev/null; rc=$?
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -eq 3 ] && return 3
  return "$rc"
}
