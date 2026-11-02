#!/usr/bin/env bash
# Construye dist/aorus-egpu-config_<ver>_all.deb.
#
# SUPERSEDED: este paquete fue purgado de la máquina de referencia el
# 2026-06-28 y egpu-tb-fix lo reemplaza. Se conserva construible como archivo
# documentado (ver docs/what-actually-works.md). NO lo instales junto a
# egpu-tb-fix: ambos gestionan el BAR0 por udev y se pisarían.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packaging/aorus-egpu-config"
OUT="$ROOT/dist"

command -v dpkg-deb >/dev/null || { echo "ERROR: falta dpkg-deb" >&2; exit 1; }
VER="$(awk -F': ' '/^Version:/{print $2; exit}' "$PKG/DEBIAN/control")"

echo "AVISO: aorus-egpu-config está SUPERSEDED por egpu-tb-fix." >&2

chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"
chmod 0755 "$PKG/usr/bin/aorus-egpu-status"
chmod 0755 "$PKG"/usr/sbin/*
find "$PKG/etc" -type f -exec chmod 0644 {} +

# Normalizar permisos de DIRECTORIO: dpkg-deb hornea el modo tal cual y
# umask 002 deja 0775, que lintian marca (non-standard-dir-perm). Los
# ficheros ya se normalizan arriba; los directorios faltaban.
find "$PKG" -type d -exec chmod 0755 {} +

mkdir -p "$OUT"
DEB="$OUT/aorus-egpu-config_${VER}_all.deb"
dpkg-deb --root-owner-group --build "$PKG" "$DEB"
echo "Construido: $DEB"
