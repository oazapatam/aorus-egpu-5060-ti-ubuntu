#!/usr/bin/env bash
# bootstrap.sh — cargador de las capas del núcleo (arquitectura hexagonal).
#
# Resuelve la raíz de las librerías en los DOS escenarios y expone `aorus_use`
# como única forma de cargar una capa:
#
#   - en el repo (desarrollo):  <repo>/src/
#   - instalado por el .deb:    /usr/lib/aorus-egpu/
#
# Así el MISMO código corre desde el checkout y desde el paquete, sin ramas.
# Ver docs/architecture.md para la regla de dependencias entre capas.

# shellcheck shell=bash

if [ -z "${AORUS_LIB_ROOT:-}" ]; then
  _bs_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -d "$_bs_self/domain" ]; then
    AORUS_LIB_ROOT="$_bs_self"            # repo: .../src
  elif [ -d /usr/lib/aorus-egpu/domain ]; then
    AORUS_LIB_ROOT=/usr/lib/aorus-egpu    # instalado
  else
    printf 'aorus: no encuentro las librerías (AORUS_LIB_ROOT)\n' >&2
    exit 70
  fi
  unset _bs_self
fi
export AORUS_LIB_ROOT

# Registro de módulos ya cargados: `aorus_use` es idempotente, así que un caso
# de uso puede declarar todas sus dependencias sin preocuparse por duplicados.
declare -A _AORUS_LOADED=()

# aorus_use <capa>/<modulo> [...]
#   aorus_use domain/overclock adapters/gpu/nvidia-smi
aorus_use() {
  local mod path
  for mod in "$@"; do
    [ -n "${_AORUS_LOADED[$mod]:-}" ] && continue
    path="$AORUS_LIB_ROOT/$mod.sh"
    if [ ! -r "$path" ]; then
      printf 'aorus: módulo no encontrado: %s (%s)\n' "$mod" "$path" >&2
      return 70
    fi
    _AORUS_LOADED[$mod]=1
    # shellcheck disable=SC1090
    . "$path"
  done
}

# Selección de adaptador por entorno: permite sustituir una implementación
# (p. ej. un doble de test) sin tocar los casos de uso — Inversión de
# Dependencias (la D de SOLID) hecha con lo que da bash.
#   AORUS_ADAPTER_GPU=adapters/gpu/fake aorus-egpu-oc status
aorus_adapter() { # $1=puerto (gpu|pci|thunderbolt|log) $2=adaptador por defecto
  local var="AORUS_ADAPTER_${1^^}"
  aorus_use "${!var:-$2}"
}
