#!/usr/bin/env bash
# ports/log.port.sh — CONTRATO del puerto de log.
#
# Existe para que domain/ y app/ nunca llamen a `printf >&2` ni a `logger`
# directamente: en una unit systemd el destino es el journal, en la CLI es la
# terminal, y en los tests es un buffer en memoria que se puede afirmar.
#
# Contrato:  log_info <msg>  log_warn <msg>  log_err <msg>  log_debug <msg>
#
# shellcheck shell=bash

port_log_assert() {
  local f missing=0
  for f in log_info log_warn log_err log_debug; do
    declare -F "$f" >/dev/null || {
      printf 'puerto log: el adaptador no implementa %s()\n' "$f" >&2; missing=1; }
  done
  return "$missing"
}
