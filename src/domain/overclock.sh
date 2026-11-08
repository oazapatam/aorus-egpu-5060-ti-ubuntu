#!/usr/bin/env bash
# domain/overclock.sh — reglas de tuning de la eGPU: validación, clamping y
# generación del PLAN. Capa de DOMINIO: PURA, sin I/O.
#
# Idea central: el dominio NO toca el hardware. Recibe (perfil + capacidades
# leídas) y emite un PLAN: líneas `op<TAB>arg...` que un adaptador ejecuta. Así
# se puede testear toda la aritmética y todos los límites sin GPU y sin root, y
# cambiar de `nvidia-smi` a NVML sin reescribir una sola regla.
#
# ALCANCE REAL (importante, sin promesas falsas). Palancas de LÍMITE y BLOQUEO:
#   - power limit            (nvidia-smi -pl)
#   - lock de reloj gráfico  (nvidia-smi -lgc)
#   - lock de reloj memoria  (nvidia-smi -lmc)
# Y palancas de OFFSET (el "overclock" clásico de +MHz sobre stock), que SÍ
# existen en esta tarjeta por NVML. MEDIDO el 2026-11-02 sobre la eGPU
# 0000:B4:00.0 con nvidia-ml-py 13.615.71:
#   nvmlDeviceGetGpcClkVfOffset = 0, ventana (-1000, 1000) MHz
#   nvmlDeviceGetMemClkVfOffset = 0, ventana (-2000, 6000) MHz
# `nvidia-settings` NO sirve (necesita NV-CONTROL sobre Xorg y la sesión es
# Wayland) y `nvmlDeviceGetClockOffsets` -la API nueva de driver 555+- tampoco:
# el binding expone la función pero no el struct c_nvmlClockOffset_v1_t.
#
# DOS REGLAS QUE ESTE FICHERO NO NEGOCIA:
#
#  1. La CAPACIDAD de offsets es un DATO, no una creencia. Antes este dominio
#     rechazaba cualquier offset con el mensaje "requiere Xorg+Coolbits": el
#     dominio opinando sobre el entorno, y encima con un hecho que hoy es
#     falso. Ahora app/ consulta al adaptador y pasa el resultado
#     ("si <gmin> <gmax> <mmin> <mmax>" o "no") como un argumento más.
#     La regla pura es: se piden offsets y el adaptador declara no
#     soportarlos => error, y no se escribe nada.
#
#  2. Un offset fuera de ventana se RECHAZA, no se acota. Acotar en silencio un
#     +400 a +150 convierte la petición del usuario en otra distinta; en una
#     palanca cuyo modo de fallo son NÚMEROS MAL CALCULADOS (resultados
#     silenciosamente incorrectos, no un cuelgue ruidoso) eso es inaceptable.
#     El power limit sí se acota porque su rango [150,180] es un límite físico
#     del vBIOS y cualquier valor dentro de él es igual de seguro.

# shellcheck shell=bash

# Operaciones válidas del plan. Es la ÚNICA definición: el ejecutor pregunta
# aquí en vez de llevar su propia lista (tener la allowlist en dos capas es
# justo lo que este diseño evita).
#
# `clock_offset` lleva DOS argumentos — `clock_offset<TAB>gpu<TAB>-200` — en vez
# de una op por dominio de reloj: el ejecutor y el puerto tratan los dos casos
# con el mismo código, y añadir un tercer dominio (si algún día NVML expone
# otro) no toca la allowlist.
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

# Entero CON signo: "-200", "+150", "0" son válidos. Hace falta porque
# domain_oc_is_uint rechaza el '-' y el '+', así que con ella sola un offset
# NEGATIVO es inexpresable: no hay forma de pedir "baja 200 MHz", que es
# justo el uso más seguro de esta palanca (menos reloj al mismo voltaje).
domain_oc_is_int() { # $1=valor
  local v="${1:-}"
  case "$v" in ''|'-'|'+') return 1 ;; esac
  v="${v#[-+]}"
  case "$v" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# Acota un entero al rango [min,max]. Imprime el valor acotado.
