#!/usr/bin/env bash
# ci/40-kernel-patches.sh — valida la serie de parches del kernel.
#
# kernel/patches/ son diffs contra el árbol upstream
# NVIDIA/open-gpu-kernel-modules tag 595.71.05. El repo NO contiene la fuente
# de NVIDIA: solo los diffs. Todo lo que se comprueba aquí se comprueba SIN
# clonar ese árbol (1 GB de red), salvo la última sección, que es opcional y
# solo corre si scripts/build-dkms.sh ya dejó el clon cacheado en build/ogkm.
#
# Lo que valida:
#   1. integridad de la serie      (numeración, huecos, colisiones, nombres)
#   2. sanidad del formato diff    (marcadores + contadores de hunk)
#   3. rutas tocadas               (solo rutas plausibles del árbol upstream)
#   4. convención de identificadores (tb_egpu_* / NVreg_TbEgpu* / TB_EGPU_*)
#   5. procedencia                 (cada parche explica qué hace y por qué)
#   6. checkpatch.pl contra BASELINE (ci/baselines/checkpatch-known.txt)
#   7. aplicación real de la serie (opcional, solo con build/ogkm cacheado)
#
# Documentación y criterios de interpretación: docs/ci-kernel-patches.md
#
# Variables de entorno:
#   CI_CHECKPATCH_REGEN=1   reescribe el baseline con los recuentos actuales
#   CI_PATCH_APPLY=0        desactiva la sección 7 aunque exista el cache
#
# NO `-e`: la etapa recoge TODOS los fallos y los reporta juntos.
set -uo pipefail

. "$(dirname "$0")/lib/report.sh"

PATCHDIR="kernel/patches"
DISABLEDIR="$PATCHDIR/disabled"
ROLLBACKDIR="$PATCHDIR/.disabled-for-rollback"
BASELINE="ci/baselines/checkpatch-known.txt"
OGKM="build/ogkm"
BUILDER="scripts/build-dkms.sh"

# Versión upstream contra la que está escrita la serie. Se lee de
# scripts/build-dkms.sh para que no puedan divergir: el build es quien decide
# qué tag se clona.
NV_VERSION="$(awk -F'"' '/^NV_VERSION=/{print $2; exit}' "$BUILDER" 2>/dev/null)"
NV_VERSION="${NV_VERSION:-595.71.05}"

# Cuántos parches ACTIVOS debe tener la serie. Es un invariante explícito: si
# alguien añade o retira un parche tiene que tocar esta línea, y eso aparece en
# el diff de la revisión en vez de pasar inadvertido.
EXPECTED_ACTIVE=34

# El 0019 está desactivado a propósito (kernel/patches/disabled/).
EXPECTED_DISABLED_NUMS="0019"

# Parches escritos a mano cuyos contadores de hunk (@@ -a,b +c,d @@) están MAL
# y que scripts/build-dkms.sh aplica con --recount a propósito. No es un fallo,
# pero sí una deuda: la etapa avisa de que el parche sigue necesitándolo.
#
# La excepción tiene que estar declarada en DOS sitios (aquí y en el build
# script); más abajo se comprueba que coinciden, porque si el build deja de
# pasar --recount el .deb falla y este CI se quedaría verde.
RECOUNT_EXPECTED="0032"

# Prefijos/ficheros válidos dentro del árbol upstream de open-gpu-kernel-modules.
# Cualquier otra ruta en un parche es sospechosa: o el parche no es para este
# árbol, o se colaron ficheros del repo (packaging/, src/bin/, docs/...).
# OJO: `src/` aquí es src/nvidia/ del árbol NVIDIA, no el src/ hexagonal del repo.
path_is_plausible() { # $1=ruta
  case "$1" in
    kernel-open/*|src/*) return 0 ;;
    version.mk|Kbuild|Makefile) return 0 ;;
    */Kbuild|*/Makefile|*.Kbuild) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# checkpatch.pl: localización y flags
# ---------------------------------------------------------------------------

# Reglas de checkpatch que NO aplican a esta serie. El razonamiento completo
# está en docs/ci-kernel-patches.md; en resumen hay dos familias:
#
# (a) ESTILO DE LA CASA NVIDIA. El árbol destino indenta con 4 ESPACIOS y pone
#     la llave de apertura en su propia línea (Allman). Un parche TIENE que
#     casar con el fichero que edita, así que "usa tabs" o "la llave va arriba"
#     no son defectos aquí: aplicarlos rompería la consistencia del fichero.
#     Se comprueba en el propio repo: las líneas de CONTEXTO de los parches
#     (las que empiezan por espacio, o sea código upstream sin tocar) están
#     indentadas con espacios.
# (b) POLÍTICA DE ENVÍO A MAINLINE. La serie es estilo quilt, se aplica con
#     `git apply` desde scripts/build-dkms.sh y nunca se manda a una lista de
#     correo. Signed-off-by, formato del Subject, longitud del cuerpo del
#     commit o MAINTAINERS no tienen destinatario.
#
# Lo que NO se excluye (queda en el baseline, visible): SPDX_LICENSE_TAG,
# BLOCK_COMMENT_STYLE, SPLIT_STRING, LONG_LINE*, INITIALISED_STATIC,
# TRAILING_STATEMENTS, SPACING, VOLATILE, AVOID_EXTERNS, DEVICE_ATTR_*,
# BAD_COMMIT_SEPARATOR... Son hallazgos discutibles o deuda real, no ruido
# categórico, y esconderlos sería mentir sobre el estado de la serie.
CP_IGNORE_STYLE="CODE_INDENT,LEADING_SPACE,SUSPECT_CODE_INDENT,OPEN_BRACE"
CP_IGNORE_STYLE="$CP_IGNORE_STYLE,ELSE_AFTER_BRACE,POINTER_LOCATION,NEW_TYPEDEFS"
CP_IGNORE_MAIL="FILE_PATH_CHANGES,COMMIT_LOG_LONG_LINE,EMAIL_SUBJECT,GIT_COMMIT_ID"
CP_IGNORE_MAIL="$CP_IGNORE_MAIL,UNKNOWN_COMMIT_ID,MISSING_SIGN_OFF,NO_AUTHOR_SIGN_OFF"
CP_IGNORE_MAIL="$CP_IGNORE_MAIL,BAD_SIGN_OFF,COMMIT_MESSAGE,COMMIT_LOG_USE_LINK"
CP_IGNORE_MAIL="$CP_IGNORE_MAIL,PREFER_LORE_ARCHIVE"
CP_IGNORE="$CP_IGNORE_STYLE,$CP_IGNORE_MAIL"

