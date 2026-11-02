#!/usr/bin/env bash
# Construye el .deb reversible aorus-egpu-nvidia-dkms: los modulos NVIDIA open
# 595.71.05 PARCHEADOS (levers de fiabilidad del eGPU AORUS) empaquetados como
# fuente DKMS. NO instala nada. Salida en dist/.
#
# Pipeline:
#   1. clona/cachea open-gpu-kernel-modules upstream @ el tag que casa,
#   2. lo deja pristino y aplica egpu-driver/patches/*.patch en orden,
#   3. fija NV_VERSION_STRING al valor stock (casa userspace + firmware GSP),
#   4. stagea el arbol parcheado + dkms.conf bajo usr/src/<name>-<ver>/,
#   5. dpkg-deb --build -> dist/.
#
# Portado del repo aorus-5060-egpu (ubuntu/build-nvidia-deb.sh) e integrado aqui
# al consolidar el stack del eGPU dentro de squadai-stable.
#
# Requiere RED para el git clone de open-gpu-kernel-modules la primera vez.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
patchdir="$HERE/kernel/patches"
dkmsconf="$HERE/kernel/dkms/nvidia-dkms.conf"
pkg="$HERE/packaging/aorus-egpu-nvidia-dkms"
build="$HERE/build"
out="$HERE/dist"

command -v dpkg-deb >/dev/null 2>&1 || { echo "ERROR: dpkg-deb no disponible." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git no disponible." >&2; exit 1; }
[ -f "$pkg/DEBIAN/control" ] || { echo "ERROR: falta $pkg/DEBIAN/control" >&2; exit 1; }
[ -f "$dkmsconf" ] || { echo "ERROR: falta $dkmsconf" >&2; exit 1; }

# Identidad de driver/version. NV_VERSION (la version reportada por el modulo)
# DEBE igualar el userspace + firmware GSP instalados; DKMS_VER es la revision
# del deb/dkms.
NV_VERSION="595.71.05"
DKMS_NAME="aorus-nvidia"
DKMS_VER="$(awk -F': ' '/^Version:/{print $2; exit}' "$pkg/DEBIAN/control")"
TAG="$NV_VERSION"
REPO_URL="https://github.com/NVIDIA/open-gpu-kernel-modules.git"

src="$build/ogkm"

echo "==> fuente upstream @ $TAG"
mkdir -p "$build"
if [ ! -d "$src/.git" ]; then
  git clone --depth 1 --branch "$TAG" "$REPO_URL" "$src"
fi
git -C "$src" fetch --depth 1 origin "$TAG" >/dev/null 2>&1 || true
git -C "$src" checkout -q "$TAG" 2>/dev/null || true
git -C "$src" checkout -q -- . 2>/dev/null || true
# -x para barrer tambien artefactos de build gitignorados (_out/, *.o, *.ko),
# no solo fuente sin rastrear, o un build previo filtraria objetos al paquete.
git -C "$src" clean -fdqx

echo "==> aplicando $(ls "$patchdir"/[0-9]*.patch | wc -l) parches"
# Apply estricto para todos. EXCEPCION: 0032 se escribio a mano y sus contadores
# de hunk (@@ -a,b +c,d @@) quedaron mal en los seis hunks -> git apply lo rechaza
# como "corrupt patch". --recount infiere los contadores del cuerpo del parche;
# el contexto SIGUE validandose (no enmascara un parche que de verdad no aplique).
# Se acota a 0032 a proposito: --recount global rompe 0023 (cambia que lineas
# entran en sus hunks), asi que el resto va con contadores estrictos.
for p in "$patchdir"/[0-9]*.patch; do
  recount=""
  case "$(basename "$p")" in 0032-*) recount="--recount" ;; esac
  git -C "$src" apply $recount --whitespace=nowarn "$p" \
    || { echo "FALLO: $(basename "$p")" >&2; exit 1; }
done

echo "==> fijando NV_VERSION_STRING a $NV_VERSION (casa userspace/firmware stock)"
sed -i "s/^NVIDIA_VERSION = .*/NVIDIA_VERSION = $NV_VERSION/" "$src/version.mk"
grep -q "^NVIDIA_VERSION = $NV_VERSION$" "$src/version.mk" \
  || { echo "fallo el pin de version.mk" >&2; exit 1; }

echo "==> staging del arbol del paquete"
stage_src="$pkg/usr/src/${DKMS_NAME}-${DKMS_VER}"
# ${pkg:?} y no "$pkg": si $pkg saliera vacío, "$pkg/usr" sería `rm -rf /usr`.
# Con `set -u` un $pkg SIN DEFINIR ya abortaría, pero no uno definido y vacío;
# el :? cubre ese hueco (SC2115). En la ruta normal no cambia nada.
rm -rf "${pkg:?}/usr"
mkdir -p "$stage_src"
# El arbol parcheado no tiene artefactos de build (clon limpio + solo parches),
# asi que una copia excluyendo .git lleva exactamente la fuente que DKMS necesita
# (incluidos los ficheros Lever sin rastrear: nv-lever-m-recover.*, nv-qwatchdog.*).
( cd "$src" && tar --exclude=./.git -cf - . ) | tar -x -C "$stage_src"
cp "$dkmsconf" "$stage_src/dkms.conf"

# Normalizar permisos que dpkg-deb hornea.
chmod 0755 "$pkg/DEBIAN/postinst" "$pkg/DEBIAN/prerm" "$pkg/DEBIAN/postrm"
find "$stage_src" -type d -exec chmod 0755 {} +
find "$stage_src" -type f -exec chmod 0644 {} +
chmod 0755 "$stage_src/conftest.sh" "$stage_src/nv-compiler.sh" 2>/dev/null || true

echo "==> construyendo deb"
mkdir -p "$out"
deb="$out/aorus-egpu-nvidia-dkms_${DKMS_VER}_all.deb"
dpkg-deb --root-owner-group --build "$pkg" "$deb"

# Mantener el arbol stageado fuera de git (grande); es reproducible desde parches.
rm -rf "${pkg:?}/usr"   # ${pkg:?}: ver la nota del rm -rf de arriba.

echo
echo "Construido: $deb"
echo "Instalar (dkms build, Secure Boot OFF):  sudo apt install \"$deb\""
echo "Verificar:  modinfo -F version nvidia ; nvidia-smi"
echo "Revertir:   sudo apt remove aorus-egpu-nvidia-dkms"