domain_oc_clamp() { # $1=valor $2=min $3=max
  local v="$1" lo="$2" hi="$3"
  [ "$v" -lt "$lo" ] && { printf '%s' "$lo"; return 0; }
  [ "$v" -gt "$hi" ] && { printf '%s' "$hi"; return 0; }
  printf '%s' "$v"
}

# Acota un entero CON SIGNO a [min,max] y NORMALIZA el signo ("+150" -> "150",
# que es la forma que NVML y el adaptador esperan). rc 1 si alguno de los tres
# no es un entero, en vez de dejar que `[ -lt ]` escupa "integer expected" por
# stderr y devuelva una condición falsa que nadie mira.
#
# AVISO DE USO: esto NO es el camino por el que pasan los offsets del usuario.
# Un offset fuera de ventana se RECHAZA en domain_oc_validate y el plan OMITE
# la operación (ver la cabecera, regla 2). Aquí el clamp es, por construcción,
# la identidad: existe como última red para que ningún camino del plan pueda
# emitir un valor fuera de la ventana declarada por el adaptador, ni siquiera
# si un llamador futuro se salta validate.
domain_oc_clamp_signed() { # $1=valor $2=min $3=max
  local v="${1:-}" lo="${2:-}" hi="${3:-}"
  domain_oc_is_int "$v" || return 1
  domain_oc_is_int "$lo" || return 1
  domain_oc_is_int "$hi" || return 1
  v=$((v)); lo=$((lo)); hi=$((hi))
  [ "$lo" -le "$hi" ] || return 1
  [ "$v" -lt "$lo" ] && { printf '%s' "$lo"; return 0; }
  [ "$v" -gt "$hi" ] && { printf '%s' "$hi"; return 0; }
  printf '%s' "$v"
}

# --- capacidad de offsets: un DATO que entra, no una creencia del dominio ----
#
# Formato (una línea, campos separados por espacio, igual que gpu_caps):
#   "si <gpu_min> <gpu_max> <mem_min> <mem_max>"   p. ej. "si -1000 1000 -2000 6000"
#   "no"                                           el adaptador no los soporta
#
# Lo produce app/ preguntando al adaptador (gpu_supports_clock_offset +
# gpu_offset_window) y lo consume el dominio. Así la MISMA regla pura vale para
# una tarjeta que los soporta, para una que no, y para un doble de test, sin
# que el dominio sepa qué es NVML.
readonly AORUS_OC_OFFCAP_NONE="no"

# Ventana de un dominio de reloj. Imprime "<min> <max>"; rc 1 si no se puede
# afirmar cuál es. Sin ventana legible NO hay permiso: misma filosofía que el
# 'unknown' del gate de enlace — sin evidencia no se escribe.
domain_oc_offcap_window() { # $1=offcap $2=gpu|mem -> "min max"
  local lo hi gmin gmax mmin mmax
  read -r _ gmin gmax mmin mmax <<< "${1:-}"
  case "${2:-}" in
    gpu) lo="$gmin"; hi="$gmax" ;;
    mem) lo="$mmin"; hi="$mmax" ;;
    *)   return 1 ;;
  esac
  domain_oc_is_int "$lo" || return 1
  domain_oc_is_int "$hi" || return 1
  [ "$((lo))" -le "$((hi))" ] || return 1
  printf '%s %s' "$((lo))" "$((hi))"
}

# ¿El adaptador declara soportar offsets Y con ventanas utilizables? Las dos
# cosas, no una: un "si" sin ventanas legibles no autoriza nada, porque sin
# ventana no se puede comprobar si el valor pedido está dentro.
domain_oc_offcap_supported() { # $1=offcap
  local flag
  read -r flag _ <<< "${1:-}"
  case "${flag:-no}" in
    si|yes|1) : ;;
    *) return 1 ;;
  esac
  domain_oc_offcap_window "${1:-}" gpu >/dev/null || return 1
  domain_oc_offcap_window "${1:-}" mem >/dev/null || return 1
  return 0
}