# Tipos que son DEFECTO DE VERDAD, no estilo: fallan SIEMPRE, estén o no en el
# baseline. Hoy los 34 parches dan cero en todos ellos, así que esta lista es
# un trinquete: un parche nuevo no puede colar ninguno.
CP_FATAL="ASSIGN_IN_IF,UNNECESSARY_ELSE,DEFAULT_NO_BREAK,MEMSET"
CP_FATAL="$CP_FATAL,MULTISTATEMENT_MACRO_USE_DO_WHILE,COMPLEX_MACRO"
CP_FATAL="$CP_FATAL,MACRO_ARG_PRECEDENCE,MACRO_ARG_REUSE,NON_OCTAL_PERMISSIONS"
CP_FATAL="$CP_FATAL,UNSPECIFIED_INT,MALFORMED_INCLUDE,OPEN_ENDED_LINE"
CP_FATAL="$CP_FATAL,ALLOC_ARRAY_ARGS,ALLOC_SIZEOF_STRUCT,ALLOC_WITH_SIZEOF"
CP_FATAL="$CP_FATAL,SIZEOF_ADDRESS,SIZEOF_PARENTHESIS,HEXADECIMAL_BOOLEAN_TEST"
CP_FATAL="$CP_FATAL,STRCPY,VSPRINTF_SPECIFIER_PX,MEMORY_BARRIER"

