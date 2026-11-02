#!/usr/bin/env bash
# app/display.sh — CASOS DE USO de "el escritorio en la iGPU, las NVIDIA para IA".
#
# Esta capa ORQUESTA: pide el inventario al puerto DRM, el veredicto al dominio
# y las operaciones de módulo al puerto kmod. No decide nada por su cuenta.
#
# Orden de los gates, cada uno por una razón concreta:
#   1. display : la iGPU DEBE tener alguna salida conectada. Sin eso, quitarle
#                el modeset a NVIDIA deja la máquina CIEGA al reiniciar, y eso
#                no se descubre hasta que ya es tarde.
#   2. outputs : si NVIDIA está conduciendo alguna pantalla, se apagará. Es una
#                decisión del usuario, así que avisa y pide --force.
#   3. kmod    : al descargar, si algo retiene el driver se dice QUIÉN, en vez
#                de dejar un "Module in use" sin dueño.

# shellcheck shell=bash

aorus_use domain/display
aorus_use ports/drm.port ports/kmod.port ports/log.port
aorus_adapter drm adapters/drm/sysfs
aorus_adapter kmod adapters/kmod/linux
aorus_adapter log adapters/log/stderr

# El servicio que vuelve a levantarse en cuanto el driver bindea
# (sys-bus-pci-drivers-nvidia.device lo arrastra), y que por tanto hay que parar
# ANTES de intentar descargar.
AORUS_DISPLAY_PERSISTENCED="${AORUS_DISPLAY_PERSISTENCED:-nvidia-persistenced.service}"

# El fichero que decide quién pinta. Lo instala el .deb; se nombra con zz- para
# que modprobe lo lea DESPUÉS de nvidia-graphics-drivers-kms.conf (que pone
# modeset=1) y de nvidia-kms.conf de nvidia-prime: en los parámetros de módulo
# gana la última asignación.
AORUS_DISPLAY_MODPROBE_CONF="${AORUS_DISPLAY_MODPROBE_CONF:-/etc/modprobe.d/zz-aorus-egpu-igpu-display.conf}"

# --- inventario ---------------------------------------------------------------
# Imprime "<card> <driver> <bdf> <conectadas>" por línea.
display_inventory() {
  local card driver bdf conn
  while IFS= read -r card; do
    [ -n "$card" ] || continue
    driver="$(drm_card_driver "$card" 2>/dev/null)" || driver="?"
    bdf="$(drm_card_bdf "$card" 2>/dev/null)" || bdf="-"
    conn="$(drm_card_connected "$card" 2>/dev/null)" || conn=""
    printf '%s %s %s %s\n' "$card" "$driver" "$bdf" "$conn"
  done < <(drm_cards)
}

# Suma de salidas conectadas de las tarjetas cuyo driver cumple el predicado.
_display_count_by() { # $1=integrated|compute
  local card driver bdf conn total=0
  while read -r card driver bdf conn; do
    case "$1" in
      integrated) domain_display_is_integrated "$driver" || continue ;;
      compute)    domain_display_is_compute "$driver" || continue ;;
    esac
    domain_display_is_count "$conn" || { printf ''; return 1; }
    total=$((total + conn))
  done < <(display_inventory)
  printf '%s' "$total"
}

# --- caso de uso: status ------------------------------------------------------
display_status() {
  drm_available || { log_err "no puedo leer DRM en $AORUS_DRM_ROOT"; return 1; }

  local card driver bdf conn role
  log_info "tarjetas DRM:"
  while read -r card driver bdf conn; do
    if domain_display_is_integrated "$driver"; then role="escritorio"
    elif domain_display_is_compute "$driver"; then role="cómputo"
    else role="?"; fi
    log_info "  $(printf '%-7s %-8s %-12s %-10s %s salida(s) conectada(s)' \
      "$card" "$driver" "$bdf" "$role" "${conn:-?}")"
    while read -r out st en; do
      [ "$st" = "connected" ] && log_info "      $out ($st, enabled=$en)"
    done < <(drm_card_outputs "$card")
  done < <(display_inventory)

  local igpu nv
  igpu="$(_display_count_by integrated)"
  nv="$(_display_count_by compute)"
  log_info "salidas conectadas: iGPU=${igpu:-?} NVIDIA=${nv:-?}"

  if [ -r "$AORUS_DISPLAY_MODPROBE_CONF" ]; then
    log_info "config instalada:  $AORUS_DISPLAY_MODPROBE_CONF"
  else
    log_info "config instalada:  no (NVIDIA sigue con modeset del paquete nvidia)"
  fi

  # El fichero del parámetro es 0400 (solo root), así que "no se puede leer" y
  # "el módulo no está cargado" son cosas DISTINTAS y hay que decirlas distinto:
  # confundirlas hacía que como usuario normal informara de que el módulo no
  # estaba cargado cuando sí lo estaba, con modeset=Y.
  local modeset=/sys/module/nvidia_drm/parameters/modeset
  if [ ! -e "$modeset" ]; then
    log_info "nvidia_drm modeset: nvidia_drm no está cargado (eso ya es sin KMS)"
  elif [ -r "$modeset" ]; then
    case "$(cat "$modeset" 2>/dev/null)" in
      Y|y|1) log_info "nvidia_drm modeset: Y — NVIDIA SÍ registra KMS (el compositor puede usarla)" ;;
      N|n|0) log_info "nvidia_drm modeset: N — sin KMS, como queremos" ;;
      *)     log_info "nvidia_drm modeset: '$(cat "$modeset" 2>/dev/null)'" ;;
    esac
  else
    log_info "nvidia_drm modeset: existe pero es 0400; córrelo con sudo para verlo"
  fi
}

