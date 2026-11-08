#!/usr/bin/env bash
# scripts/lib/bundle.sh — ensambla el núcleo src/ y los entrypoints dentro del
# payload de un paquete. Fuente ÚNICA: src/. Lo que queda bajo
# packaging/<pkg>/usr/ es GENERADO y está gitignorado, igual que el árbol
# usr/src del paquete DKMS.
#
# Mapeo:  src/{bootstrap.sh,domain,ports,adapters,app}  ->  usr/lib/aorus-egpu/
#           ... y eso lo entrega UN SOLO paquete: aorus-egpu-core.
#         src/bin/<x>                                   ->  usr/sbin/<x>
#           ... y eso lo entrega el paquete de la capacidad.
#
# POR QUÉ EL NÚCLEO VIVE EN SU PROPIO PAQUETE (y no una copia por paquete, que
# es lo que se hacía hasta el 2026-11-07):
#
#   Los cuatro paquetes hexagonales entregaban el núcleo ENTERO en la misma
#   ruta, /usr/lib/aorus-egpu/. dpkg no permite que dos paquetes se pisen un
#   fichero, así que instalar un segundo paquete fallaba en seco:
#
#     trying to overwrite '/usr/lib/aorus-egpu/adapters/drm/sysfs.sh',
#     which is also in package aorus-egpu-igpu-display
#
#   No se había notado porque nunca había habido dos instalados a la vez. El
#   solape medido era de 45 de 46 ficheros: no era un roce, era el payload
#   completo. Y los arreglos de atajo (Replaces sin Breaks, o un Conflicts)
#   rompían la REVERSIBILIDAD, que es el invariante nº1 del repo: con Replaces,
#   `apt remove` del último instalado se habría llevado el núcleo que el otro
#   paquete necesitaba para seguir funcionando.
#
#   Así que el núcleo compartido se entrega una vez, en aorus-egpu-core, y cada
#   paquete de capacidad lo DECLARA como dependencia. Es la misma idea que ya
#   gobierna src/: una sola fuente de lógica.
#
# Por qué copiar y no symlinks: dpkg-deb hornea el contenido, y un symlink al
# checkout dejaría el paquete roto en cualquier otra máquina.
#
# VARIOS entrypoints por paquete es parte del contrato, no un accidente:
# `bundle_bins <root> <pkg> <bin>...` y `bundle_clean <pkg> <bin>...` toman una
# lista. Lo usan build-health.sh, build-forensics.sh, build-igpu-display.sh y
# build-overclock.sh (que entrega la CLI `aorus-egpu-oc` y el TUI `nvidia-oc`).
# Un paquete con un solo binario pasa un solo nombre y nada cambia.

# Ensambla el NÚCLEO compartido. Lo llama SOLO scripts/build-core.sh: si lo
# llamara un paquete de capacidad, volvería el solape que este fichero
# documenta más arriba.
bundle_payload() { # $1=dir raíz del repo  $2=dir del paquete (aorus-egpu-core)
  local root="$1" pkg="$2"
  local lib="$pkg/usr/lib/aorus-egpu" layer

  rm -rf "$lib"
  mkdir -p "$lib"
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

  # El BYTECODE de python tampoco se entrega. `cp -a` arrastra cualquier
  # __pycache__ que haya quedado en src/adapters/ -lo crea python al importar
  # los helpers (el verificador se importa por ruta desde tools/egpu-oc-edge,
  # y eso basta)-, y un .pyc es contenido GENERADO, atado a la versión de
  # python de la máquina que construyó el paquete: en otra, el intérprete lo
  # ignora o lo invalida. Lintian lo marca (package-installs-python-pycache-dir)
  # y tiene razón. Mismo criterio que fake.sh: el payload solo lleva fuente.
  find "$lib" -type d -name '__pycache__' -prune -exec rm -rf {} +
  find "$lib" -type f -name '*.pyc' -delete

  find "$lib" -type d -exec chmod 0755 {} +
  find "$lib" -type f -exec chmod 0644 {} +
}

# Instala los ENTRYPOINTS de un paquete de capacidad. No toca usr/lib: el
# núcleo lo pone aorus-egpu-core y el paquete lo declara en Depends.
bundle_bins() { # $1=dir raíz del repo  $2=dir del paquete  $3..=binarios de src/bin
  local root="$1" pkg="$2"; shift 2
  local b

  mkdir -p "$pkg/usr/sbin"
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
