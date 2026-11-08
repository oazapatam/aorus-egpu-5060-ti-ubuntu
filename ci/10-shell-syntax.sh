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
# src/bin/* NO entra en esta lista: desde que hay un entrypoint en python
# (src/bin/nvidia-oc, el TUI) elegir por DIRECTORIO manda un fichero python a
# `bash -n`, que lo rechaza por sintaxis. Se despacha por shebang más abajo.
mapfile -t bash_files < <(
  printf '%s\n' \
    src/bootstrap.sh src/domain/*.sh src/ports/*.sh src/adapters/*/*.sh \
    src/app/*.sh scripts/*.sh scripts/lib/*.sh tests/*.sh \
    ci/lib/*.sh ci/*.sh tools/*.sh tools/*/*.sh tools/*/*/*.sh 2>/dev/null \
  | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | sort -u
)
for f in "${bash_files[@]}"; do
  out="$(bash -n "$f" 2>&1)"
  if [ -n "$out" ]; then ci_fail "bash -n: $f" "$out"; else ci_ok "$f"; fi
done

# --- los entrypoints de src/bin/, cada uno con su intérprete ------------------
# Un shebang que no se reconoce es un FALLO, no un fichero que se salta en
# silencio: un entrypoint sin comprobar es peor que uno que rompe el CI. Es el
# mismo criterio que ya aplica la sección de maintainer scripts.
ci_section "sintaxis de los entrypoints de src/bin/ (por shebang)"
py_files=()
for f in src/bin/*; do
  [ -f "$f" ] || continue
  case "$(head -1 "$f")" in
    '#!'*bash*)
      out="$(bash -n "$f" 2>&1)"
      if [ -n "$out" ]; then ci_fail "bash -n: $f" "$out"; else ci_ok "$f (bash)"; fi ;;
    '#!'*python3*) py_files+=("$f") ;;
    *) ci_fail "shebang inesperado en $f" "$(head -1 "$f")" ;;
  esac
done

# --- python: adaptadores, entrypoints y utillaje ------------------------------
# Hasta ahora NADA del CI comprobaba la sintaxis del python del repo, y hay
# python en el camino de ESCRITURA (adapters/gpu/nvml-offsets.py escribe los
# offsets) y en el VERIFICADOR del que depende el gate
# (adapters/verify/gemm-integrity.py). Se compila con `-B`: un __pycache__
# junto al fuente se colaba en el payload de los .deb.
ci_section "sintaxis python"
if ! command -v python3 >/dev/null 2>&1; then
  ci_warn "falta python3: no puedo comprobar la sintaxis de los helpers python"
else
  for f in "${py_files[@]}" src/adapters/*/*.py tools/*.py tools/egpu-oc-edge; do
    [ -f "$f" ] || continue
    if out="$(python3 -B -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$f" 2>&1)"; then
      ci_ok "$f (python3)"
    else
      ci_fail "python3 ast.parse: $f" "$out"
    fi
  done
fi

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
