#!/usr/bin/env bash
# domain/health.sh — QUÉ significa cada mensaje del kernel sobre la eGPU.
#
# Capa de DOMINIO: funciones PURAS. Reciben una línea de log ya leída y
# deciden; no abren el journal, no escriben nada. Eso vive en adapters/.
#
# POR QUÉ EXISTE ESTE MÓDULO: el 2026-11-02 la eGPU sufrió un Xid 79 y nada
# avisó. Se encontró a mano, rebuscando en `dmesg`, y la pregunta que de verdad
# importaba —¿falló la GPU, o se cayó la caja entera y la GPU es la víctima?—
# costó una hora de correlación manual de timestamps.
# Esa correlación es una REGLA, así que vive aquí y lleva test.
#
# El veredicto de incidente es la pieza central. Distinguir
# `tb_device_loss` de `gpu_fault` cambia el diagnóstico por completo:
# el primero apunta al túnel/caja/energía, el segundo a la GPU o al driver.
# Confundirlos manda la investigación al sitio equivocado.

# shellcheck shell=bash

# Clasifica UNA línea de log del kernel. Imprime la clase, siempre una sola.
#
# Los patrones son los mensajes REALES observados en esta máquina, no los que
# la documentación de NVIDIA sugiere: se capturaron del incidente de
# 13:31:52-53 del 2026-11-02 y de los arranques de egpu-tb-fix.
# Variante que ASIGNA en vez de imprimir, para el camino caliente.
# `$(domain_health_classify ...)` forkea un subshell por línea, y el scan
# recorre decenas de miles de líneas del journal: medido el 2026-11-02, el
# barrido de 13 días no terminaba en 120 s por esto solo. La regla no se
# duplica: este es el único `case`, y domain_health_classify() lo envuelve.
domain_health_classify_var() { # $1=linea -> AORUS_HEALTH_CLASS
  local l="${1:-}"
  case "$l" in
    # --- NVIDIA ---
    *"has fallen off the bus"*)        AORUS_HEALTH_CLASS=xid_fallen_off_bus ;;
    *"GPU recovery action changed"*)   AORUS_HEALTH_CLASS=xid_recovery_required ;;
    *"GPU lost from the bus"*)         AORUS_HEALTH_CLASS=gpu_lost ;;
    *"Xid"*)                           AORUS_HEALTH_CLASS=xid_other ;;
    # --- Thunderbolt ---
    *"thunderbolt"*"device disconnected"*) AORUS_HEALTH_CLASS=tb_disconnect ;;
    *"thunderbolt"*"new device found"*)    AORUS_HEALTH_CLASS=tb_connect ;;
    # --- hotplug PCIe ---
    # "Card not present" lo emite el puerto hotplug cuando el túnel se derriba;
    # NO implica que alguien desenchufara nada.
    *"pciehp"*"Link Down"*)            AORUS_HEALTH_CLASS=pcie_link_down ;;
    *"pciehp"*"Card not present"*)     AORUS_HEALTH_CLASS=pcie_card_gone ;;
    *"pciehp"*"Link Up"*)              AORUS_HEALTH_CLASS=pcie_link_up ;;
    *"pciehp"*"Card present"*)         AORUS_HEALTH_CLASS=pcie_card_present ;;
    # --- USB de la caja ---
    # La caja expone un hub USB y una ethernet r8152 por el MISMO túnel. Que el
    # USB se vaya es la señal de que cae el dispositivo entero, no solo la GPU.
    *"USB disconnect"*)                AORUS_HEALTH_CLASS=usb_disconnect ;;
    *)                                 AORUS_HEALTH_CLASS=none ;;
  esac
}

# Interfaz que imprime. Envuelve a la anterior para que la regla exista UNA vez.
domain_health_classify() { # $1=linea
  domain_health_classify_var "${1:-}"
  printf '%s' "$AORUS_HEALTH_CLASS"
}

# Severidad de una clase. 'critical' = perdiste el dispositivo o el trabajo.
domain_health_severity() { # $1=clase
  case "${1:-}" in
    xid_fallen_off_bus|pcie_link_down|pcie_card_gone|tb_disconnect)
      printf 'critical' ;;
    xid_recovery_required|gpu_lost|xid_other|usb_disconnect)
      printf 'warning' ;;
    tb_connect|pcie_link_up|pcie_card_present)
      printf 'info' ;;
    *)
      printf 'none' ;;
  esac
}

# Extrae el número de Xid de una línea. Vacío si no es un Xid.
# Formato real: "NVRM: Xid (PCI:0000:b4:00): 79, GPU has fallen off the bus."
domain_health_xid_number() { # $1=linea
  local l="${1:-}" n
  case "$l" in *"Xid ("*) ;; *) return 1 ;; esac
  n="${l#*): }"; n="${n%%,*}"
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$n" ;;
  esac
}

