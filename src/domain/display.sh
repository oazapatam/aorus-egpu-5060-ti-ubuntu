#!/usr/bin/env bash
# domain/display.sh — reglas puras sobre quién debe pintar el escritorio.
#
# Capa de DOMINIO: puro. Recibe lo que el adaptador ya leyó de DRM y decide.
#
# POR QUÉ EXISTE: en esta máquina hay tres GPUs (iGPU Intel, dGPU NVIDIA interna
# y eGPU NVIDIA por Thunderbolt) y el objetivo es que el escritorio salga SIEMPRE
# por la iGPU, para dejar las dos NVIDIA libres para cómputo y poder cargar y
# descargar su driver sin pelearse con el compositor.
#
# El gate que vive aquí es de seguridad, no de estética: si se le quita a NVIDIA
# el modeset y la iGPU no tiene ninguna salida conectada, la máquina arranca
# CIEGA. Eso no se puede descubrir después de reiniciar, así que se decide antes
# y con una función testeada.

# shellcheck shell=bash

# Drivers DRM que consideramos "integrados" y aptos para el escritorio.
# No es una lista de gustos: es la lista de los que NO queremos liberar.
readonly AORUS_DISPLAY_INTEGRATED_DRIVERS="i915 xe amdgpu radeon"

# Drivers cuyo modeset queremos poder apagar para dedicar la GPU a cómputo.
readonly AORUS_DISPLAY_COMPUTE_DRIVERS="nvidia"

domain_display_is_integrated() { # $1=driver DRM
  local d=" $AORUS_DISPLAY_INTEGRATED_DRIVERS "
  case "$d" in *" ${1:-} "*) return 0 ;; esac
  return 1
}

domain_display_is_compute() { # $1=driver DRM
  local d=" $AORUS_DISPLAY_COMPUTE_DRIVERS "
  case "$d" in *" ${1:-} "*) return 0 ;; esac
  return 1
}

# ¿Es un entero no negativo? Un recuento vacío o con basura no puede pasar por
# cero en silencio: cero es justamente la condición que BLOQUEA.
domain_display_is_count() { # $1=valor
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Veredicto de si se puede liberar la GPU de cómputo del trabajo de pantalla.
#
# Imprime ok|no-display|nvidia-outputs-lost|unknown y devuelve:
#   0  ok                   — la iGPU tiene pantalla y NVIDIA no: adelante.
#   1  no-display           — la iGPU no tiene NINGUNA salida conectada.
#                             BLOQUEA: el cambio dejaría la máquina ciega.
#   2  nvidia-outputs-lost  — la iGPU tiene pantalla, pero NVIDIA también está
#                             conduciendo alguna que se apagará. Es una decisión
#                             del usuario, no un bug: se permite con --force.
#   3  unknown              — algún recuento no es utilizable. No se afirma que
#                             sea seguro, así que no se autoriza.
domain_display_release_verdict() { # $1=salidas iGPU conectadas $2=salidas NVIDIA conectadas
  local igpu="${1:-}" nvidia="${2:-}"
  if ! domain_display_is_count "$igpu" || ! domain_display_is_count "$nvidia"; then
    printf 'unknown'; return 3
  fi
  if [ "$igpu" -eq 0 ]; then
    printf 'no-display'; return 1
  fi
  if [ "$nvidia" -gt 0 ]; then
    printf 'nvidia-outputs-lost'; return 2
  fi
  printf 'ok'; return 0
}

# ¿Se autoriza el cambio sin intervención del usuario?
domain_display_release_allowed() { # $1=salidas iGPU $2=salidas NVIDIA
  [ "$(domain_display_release_verdict "$1" "$2")" = "ok" ]
}

# Módulos que hay que descargar, y EN ESTE ORDEN, para soltar el driver NVIDIA.
# El orden no es cosmético: nvidia_drm depende de nvidia_modeset, y los dos de
# nvidia, así que al revés `modprobe -r` falla con "Module in use".
domain_display_unload_order() {
  printf 'nvidia_drm\nnvidia_modeset\nnvidia_uvm\nnvidia\n'
}
