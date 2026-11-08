#!/usr/bin/env bash
# ports/verify.port.sh — CONTRATO del verificador NUMÉRICO de la eGPU.
#
# PARA QUÉ EXISTE, que es lo único que justifica un puerto nuevo: el resto de
# los gates de este repo protegen contra fallos RUIDOSOS —el host se congela,
# nvidia-smi se queda en estado-D, el túnel se cae y salta un Xid 79—. Un
# offset de reloj positivo no falla así. Falla CALCULANDO MAL: el kernel CUDA
# termina, nadie ve un error, y el resultado trae bits distintos de los que
# debía. En una máquina que se usa para cargas de IA eso es el peor fallo
# posible, porque se propaga a los pesos y no deja rastro en ningún log.
#
# De ahí la asimetría con --force que fija app/overclock.sh: un enlace
# degradado es un riesgo que el operador puede EVALUAR y asumir; un número mal
# calculado no lo puede ni detectar, así que no puede consentirlo. Este puerto
# es la única forma de obtener esa evidencia, y sin evidencia no se escribe.
#
# Contrato (todo adaptador de este puerto implementa):
#   verify_available                       -> 0 si el verificador es usable
#                                             AHORA (intérprete, dependencias,
#                                             runtime CUDA). Debe ser BARATO y
#                                             no debe cargar la GPU.
#   verify_numeric_integrity <busid> <segundos>
#                                          -> rc 0   la GPU calcula bien
#                                             rc 1   FALLA: hubo al menos un
#                                                    resultado incorrecto
#                                             rc 2   no disponible (sin
#                                                    evidencia: el gate CIERRA)
#                                             rc 124 colgado (NO reintentar, NO
#                                                    revertir: martillear un
#                                                    eGPU semi-roto lo deja
#                                                    wedged en estado-D)
#                                             imprime "errors=<n> iters=<n>"
#
# Invariantes del contrato:
#   - La comprobación es BIT-EXACTA, nunca por tolerancia. Un GEMM con entrada
#     entera tiene un resultado exacto conocido; comparar con epsilon es
#     justamente la forma de no ver el fallo que se busca.
#   - Se direcciona por PCI bus-id, nunca por ordinal CUDA (gate R4: en esta
#     máquina el ordinal 0 es la GPU INTERNA, ver
#     tools/pytorch-cuda-smoke-test.py).
#   - `segundos` es un PRESUPUESTO de tiempo, no un objetivo: el adaptador para
#     cuando lo agota y reporta cuántas iteraciones hizo.
#
# shellcheck shell=bash

port_verify_assert() {
  local f missing=0
  for f in verify_available verify_numeric_integrity; do
    declare -F "$f" >/dev/null || {
      printf 'puerto verify: el adaptador no implementa %s()\n' "$f" >&2; missing=1; }
  done
  return "$missing"
}

# Defaults HONESTOS: sin adaptador cargado no hay verificador, y "no hay
# verificador" se traduce en rc 2, que para app/ significa gate CERRADO. El
# default no puede ser 0 ("pasa"): eso convertiría la ausencia de evidencia en
# una afirmación de que la GPU calcula bien.
verify_available() { return 1; }

verify_numeric_integrity() { # $1=busid $2=segundos
  printf 'errors=0 iters=0'
  return 2
}
