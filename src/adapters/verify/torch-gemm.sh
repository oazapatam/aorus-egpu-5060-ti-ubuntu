#!/usr/bin/env bash
# adapters/verify/torch-gemm.sh — implementación del puerto `verify` con
# PyTorch/CUDA sobre la eGPU.
#
# Qué mide y por qué estas dos pruebas y no otras:
#   1. GEMM con entrada ENTERA y comprobación BIT-EXACTA. El resultado es
#      analíticamente conocido, así que no hace falta referencia en CPU ni
#      tolerancia: cualquier bit distinto es un fallo. Es el camino que de
#      verdad usa una carga de IA (cuBLAS), y el primer sitio donde se nota un
#      offset de reloj demasiado agresivo.
#   2. PATRÓN conocido sobre buena parte de la VRAM, releído y comparado byte a
#      byte. El GEMM toca poca memoria y mucha SM; un offset de MEMORIA falla
#      al revés: la ALU calcula bien y lo que vuelve mal es lo que se guardó.
#
# El helper fija la GPU por PCI BUS-ID, nunca por ordinal: en esta máquina el
# ordinal 0 es la GPU INTERNA, y un test que use `cuda:0` da `pass` sin haber
# tocado la eGPU. Ver la cabecera de tools/pytorch-cuda-smoke-test.py, de donde
# sale el enfoque (enumerar y emparejar por pci_bus_id, sin
# CUDA_VISIBLE_DEVICES, que no acepta bus-ids y los lee como índices).

# shellcheck shell=bash

# torch no está en el python3 del sistema: vive en el venv del laboratorio
# (~/.venvs/egpu-torch-test). Por eso el intérprete es configurable, y por eso
# verify_available debe poder decir "no" sin que eso sea un error del paquete.
AORUS_VERIFY_PYTHON="${AORUS_VERIFY_PYTHON:-python3}"
AORUS_VERIFY_HELPER="${AORUS_VERIFY_HELPER:-${AORUS_LIB_ROOT:-/usr/lib/aorus-egpu}/adapters/verify/gemm-integrity.py}"
# Margen sobre el presupuesto de la prueba: importar torch e inicializar el
# runtime CUDA sobre un túnel Thunderbolt tarda varios segundos antes de que
# empiece a contar el primer kernel.
AORUS_VERIFY_MARGIN="${AORUS_VERIFY_MARGIN:-120}"
# La comprobación de disponibilidad también va acotada: `import torch` sobre un
# eGPU semi-roto se queda esperando al driver igual que nvidia-smi.
AORUS_VERIFY_PROBE_TIMEOUT="${AORUS_VERIFY_PROBE_TIMEOUT:-120}"
aorus_use domain/proc

# `-I` (modo aislado) en todas las invocaciones por lo mismo que en
# adapters/gpu/nvml.sh: esto puede correr como root y sin aislamiento un módulo
# plantado junto al script -o en el site-packages del usuario- se importaría.
verify_available() {
  [ -r "$AORUS_VERIFY_HELPER" ] || return 1
  command -v "$AORUS_VERIFY_PYTHON" >/dev/null 2>&1 || return 1
  timeout -k "$(domain_proc_kill_grace "$AORUS_VERIFY_PROBE_TIMEOUT")" \
    "$AORUS_VERIFY_PROBE_TIMEOUT" \
    "$AORUS_VERIFY_PYTHON" -I "$AORUS_VERIFY_HELPER" available >/dev/null 2>&1
}

verify_numeric_integrity() { # $1=busid $2=segundos
  local bus="${1:-}" secs="${2:-25}" out rc budget line
  if [ -z "$bus" ]; then
    printf 'errors=0 iters=0'
    return 2
  fi
  case "$secs" in
    ''|*[!0-9]*) secs=25 ;;
  esac
  budget=$(( secs + AORUS_VERIFY_MARGIN ))

  # `-k` por lo mismo que en adapters/gpu/*: sin él, un `import torch` colgado
  # contra la tarjeta semi-rota se lleva por delante al verificador Y al gate
  # que depende de su 124. La gracia se calcula aquí (no al cargar) porque el
  # presupuesto depende de los segundos pedidos; es un fork por verificación,
  # que dura decenas de segundos, así que no cuenta.
  out="$(timeout -k "$(domain_proc_kill_grace "$budget")" "$budget" \
         "$AORUS_VERIFY_PYTHON" -I "$AORUS_VERIFY_HELPER" \
         check "$bus" "$secs" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 124 ]; then
    # Colgado. El contrato del puerto es explícito: el caso de uso NO revierte
    # en este caso, porque revertir son dos escrituras más contra una tarjeta
    # que ya no responde — el martilleo que deja el eGPU wedged en estado-D.
    printf 'errors=0 iters=0'
    return 124
  fi

  line="$(printf '%s\n' "$out" | sed -n 's/^\(errors=[-0-9]* iters=[0-9]*\)$/\1/p' | tail -1)"
  if [ -z "$line" ]; then
    # El helper no llegó a emitir su resumen: no hay evidencia, así que esto es
    # 'no disponible' (rc 2 -> el gate CIERRA), nunca un 'pasa'.
    printf 'errors=0 iters=0'
    return 2
  fi
  printf '%s' "$line"
  return "$rc"
}
