#!/usr/bin/env bash
# adapters/thunderbolt/boltctl.sh — puerto Thunderbolt sobre boltctl + sysfs.
#
# SOLO LECTURA (`boltctl list`). Autorizar/olvidar es competencia de
# aorus-egpu-connect en el paquete aorus-egpu-config.
# shellcheck shell=bash

AORUS_TB_ROOT="${AORUS_TB_ROOT:-/sys/bus/thunderbolt/devices}"

tb_available() { command -v boltctl >/dev/null 2>&1 || [ -d "$AORUS_TB_ROOT" ]; }

# Localiza la caja eGPU por sysfs y devuelve UN SOLO UUID, como exige el
# contrato del puerto. Los dominios (domainN) y el router del host no tienen
# `authorized`, así que ese fichero ya filtra los routers no conectables.
#
# Con varios periféricos TB (un dock Y la eGPU) hay más de un candidato, y
# devolver los dos pegados rompería a quien nos consuma con `$(...)`. Se
# desempata por topología: nos queda el device bajo cuyo árbol PCI aparece la
# eGPU. Si no se puede desempatar, se devuelve el primero y se avisa por rc 2
# para que el consumidor sepa que la elección fue arbitraria.
tb_device_uuid() {
  local d uid first="" n=0
  for d in "$AORUS_TB_ROOT"/*; do
    [ -r "$d/unique_id" ] || continue
    [ -r "$d/authorized" ] || continue
    uid="$(cat "$d/unique_id")"
    n=$((n + 1))
    [ -z "$first" ] && first="$uid"
    # El árbol del device TB contiene la eGPU: desempate fuerte.
    if [ -n "$(find "$d" -maxdepth 3 -name 'domain*' -prune -o \
                 -name 'device' -print 2>/dev/null | head -1)" ] &&
       grep -qls "$AORUS_EGPU_DEVICE" "$d"/*/device 2>/dev/null; then
      printf '%s' "$uid"; return 0
    fi
  done
  [ -z "$first" ] && return 1
  printf '%s' "$first"
  [ "$n" -gt 1 ] && return 2
  return 0
}

tb_is_authorized() { # $1=uuid
  local d
  for d in "$AORUS_TB_ROOT"/*; do
    [ -r "$d/unique_id" ] || continue
    [ "$(cat "$d/unique_id")" = "${1:-}" ] || continue
    [ "$(cat "$d/authorized" 2>/dev/null)" != "0" ] && return 0
    return 1
  done
  return 1
}

tb_policy() { # $1=uuid -> auto|manual|iommu|unknown
  local out
  command -v boltctl >/dev/null 2>&1 || { printf 'unknown'; return 1; }
  out="$(boltctl list 2>/dev/null | awk -v u="${1:-}" '
    $0 ~ u {found=1} found && /policy:/ {print $2; exit}')"
  printf '%s' "${out:-unknown}"
}