find_checkpatch() {
  local c
  for c in \
    "/usr/src/linux-headers-$(uname -r)/scripts/checkpatch.pl" \
    /usr/src/linux-oem-*/scripts/checkpatch.pl \
    /usr/src/linux-headers-*/scripts/checkpatch.pl
  do
    [ -r "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  c="$(command -v checkpatch.pl 2>/dev/null)" || c=""
  [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
  return 1
}

# checkpatch SE EJECUTA POR STDIN A PROPÓSITO.
#
# Si se le pasa la ruta de un fichero que git rastrea, su git_is_single_file()
# da verdad y checkpatch entra en modo --file: trata el .patch como si fuera
# código fuente, prefija cada línea con '+' y reporta basura (p. ej. "trailing
# whitespace" sobre las líneas de contexto en blanco del propio diff). Por
# stdin no puede confundirse y lo analiza en modo parche, con las rutas y los
# números de línea del fichero DESTINO, que es lo que queremos revisar.
#
# --no-tree: no estamos dentro de un árbol del kernel.
# --terse / --show-types: una línea por hallazgo, con el nombre del tipo.
# --max-line-length: se deja el default del kernel (100). No se sube: las
#   líneas largas son casi todas strings de log y están contadas en el
#   baseline; subir el límite esconderría también las nuevas.
cp_run() { # $1=parche  $2=lista --types (opcional)
  local types_arg=()
  [ -n "${2:-}" ] && types_arg=(--types "$2")
  perl "$CHECKPATCH" --no-tree --no-signoff --terse --show-types --no-summary \
    --ignore "$CP_IGNORE" "${types_arg[@]}" - < "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. Integridad de la serie
# ---------------------------------------------------------------------------
ci_section "integridad de la serie"

if [ ! -d "$PATCHDIR" ]; then
  ci_fail "no existe $PATCHDIR — ¿se ejecuta la etapa desde la raíz del repo?"
  ci_summary
  exit $?
fi

mapfile -t ACTIVE < <(LC_ALL=C find "$PATCHDIR" -maxdepth 1 -type f -name '*.patch' | sort)
mapfile -t STRAY < <(LC_ALL=C find "$PATCHDIR" -maxdepth 1 -type f ! -name '*.patch' ! -name '*.md' | sort)

if [ "${#ACTIVE[@]}" -eq "$EXPECTED_ACTIVE" ]; then
  ci_ok "${#ACTIVE[@]} parches activos (esperados $EXPECTED_ACTIVE)"
else
  ci_fail "la serie tiene ${#ACTIVE[@]} parches activos, se esperaban $EXPECTED_ACTIVE" \
    "Si el cambio es intencionado, actualiza EXPECTED_ACTIVE en esta etapa y" \
    "regenera el baseline:  CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh"
fi

if [ "${#STRAY[@]}" -gt 0 ]; then
  ci_fail "ficheros sin extensión .patch en $PATCHDIR" "${STRAY[@]}"
else
  ci_ok "no hay ficheros ajenos en $PATCHDIR"
fi

# Nombres: NNNN-descripcion.patch
badname=()
for p in "${ACTIVE[@]}"; do
  b="$(basename "$p")"
  [[ "$b" =~ ^[0-9]{4}-[A-Za-z0-9][A-Za-z0-9._-]*\.patch$ ]] || badname+=("$b")
done
if [ "${#badname[@]}" -gt 0 ]; then
  ci_fail "nombres que no siguen NNNN-descripcion.patch" "${badname[@]}"
else
  ci_ok "todos los nombres siguen NNNN-descripcion.patch"
fi

# Numeración: duplicados entre los activos.
active_nums=()
for p in "${ACTIVE[@]}"; do active_nums+=("$(basename "$p" | cut -c1-4)"); done
dups="$(printf '%s\n' "${active_nums[@]}" | sort | uniq -d)"
if [ -n "$dups" ]; then
  ci_fail "números duplicados entre parches activos" "$dups"
else
  ci_ok "sin números duplicados entre los activos"
fi

# Desactivados: el 0019 y solo el 0019, y solo en disabled/.
disabled_arr=()
if [ -d "$DISABLEDIR" ]; then
  mapfile -t disabled_arr < <(LC_ALL=C find "$DISABLEDIR" -maxdepth 1 -type f \
    -name '*.patch' -printf '%f\n' | cut -c1-4 | sort -u)
fi
disabled_nums="${disabled_arr[*]}"
if [ "$disabled_nums" = "$EXPECTED_DISABLED_NUMS" ]; then
  ci_ok "desactivados en disabled/: $disabled_nums (como se documenta)"
else
  ci_fail "disabled/ contiene '$disabled_nums', se esperaba '$EXPECTED_DISABLED_NUMS'" \
    "Un parche que se desactiva se mueve a $DISABLEDIR y se declara en" \
    "EXPECTED_DISABLED_NUMS; si no, la comprobación de huecos no puede" \
    "distinguir un hueco intencionado de un parche perdido."
fi

# Colisión activo <-> desactivado.
collide=""
for n in "${disabled_arr[@]}"; do
  printf '%s\n' "${active_nums[@]}" | grep -qx "$n" && collide="$collide $n"
done
if [ -n "$collide" ]; then
  ci_fail "números que están a la vez activos y desactivados:$collide" \
    "Reutilizar el número de un parche desactivado hace ambiguo el orden de" \
    "aplicación y el historial."
else
  ci_ok "ningún número activo colisiona con uno desactivado"
fi

# Huecos: activos ∪ desactivados debe ser contiguo desde el primero.
all_nums="$(printf '%s\n' "${active_nums[@]}" "${disabled_arr[@]}" | sort -u)"
first="$(printf '%s\n' "$all_nums" | head -1 | sed 's/^0*//')"
last="$(printf '%s\n' "$all_nums" | tail -1 | sed 's/^0*//')"
expected_span=$((last - first + 1))
actual_span="$(printf '%s\n' "$all_nums" | wc -l)"
if [ "$expected_span" -eq "$actual_span" ]; then
  ci_ok "numeración contigua $(printf '%04d' "$first")..$(printf '%04d' "$last") (activos + disabled/)"
else
  gaps=""
  for ((i = first; i <= last; i++)); do
    printf '%s\n' "$all_nums" | grep -qx "$(printf '%04d' "$i")" \
      || gaps="$gaps $(printf '%04d' "$i")"
  done
  ci_fail "huecos en la numeración de la serie:$gaps" \
    "Un hueco significa un parche borrado sin dejar rastro. Si fue una" \
    "retirada, muévelo a $ROLLBACKDIR y renumera, o declara el hueco."
fi

# .disabled-for-rollback/ es archivo documentado: solo se informa.
if [ -d "$ROLLBACKDIR" ]; then
  nroll="$(LC_ALL=C find "$ROLLBACKDIR" -maxdepth 1 -type f -name '*.patch' | wc -l)"
  ci_ok "$nroll parches retirados en .disabled-for-rollback/ (archivo, fuera de la serie)"
fi

# Coherencia con el build: scripts/build-dkms.sh es quien aplica la serie, así
# que su glob y su excepción de --recount tienen que casar con lo que valida
# esta etapa. Si divergen, el CI pasaría en verde y el .deb fallaría.
if [ ! -r "$BUILDER" ]; then
  ci_skip "no se encontró $BUILDER — no se puede comprobar la coherencia con el build"
else
  builder_recount="$(grep -oE '\b[0-9]{4}-\*\)' "$BUILDER" | cut -c1-4 | sort -u | tr '\n' ' ')"
  builder_recount="${builder_recount% }"
  if [ "$builder_recount" = "$RECOUNT_EXPECTED" ]; then
    ci_ok "excepción de --recount coherente con $BUILDER ($RECOUNT_EXPECTED)"
  else
    ci_fail "la excepción de --recount no coincide con $BUILDER" \
      "esta etapa: '$RECOUNT_EXPECTED'" \
      "$BUILDER:   '$builder_recount'" \
      "El build solo pasa --recount a los parches de su propio case; si las dos" \
      "listas divergen, o el CI perdona un parche que el build rechaza, o al" \
      "contrario."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Sanidad del formato diff
# ---------------------------------------------------------------------------
ci_section "formato de los diffs"

# Comprobador de contadores de hunk. No necesita el árbol: solo cuenta las
# líneas del cuerpo de cada hunk y las compara con su cabecera @@ -a,b +c,d @@.
# Un hunk termina EXACTAMENTE cuando se satisfacen los dos contadores; así, un
# contador mal puesto se delata porque el hunk se cierra antes de tiempo (y la
# siguiente línea sale como `stray`) o se come la cabecera del fichero
# siguiente.
#
# shellcheck disable=SC2016  # es un programa de awk: $1/$2 son suyos, no del shell
HUNK_AWK='
function flush() {
  if (inh && (oseen != oexp || nseen != nexp))
    printf "hunk en línea %d: la cabecera dice -%d/+%d, el cuerpo trae -%d/+%d\n",
           hline, oexp, nexp, oseen, nseen
  inh = 0
}
/^@@ / {
  flush()
  o = substr($2, 2); n = substr($3, 2)
  oi = index(o, ","); oexp = (oi ? substr(o, oi + 1) : 1) + 0
  ni = index(n, ","); nexp = (ni ? substr(n, ni + 1) : 1) + 0
  hunks++; hline = FNR; oseen = 0; nseen = 0; inh = 1
  next
}
inh {
  c = substr($0, 1, 1)
  if (c == "\\") next
  if (c == " " || $0 == "") { oseen++; nseen++ }
  else if (c == "-") oseen++
  else if (c == "+") nseen++
  else printf "línea %d fuera de hunk: %s\n", FNR, substr($0, 1, 50)
  if (oseen >= oexp && nseen >= nexp) flush()
  next
}
/^--- / { oldhdr++; next }
/^\+\+\+ / { newhdr++; next }
END { flush(); printf "MARKERS %d %d %d\n", oldhdr, newhdr, hunks }
'

have_git=0
command -v git >/dev/null 2>&1 && have_git=1
[ "$have_git" -eq 1 ] || ci_skip "falta 'git' — no se puede validar el parseo con git apply --numstat"

declare -A NEEDS_RECOUNT=()
declare -a TOUCHED_BAD=()
diff_bad=0

for p in "${ACTIVE[@]}"; do
  b="$(basename "$p")"
  num="$(printf '%s' "$b" | cut -c1-4)"
  recount_ok=0
  case " $RECOUNT_EXPECTED " in *" $num "*) recount_ok=1 ;; esac

  # (a) marcadores mínimos + contadores de hunk, sin herramientas externas.
  awkout="$(awk "$HUNK_AWK" "$p")"
  markers="$(printf '%s\n' "$awkout" | grep '^MARKERS ' | tail -1)"
  problems="$(printf '%s\n' "$awkout" | grep -v '^MARKERS ' | grep -v '^$')"
  read -r _ oldhdr newhdr hunks <<<"$markers"

  struct_err=""
  [ "${oldhdr:-0}" -ge 1 ] || struct_err="$struct_err;sin ninguna línea '--- a/'"
  [ "${newhdr:-0}" -ge 1 ] || struct_err="$struct_err;sin ninguna línea '+++ b/'"
  [ "${hunks:-0}" -ge 1 ] || struct_err="$struct_err;sin ningún '@@ '"
  if [ "$recount_ok" -eq 0 ] && [ "${oldhdr:-0}" -ne "${newhdr:-0}" ]; then
    struct_err="$struct_err;cabeceras descompensadas (--- x$oldhdr vs +++ x$newhdr)"
  fi

  if [ -n "$struct_err" ]; then
    diff_bad=$((diff_bad + 1))
    ci_fail "$b: no parsea como diff unificado" "${struct_err#;}"
  elif [ -n "$problems" ]; then
    if [ "$recount_ok" -eq 1 ]; then
      NEEDS_RECOUNT[$num]=1
      ci_warn "$b: contadores de hunk incoherentes (excepción conocida; se aplica con --recount)"
    else
      diff_bad=$((diff_bad + 1))
      ci_fail "$b: contadores de hunk incoherentes" "$problems" \
        "Si el parche es correcto pero se escribió a mano, añade su número a" \
        "RECOUNT_EXPECTED y a scripts/build-dkms.sh; si no, corrige las cabeceras @@."
    fi
  fi

  # (b) parseo autoritativo. git apply --numstat calcula las líneas tocadas sin
  # necesitar el árbol destino, así que vale como oráculo de "esto es un diff
  # válido" sin clonar 1 GB. --check sí necesitaría los ficheros: no sirve.
  [ "$have_git" -eq 1 ] || continue

  if ! numstat="$(git apply --numstat "$p" 2>&1)"; then
    if ! numstat="$(git apply --recount --numstat "$p" 2>&1)"; then
      diff_bad=$((diff_bad + 1))
      ci_fail "$b: git apply --numstat lo rechaza incluso con --recount" "$numstat"
      continue
    fi
    if [ "$recount_ok" -eq 1 ]; then
      [ -n "${NEEDS_RECOUNT[$num]:-}" ] || ci_warn "$b: sigue necesitando --recount para aplicar"
      NEEDS_RECOUNT[$num]=1
    else
      diff_bad=$((diff_bad + 1))
      ci_fail "$b: solo parsea con --recount, y no está declarado como excepción" \
        "RECOUNT_EXPECTED='$RECOUNT_EXPECTED'" \
        "scripts/build-dkms.sh solo pasa --recount a los parches declarados ahí," \
        "así que este parche haría fallar el build."
    fi
  fi

  # (c) rutas tocadas.
  while read -r _ _ path; do
    [ -n "$path" ] || continue
    path_is_plausible "$path" || TOUCHED_BAD+=("$b -> $path")
  done <<<"$numstat"
done

ok_recount="$(printf '%s ' "${!NEEDS_RECOUNT[@]}")"
ok_recount="${ok_recount% }"
if [ -z "$ok_recount" ] && [ -n "$RECOUNT_EXPECTED" ]; then
  ci_warn "ningún parche necesita ya --recount: quita $RECOUNT_EXPECTED de RECOUNT_EXPECTED y de scripts/build-dkms.sh"
fi
if [ "$diff_bad" -eq 0 ]; then
  ci_ok "los ${#ACTIVE[@]} parches parsean como diff unificado"
fi

ci_section "rutas tocadas"
if [ "${#TOUCHED_BAD[@]}" -gt 0 ]; then
  ci_fail "rutas fuera del árbol upstream de open-gpu-kernel-modules" "${TOUCHED_BAD[@]}" \
    "Válido: kernel-open/**, src/** (= src/nvidia del árbol NVIDIA), version.mk," \
    "Kbuild, Makefile. Una ruta fuera de ahí significa que el parche no es para" \
    "este árbol o que se colaron ficheros del repo."
else
  ci_ok "todas las rutas caen en kernel-open/, src/, version.mk o Kbuild/Makefile"
fi

# ---------------------------------------------------------------------------
# 3. Convención de identificadores del proyecto
# ---------------------------------------------------------------------------
ci_section "convención de identificadores (tb_egpu_* / NVreg_TbEgpu* / TB_EGPU_*)"

# Solo LÍNEAS AÑADIDAS, y solo identificadores de C: se quitan los strings y
# los comentarios antes de buscar. Un comentario o un mensaje de log SÍ puede
# decir "AORUS" — la convención es para funciones, variables, macros y
# parámetros del módulo.
scan_added_identifiers() { # $1=parche
  grep '^+' "$1" \
    | grep -vE '^\+[[:space:]]*(//|\*|/\*)' \
    | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g" -e 's|/\*.*||' -e 's|//.*||' \
    | grep -oE '\b(aorus_[a-z0-9_]+|AORUS_[A-Z0-9_]+|NVreg_Aorus[A-Za-z0-9_]*)' \
    | grep -vE '^aorus_egpu_' \
    | sort -u
}

ident_drift=()
for p in "${ACTIVE[@]}"; do
  while read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      aorus_*)     want="tb_egpu_${id#aorus_}" ;;
      AORUS_*)     want="TB_EGPU_${id#AORUS_}" ;;
      NVreg_Aorus*) want="NVreg_TbEgpu${id#NVreg_Aorus}" ;;
      *)           want="(ver CLAUDE.md)" ;;
    esac
    ident_drift+=("$(basename "$p"): $id  ->  $want")
  done < <(scan_added_identifiers "$p")
