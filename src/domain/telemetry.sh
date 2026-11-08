#!/usr/bin/env bash
# domain/telemetry.sh — reglas para PRESENTAR el estado vivo de las GPUs.
# Capa de DOMINIO: PURA, sin I/O. Ni un `nvidia-smi`, ni un fichero, ni un awk.
#
# POR QUÉ ESTO ES DOMINIO Y NO "cosas de pintar". Un panel tipo htop parece
# presentación, pero casi todo lo que hace son DECISIONES, y una decisión mal
# tomada aquí miente al operador con mucha autoridad:
#   - ¿cuántas celdas de barra toca un 62%? (y qué pasa con un 0, un 100 o un
#     valor que la tarjeta no publica)
#   - ¿este 84 °C es normal, es un aviso o es grave?
#   - ¿qué significa la máscara 0x4 de throttling?
#   - ¿se puede desconectar el cable ahora mismo? (H28: no, si alguien tiene
#     la eGPU abierta)
# Todas son puras, todas tienen test, y ninguna necesita una GPU para
# comprobarse. Lo único que queda fuera es el dibujo: colocar caracteres.
#
# REGLA QUE ESTE FICHERO NO NEGOCIA: un valor que la tarjeta NO publica se
# propaga como DESCONOCIDO, nunca como 0. `nvidia-smi` devuelve `[N/A]` en
# campos reales de esta máquina (la GPU interna no publica `power.limit` ni
# `fan.speed`), y pintar un 0% de ventilador o un 0 W de consumo donde no hay
# dato es inventarse una lectura tranquilizadora. Un hueco se ve como hueco.

# shellcheck shell=bash

# Niveles de sparkline. Son OCHO porque es lo que ofrece el bloque de Unicode
# con una altura de una sola línea, pero aquí solo vive el NÚMERO: la tabla de
# caracteres '▁▂▃▄▅▆▇█' está en la capa de presentación, y esa separación es
# justo el punto. El dominio decide a qué nivel corresponde un valor —regla, con
# test— y quien dibuja elige con qué carácter pintarlo. Si la tabla estuviera
# aquí, el dominio estaría opinando sobre tipografía; si el nivel estuviera
# allí, habría dos definiciones de la escala.
readonly AORUS_TEL_SPARK_LEVELS=8

# --- utilidades puras ---------------------------------------------------------

# ¿Es un entero no negativo? Los porcentajes y los MiB lo son.
domain_tel_is_uint() { # $1=valor
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# Normaliza un campo tal como lo publica la capa de adaptador. `nvidia-smi`
# emite `[N/A]`, `[Not Supported]`, `N/A` y a veces la cadena vacía para el
# mismo concepto —"no hay dato"—, así que los cuatro casos colapsan aquí en uno
# y el resto del dominio solo tiene que distinguir "hay número" de "no hay".
# Imprime el valor limpio, o nada (rc 1) si no hay dato.
domain_tel_field() { # $1=valor crudo
  local v="${1:-}"
  # Recorta espacios por los dos lados sin invocar nada externo.
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    ''|'[N/A]'|'N/A'|'[Not Supported]'|'Not Supported'|'[Unknown Error]') return 1 ;;
  esac
  printf '%s' "$v"
}

# Un entero a partir de un campo que puede venir con decimales ("143.52" ->
# 143) o con unidad pegada. Trunca, no redondea: para una barra de 20 celdas la
# diferencia es invisible y truncar nunca inventa un vatio que no se gastó.
# rc 1 si no hay número que extraer.
domain_tel_int() { # $1=valor crudo
  local v
  v="$(domain_tel_field "${1:-}")" || return 1
  v="${v%%.*}"      # fuera la parte decimal
  v="${v%% *}"      # fuera una unidad separada por espacio ("180 W")
  v="${v#+}"
  domain_tel_is_uint "$v" || return 1
  printf '%s' "$v"
}

# --- porcentajes --------------------------------------------------------------

# Porcentaje de used sobre total, truncado a entero. rc 1 si no se puede
# afirmar (campos no numéricos, o un total 0: dividir por él sería un fallo de
# shell, y un "0%" sería una respuesta inventada a una pregunta sin sentido).
domain_tel_pct() { # $1=used $2=total
  local u t
  u="$(domain_tel_int "${1:-}")" || return 1
  t="$(domain_tel_int "${2:-}")" || return 1
  [ "$t" -gt 0 ] || return 1
  printf '%s' "$(( u * 100 / t ))"
}

# Acota un porcentaje a [0,100]. Aquí SÍ se acota, al contrario que los offsets
# de reloj: un 103% de uso es un artefacto de muestreo del driver y mostrarlo
# como 100 no cambia ninguna decisión del operador, mientras que un offset
# acotado en silencio sí convertiría su petición en otra.
domain_tel_pct_clamp() { # $1=pct
  local p
  p="$(domain_tel_int "${1:-}")" || return 1
  [ "$p" -gt 100 ] && p=100
  printf '%s' "$p"
}

