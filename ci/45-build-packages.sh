#!/usr/bin/env bash
# ci/45-build-packages.sh — construye los .deb y comprueba que son instalables.
#
# Va en el 45 a propósito: después de los parches del kernel (40) y ANTES de
# lintian (60) y de la política de paquetes (50), que necesitan los .deb hechos.
#
# No instala NADA. `apt-get install --simulate` solo resuelve dependencias, que
# es la comprobación que de verdad importa: un paquete que construye pero cuyas
# dependencias no se satisfacen es un paquete roto.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ci/lib/report.sh
CI_STAGE=45-build-packages

# Paquetes que el CI construye. Los SUPERSEDED se construyen también —deben
# seguir siendo construibles como archivo documentado— pero su fallo no tumba el
# CI, porque arrastran deuda conocida (ver docs/what-actually-works.md).
# El DKMS se EXCLUYE: clona ~1 GB de open-gpu-kernel-modules de la red.
declare -A BUILD=(
  [egpu-tb-fix]="scripts/build-tb-fix.sh:critico"
  [aorus-egpu-forensics]="scripts/build-forensics.sh:critico"
  [aorus-egpu-health]="scripts/build-health.sh:critico"
  [aorus-egpu-overclock]="scripts/build-overclock.sh:critico"
  [aorus-egpu-config]="scripts/build-config.sh:archivo"
)

ci_section "construcción de paquetes"
ci_need dpkg-deb "sudo apt install dpkg-dev" || { ci_summary; exit $?; }

for pkg in $(printf '%s\n' "${!BUILD[@]}" | sort); do
  spec="${BUILD[$pkg]}"; script="${spec%%:*}"; clase="${spec##*:}"
  if [ ! -f "$script" ]; then ci_fail "falta el build script de $pkg: $script"; continue; fi
  out="$(bash "$script" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ci_ok "$pkg construido"
  elif [ "$clase" = "archivo" ]; then
    ci_warn_with "$pkg (SUPERSEDED) no construye — deuda conocida" "$out"
  else
    ci_fail "$pkg NO construye (rc=$rc)" "$out"
  fi
done

# --- los .deb resultantes deben ser legibles y resolver dependencias ---------
ci_section "integridad y dependencias de los .deb"
shopt -s nullglob
debs=(dist/*.deb)
if [ "${#debs[@]}" -eq 0 ]; then
  ci_fail "no se produjo ningún .deb en dist/"
else
  for d in "${debs[@]}"; do
    if ! out="$(dpkg-deb -I "$d" 2>&1)"; then
      ci_fail "dpkg-deb no puede leer $d" "$out"; continue
    fi
    # --simulate NO instala; solo resuelve. Necesita root para leer el estado
    # de apt, así que si no hay sudo sin contraseña se omite en vez de fallar.
    if sim="$(sudo -n apt-get install --simulate "./$d" 2>&1)"; then
      ci_ok "$(basename "$d") — legible y con dependencias satisfechas"
    else
      case "$sim" in
        *"a password is required"*|*"sudo:"*)
          ci_skip "$(basename "$d") — legible; dependencias sin comprobar (sudo pide contraseña)" ;;
        *) ci_fail "$(basename "$d") — dependencias NO satisfechas" "$sim" ;;
      esac
    fi
  done
fi

# --- los árboles ensamblados deben quedar limpios tras el build --------------
# bundle_clean los barre; si quedan, el siguiente build arrastra basura y
# podrían colarse en git.
ci_section "limpieza de los árboles generados"
sucio=0
for p in packaging/aorus-egpu-overclock packaging/aorus-egpu-forensics; do
  if [ -d "$p/usr/lib/aorus-egpu" ]; then
    ci_fail "$p/usr/lib/aorus-egpu no se limpió tras el build"; sucio=1
  fi
done
[ "$sucio" -eq 0 ] && ci_ok "sin restos de bundle_core"

ci_summary