done

if [ "${#ident_drift[@]}" -gt 0 ]; then
  ci_warn_with "identificadores de C añadidos que se desvían de la convención: ${#ident_drift[@]}" \
    "${ident_drift[@]}" \
    "" \
    "CLAUDE.md fija tb_egpu_* (funciones/variables), NVreg_TbEgpu* (parámetros" \
    "del módulo) y TB_EGPU_* (macros). Es AVISO, no fallo: renombrar un símbolo" \
    "del driver ya desplegado es un cambio de ABI para los parches que lo usan," \
    "así que se arregla con un parche de renombrado deliberado, no al paso."
else
  ci_ok "ningún identificador de C añadido se desvía de la convención"
fi

# ---------------------------------------------------------------------------
# 4. Procedencia (Levers): cada parche explica qué hace y por qué
# ---------------------------------------------------------------------------
ci_section "procedencia"

noprov=()
for p in "${ACTIVE[@]}"; do
  # Vale cualquiera de las dos formas que usa la serie: un comentario de C
  # añadido en el código, o una cabecera de commit (Subject:) con cuerpo.
  ncom="$(grep -cE '^\+[[:space:]]*(/\*|\*|//)' "$p")"
  nsub="$(grep -cE '^Subject:' "$p")"
  if [ "$ncom" -eq 0 ] && [ "$nsub" -eq 0 ]; then
    noprov+=("$(basename "$p")")
  fi