# Extrae el BDF de una línea de Xid, normalizado a dominio:bus:slot.func
# ("0000:b4:00" -> "0000:b4:00.0"). El journal lo da SIN función; sysfs la
# necesita, y compararlos sin normalizar daba un falso negativo.
domain_health_xid_bdf() { # $1=linea
  local l="${1:-}" b
  case "$l" in *"Xid (PCI:"*) ;; *) return 1 ;; esac
  b="${l#*Xid (PCI:}"; b="${b%%)*}"
  [ -n "$b" ] || return 1
  case "$b" in *.*) printf '%s' "$b" ;; *) printf '%s.0' "$b" ;; esac
}

# ¿Este Xid significa que el dispositivo desapareció del bus?
# 79 y 154 son los dos observados en el incidente real; el resto de Xid son
# errores de cómputo o de canal y NO implican pérdida del dispositivo.
domain_health_xid_is_device_loss() { # $1=numero
  case "${1:-}" in 79|154) return 0 ;; *) return 1 ;; esac
}

# VEREDICTO DE INCIDENTE — el corazón de este módulo.
#
# Recibe las clases observadas en una ventana temporal, en orden de aparición,
# como argumentos. Decide DÓNDE está la causa:
#
#   tb_device_loss  el dispositivo Thunderbolt entero se fue (USB + PCIe).
#                   La GPU es la VÍCTIMA. Investigar túnel, energía, cable,
#                   ASPM/runtime PM del camino. NO la GPU ni el driver.
#   pcie_link_loss  cayó la rama PCIe de la GPU pero el USB de la caja siguió.
#                   Apunta al puente/puerto de esa rama.
#   gpu_fault       Xid de pérdida SIN que el enlace cayera: la GPU o el
#                   driver fallaron con el bus intacto.
#   degraded        hubo avisos pero nada crítico.
#   healthy         nada que reportar.
#
# Por qué el USB decide: el 2026-11-02 el primer evento fue
# "usb 6-2: USB disconnect", 3 ms ANTES del Link Down de PCIe. La ethernet de
# la caja se fue en el mismo instante. Un fallo de la GPU no puede tirar la
# ethernet de la caja: si el USB cae, cayó el dispositivo entero.
domain_health_incident_verdict() { # $@=clases en orden
  local c usb=0 link=0 xid=0 tb=0 warn=0
  for c in "$@"; do
    case "$c" in
      # Solo marca usb; deliberadamente NO cuenta como aviso.
      #
      # LIMITACIÓN CONSCIENTE: por la línea de log no se puede saber si el USB
      # que se fue pertenece a la caja o es un pendrive cualquiera. Atribuirlo
      # exigiría conocer la ruta del hub de la caja, que es configuración del
      # entorno y no una regla del dominio.
      #
      # Se eligió no avisar: barriendo 13 días de journal aparecieron 6
      # `usb_disconnect` sueltos de dispositivos ajenos y 0 caídas reales de la
      # caja sin PCIe detrás. Avisar de los 6 entrena a ignorar la herramienta,
      # que es peor que no avisar. En los DOS incidentes reales el USB vino
      # siempre acompañado de Link Down, así que el modo de fallo que importa
      # se sigue detectando.
      usb_disconnect)                   usb=1 ;;
      pcie_link_down|pcie_card_gone)    link=1 ;;
      xid_fallen_off_bus)               xid=1 ;;
      tb_disconnect)                    tb=1 ;;
      gpu_lost|xid_recovery_required|xid_other) warn=1 ;;
    esac
  done
  if [ "$usb" = 1 ] && { [ "$link" = 1 ] || [ "$tb" = 1 ]; }; then
    printf 'tb_device_loss'
  elif [ "$link" = 1 ] || [ "$tb" = 1 ]; then
    printf 'pcie_link_loss'
  elif [ "$xid" = 1 ]; then
    printf 'gpu_fault'
  elif [ "$warn" = 1 ]; then
    printf 'degraded'
  else
    # Una ventana con SOLO eventos de conexión (tb_connect / link up) es el
    # arranque normal, no un incidente. Marcarla 'degraded' llenaba el registro
    # de falsos positivos y entrena a ignorar la herramienta.
    printf 'healthy'
  fi
}

# ¿Se recuperó el dispositivo dentro de la ventana?
# Un incidente con recuperación sigue siendo un incidente: mató el proceso en
# vuelo. Pero "se recuperó solo" y "sigue caído" piden acciones distintas.
domain_health_incident_recovered() { # $@=clases
  local c
  for c in "$@"; do
    case "$c" in tb_connect|pcie_link_up|pcie_card_present) return 0 ;; esac
  done
  return 1
}