# --- barras -------------------------------------------------------------------

# Celdas LLENAS de una barra de ancho $2 para un porcentaje $1.
# Redondea al más cercano para que un 99% no se vea idéntico a un 100%: con
# truncamiento, 99% de 20 celdas da 19 igual que un 96%, y el final de la barra
# es justo donde el operador mira.
# rc 1 sin porcentaje: el llamador pinta la barra vacía con la marca de "n/d",
# que no es lo mismo que una barra a 0.
domain_tel_bar_cells() { # $1=pct $2=ancho
  local p w
  p="$(domain_tel_pct_clamp "${1:-}")" || return 1
  w="$(domain_tel_int "${2:-}")" || return 1
  [ "$w" -gt 0 ] || return 1
  printf '%s' "$(( (p * w + 50) / 100 ))"
}

# --- sparklines ---------------------------------------------------------------

# Índice (0..7) del carácter de sparkline que corresponde a $1 dentro del rango
# [$2,$3]. Imprime el índice; rc 1 si no hay dato.
#
# Un rango degenerado (min==max) devuelve el nivel MÁS BAJO, no el más alto:
# una serie plana es la lectura correcta de "no ha pasado nada", y pintarla
# toda a ████ sugeriría saturación donde hay reposo.
domain_tel_spark_level() { # $1=valor $2=min $3=max
  local v lo hi span
  v="$(domain_tel_int "${1:-}")" || return 1
  lo="$(domain_tel_int "${2:-}")" || return 1
  hi="$(domain_tel_int "${3:-}")" || return 1
  [ "$hi" -ge "$lo" ] || return 1
  [ "$v" -lt "$lo" ] && v="$lo"
  [ "$v" -gt "$hi" ] && v="$hi"
  span=$(( hi - lo ))
  [ "$span" -eq 0 ] && { printf '0'; return 0; }
  printf '%s' "$(( (v - lo) * (AORUS_TEL_SPARK_LEVELS - 1) / span ))"
}

# --- severidad ----------------------------------------------------------------
#
# Tres niveles: ok | warn | crit. Los umbrales NO son universales, son de ESTA
# tarjeta, y por eso viven aquí con su justificación en vez de repartidos por
# el código de dibujo.

# Temperatura. La escalera medida de H25 llegó a 78 °C en el escalón +600 sin
# un solo throttle (`clocks_throttle_reasons.active = 0x0`), así que 78 es
# territorio NORMAL en esta caja y un umbral de aviso por debajo de eso daría
# una alarma permanente. El aviso se pone en 80 y el crítico en 87, por debajo
# del punto en que la tarjeta recorta sola.
domain_tel_sev_temp() { # $1=°C
  local c
  c="$(domain_tel_int "${1:-}")" || { printf 'unknown'; return 0; }
  if   [ "$c" -ge 87 ]; then printf 'crit'
  elif [ "$c" -ge 80 ]; then printf 'warn'
  else                       printf 'ok'
  fi
}

# Ocupación (VRAM o cualquier porcentaje de llenado). El aviso en 90% y el
# crítico en 97%: quedarse sin VRAM no degrada, aborta el proceso.
domain_tel_sev_fill() { # $1=pct
  local p
  p="$(domain_tel_pct_clamp "${1:-}")" || { printf 'unknown'; return 0; }
  if   [ "$p" -ge 97 ]; then printf 'crit'
  elif [ "$p" -ge 90 ]; then printf 'warn'
  else                       printf 'ok'
  fi
}

# Utilización. Un 100% de uso es el OBJETIVO de una carga de IA, no un
# problema: esta función no clasifica nada como grave, solo distingue reposo de
# actividad para que el dibujo pueda resaltar la GPU que está trabajando.
domain_tel_sev_util() { # $1=pct
  local p
  p="$(domain_tel_pct_clamp "${1:-}")" || { printf 'unknown'; return 0; }
  if   [ "$p" -ge 50 ]; then printf 'busy'
  elif [ "$p" -ge 5 ];  then printf 'light'
  else                       printf 'idle'
  fi
}

