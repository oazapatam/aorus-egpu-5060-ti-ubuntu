#!/usr/bin/env bash
# ci/20-shellcheck.sh — análisis estático de TODO el shell del repo.
#
# Por qué esta etapa existe: en este proyecto el modo de fallo es que el host se
# CONGELA sin Xid ni panic, así que un bug de shell que se descubre en caliente
# cuesta un reinicio duro. shellcheck encuentra gratis la clase de errores que
# aquí duelen: una variable sin comillas que parte un BDF en dos, un `rm -rf
# "$vacío/usr"`, un `&&`/`||` que ejecuta la rama de error cuando no toca.
#
# NIVELES DE SEVERIDAD — no es el mismo listón para todo el repo:
#
#   src/                 -S style   (el más exigente)
#       Código NUEVO, escrito con la arquitectura hexagonal y cubierto por
#       tests/run.sh. No hay deuda que respetar, así que se exige todo:
#       error, warning, info Y style. Es además el único código de este grupo
#       que se EMPAQUETA y corre como root en la máquina del usuario, que es lo
#       que justifica el listón extra.
#
#   scripts/, tests/, ci/   -S warning
#       Utillaje de desarrollo: corre en una shell con `set -euo pipefail`, y
#       si se rompe se nota en el acto, no en producción. Se exigen error y
#       warning (bugs de verdad) y se dejan pasar info/style.
#       Esto perdona a conciencia tres cosas legítimas: el SC2015 de
#       `[ ... ] && ok || bad` en los helpers de tests/run.sh (ok/bad devuelven
#       siempre 0, así que la cadena es segura y es LA forma idiomática de un
#       arnés de tests), el SC2012 de un `ls | wc -l` para contar parches, y los
#       SC2016 de los `grep -qE '...\$1...'` de las etapas de política, donde
#       las comillas simples son el regex y no un error.
#
#       ci/ está AQUÍ y no con src/ a propósito, y la decisión está medida: con
#       -S style, ci/ saca 7 avisos de nivel "note" (SC2016 de regex en
#       comillas simples, SC2181 de `$?`, SC2086) en etapas que no aportan nada
#       al riesgo del proyecto, mientras el único hallazgo que de verdad
#       importa —un SC1087 de nivel ERROR— se ve igual a -S warning. Es decir:
#       -S style aquí solo compraba ruido. Lo que sí hace falta vigilar en ci/
#       (un contador perdido en una subshell, un `$?` leído tarde, una variable
#       sin comillas) es error o warning, no style.
#
#   packaging/*/DEBIAN/{preinst,postinst,prerm,postrm,config}   -s sh -S style
#       CRÍTICOS: los ejecuta dpkg y un error deja `apt install` a medias, con
#       el paquete en estado "half-configured" y la máquina sin eGPU. Por eso
#       aquí sí se falla, y al nivel más exigente.
#       Se FUERZA el dialecto a `sh` en vez de confiar en el shebang: la
#       política de Debian pide POSIX sh en los maintainer scripts y los 12 de
#       este repo son `#!/bin/sh`. Forzarlo fija esa convención — si alguien
#       mete un bashism, la etapa lo dice en vez de aprobarlo porque el shebang
#       hubiera cambiado a bash. Si un maintainer script deja de ser /bin/sh se
#       avisa aparte, para que la discrepancia se vea y no se linte en silencio
#       contra el dialecto equivocado.
#
#   resto de packaging/ (el payload), tools/      INFORMATIVO (ci_warn_with)
#       `packaging/egpu-tb-fix/usr/sbin/egpu-tb-fix` y los `usr/sbin/*` de
#       aorus-egpu-config están VALIDADOS EN VIVO: son lo único que se sabe que
#       funciona en esta máquina (docs/what-actually-works.md). Reescribirlos
#       para contentar a un linter es exactamente el cambio que no se puede
#       justificar: el riesgo de romperlos supera a cualquier hallazgo de
#       estilo. Se linta para que los hallazgos SEAN VISIBLES, pero nunca falla.
#       tools/ va igual: sondas de laboratorio, fuera de la superficie
#       empaquetada, y hoy tiene hallazgos reales (SC2261) que conviene que se
#       vean sin bloquear a nadie.
#
#   legacy/                                        OMITIDO
#       El stack Fedora retirado, que se conserva como archivo documentado. No
#       se instala, no se construye y no tiene dueño; lintarlo sería ~40 avisos
#       permanentes que nadie va a arreglar, es decir, ruido que enseña al
#       equipo a ignorar esta etapa.
#
# FICHEROS SIN EXTENSIÓN (src/bin/aorus-egpu-oc y compañía, usr/sbin/*):
#   NO hace falta `-s bash`. shellcheck lee el shebang también cuando el
#   fichero no acaba en .sh. Comprobado de verdad, no asumido (el `$ ` del
#   principio de cada línea NO es decorativo: un comentario que empieza por la
#   palabra "shellcheck" lo intenta parsear como directiva y revienta con
#   SC1073 — es justo el bug que tiene hoy ci/lib/report.sh:13):
#     $ shellcheck -x -S style src/bin/aorus-egpu-oc            -> 0 hallazgos
#     $ shellcheck -s bash -x -S style src/bin/aorus-egpu-oc    -> 0 hallazgos
#     $ shellcheck -s sh -S style src/bin/aorus-egpu-oc         -> 9 SC3xxx
#   Es decir: el automático COINCIDE con `-s bash` y DIFIERE de `-s sh`, luego
#   el shebang se está honrando. Por eso el dialecto solo se fuerza donde hay un
#   motivo (los maintainer scripts de Debian, arriba).
#
# LIBRERÍAS QUE SE CARGAN CON `.` Y NO SE EJECUTAN SOLAS
#   (src/domain, src/ports, src/adapters, src/app, ci/lib, scripts/lib):
#   dos problemas, dos soluciones distintas, ninguna con un `disable` global:
#     - "no sé qué shell es esto": cada librería lleva ya su
#       `# shellcheck shell=bash` en la cabecera.
#     - "no puedo seguir el source" (SC1090/SC1091): se resuelve con `-x` más
#       las entradas `source-path` de .shellcheckrc. Ver ese fichero.
#   Lo que shellcheck NO puede resolver es `aorus_use domain/overclock`: la ruta
#   se construye en tiempo de ejecución. De ahí vienen los SC2034 "variable sin
#   usar" de las OC_* y de AORUS_TRACE_ROOT, que son dependencias REALES entre
#   capas vía entorno; están suprimidos línea a línea, con su porqué, en el
#   fichero que las asigna.
set -uo pipefail

