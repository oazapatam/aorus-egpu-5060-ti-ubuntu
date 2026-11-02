#!/usr/bin/env bash
# domain/overclock.sh — reglas de tuning de la eGPU: validación, clamping y
# generación del PLAN. Capa de DOMINIO: PURA, sin I/O.
#
# Idea central: el dominio NO toca el hardware. Recibe (perfil + capacidades
# leídas) y emite un PLAN: líneas `op<TAB>arg...` que un adaptador ejecuta. Así
# se puede testear toda la aritmética y todos los límites sin GPU y sin root, y
# cambiar de `nvidia-smi` a NVML sin reescribir una sola regla.
#
# ALCANCE REAL (importante, sin promesas falsas): con el driver NVIDIA en Linux
# headless/Wayland solo hay palancas de LÍMITE y BLOQUEO de reloj:
#   - power limit            (nvidia-smi -pl)
#   - lock de reloj gráfico  (nvidia-smi -lgc)
#   - lock de reloj memoria  (nvidia-smi -lmc)
# Los OFFSETS de frecuencia por encima de stock (el "overclock" clásico de
# +MHz) requieren `nvidia-settings` con Coolbits bajo Xorg, o las llamadas NVML
# de VF offset; NINGUNA está disponible aquí (sesión Wayland, sin pynvml). El
# puerto gpu.port define `gpu_set_clock_offset` para que un adaptador futuro lo
# implemente, pero el perfil que lo pida se rechaza como no soportado en vez de
# fingir que se aplicó. Ver docs/overclock.md.

# shellcheck shell=bash

# Operaciones válidas del plan. Es la ÚNICA definición: el ejecutor pregunta
# aquí en vez de llevar su propia lista (tener la allowlist en dos capas es
# justo lo que este diseño evita). `clock_offset` está incluido a propósito
# aunque hoy ningún adaptador lo implemente: el plan nunca lo emite porque
# domain_oc_validate rechaza antes los perfiles que lo piden.
readonly AORUS_OC_OPS="power_limit gpu_clock mem_clock clock_offset reset"

domain_oc_op_is_valid() { # $1=op
  local o
  for o in $AORUS_OC_OPS; do [ "$o" = "${1:-}" ] && return 0; done
  return 1
}

# --- utilidades puras ---------------------------------------------------------