done

if [ "${#noprov[@]}" -gt 0 ]; then
  ci_warn_with "sin explicación de qué hacen ni por qué: ${#noprov[@]} parche(s)" \
    "${noprov[@]}" \
    "" \
    "Cada lever necesita procedencia: o un comentario de C añadido junto al" \
    "cambio, o una cabecera 'Subject:' + cuerpo al principio del .patch."
else
  ci_ok "los ${#ACTIVE[@]} parches llevan comentario explicativo o cabecera Subject:"
fi

# ---------------------------------------------------------------------------
# 5. checkpatch.pl contra baseline
# ---------------------------------------------------------------------------
ci_section "checkpatch.pl (baseline)"

CHECKPATCH="$(find_checkpatch)" || CHECKPATCH=""
if [ -z "$CHECKPATCH" ]; then
  ci_skip "no se encontró checkpatch.pl — instala los headers del kernel: sudo apt install linux-headers-\$(uname -r)"
elif ! ci_need perl "sudo apt install perl"; then
  : # ci_need ya ha contado el skip
else
  ci_ok "checkpatch.pl: $CHECKPATCH"

  # (a) trinquete de defectos reales: fallan siempre, baseline o no.
  fatal_hits=()
  for p in "${ACTIVE[@]}"; do
    out="$(cp_run "$p" "$CP_FATAL")"
    if [ -n "$out" ]; then
      while read -r l; do
        [ -n "$l" ] && fatal_hits+=("$(basename "$p"): ${l#-:}")
      done <<<"$out"
    fi
  done
  if [ "${#fatal_hits[@]}" -gt 0 ]; then
    ci_fail "checkpatch encontró defectos de los que NO se perdonan" "${fatal_hits[@]}" \
      "Estos tipos son defectos reales (asignación en condición, else tras" \
      "return, break ausente en default, macro sin do/while, permisos no" \
      "octales, sizeof mal...), no estilo. Hoy la serie da cero: arréglalo en" \
      "el parche, no en el baseline."
  else
    ci_ok "cero defectos de la lista fatal en los ${#ACTIVE[@]} parches"
  fi

  # (b) recuento por parche contra el baseline.
  tmp_counts="$(mktemp)"
  trap 'rm -f "$tmp_counts"' EXIT
  for p in "${ACTIVE[@]}"; do
    out="$(cp_run "$p")"
    e="$(printf '%s\n' "$out" | grep -c ' ERROR:')"
    w="$(printf '%s\n' "$out" | grep -c ' WARNING:')"
    printf '%s %s %s\n' "$(basename "$p")" "$e" "$w" >> "$tmp_counts"
  done

  if [ "${CI_CHECKPATCH_REGEN:-0}" = "1" ]; then
    mkdir -p "$(dirname "$BASELINE")"
    {
      printf '# ci/baselines/checkpatch-known.txt\n'
      printf '#\n'
      printf '# Recuento de hallazgos de checkpatch.pl POR PARCHE que la serie ya tenía\n'
      printf '# cuando se montó la etapa ci/40-kernel-patches.sh. La etapa falla solo si\n'
      printf '# un parche EMPEORA respecto a su línea aquí; no pretende que la serie\n'
      printf '# llegue a cero (es un fork de un driver fuera del árbol, con el estilo de\n'
      printf '# la casa NVIDIA, y ~2.600 de los ~2.800 hallazgos originales eran\n'
      printf '# indentación con espacios y llaves Allman, ya excluidas por --ignore).\n'
      printf '#\n'
      printf '# Formato:  <fichero.patch> <errores> <avisos>\n'
      printf '# Regenerar: CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh\n'
      printf '# Interpretación de los fallos: docs/ci-kernel-patches.md\n'
      printf '#\n'
      printf '# Generado con: checkpatch.pl --no-tree --no-signoff --terse --show-types\n'
      printf '#   --ignore %s\n' "$CP_IGNORE"
      cat "$tmp_counts"
    } > "$BASELINE"
    ci_warn "baseline REGENERADO en $BASELINE — revísalo en el diff antes de commitear"
  elif [ ! -r "$BASELINE" ]; then
    ci_fail "falta el baseline $BASELINE" \
      "Genéralo una vez y revísalo:  CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh"
  else
    worse=() better=() unknown=()
    while read -r name e w; do
      be="$(awk -v n="$name" '$1 == n { print $2; exit }' "$BASELINE")"
      bw="$(awk -v n="$name" '$1 == n { print $3; exit }' "$BASELINE")"
      if [ -z "$be" ]; then
        if [ "$e" -gt 0 ] || [ "$w" -gt 0 ]; then
          unknown+=("$name: $e errores, $w avisos (parche nuevo, sin línea en el baseline)")
        fi
        continue
      fi
      if [ "$e" -gt "$be" ] || [ "$w" -gt "$bw" ]; then
        worse+=("$name: $e/$w (errores/avisos), el baseline dice $be/$bw")
      elif [ "$e" -lt "$be" ] || [ "$w" -lt "$bw" ]; then
        better+=("$name: $e/$w, el baseline dice $be/$bw")
      fi
    done < "$tmp_counts"

    # Entradas del baseline que ya no corresponden a ningún parche.
    stale=()
    while read -r name _ _; do
      case "$name" in '#'*|'') continue ;; esac
      grep -qE "^$name " "$tmp_counts" || stale+=("$name")
    done < "$BASELINE"

    if [ "${#worse[@]}" -gt 0 ]; then
      ci_fail "empeoran respecto al baseline de checkpatch: ${#worse[@]} parche(s)" "${worse[@]}" \
        "" \
        "Reproduce el detalle de uno:" \
        "  perl $CHECKPATCH --no-tree --no-signoff --terse --show-types \\" \
        "    --ignore $CP_IGNORE - < $PATCHDIR/<parche>" \
        "Arregla el hallazgo nuevo. Solo si el aumento es legítimo:" \
        "  CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh"
    else
      ci_ok "ningún parche empeora el baseline de checkpatch"
    fi
    [ "${#better[@]}" -gt 0 ] && ci_warn_with "mejoran respecto al baseline: ${#better[@]} parche(s); refréscalo" \
      "${better[@]}" "" "CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh"
    [ "${#unknown[@]}" -gt 0 ] && ci_warn_with "nuevos, sin línea en el baseline: ${#unknown[@]} parche(s)" \
      "${unknown[@]}" "" \
      "Revisa sus hallazgos a mano y luego fija su línea con" \
      "CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh"
    [ "${#stale[@]}" -gt 0 ] && ci_warn_with "entradas del baseline que ya no tienen parche: ${#stale[@]}" \
      "${stale[@]}" "" "CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Aplicación real de la serie (opcional, acotada)