# El `.` lo resuelve shellcheck por la entrada `source-path=SCRIPTDIR/lib` de
# .shellcheckrc; no hace falta una directiva `source=` en el script.
. "$(dirname "$0")/lib/report.sh"

if ! ci_need shellcheck "sudo apt install shellcheck"; then
  ci_summary; exit $?
fi

# --- utilidades ---------------------------------------------------------------

# ¿Es un script de shell? Se decide por SHEBANG, no por extensión: el payload de
# los paquetes tiene ficheros sin extensión (usr/sbin/egpu-tb-fix) y con
# extensiones que no son .sh (egpu-tb-fix.shutdown), y tools/ mezcla shell con
# Python y con un ELF compilado (tools/egpu-bandwidth).
sc_is_shell() { # $1=fichero
  local first
  # grep -I descarta los binarios antes de intentar leerlos como texto.
  grep -qI . "$1" 2>/dev/null || return 1
  IFS= read -r first < "$1" 2>/dev/null || return 1
  case "$first" in
    '#!'*sh|'#!'*sh[[:space:]]*) return 0 ;;
  esac
  return 1
}

# El motor de la etapa. Linta fichero a fichero (no en un solo lote) para que el
# informe diga QUÉ fichero está roto, en vez de volcar un muro de texto sin
# dueño. `-f gcc` da una línea por hallazgo, que es lo que mejor se lee dentro
# del bloque de detalle de ci_fail.
sc_check() { # $1=fail|warn  $2=severidad  $3=auto|sh|bash  $4..=ficheros
  local mode="$1" sev="$2" dialect="$3"; shift 3
  local f out args
  for f in "$@"; do
    args=(-x -S "$sev" -f gcc)
    [ "$dialect" = "auto" ] || args+=(-s "$dialect")
    # OJO: la salida se CAPTURA en una variable y se pasa como argumento.
    # `shellcheck ... | ci_fail "..."` haría correr ci_fail en una subshell y el
    # incremento de CI_FAIL se perdería -> CI falso-verde. Ver ci/lib/report.sh.
    out="$(shellcheck "${args[@]}" "$f" 2>&1)"
    if [ -z "$out" ]; then
      ci_ok "$f"
    elif [ "$mode" = "warn" ]; then
      ci_warn_with "$f" "$out"
    else
      ci_fail "$f" "$out"
    fi
  done
}

