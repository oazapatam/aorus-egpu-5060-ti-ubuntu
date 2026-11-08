#!/usr/bin/env bash
# domain/proc.sh — reglas puras sobre cómo se ACOTA un proceso externo.
#
# POR QUÉ EXISTE ESTE MÓDULO
# --------------------------
# El 2026-11-07, midiendo el borde del reloj, la eGPU quedó en
# `GPU Reset Required` (`Xid 175` GSP RPC timeout, luego `Xid 154`) y el proceso
# que medía quedó ZOMBI IRREAPEABLE: su líder había salido, pero un hilo suyo
# seguía atascado dentro del driver, así que el núcleo no podía cerrarlo.
# El padre se bloqueó en `wait4()` **para siempre**, y con él se perdió todo lo
# que venía después:
#   - el ABORTO no se registró en los breadcrumbs,
#   - los offsets NO volvieron a 0,
#   - no hubo informe, ni código de salida, ni veredicto.
# El fallo real no fue el cuelgue de la tarjeta —eso es justo lo que se estaba
# buscando— sino que **la reacción al cuelgue no llegó a ejecutarse**.
#
# Y no era un defecto del tool de laboratorio: era del paquete. Los adaptadores
# DECLARAN esta garantía (`adapters/gpu/nvidia-smi.sh`: "CADA invocación va
# acotada por `timeout`; exit 124 se propaga como rc 124 y el caso de uso
# ABORTA, no reintenta") y no la cumplían, porque `timeout N cmd` manda
# `SIGTERM` al agotarse el presupuesto y **luego espera a que el hijo muera**.
# Un proceso que no muere con `TERM` cuelga a `timeout` con él, y el 124 que el
# caso de uso espera para abortar no llega nunca.
#
# LO QUE SE PUEDE Y NO SE PUEDE PROMETER
# --------------------------------------
# `timeout -k` convierte "ignora TERM" en "lo mata KILL", que es el caso
# habitual. Lo que NINGÚN programa de usuario puede prometer es matar a un hilo
# en estado-D dentro del driver: ni `SIGKILL` lo saca de ahí. Para ese caso la
# única salida honesta es **ABANDONARLO** y devolver 124 igual, para que el que
# llamó siga vivo y pueda revertir, registrar y avisar.
# De ahí las dos decisiones de aquí: cuánta gracia dar antes de `KILL`, y qué
# códigos de salida significan "colgado". El MECANISMO (`timeout -k`, abandonar
# al irreapeable) es I/O y vive en `adapters/`.

# shellcheck shell=bash

# Gracia entre SIGTERM y SIGKILL, en segundos, para un presupuesto dado.
#
# Regla: una cuarta parte del presupuesto, acotada a [2, 10].
#   - un cuarto, porque la gracia escala con lo que costaba la orden: a 12 s de
#     nvidia-smi no se le dan 30 s de cortesía;
#   - mínimo 2, para que un proceso cooperativo alcance a vaciar su salida;
#   - máximo 10, porque el peor caso de pared es presupuesto + gracia y quien
#     llama tiene que poder prometer un tope. Pasados 10 s, un proceso que
#     sigue vivo tras el TERM no está terminando: está atascado.
#
# Una entrada ilegible (vacía, no numérica, 0) devuelve el MÍNIMO: sin
# presupuesto que escalar, la respuesta conservadora es esperar lo menos
# posible, no lo más.
domain_proc_kill_grace() { # $1=presupuesto en segundos -> gracia en segundos
  local budget="${1:-}" grace
  case "$budget" in
    ''|*[!0-9]*) printf '2'; return 0 ;;
  esac
  grace=$(( budget / 4 ))
  [ "$grace" -lt 2 ]  && grace=2
  [ "$grace" -gt 10 ] && grace=10
  printf '%s' "$grace"
}

# Peor caso de reloj de pared de una invocación acotada: presupuesto + gracia.
# Lo usa quien tiene que prometer un tope hacia arriba (p. ej. el presupuesto
# del padre que envuelve a su vez a este proceso).
domain_proc_worst_case() { # $1=presupuesto -> segundos
  local budget="${1:-}"
  case "$budget" in
    ''|*[!0-9]*) printf '0'; return 0 ;;
  esac
  printf '%s' "$(( budget + $(domain_proc_kill_grace "$budget") ))"
}

# ¿Este código de salida significa "no terminó en su presupuesto"?
#
#   124 — `timeout` agotó el presupuesto. Es el código que todo el repo trata
#         como "colgado: ABORTAR sin reintentar".
#   137 — 128+9: al proceso lo mató SIGKILL. Con `-k` es el desenlace normal de
#         un proceso que ignoró el TERM, y significa lo mismo: no terminó solo.
#
# 125/126/127 son errores de `timeout` en sí (no pudo ejecutar la orden) y NO
# son cuelgues: confundirlos haría que un binario ausente se tratase como una
# tarjeta semi-rota, y la reacción correcta es la opuesta.
domain_proc_is_hung() { # $1=rc
  case "${1:-}" in
    124|137) return 0 ;;
    *)       return 1 ;;
  esac
}