domain_oc_is_uint() { # $1=valor
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# Acota un entero al rango [min,max]. Imprime el valor acotado.
domain_oc_clamp() { # $1=valor $2=min $3=max
  local v="$1" lo="$2" hi="$3"
  [ "$v" -lt "$lo" ] && { printf '%s' "$lo"; return 0; }
  [ "$v" -gt "$hi" ] && { printf '%s' "$hi"; return 0; }
  printf '%s' "$v"
}

# --- perfiles -----------------------------------------------------------------
#
# Un perfil es un conjunto de claves key=value. Se valida ESTRICTAMENTE: una
# clave desconocida es un error, no un aviso silencioso, para que un typo en
# /etc/aorus-egpu/overclock.conf no deje la eGPU en un estado que nadie pidió.
readonly AORUS_OC_KEYS="power_limit_w gpu_clock_min_mhz gpu_clock_max_mhz mem_clock_mhz gpu_clock_offset_mhz mem_clock_offset_mhz"

domain_oc_key_is_valid() { # $1=clave
  local k
  for k in $AORUS_OC_KEYS; do [ "$k" = "${1:-}" ] && return 0; done
  return 1
}

# Valida un perfil ya parseado a variables OC_<clave>. Imprime los errores
# encontrados (uno por línea) y devuelve 1 si hubo alguno.
domain_oc_validate() { # usa OC_* del entorno; $1=cap_power_min $2=cap_power_max $3=cap_gpu_max $4=cap_mem_max [$5=cap_gpu_min] [$6=cap_mem_min]
  local pmin="$1" pmax="$2" gmax="$3" mmax="$4" errs=0
  if [ -n "${OC_power_limit_w:-}" ]; then
    if ! domain_oc_is_uint "$OC_power_limit_w"; then
      printf 'power_limit_w: "%s" no es un entero\n' "$OC_power_limit_w"; errs=1
    elif [ "$OC_power_limit_w" -lt "$pmin" ] || [ "$OC_power_limit_w" -gt "$pmax" ]; then
      # No es error fatal: se acota en el plan y se avisa.
      printf 'power_limit_w: %s W fuera de [%s,%s] - se acotará\n' "$OC_power_limit_w" "$pmin" "$pmax"
    fi
  fi
  # Los TRES relojes pasan por domain_oc_is_uint antes de cualquier comparación
  # numérica. Antes solo lo hacía power_limit_w, y las claves de reloj iban
  # directas a `-gt`: con un valor no entero, bash devuelve 2 y escupe
  # "integer expected" por stderr, la condición queda falsa, no se registra
  # error y validate salía rc=0. Medido el 2026-11-02 ejecutando solo el
  # dominio: `gpu_clock_max_mhz=abc` validaba bien y el plan emitía
  # `gpu_clock<TAB>abc<TAB>abc`, que acaba en `nvidia-smi -lgc abc,abc`.
  # Un valor que no es un entero no se acota: se rechaza.
  local k v
  for k in gpu_clock_min_mhz gpu_clock_max_mhz mem_clock_mhz; do
    eval "v=\${OC_$k:-}"
    if [ -n "$v" ] && ! domain_oc_is_uint "$v"; then
      printf '%s: "%s" no es un entero\n' "$k" "$v"; errs=1
    fi
  done
  # Con algún reloj no entero se vuelve ya: las comparaciones de abajo no son
  # seguras y seguir solo añadiría ruido sobre un perfil que ya está rechazado.
  [ "$errs" -eq 0 ] || return 1

  if [ -n "${OC_gpu_clock_min_mhz:-}" ] && [ -n "${OC_gpu_clock_max_mhz:-}" ]; then
    if [ "$OC_gpu_clock_min_mhz" -gt "$OC_gpu_clock_max_mhz" ]; then
      printf 'gpu_clock: min (%s) > max (%s)\n' "$OC_gpu_clock_min_mhz" "$OC_gpu_clock_max_mhz"; errs=1
    fi
  fi
  # Un `min` a solas no produce ninguna operación -domain_oc_plan solo emite
  # gpu_clock si hay `max`-, así que el perfil se descartaba EN SILENCIO.
  if [ -n "${OC_gpu_clock_min_mhz:-}" ] && [ -z "${OC_gpu_clock_max_mhz:-}" ]; then
    printf 'gpu_clock_min_mhz sin gpu_clock_max_mhz: no se puede fijar un suelo de reloj sin techo\n'
    errs=1
  fi
  if [ -n "${OC_gpu_clock_max_mhz:-}" ] && [ "$OC_gpu_clock_max_mhz" -gt "$gmax" ]; then
    printf 'gpu_clock_max_mhz: %s > máximo soportado %s - se acotará\n' "$OC_gpu_clock_max_mhz" "$gmax"
  fi
  if [ -n "${OC_mem_clock_mhz:-}" ] && [ "$OC_mem_clock_mhz" -gt "$mmax" ]; then
    printf 'mem_clock_mhz: %s > máximo soportado %s - se acotará\n' "$OC_mem_clock_mhz" "$mmax"
  fi
  # Offsets: se aceptan sintácticamente pero NO hay adaptador que los aplique.
  if [ -n "${OC_gpu_clock_offset_mhz:-}" ] || [ -n "${OC_mem_clock_offset_mhz:-}" ]; then
    printf 'clock_offset: no soportado en este sistema (requiere Xorg+Coolbits o NVML VF offset)\n'; errs=1
  fi
  return "$errs"
}

# Emite el PLAN: líneas "op<TAB>args". Es la única salida que el ejecutor
# consume. Vacío = nada que hacer.
# $5=cap_gpu_min y $6=cap_mem_min se APPENDEAN: un llamador que no los pase
# sigue funcionando, pero entonces un perfil de SOLO TECHO se rechaza en vez
# de anclar el reloj en duro (ver abajo).
domain_oc_plan() { # $1=cap_power_min $2=cap_power_max $3=cap_gpu_max $4=cap_mem_max [$5=cap_gpu_min] [$6=cap_mem_min]
  local pmin="$1" pmax="$2" gmax="$3" mmax="$4" gmin="${5:-}" mmin="${6:-}" v lo hi
  if [ "${OC_profile:-}" = "stock" ]; then
    printf 'reset\tall\n'
    return 0
  fi
  if [ -n "${OC_power_limit_w:-}" ]; then
    v="$(domain_oc_clamp "$OC_power_limit_w" "$pmin" "$pmax")"
    printf 'power_limit\t%s\n' "$v"
  fi
  if [ -n "${OC_gpu_clock_max_mhz:-}" ]; then
    hi="$(domain_oc_clamp "$OC_gpu_clock_max_mhz" 0 "$gmax")"
    # Un TECHO a solas usaba el propio techo como suelo, así que
    # `gpu_clock_max_mhz=2400` emitía `gpu_clock 2400 2400` -o sea
    # `nvidia-smi -lgc 2400,2400`-, que ANCLA el reloj en duro también en
    # reposo. El usuario pedía un tope y obtenía un suelo, con más consumo y
    # temperatura en reposo: justo el régimen donde pega H23. Por eso el
    # defecto obligaba a que efficient.profile se inventara un
    # gpu_clock_min_mhz=500 que nadie había pedido.
    # Ahora el suelo por defecto es el MÍNIMO de la tarjeta (180 MHz aquí).
    lo="${OC_gpu_clock_min_mhz:-$gmin}"
    if [ -z "$lo" ]; then
      # Sin suelo explícito y sin gmin legible no se adivina: se omite la
      # operación. Escribir un 0 no verificado sería peor que no hacer nada.
      printf 'gpu_clock_max_mhz pedido sin gpu_clock_min_mhz y sin mínimo legible: operación omitida\n' >&2
    else
      lo="$(domain_oc_clamp "$lo" 0 "$hi")"
      printf 'gpu_clock\t%s\t%s\n' "$lo" "$hi"
    fi
  fi
  if [ -n "${OC_mem_clock_mhz:-}" ]; then
    # El suelo del clamp es el mínimo REAL de la tarjeta cuando se conoce
    # (405 MHz aquí), no 0: un 0 no es un reloj de memoria que -lmc acepte.
    v="$(domain_oc_clamp "$OC_mem_clock_mhz" "${mmin:-0}" "$mmax")"
    printf 'mem_clock\t%s\n' "$v"
  fi
}
