#!/usr/bin/env bash
# ci/10-shell-syntax.sh — sintaxis de TODO el shell del repo.
#
# Es la etapa más barata y la que más vale: un error de sintaxis en un
# maintainer script de Debian rompe `apt install` a MITAD de la instalación y
# deja el sistema en un estado raro, que es justo lo que este proyecto no puede
# permitirse.
#
# Separa bash de POSIX sh a propósito: los maintainer scripts declaran
# `#!/bin/sh` y hay que validarlos como sh, no como bash, o se colarían
# bashismos que fallarían en el arranque de dpkg.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ci/lib/report.sh
CI_STAGE=10-shell-syntax

# --- bash: el núcleo, los scripts de build y los tests ------------------------
ci_section "sintaxis bash"
mapfile -t bash_files < <(
  printf '%s\n' \
    src/bootstrap.sh src/domain/*.sh src/ports/*.sh src/adapters/*/*.sh \
    src/app/*.sh src/bin/* scripts/*.sh scripts/lib/*.sh tests/*.sh \
    ci/lib/*.sh ci/*.sh tools/*.sh tools/*/*.sh tools/*/*/*.sh 2>/dev/null \
  | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | sort -u
)
for f in "${bash_files[@]}"; do
  out="$(bash -n "$f" 2>&1)"
  if [ -n "$out" ]; then ci_fail "bash -n: $f" "$out"; else ci_ok "$f"; fi
done

# --- POSIX sh: los maintainer scripts de Debian -------------------------------
ci_section "sintaxis POSIX sh (maintainer scripts)"
found=0
for f in packaging/*/DEBIAN/postinst packaging/*/DEBIAN/preinst \
         packaging/*/DEBIAN/prerm packaging/*/DEBIAN/postrm; do
  [ -f "$f" ] || continue
  found=1
  shebang="$(head -1 "$f")"
  case "$shebang" in
    '#!/bin/sh'|'#!/bin/sh '*) checker="sh" ;;
    '#!/bin/bash'|'#!/usr/bin/env bash'*) checker="bash" ;;
    *) ci_fail "shebang inesperado en $f" "$shebang"; continue ;;
  esac
  out="$($checker -n "$f" 2>&1)"
  if [ -n "$out" ]; then ci_fail "$checker -n: $f" "$out"; else ci_ok "$f ($checker)"; fi
done
[ "$found" -eq 0 ] && ci_warn "no encontré maintainer scripts; ¿cambió la estructura?"

# --- payload de los paquetes: scripts que acaban en el sistema ----------------
# No son maintainer scripts, pero se instalan y se ejecutan como root por udev
# o systemd. egpu-tb-fix es bash (usa arrays y [[ ]]).
ci_section "sintaxis del payload instalable"
for f in packaging/*/usr/sbin/* packaging/*/usr/bin/* \
         packaging/*/usr/lib/systemd/system-shutdown/*; do
  [ -f "$f" ] || continue
  case "$(head -1 "$f")" in
    '#!'*bash*) checker="bash" ;;
    '#!'*sh*)   checker="sh" ;;
    *) continue ;;   # no es un script (binario, unit, etc.)
  esac
  out="$($checker -n "$f" 2>&1)"
  if [ -n "$out" ]; then ci_fail "$checker -n: $f" "$out"; else ci_ok "$f ($checker)"; fi
done

ci_summary
