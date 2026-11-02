#!/usr/bin/env bash
# ports/trace.port.sh — CONTRATO del puerto de traza forense.
#
# Para qué: cuando el host se CONGELA del todo (sin Xid, sin panic, sin oops),
# todo lo que estaba en RAM se pierde — incluido el buffer de journald. Al
# reiniciar no queda ni una pista de qué se estaba haciendo. Este puerto define
# la traza que SÍ sobrevive: escritura en disco con fsync ANTES de cada paso
# arriesgado, de modo que el último paso registrado es el que mató la máquina.
#
# Contrato:
#   trace_begin <sesion>            -> abre la traza; imprime su directorio Y
#                                      exporta AORUS_TRACE_DIR.
#                                      OJO: NO lo llames en una subshell
#                                      `dir=$(trace_begin x)` — la asignación de
#                                      AORUS_TRACE_DIR se perdería y trace_mark
#                                      saldría en silencio sin escribir nada.
#                                      Uso correcto:
#                                        trace_begin x >/dev/null
#                                        dir="$AORUS_TRACE_DIR"
#   trace_mark  <paso> [detalle]    -> registra un paso y lo FUERZA a disco
#   trace_snapshot <nombre>         -> guarda estado de hardware en la traza
#   trace_end   <estado>            -> cierra la traza
#
# Invariante no negociable: trace_mark no retorna hasta que el dato está en el
# plato. Una traza que se pierde en el cuelgue no sirve para nada.
#
# shellcheck shell=bash

port_trace_assert() {
  local f missing=0
  for f in trace_begin trace_mark trace_snapshot trace_end; do
    declare -F "$f" >/dev/null || {
      printf 'puerto trace: el adaptador no implementa %s()\n' "$f" >&2; missing=1; }
  done
  return "$missing"
}
