#!/usr/bin/env bash
# Construye dist/aorus-egpu-overclock_<ver>_all.deb.
# El payload se ENSAMBLA desde src/ (ver scripts/lib/bundle.sh); nada de lógica
# duplicada en packaging/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packaging/aorus-egpu-overclock"
OUT="$ROOT/dist"
# Dos entrypoints: la CLI y el TUI de ncurses. Array como en
# build-health.sh / build-forensics.sh, que es el idioma del repo para
# esto; `bundle_core` y `bundle_clean` ya toman una lista.
BINS=(aorus-egpu-oc nvidia-oc)

. "$ROOT/scripts/lib/bundle.sh"

command -v dpkg-deb >/dev/null || { echo "ERROR: falta dpkg-deb" >&2; exit 1; }
VER="$(awk -F': ' '/^Version:/{print $2; exit}' "$PKG/DEBIAN/control")"

echo "==> ensamblando el núcleo src/ en el paquete"
bundle_core "$ROOT" "$PKG" "${BINS[@]}"

echo "==> normalizando permisos"
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"
find "$PKG/etc" "$PKG/usr/lib/systemd" "$PKG/usr/lib/udev" -type f -exec chmod 0644 {} +

# Normalizar permisos de DIRECTORIO: dpkg-deb hornea el modo tal cual y
# umask 002 deja 0775, que lintian marca (non-standard-dir-perm). Los
# ficheros ya se normalizan arriba; los directorios faltaban.
find "$PKG" -type d -exec chmod 0755 {} +

echo "==> construyendo deb"
mkdir -p "$OUT"
DEB="$OUT/aorus-egpu-overclock_${VER}_all.deb"
dpkg-deb --root-owner-group --build "$PKG" "$DEB"

bundle_clean "$PKG" "${BINS[@]}"

echo
echo "Construido: $DEB"
echo "  dpkg-deb -c \"$DEB\"      # qué instala"
echo "  sudo apt install \"$DEB\"  # instalar (no aplica ningún perfil)"
echo "  sudo apt remove aorus-egpu-overclock   # revertir a fábrica"
