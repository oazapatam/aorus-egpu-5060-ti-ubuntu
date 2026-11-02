#!/usr/bin/env bash
# ports/kevents.port.sh — CONTRATO del puerto de eventos del kernel.
#
# Existe para que app/health.sh no sepa nada de `journalctl`. La fuente real
# puede ser el journal, `dmesg`, o un fichero de texto en los tests: la regla
# de clasificación (domain/health.sh) no cambia por eso.
#
# Contrato:
#   kevents_read <desde>   emite las líneas del kernel desde <desde>, una por
#                          línea, con el formato "<epoch.micros>\t<mensaje>".
#                          <desde> es una expresión temporal ("-10 min", una
#                          hora "13:31:45", o "boot" para el arranque actual).
#   kevents_follow         igual, pero sigue emitiendo a medida que llegan.
#                          BLOQUEANTE: solo para el modo watch.
#
# El epoch va PRIMERO y en segundos con decimales a propósito: agrupar eventos
# en incidentes necesita aritmética, y el formato humano del journal
# ("nov 02 13:31:52") no se resta.
#
# shellcheck shell=bash

port_kevents_assert() {
  local f missing=0
  for f in kevents_read kevents_follow; do
    declare -F "$f" >/dev/null || {
      printf 'puerto kevents: el adaptador no implementa %s()\n' "$f" >&2; missing=1; }
  done
  return "$missing"
}