# Avisa si una lista salió vacía: un glob que deja de casar es un agujero
# silencioso en la cobertura de la etapa, no un pase.
sc_require_nonempty() { # $1=qué se esperaba  $2=cuántos hay
  [ "$2" -gt 0 ] && return 0
  ci_fail "no he encontrado ningún fichero para '$1' — ¿se movió el directorio?"
  return 1
}

# --- 1. núcleo src/ : el listón más alto --------------------------------------

ci_section "src/ — núcleo hexagonal (-S style, el nivel más exigente)"
src_files=()
while IFS= read -r f; do src_files+=("$f"); done < <(
  find src -type f \( -name '*.sh' -o -path 'src/bin/*' \) | sort)
if sc_require_nonempty "src/" "${#src_files[@]}"; then
  sc_check fail style auto "${src_files[@]}"
fi

# --- 2. utillaje de build y tests ---------------------------------------------

ci_section "scripts/ y tests/ — utillaje de desarrollo (-S warning)"
dev_files=()
while IFS= read -r f; do dev_files+=("$f"); done < <(
  find scripts tests -type f -name '*.sh' | sort)
if sc_require_nonempty "scripts/+tests/" "${#dev_files[@]}"; then
  sc_check fail warning auto "${dev_files[@]}"
fi

# --- 3. etapas de CI : mismo listón que el resto del utillaje -----------------

ci_section "ci/ — las propias etapas y su librería (-S warning)"
ci_files=()
while IFS= read -r f; do ci_files+=("$f"); done < <(find ci -type f -name '*.sh' | sort)
if sc_require_nonempty "ci/" "${#ci_files[@]}"; then
  # Se lintea a sí misma: si esta etapa se rompe, lo dice ella.
  sc_check fail warning auto "${ci_files[@]}"
fi

# --- 4. maintainer scripts de Debian : críticos, POSIX sh ---------------------

ci_section "packaging/*/DEBIAN/ — maintainer scripts (-s sh -S style, críticos)"
deb_files=()
while IFS= read -r f; do deb_files+=("$f"); done < <(
  find packaging -type f -path '*/DEBIAN/*' \
       \( -name preinst -o -name postinst -o -name prerm -o -name postrm \
          -o -name config \) | sort)
if sc_require_nonempty "packaging/*/DEBIAN/" "${#deb_files[@]}"; then
  # La discrepancia de shebang se avisa ANTES de lintar, para que si un fichero
  # no es /bin/sh se vea que lo estamos midiendo con la vara de POSIX a mano.
  for f in "${deb_files[@]}"; do
    IFS= read -r shebang < "$f" || shebang=""
    case "$shebang" in
      '#!/bin/sh'|'#!/bin/sh '*|'#!/usr/bin/sh'|'#!/bin/dash') : ;;
      *) ci_warn "shebang no-POSIX en un maintainer script: $f ('$shebang') — la política de Debian pide #!/bin/sh; se linta igualmente como sh" ;;
    esac
  done
  sc_check fail style sh "${deb_files[@]}"
fi

# --- 5. payload validado en vivo y utillaje de laboratorio : INFORMATIVO ------

ci_section "packaging/ (payload) y tools/ — informativo, NUNCA falla"
info_files=()
while IFS= read -r f; do
  sc_is_shell "$f" && info_files+=("$f")
done < <(find packaging tools -type f ! -path '*/DEBIAN/*' | sort)
if [ "${#info_files[@]}" -eq 0 ]; then
  ci_warn "no he encontrado scripts de shell en packaging/ ni tools/"
else
  sc_check warn warning auto "${info_files[@]}"
fi

# --- 6. lo que se omite a conciencia -----------------------------------------

ci_section "omitido a conciencia"
if [ -d legacy ]; then
  ci_skip "legacy/ — stack Fedora retirado, archivo documentado: sin dueño, sin instalar y sin construir; lintarlo solo añadiría ruido permanente"
fi

ci_summary
exit $?
