#!/usr/bin/env bash
# adapters/kmod/linux.sh — implementación del puerto kmod sobre /proc, modprobe
# y systemctl. Único sitio con I/O de esta capacidad.

# shellcheck shell=bash

AORUS_KMOD_PROC="${AORUS_KMOD_PROC:-/proc/modules}"

kmod_available() { [ -r "$AORUS_KMOD_PROC" ] && command -v modprobe >/dev/null 2>&1; }

# /proc/modules: "<nombre> <tamaño> <refcount> <usuarios>, <offset> <estado>"
_kmod_field() { # $1=mod $2=número de campo
  awk -v m="$1" -v f="$2" '$1 == m { print $f; exit }' "$AORUS_KMOD_PROC" 2>/dev/null
}

kmod_loaded()   { [ -n "$(_kmod_field "$1" 1)" ]; }
kmod_refcount() { _kmod_field "$1" 3; }

# Los usuarios vienen como lista con comas, o "-" si no hay ninguno.
kmod_users() { # $1=mod
  local u; u="$(_kmod_field "$1" 4)"
  [ "$u" = "-" ] && return 0
  printf '%s' "${u%,}" | tr ',' ' '
}

kmod_unload() { modprobe -r "$1" 2>&1; }
kmod_load()   { modprobe "$1" 2>&1; }

# Procesos con un nodo del driver abierto. Sin fuser ni lsof: /proc es
# suficiente y no añade dependencias al paquete.
kmod_node_holders() {
  local fd pid target comm
  for fd in /proc/[0-9]*/fd/*; do
    target="$(readlink "$fd" 2>/dev/null)" || continue
    case "$target" in
      /dev/nvidia*) ;;
      *) continue ;;
    esac
    pid="${fd#/proc/}"; pid="${pid%%/*}"
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || comm="?"
    printf '%s %s\n' "$pid" "$comm"
  done | sort -u -k1,1n
}

kmod_service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
kmod_service_stop()   { systemctl stop "$1" 2>&1; }