# --- caso de uso: check (el gate, sin tocar nada) -----------------------------
# rc: 0 ok, 1 dejaría la máquina ciega, 2 se apagarían pantallas de NVIDIA,
#     3 no se puede determinar.
display_check() {
  drm_available || { log_err "no puedo leer DRM en $AORUS_DRM_ROOT"; return 3; }
  local igpu nv verdict rc
  igpu="$(_display_count_by integrated)"
  nv="$(_display_count_by compute)"
  verdict="$(domain_display_release_verdict "$igpu" "$nv")"; rc=$?
  case "$verdict" in
    ok)
      log_info "GATE de pantalla: ok — la iGPU tiene $igpu salida(s) y NVIDIA $nv."
      ;;
    no-display)
      log_err "GATE de pantalla: la iGPU NO tiene ninguna salida conectada."
      log_err "Quitarle el modeset a NVIDIA dejaría la máquina CIEGA al reiniciar."
      log_err "Conecta el panel o un monitor a la iGPU antes de aplicar esto."
      ;;
    nvidia-outputs-lost)
      log_warn "GATE de pantalla: NVIDIA conduce $nv pantalla(s) que se APAGARÁN."
      log_warn "La iGPU tiene $igpu salida(s), así que no te quedas sin escritorio,"
      log_warn "pero esa(s) pantalla(s) no darán imagen. Pásalas a un puerto"
      log_warn "USB-C/Thunderbolt (van a la iGPU) o acepta con --force."
      ;;
    *)
      log_err "GATE de pantalla: no he podido contar las salidas (iGPU='$igpu' NVIDIA='$nv')."
      log_err "Sin ese dato no puedo afirmar que el cambio sea seguro."
      ;;
  esac
  return "$rc"
}

# --- caso de uso: soltar el driver --------------------------------------------
display_unload() {
  kmod_available || { log_err "no puedo operar con módulos del kernel."; return 1; }

  if kmod_service_active "$AORUS_DISPLAY_PERSISTENCED"; then
    log_info "parando $AORUS_DISPLAY_PERSISTENCED (lo arrastra el bind del driver)"
    kmod_service_stop "$AORUS_DISPLAY_PERSISTENCED" >/dev/null 2>&1 || \
      log_warn "no pude pararlo; la descarga puede fallar"
  fi

  local holders
  holders="$(kmod_node_holders)"
  if [ -n "$holders" ]; then
    log_warn "hay procesos con nodos /dev/nvidia* abiertos; la descarga fallará:"
    printf '%s\n' "$holders" | while read -r pid comm; do
      log_warn "  pid $pid  $comm"
    done
    log_warn "ciérralos (o el compositor los tiene: revisa 'status')."
  fi

  local mod rc=0 out
  while IFS= read -r mod; do
    kmod_loaded "$mod" || { log_info "  $mod ya no está cargado"; continue; }
    out="$(kmod_unload "$mod")" || {
      log_err "  no pude descargar $mod: ${out:-sin detalle}"
      log_err "  refcount=$(kmod_refcount "$mod") usuarios=$(kmod_users "$mod")"
      rc=1; continue
    }
    log_info "  $mod descargado"
  done < <(domain_display_unload_order)

  if [ "$rc" -eq 0 ]; then
    log_info "driver NVIDIA soltado."
  else
    log_err "quedan módulos cargados; nada se ha forzado."
  fi
  return "$rc"
}

display_reload() {
  kmod_available || { log_err "no puedo operar con módulos del kernel."; return 1; }
  local out
  out="$(kmod_load nvidia)" || { log_err "no pude cargar nvidia: $out"; return 1; }
  out="$(kmod_load nvidia_uvm)" || log_warn "nvidia cargado, pero nvidia_uvm no: $out"
  log_info "driver NVIDIA cargado (nvidia + nvidia_uvm; sin KMS por diseño)."
}
