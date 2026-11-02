#!/usr/bin/env bash
# adapters/kevents/journalctl.sh — eventos del kernel leídos del journal.
#
# Único sitio de este flujo con I/O. `-o short-unix` da el epoch con
# microsegundos, que es lo que app/health.sh necesita para agrupar.
#
# POR QUÉ NO `dmesg`: su reloj es monotónico desde el arranque, no epoch, y
# tras un cuelgue el journal en disco sobrevive y el buffer de dmesg no.
# shellcheck shell=bash

# Normaliza la salida de journalctl a "<epoch>\t<mensaje>".
# `-o short-unix` emite "1793644312.903030 host kernel: texto"; se quitan el
# host y el prefijo de la facility para que domain/health.sh reciba el mensaje
# tal cual, sin saber de formatos.
_kevents_normalize() {
  sed -E 's/^([0-9]+\.[0-9]+) [^ ]+ ([a-zA-Z0-9_.-]+(\[[0-9]+\])?): /\1\t\2: /' |
  awk -F'\t' 'NF==2 {print; next} {print $0}'
}

# OJO CON `-k`: implica `-b`, asi que FILTRA AL ARRANQUE ACTUAL en silencio.
# Medido el 2026-11-02: `journalctl -k --since '11:00' --until '13:00'` devolvia
# 0 eventos mientras `journalctl -k -b -1` tenia 28 -- el incidente del arranque
# anterior era invisible, que es precisamente el historico que hace falta para
# acumular evidencia. Se usa el match `_TRANSPORT=kernel`, que selecciona los
# mismos mensajes SIN implicar `-b`.
_KEVENTS_MATCH=_TRANSPORT=kernel

kevents_read() { # $1=desde
  local since="${1:-boot}"
  if [ "$since" = "boot" ]; then
    journalctl "$_KEVENTS_MATCH" -b -o short-unix --no-pager 2>/dev/null | _kevents_normalize
  else
    journalctl "$_KEVENTS_MATCH" -o short-unix --no-pager --since "$since" 2>/dev/null | _kevents_normalize
  fi
}

kevents_follow() {
  journalctl "$_KEVENTS_MATCH" -o short-unix --no-pager -f -n 0 2>/dev/null | _kevents_normalize
}
