#!/usr/bin/env bash
# adapters/log/stderr.sh — puerto de log para la CLI y para units systemd.
#
# systemd captura stdout/stderr al journal, así que el mismo adaptador sirve en
# terminal y en servicio. AORUS_DEBUG=1 habilita log_debug.
# shellcheck shell=bash

log_info()  { printf '%s\n'      "$*"; }
log_warn()  { printf 'aviso: %s\n' "$*" >&2; }
log_err()   { printf 'ERROR: %s\n' "$*" >&2; }
log_debug() { [ "${AORUS_DEBUG:-0}" = "1" ] && printf 'debug: %s\n' "$*" >&2; return 0; }