# ---------------------------------------------------------------------------
ci_section "aplicación de la serie sobre el árbol upstream"

# NUNCA se clona nada aquí: serían ~1 GB de red en un CI local. Solo se usa el
# cache que deja scripts/build-dkms.sh.
if [ "${CI_PATCH_APPLY:-1}" = "0" ]; then
  ci_skip "desactivado con CI_PATCH_APPLY=0"
elif [ "$have_git" -eq 0 ]; then
  ci_skip "falta 'git'"
elif [ ! -d "$OGKM/.git" ]; then
  ci_skip "sin cache del árbol upstream en $OGKM — créalo con: $BUILDER (clona open-gpu-kernel-modules @$NV_VERSION, ~1 GB)"
elif [ -n "$(git -C "$OGKM" status --porcelain 2>/dev/null)" ]; then
  ci_skip "$OGKM tiene cambios sin commitear — no se toca; límpialo con: git -C $OGKM checkout -- . && git -C $OGKM clean -fdqx"
elif ! grep -q "^NVIDIA_VERSION = $NV_VERSION\$" "$OGKM/version.mk" 2>/dev/null; then
  # Sin esta guarda, un cache en otro tag daría un fallo de aplicación que
  # parecería culpa del parche cuando en realidad el árbol base es el que no
  # corresponde.
  ci_skip "el cache $OGKM no está en $NV_VERSION (version.mk no cuadra) — resincronízalo con $BUILDER"
