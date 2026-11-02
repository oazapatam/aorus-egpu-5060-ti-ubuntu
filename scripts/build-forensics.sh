#!/usr/bin/env bash
# Construye dist/aorus-egpu-forensics_<ver>_all.deb.
# El payload se ensambla desde src/ (ver scripts/lib/bundle.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packaging/aorus-egpu-forensics"
OUT="$ROOT/dist"
BINS=(aorus-egpu-probe aorus-egpu-postmortem)

. "$ROOT/scripts/lib/bundle.sh"

command -v dpkg-deb >/dev/null || { echo "ERROR: falta dpkg-deb" >&2; exit 1; }
VER="$(awk -F': ' '/^Version:/{print $2; exit}' "$PKG/DEBIAN/control")"

echo "==> ensamblando el núcleo src/ en el paquete"
bundle_core "$ROOT" "$PKG" "${BINS[@]}"

# Se envía el FUENTE del medidor de ancho de banda, no el binario: este paquete
# es Architecture: all y meter un ELF dentro lo haría mentir (y lintian lo marca
# con arch-independent-package-contains-binary, missing-dependency-on-libc y
# unstripped-binary-or-object). El fuente es portable y compila en un segundo;
# `aorus-egpu-probe bandwidth` imprime la orden exacta si no lo encuentra.
install -D -m 0644 "$ROOT/tools/egpu-bandwidth.cu" \
  "$PKG/usr/share/aorus-egpu/egpu-bandwidth.cu"
echo "==> incluido el fuente tools/egpu-bandwidth.cu"

echo "==> normalizando permisos"
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"
for d in etc usr/lib/systemd usr/lib/udev usr/lib/modules-load.d usr/share; do
  [ -d "$PKG/$d" ] && find "$PKG/$d" -type f -exec chmod 0644 {} +
done

# Normalizar permisos de DIRECTORIO: dpkg-deb hornea el modo tal cual y
# umask 002 deja 0775, que lintian marca (non-standard-dir-perm). Los
# ficheros ya se normalizan arriba; los directorios faltaban.
find "$PKG" -type d -exec chmod 0755 {} +

echo "==> construyendo deb"
mkdir -p "$OUT"
DEB="$OUT/aorus-egpu-forensics_${VER}_all.deb"
dpkg-deb --root-owner-group --build "$PKG" "$DEB"

bundle_clean "$PKG" "${BINS[@]}"

echo
echo "Construido: $DEB"
echo "  sudo apt install \"$DEB\"   # capas 1 y 2 activas al instante"
echo "  sudo reboot                 # habilita ramoops (capa 3)"
