#!/usr/bin/env bash
# scripts/lib/bundle.sh — ensambla el núcleo src/ dentro del payload de un
# paquete. Fuente ÚNICA: src/. Lo que queda bajo packaging/<pkg>/usr/lib/ es
# GENERADO y está gitignorado, igual que el árbol usr/src del paquete DKMS.
#
# Mapeo:  src/{bootstrap.sh,domain,ports,adapters,app}  ->  usr/lib/aorus-egpu/
#         src/bin/<x>                                   ->  usr/sbin/<x>
#
# Por qué copiar y no symlinks: dpkg-deb hornea el contenido, y un symlink al
# checkout dejaría el paquete roto en cualquier otra máquina.

bundle_core() { # $1=dir raíz del repo  $2=dir del paquete  $3..=binarios de src/bin a incluir
  local root="$1" pkg="$2"; shift 2
  local lib="$pkg/usr/lib/aorus-egpu" b

  rm -rf "$lib"
  mkdir -p "$lib" "$pkg/usr/sbin"
  install -m 0644 "$root/src/bootstrap.sh" "$lib/bootstrap.sh"
  for layer in domain ports adapters app; do
    cp -a "$root/src/$layer" "$lib/$layer"
  done

  # Los DOBLES DE TEST no se entregan. Viven en src/adapters/ porque son
  # adaptadores legítimos de su puerto y `aorus_adapter` los resuelve bajo
  # AORUS_LIB_ROOT, pero no son código de producción.
  #
  # No es una cuestión de tamaño: `aorus-egpu-oc` eleva con `sudo -E`, que
  # PRESERVA AORUS_ADAPTER_GPU, así que con el doble instalado un
  # `AORUS_ADAPTER_GPU=adapters/gpu/fake aorus-egpu-oc apply performance`
  # reportaría "perfil aplicado" sin haber tocado la tarjeta. Un falso éxito
  # en la ruta de escritura es peor que no tener la herramienta.
  find "$lib" -type f -name 'fake.sh' -delete

  find "$lib" -type d -exec chmod 0755 {} +
  find "$lib" -type f -exec chmod 0644 {} +

  for b in "$@"; do
    install -m 0755 "$root/src/bin/$b" "$pkg/usr/sbin/$b"
  done
}

# Quita lo generado para que no se cuele en git ni en el siguiente build.
bundle_clean() { # $1=dir del paquete $2..=binarios a borrar
  local pkg="$1"; shift
  rm -rf "$pkg/usr/lib/aorus-egpu"
  # usr/share/aorus-egpu lo genera build-forensics.sh (copia del fuente del
  # medidor). Si no se barre, queda en el arbol y un `git add -A` lo versiona:
  # ya paso una vez.
  rm -rf "$pkg/usr/share/aorus-egpu"
  local b; for b in "$@"; do rm -f "$pkg/usr/sbin/$b"; done
  # Barre los directorios que se quedaron VACÍOS al retirar lo generado, de
  # abajo arriba. `rmdir` sin -p no basta: deja usr/ y usr/lib/ colgando, y un
  # `rm -rf usr` se llevaría los ficheros que el paquete SÍ mantiene a mano
  # (units systemd, reglas udev). Solo se borra lo que está vacío.
  find "$pkg/usr" -depth -type d -empty -delete 2>/dev/null || true
}