else
  # Se aplica EN SITIO y se restaura al salir: duplicar el árbol costaría otro
  # GB de disco, y scripts/build-dkms.sh hace exactamente este mismo reset
  # antes de cada build.
  applied=0
  failed=""
  for p in "${ACTIVE[@]}"; do
    num="$(basename "$p" | cut -c1-4)"
    rc_flag=()
    case " $RECOUNT_EXPECTED " in *" $num "*) rc_flag=(--recount) ;; esac
    if out="$(git -C "$OGKM" apply "${rc_flag[@]}" --whitespace=nowarn "$(pwd)/$p" 2>&1)"; then
      applied=$((applied + 1))
    else
      failed="$(basename "$p")"
      ci_fail "la serie se rompe en $failed (parche $((applied + 1)) de ${#ACTIVE[@]})" \
        "$out" \
        "Los $applied parches anteriores sí aplicaron. Con el cache verificado en" \
        "$NV_VERSION, el conflicto es de ESTE parche contra el estado que dejan los" \
        "previos: rebásalo, no el árbol."
      break
    fi
  done
  git -C "$OGKM" checkout -q -- . 2>/dev/null || true
  git -C "$OGKM" clean -fdq 2>/dev/null || true
  [ -z "$failed" ] && ci_ok "los $applied parches aplican en orden sobre $OGKM (árbol restaurado)"
fi

# ---------------------------------------------------------------------------
# 6b. Aplicación de la mitad kernel-open sobre el driver INSTALADO
# ---------------------------------------------------------------------------
ci_section "aplicación de la mitad kernel-open sobre el driver instalado"

# POR QUÉ EXISTE ESTA SECCIÓN SI YA HAY UNA 6:
# la sección 6 es la buena -serie completa, árbol del tag exacto-, pero vive en
# skip PERMANENTE porque exige un clon de ~1 GB que nadie tiene cacheado. Un
# skip permanente es un agujero: la serie puede dejar de aplicar y el CI sigue
# en verde, sin que nadie se entere. Eso ya pasó: una revisión externa reportó
# "0032 no aplica, el paquete no se puede construir" y el CI no tenía forma de
# confirmarlo ni de desmentirlo.
#
# El paquete nvidia-kernel-source-NNN-open de Canonical ya deja en
# /usr/src/nvidia-<ver>/ el árbol kernel-open APLANADO (su contenido en la
# raíz, sin el prefijo kernel-open/). Son ~29 MB que ya están en disco.
#
# CÓMO SE USA SIN HACER CIRUGÍA AL DIFF:
# se copia el árbol DENTRO de <tmp>/kernel-open/, que reproduce el layout
# upstream, y se aplica el parche entero con -p1 y `--include='kernel-open/*'`.
# Filtrar con --include es de git: entiende cabeceras `diff --git`, diffs
# desnudos, `new file mode` y creaciones con `--- /dev/null`. Extraer la mitad
# kernel-open a mano con awk/filterdiff parece equivalente y NO lo es: pierde
# las líneas de metadatos y produce fallos fantasma que se confunden con
# defectos del parche. (Aplicar con -p2 sobre el árbol plano tiene el mismo
# problema: /dev/null no se puede despojar de dos componentes.)
#
# LO QUE NO CUBRE, dicho claro:
#   - la mitad RM (src/nvidia/**): ningún paquete de Canonical entrega ese
#     árbol, así que esos parches aquí solo se cuentan, no se prueban.
#   - version.mk: upstream vive en la raíz del repo, no dentro de kernel-open.
#   - si el árbol instalado no es del tag de la serie, un fallo por contexto de
#     NVIDIA es deuda de REBASE, no un defecto del parche. Los dos casos se
#     informan distinto: deuda -> WARN, defecto -> FAIL.
#
# Un fallo cuyo contexto lo añade un parche ANTERIOR de la serie no depende de
# la versión: es un defecto del parche y falla contra cualquier tag. Por eso
# solo los parches de VERSION_DRIFT_OK pueden degradarse a WARN.

# Parches cuyo único ancla es la cadena de versión hardcodeada en Kbuild. Si el
# árbol instalado no es $NV_VERSION, fallan POR DISEÑO y no dicen nada del
# estado de la serie.
VERSION_DRIFT_OK="0005 0025"

LOCAL_TREE="${CI_LOCAL_TREE:-}"
if [ -z "$LOCAL_TREE" ]; then
  for _cand in "/usr/src/nvidia-$NV_VERSION" /usr/src/nvidia-*; do
    [ -f "$_cand/Kbuild" ] && [ -f "$_cand/nvidia-uvm/uvm.c" ] || continue
    LOCAL_TREE="$_cand"; break
  done
fi

if [ "${CI_PATCH_APPLY_LOCAL:-1}" = "0" ]; then
  ci_skip "desactivado con CI_PATCH_APPLY_LOCAL=0"
elif [ "$have_git" -eq 0 ]; then
  ci_skip "falta 'git'"
elif [ -z "$LOCAL_TREE" ]; then
  ci_skip "sin árbol kernel-open en /usr/src/nvidia-* — instálalo con: sudo apt install nvidia-kernel-source-595-open (o apunta CI_LOCAL_TREE a uno)"
