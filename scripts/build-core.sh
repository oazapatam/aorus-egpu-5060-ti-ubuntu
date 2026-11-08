#!/usr/bin/env bash
# Construye dist/aorus-egpu-core_<ver>_all.deb — el núcleo COMPARTIDO.
#
# Este es el único build que ensambla src/{bootstrap.sh,domain,ports,adapters,
# app} en /usr/lib/aorus-egpu/. Los paquetes de capacidad solo entregan sus
# entrypoints de /usr/sbin y declaran este paquete en Depends; si alguno
# volviera a empaquetar el núcleo, dpkg rechazaría la instalación por ficheros
# pisados (ver el encabezado de scripts/lib/bundle.sh y la sección de solapes
# de ci/50-package-policy.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packaging/aorus-egpu-core"
OUT="$ROOT/dist"

. "$ROOT/scripts/lib/bundle.sh"

command -v dpkg-deb >/dev/null || { echo "ERROR: falta dpkg-deb" >&2; exit 1; }
VER="$(awk -F': ' '/^Version:/{print $2; exit}' "$PKG/DEBIAN/control")"

echo "==> ensamblando el núcleo src/ en el paquete"
bundle_payload "$ROOT" "$PKG"

echo "==> normalizando permisos"
# Directorios a 0755: dpkg-deb hornea el modo tal cual y umask 002 deja 0775,
# que lintian marca (non-standard-dir-perm).
find "$PKG" -type d -exec chmod 0755 {} +

echo "==> construyendo deb"
mkdir -p "$OUT"
DEB="$OUT/aorus-egpu-core_${VER}_all.deb"
dpkg-deb --root-owner-group --build "$PKG" "$DEB"

bundle_clean "$PKG"

echo
echo "Construido: $DEB"
echo "  dpkg-deb -c \"$DEB\"   # el núcleo que comparten los paquetes de capacidad"
echo "  no se instala solo: lo arrastra cualquier aorus-egpu-* >= 0.2.0"
