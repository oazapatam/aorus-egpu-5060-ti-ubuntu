#!/usr/bin/env bash
# Construye dist/aorus-egpu-igpu-display_<ver>_all.deb.
# El payload se ensambla desde src/ (ver scripts/lib/bundle.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packaging/aorus-egpu-igpu-display"
OUT="$ROOT/dist"
BINS=(aorus-egpu-display)

. "$ROOT/scripts/lib/bundle.sh"

command -v dpkg-deb >/dev/null || { echo "ERROR: falta dpkg-deb" >&2; exit 1; }
VER="$(awk -F': ' '/^Version:/{print $2; exit}' "$PKG/DEBIAN/control")"

echo "==> ensamblando el núcleo src/ en el paquete"
bundle_core "$ROOT" "$PKG" "${BINS[@]}"

# La plantilla de modprobe se instala AQUÍ, no se envía en el árbol del paquete:
# bundle_clean borra usr/share/aorus-egpu tras cada build (ahí genera forensics
# su copia del medidor), así que una plantilla guardada en su ruta final se
# autodestruye en el primer build. Mismo patrón que build-forensics.sh con
# tools/egpu-bandwidth.cu.
install -D -m 0644 "$ROOT/packaging/templates/zz-aorus-egpu-igpu-display.conf" \
  "$PKG/usr/share/aorus-egpu/zz-aorus-egpu-igpu-display.conf"
echo "==> instalada la plantilla de modprobe.d"

echo "==> normalizando permisos"
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"
[ -d "$PKG/usr/share" ] && find "$PKG/usr/share" -type f -exec chmod 0644 {} +
# Directorios a 0755: dpkg-deb hornea el modo tal cual y umask 002 deja 0775,
# que lintian marca (non-standard-dir-perm).
find "$PKG" -type d -exec chmod 0755 {} +

echo "==> construyendo deb"
mkdir -p "$OUT"
DEB="$OUT/aorus-egpu-igpu-display_${VER}_all.deb"
dpkg-deb --root-owner-group --build "$PKG" "$DEB"

bundle_clean "$PKG" "${BINS[@]}"

echo
echo "Construido: $DEB"
echo "  aorus-egpu-display check            compruébalo ANTES de instalar"
echo "  sudo apt install \"$DEB\""
echo "  sudo reboot                         nvidia_drm ya está cargado con KMS"
