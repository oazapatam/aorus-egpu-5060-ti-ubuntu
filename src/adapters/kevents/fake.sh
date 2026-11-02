#!/usr/bin/env bash
# adapters/kevents/fake.sh — eventos del kernel leídos de un fichero fijo.
#
# Doble de test del puerto kevents. Se selecciona con
# AORUS_ADAPTER_KEVENTS=adapters/kevents/fake (ver aorus_adapter en
# bootstrap.sh), que es la Inversión de Dependencias del repo en la práctica.
#
# POR QUÉ EXISTE: el acumulador de app/health.sh tuvo un bug que los tests del
# dominio no podían ver -las reglas puras estaban bien; lo que estaba roto era
# la ORQUESTACIÓN-. Capturar la salida de _health_acc_emit con una sustitución
# de comandos la ejecutaba en un subshell y el reset no llegaba al padre, así
# que el acumulador no se vaciaba nunca: 13 incidentes con el mismo instante de
# inicio y 5 `tb_device_loss` donde solo había 2. Sin un doble del puerto no
# había forma de probar esto sin un journal real y una eGPU que se caiga.
#
# Formato del fixture, idéntico al del adaptador real: "<epoch>\t<mensaje>".
# shellcheck shell=bash

: "${AORUS_KEVENTS_FIXTURE:=}"

kevents_read() { # $1=desde (se ignora: el fixture ya es la ventana)
  [ -r "$AORUS_KEVENTS_FIXTURE" ] || return 0
  cat -- "$AORUS_KEVENTS_FIXTURE"
}

# El follow del doble no bloquea: emite el fixture y termina. Así un test de
# health_watch comprueba que al cerrarse la fuente devuelve 75 y no gira en
# vacío, que es el contrato que espera systemd.
kevents_follow() { kevents_read ""; }