# ¿Hay que verificar numéricamente el resultado antes de darlo por bueno?
# Imprime "gemm" o "none". Lee OC_* del entorno, como el resto del dominio.
#
# La regla, y por qué cada caso cae donde cae:
#   - offset POSITIVO (core o memoria) -> "gemm". Subir reloj al mismo voltaje
#     no se manifiesta como un cuelgue ruidoso: lo primero que aparece son
#     resultados MAL CALCULADOS. Nadie puede detectar eso a ojo, así que se
#     mide.
#   - offset NEGATIVO -> "none". Bajar el reloj al mismo voltaje aumenta el
#     margen; no hay nada nuevo que verificar.
#   - solo locks (-pl/-lgc/-lmc) -> "none". Son valores DENTRO del rango de
#     fábrica; la tarjeta ya está validada ahí por el vBIOS.
#   - verify=gemm en el perfil -> "gemm" aunque no haya offsets, para poder
#     medir un perfil de locks a mano si se quiere.
domain_oc_verify_required() { # usa OC_* del entorno
  case "${OC_verify:-}" in
    gemm) printf 'gemm'; return 0 ;;
  esac
  local k v
  for k in gpu_clock_offset_mhz mem_clock_offset_mhz; do
    eval "v=\${OC_$k:-}"
    [ -n "$v" ] || continue
    domain_oc_is_int "$v" || continue
    if [ "$((v))" -gt 0 ]; then printf 'gemm'; return 0; fi
  done
  printf 'none'
}

# --- perfiles -----------------------------------------------------------------
#
# Un perfil es un conjunto de claves key=value. Se valida ESTRICTAMENTE: una
# clave desconocida es un error, no un aviso silencioso, para que un typo en
# /etc/aorus-egpu/overclock.conf no deje la eGPU en un estado que nadie pidió.
#
# `verify` es una META-clave: no describe un valor que se escriba en la
# tarjeta, sino cómo se COMPRUEBA lo que se escribió. Valores: none | gemm.
readonly AORUS_OC_KEYS="power_limit_w gpu_clock_min_mhz gpu_clock_max_mhz mem_clock_mhz gpu_clock_offset_mhz mem_clock_offset_mhz verify"
readonly AORUS_OC_VERIFY_MODES="none gemm"

domain_oc_key_is_valid() { # $1=clave
  local k
  for k in $AORUS_OC_KEYS; do [ "$k" = "${1:-}" ] && return 0; done
  return 1
}