# --- throttling ---------------------------------------------------------------
#
# `clocks_throttle_reasons.active` es una máscara de bits. Mostrarla en hex es
# trasladarle al operador un trabajo que el programa puede hacer: traducirla.
# Los bits son los de NVML (nvml.h, nvmlClocksThrottleReasons*).
#
# Imprime UNA razón por línea, de la más informativa a la menos. Máscara 0 o
# solo-GpuIdle -> "ninguno" (el bit 0x1 significa literalmente que la GPU está
# en reposo, que no es un recorte del que haya que avisar).
# rc 1 si la máscara no se puede leer.
domain_tel_throttle_decode() { # $1=máscara (hex 0x... o decimal)
  local raw m found=0
  raw="$(domain_tel_field "${1:-}")" || return 1
  # Acepta 0x... y decimal. Una máscara ilegible es rc 1, no "ninguno": decir
  # "no hay throttling" sin poder leerlo es exactamente el tipo de respuesta
  # tranquilizadora que este fichero no se permite.
  case "$raw" in
    0x*|0X*) case "${raw#0[xX]}" in ''|*[!0-9a-fA-F]*) return 1 ;; esac ;;
    *)       domain_tel_is_uint "$raw" || return 1 ;;
  esac
  m=$(( raw ))

  (( m & 0x8   )) && { printf 'parada por HW (HW Slowdown)\n';             found=1; }
  (( m & 0x80  )) && { printf 'freno de potencia por HW (Power Brake)\n';  found=1; }
  (( m & 0x40  )) && { printf 'térmico por HW (HW Thermal)\n';             found=1; }
  (( m & 0x20  )) && { printf 'térmico por SW (SW Thermal)\n';             found=1; }
  (( m & 0x4   )) && { printf 'techo de potencia por SW (SW Power Cap)\n'; found=1; }
  (( m & 0x10  )) && { printf 'sync boost\n';                              found=1; }
  (( m & 0x2   )) && { printf 'reloj fijado por aplicación\n';             found=1; }
  (( m & 0x100 )) && { printf 'reloj de display\n';                        found=1; }
  [ "$found" -eq 0 ] && printf 'ninguno\n'
  return 0
}

# ¿Hay algún recorte del que avisar? rc 0 si sí. Separado del decode para que
# el dibujo no tenga que interpretar su salida de texto.
domain_tel_throttle_active() { # $1=máscara
  local raw m
  raw="$(domain_tel_field "${1:-}")" || return 1
  case "$raw" in
    0x*|0X*) case "${raw#0[xX]}" in ''|*[!0-9a-fA-F]*) return 1 ;; esac ;;
    *)       domain_tel_is_uint "$raw" || return 1 ;;
  esac
  m=$(( raw ))
  # 0x1 (GpuIdle) se excluye a propósito: no es un recorte.
  (( m & ~0x1 )) && return 0
  return 1
}

# --- tamaños legibles ---------------------------------------------------------

# MiB -> "6.7 GiB" / "512 MiB". Un decimal en GiB, cero en MiB: más precisión
# es ruido en un panel que se refresca cada segundo.
# Aritmética entera, sin `bc`: el dominio no invoca nada.
domain_tel_mib_human() { # $1=MiB
  local m int frac
  m="$(domain_tel_int "${1:-}")" || return 1
  if [ "$m" -lt 1024 ]; then
    printf '%s MiB' "$m"
    return 0
  fi
  int=$(( m / 1024 ))
  frac=$(( (m % 1024) * 10 / 1024 ))
  printf '%s.%s GiB' "$int" "$frac"
}

# ¿Esta fila de `--query-compute-apps` describe un proceso DE VERDAD?
#
# Medido el 2026-11-07 con la eGPU en `GPU requires reset` tras el incidente
# del offset +600: nvidia-smi devuelve una fila con el bus-id RELLENO y el
# resto en hueco —
#     00000000:8D:00.0, [N/A], [N/A], [N/A]
# — es decir, anuncia una GPU sin anunciar ningún proceso. Contarla como
# proceso tenía dos consecuencias, y la segunda es la grave:
#   1. el panel listaba un proceso fantasma con 'pid=[N/A]';
#   2. el veredicto de H28 decía 'peligroso' sin que nadie tuviera la tarjeta
#      abierta, y justo entonces la recuperación documentada consiste en
#      desconectar el cable. Un aviso que grita cuando no hay peligro se
#      aprende a ignorar, y el día que sí haya peligro ya no se lee.
#
# La regla: sin un PID numérico no hay proceso. El criterio es el pid y no el
# bus-id porque el bus-id es justo el campo que la tarjeta rota SÍ rellena.
domain_tel_proc_is_real() { # $1=pid tal como lo publica el adaptador
  domain_tel_int "${1:-}" >/dev/null || return 1
  return 0
}

# --- la pregunta de H28 -------------------------------------------------------
#
# "¿Puedo desconectar el cable ahora?" Desconectar el túnel con un proceso
# CUDA vivo hizo que el cierre de /dev/nvidia-uvm escribiera en un BAR0 ya
# desmapeado: Oops con el spinlock de ISR tomado y el host irrecuperable
# (ledger H28). La regla operativa es drenar ANTES, y el panel es el único
# sitio donde el operador ya está mirando.
#
# Imprime "seguro" o "peligroso". Entrada: el NÚMERO de procesos que tienen la
# eGPU abierta, que es lo que el adaptador puede contar.
# Un recuento ilegible imprime "desconocido" y NO "seguro": sin evidencia no se
# autoriza, misma filosofía que el gate de enlace.
domain_tel_unplug_verdict() { # $1=nº de procesos con la eGPU abierta
  local n
  n="$(domain_tel_int "${1:-}")" || { printf 'desconocido'; return 0; }
  [ "$n" -gt 0 ] && { printf 'peligroso'; return 0; }
  printf 'seguro'
}