else
  # La línea es:  ccflags-y += -DNV_VERSION_STRING=\"595.99.02\"
  # Partir por '"' deja la barra invertida del escape pegada al campo, así que
  # hay que quitarla; sin esto la versión se imprime como "595.99.02\".
  tree_ver="$(awk -F'"' '/NV_VERSION_STRING/{gsub(/\\/,"",$2); print $2; exit}' \
              "$LOCAL_TREE/Kbuild" 2>/dev/null)"
  tree_ver="${tree_ver:-desconocida}"
  if [ "$tree_ver" = "$NV_VERSION" ]; then
    ci_ok "árbol local $LOCAL_TREE en $tree_ver (= el tag de la serie)"
  else
    ci_warn_with "el árbol local está en $tree_ver y la serie apunta a $NV_VERSION" \
      "$LOCAL_TREE" \
      "Los fallos por contexto de NVIDIA son deuda de rebase, no defectos de los" \
      "parches. Los fallos por contexto que añaden parches ANTERIORES sí son" \
      "defectos, y esos siguen saliendo en rojo."
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/ci-ogkm-local.XXXXXX")"
  mkdir -p "$work/kernel-open"
  if ! cp -a "$LOCAL_TREE/." "$work/kernel-open/" 2>/dev/null; then
    ci_fail "no pude copiar $LOCAL_TREE a $work"
  elif ! git -C "$work" init -q . 2>/dev/null \
     || ! git -C "$work" add -A >/dev/null 2>&1 \
     || ! git -C "$work" -c user.email=ci@local -c user.name=ci commit -qm base >/dev/null 2>&1; then
    ci_fail "no pude preparar el árbol de trabajo en $work"
  else
    applied_local=0; norm=0; drift=(); broken=()
    for p in "${ACTIVE[@]}"; do
      num="$(basename "$p" | cut -c1-4)"
      # ¿Tiene este parche alguna ruta bajo kernel-open/? Si no, aquí no hay
      # nada que probar y `git apply --include` devolvería 0 sin aplicar nada:
      # un "ok" falso que inflaría la cobertura.
      if ! grep -qE '^(\+\+\+ b/|diff --git a/)kernel-open/' "$p"; then
        norm=$((norm + 1)); continue
      fi
      rc_flag=()
      case " $RECOUNT_EXPECTED " in *" $num "*) rc_flag=(--recount) ;; esac
      if out="$(git -C "$work" apply "${rc_flag[@]}" --include='kernel-open/*' \
                  --whitespace=nowarn "$(pwd)/$p" 2>&1)"; then
        applied_local=$((applied_local + 1))
      else
        case " $VERSION_DRIFT_OK " in
          *" $num "*) [ "$tree_ver" != "$NV_VERSION" ] && drift+=("$num") || broken+=("$num: $out") ;;
          *) broken+=("$(basename "$p"): $(printf '%s' "$out" | grep -v '^Skipped' | head -3 | tr '\n' ' ')") ;;
        esac
      fi
    done

    if [ "${#broken[@]}" -gt 0 ]; then
      ci_fail "la mitad kernel-open de la serie se rompe en ${#broken[@]} parche(s)" \
        "${broken[@]}" "" \
        "Los $applied_local anteriores sí aplicaron en orden. Un fallo aquí NO es" \
        "deuda de versión salvo que el ancla sea la cadena NV_VERSION_STRING:" \
        "es este parche contra el estado que dejan los previos. Rebásalo."
    else
      ci_ok "$applied_local parches aplican en orden sobre la mitad kernel-open de $tree_ver"
    fi
    if [ "${#drift[@]}" -gt 0 ]; then
      ci_warn_with "${#drift[@]} parche(s) fallan solo por la cadena de versión: ${drift[*]}" \
        "Anclan en Kbuild con NV_VERSION_STRING=\"$NV_VERSION\" y el árbol dice \"$tree_ver\"." \
        "Es deuda de rebase conocida y acotada; no dice nada del resto de la serie."
    fi
    ci_ok "$norm parches sin mitad kernel-open (solo RM, src/nvidia/**): no cubiertos aquí"
  fi
  rm -rf "$work"
fi

# ---------------------------------------------------------------------------
# 7. tools/lint-identifiers.sh
# ---------------------------------------------------------------------------
ci_section "tools/lint-identifiers.sh"

# El script existe y comprueba justo lo que nos interesa (NVreg_Aorus*,
# aorus_lever_*, AORUS_*...), pero su lista de rutas es del layout ANTERIOR al
# monorepo: busca './patches/*.patch'. Los parches viven hoy en
# kernel/patches/, así que su `find` no selecciona ninguno y el script termina
# en verde con "0 files scanned" — verde vacío, que es peor que rojo.
#
# Por eso esta etapa NO lo invoca para los parches y hace la comprobación por
# su cuenta (sección "convención de identificadores"). La detección es
# dinámica: en cuanto alguien arregle las rutas del script, esta sección pasa
# a ejecutarlo.
LINTER="tools/lint-identifiers.sh"
if [ ! -x "$LINTER" ] && [ ! -r "$LINTER" ]; then
  ci_skip "no existe $LINTER"
elif grep -q "kernel/patches" "$LINTER"; then
  if out="$(bash "$LINTER" 2>&1)"; then
    ci_ok "$LINTER: limpio"
  else
    ci_fail "$LINTER encontró identificadores obsoletos" "$out"
  fi
else
  ci_skip "$LINTER no cubre $PATCHDIR (su find busca './patches/*.patch', layout pre-monorepo) — la comprobación la hace esta etapa; detalle en docs/ci-kernel-patches.md"
fi

ci_summary
exit $?