# Valida un perfil ya parseado a variables OC_<clave>. Imprime los errores
# encontrados (uno por línea) y devuelve 1 si hubo alguno.
# $7=offcap: la capacidad de offsets, como DATO (ver AORUS_OC_OFFCAP_NONE).
# Si no se pasa, el defecto es "no": un llamador que no pregunte al adaptador
# NO obtiene offsets, que es exactamente el comportamiento anterior.
domain_oc_validate() { # usa OC_* del entorno; $1=cap_power_min $2=cap_power_max $3=cap_gpu_max $4=cap_mem_max [$5=cap_gpu_min] [$6=cap_mem_min] [$7=offcap]
  local pmin="$1" pmax="$2" gmax="$3" mmax="$4" offcap="${7:-$AORUS_OC_OFFCAP_NONE}" errs=0
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
  # --- la meta-clave verify ---------------------------------------------------
  if [ -n "${OC_verify:-}" ]; then
    local vm found=0
    for vm in $AORUS_OC_VERIFY_MODES; do
      [ "$vm" = "$OC_verify" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      printf 'verify: "%s" no es un modo conocido (%s)\n' "$OC_verify" "$AORUS_OC_VERIFY_MODES"; errs=1
    fi
  fi

  # --- offsets ----------------------------------------------------------------
  # Tres cosas, en este orden: ¿son enteros?, ¿los soporta el adaptador?,
  # ¿están dentro de la ventana que el propio adaptador declara?
  local pair which okey off win olo ohi want_off=0
  for pair in gpu:gpu_clock_offset_mhz mem:mem_clock_offset_mhz; do
    okey="${pair#*:}"
    eval "off=\${OC_$okey:-}"
    [ -n "$off" ] || continue
    want_off=1
    if ! domain_oc_is_int "$off"; then
      printf '%s: "%s" no es un entero con signo\n' "$okey" "$off"; errs=1
    fi
  done

  if [ "$want_off" -eq 1 ] && ! domain_oc_offcap_supported "$offcap"; then
    # El dominio NO afirma POR QUÉ no se soporta -eso es un hecho del entorno,
    # que es quien lo ha dicho-: solo que sin soporte declarado no se escribe.
    printf 'clock_offset: el adaptador declara que esta GPU no soporta offsets de reloj; no se escribe nada\n'
    errs=1
  elif [ "$want_off" -eq 1 ]; then
    for pair in gpu:gpu_clock_offset_mhz mem:mem_clock_offset_mhz; do
      which="${pair%%:*}"; okey="${pair#*:}"
      eval "off=\${OC_$okey:-}"
      [ -n "$off" ] || continue
      domain_oc_is_int "$off" || continue
      win="$(domain_oc_offcap_window "$offcap" "$which")" || continue
      read -r olo ohi <<< "$win"
      if [ "$((off))" -lt "$olo" ] || [ "$((off))" -gt "$ohi" ]; then
        # RECHAZO, no clamp: ver la regla 2 de la cabecera.
        printf '%s: %s MHz fuera de la ventana [%s,%s] que declara la tarjeta - se RECHAZA (un offset no se acota: acotarlo convertiría tu petición en otra distinta)\n' \
          "$okey" "$off" "$olo" "$ohi"
        errs=1
      fi
    done
  fi
  return "$errs"
}

# Emite el PLAN: líneas "op<TAB>args". Es la única salida que el ejecutor
# consume. Vacío = nada que hacer.
# $5=cap_gpu_min y $6=cap_mem_min se APPENDEAN: un llamador que no los pase
# sigue funcionando, pero entonces un perfil de SOLO TECHO se rechaza en vez
# de anclar el reloj en duro (ver abajo).
# $7=offcap: igual que en domain_oc_validate. Sin él no se emite NINGUNA
# operación de offset (defecto honesto: "no soportado").
domain_oc_plan() { # $1=cap_power_min $2=cap_power_max $3=cap_gpu_max $4=cap_mem_max [$5=cap_gpu_min] [$6=cap_mem_min] [$7=offcap]
  local pmin="$1" pmax="$2" gmax="$3" mmax="$4" gmin="${5:-}" mmin="${6:-}" v lo hi
  local offcap="${7:-$AORUS_OC_OFFCAP_NONE}"
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

  # --- offsets, SIEMPRE AL FINAL DEL PLAN -------------------------------------
  # El orden no es cosmético: el power limit y los locks se escriben antes, así
  # que cuando el reloj sube por encima de stock el techo de potencia ya está
  # puesto. Al revés, la tarjeta pasaría un instante con el offset aplicado y
  # el límite de potencia todavía de fábrica.
  local pair which okey off win olo ohi
  if [ -n "${OC_gpu_clock_offset_mhz:-}" ] || [ -n "${OC_mem_clock_offset_mhz:-}" ]; then
    if ! domain_oc_offcap_supported "$offcap"; then
      # El plan NO emite nada que el adaptador no pueda cumplir. Quien aborta
      # con un error es domain_oc_validate; aquí solo se deja constancia, para
      # que un llamador que se salte validate no acabe escribiendo a ciegas.
      printf 'offsets pedidos y el adaptador no declara soportarlos: operaciones OMITIDAS\n' >&2
    else
      for pair in gpu:gpu_clock_offset_mhz mem:mem_clock_offset_mhz; do
        which="${pair%%:*}"; okey="${pair#*:}"
        eval "off=\${OC_$okey:-}"
        [ -n "$off" ] || continue
        if ! domain_oc_is_int "$off"; then
          printf '%s="%s" no es un entero con signo: operación OMITIDA\n' "$okey" "$off" >&2
          continue
        fi
        win="$(domain_oc_offcap_window "$offcap" "$which")" || continue
        read -r olo ohi <<< "$win"
        if [ "$((off))" -lt "$olo" ] || [ "$((off))" -gt "$ohi" ]; then
          printf '%s=%s fuera de [%s,%s]: operación OMITIDA (un offset no se acota)\n' \
            "$okey" "$off" "$olo" "$ohi" >&2
          continue
        fi
        printf 'clock_offset\t%s\t%s\n' "$which" "$(domain_oc_clamp_signed "$off" "$olo" "$ohi")"
      done
    fi
  fi
}
