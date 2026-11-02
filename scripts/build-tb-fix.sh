#!/usr/bin/env bash
# Construye dist/egpu-tb-fix_<ver>_all.deb — el paquete PRINCIPAL y el único
# verificado en vivo (ver docs/what-actually-works.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packaging/egpu-tb-fix"
OUT="$ROOT/dist"

command -v dpkg-deb >/dev/null || { echo "ERROR: falta dpkg-deb" >&2; exit 1; }
VER="$(awk -F': ' '/^Version:/{print $2; exit}' "$PKG/DEBIAN/control")"

find "$PKG" -type d -exec chmod 0755 {} +
find "$PKG" -type f -exec chmod 0644 {} +
chmod 0755 "$PKG/usr/sbin/egpu-tb-fix" \
           "$PKG/usr/lib/systemd/system-shutdown/egpu-tb-fix.shutdown" \
           "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"

mkdir -p "$OUT"
DEB="$OUT/egpu-tb-fix_${VER}_all.deb"
dpkg-deb --root-owner-group --build "$PKG" "$DEB"
echo "Construido: $DEB"
