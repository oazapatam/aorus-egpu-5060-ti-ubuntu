#!/usr/bin/env bash
# ci/70-docs.sh — etapa de CI de DOCUMENTACIÓN.
#
# Qué defiende esta etapa, y por qué cada cosa es fallo o aviso:
#
#   1. sembr (AVISO). La convención del repo es semantic line breaks
#      (sembr.org): una frase por línea como suelo, una cláusula como techo,
#      para que `git diff` muestre la cláusula cambiada y no el párrafo
#      reflowado. Es un AVISO y no un fallo a propósito: CLAUDE.md prohíbe
#      reflowear ficheros existentes sin motivo sustantivo, así que una doc
#      heredada en prosa larga no puede bloquear un commit.
#
#   2. Enlaces internos colgados (FALLO). Un enlace relativo que apunta a un
#      fichero inexistente es un defecto objetivo, no una cuestión de estilo.
#      Ya pasó de verdad: la reestructura movió media docena de docs a
#      docs/research/ y los enlaces que apuntaban al sitio viejo quedaron
#      rotos.
#
#   3. markdownlint (OMITIDA si falta). Estructura, no prosa. Respeta
#      .markdownlint.yaml, que desactiva MD013 (longitud de línea; sembr hace
#      variar la longitud por cláusula) y MD040 entre otras.
#
#   4. Fences de código balanceadas (FALLO). Un ``` sin cerrar se come el
#      resto del documento al renderizar: media doc invisible sin aviso.
#
#   5. Coherencia de versiones (FALLO). La tabla de docs/packages/README.md es
#      la "tabla de verdad única" sobre qué paquete usar; si su columna
#      Versión no cuadra con el campo Version: del DEBIAN/control, la doc
#      miente sobre lo que el usuario va a instalar. Los control se LEEN,
#      nunca se modifican desde aquí.
#
# Contrato de etapa: ver ci/lib/report.sh. Sin `set -e` a propósito — la etapa
# recoge TODOS los fallos y los reporta juntos.
set -uo pipefail
# shellcheck source=ci/lib/report.sh
. "$(dirname "$0")/lib/report.sh"

# El contrato dice "desde la raíz del repo"; lo garantizamos en vez de
# confiarlo, porque todas las rutas que se reportan son relativas a la raíz.
cd "$(dirname "$0")/.." || exit 1

# ---------------------------------------------------------------------------
# Inventario de markdown
# ---------------------------------------------------------------------------
# Se usa git ls-files para no auditar nada ignorado (dist/, build/, clones de
# upstream); con fallback a find por si el árbol se exporta como tarball sin
# .git.
#
# --others --exclude-standard NO es decorativo: sin él solo se auditarían los
# ficheros YA versionados, y una doc recién creada y sin añadir al índice
# —justo la que más falta hace revisar— pasaría invisible. Verificado en vivo:
# docs/freeze-forensics.md quedaba fuera del inventario.
ci_section "Inventario de documentación"

MD=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t MD < <(git ls-files --cached --others --exclude-standard '*.md' | sort -u)
else
  mapfile -t MD < <(find . -name '*.md' -not -path './.git/*' -printf '%P\n' | sort)
fi

if [ "${#MD[@]}" -eq 0 ]; then
  ci_fail "no se encontró ningún fichero .md que auditar"
  ci_summary
  exit $?
fi
ci_ok "${#MD[@]} ficheros markdown en el inventario"

# ---------------------------------------------------------------------------
# Analizador: un solo recorrido por fichero
# ---------------------------------------------------------------------------
# Emite registros con tabulador:
#   LINK  <línea> <destino>   enlace markdown (se filtran los externos en bash)
#   SEMBR <línea>             línea de prosa con más de una frase
#   FENCE <nº>                número IMPAR de fences al terminar el fichero
#
# Lleva la cuenta de las fences en una máquina de estados: con grep a secas
# un `# ```markdown` dentro de un bloque de ejemplo contaría como apertura.
read -r -d '' AWK_MD <<'AWK_EOF'
BEGIN { fence = 0; nfence = 0 }

# Apertura/cierre de bloque de código. Cuenta y cambia de estado.
/^[ \t]*(```|~~~)/ { nfence++; fence = 1 - fence; next }

# Dentro de un bloque de código no hay ni prosa ni enlaces que resolver.
fence == 1 { next }

{
  raw = $0
  s = raw

  # Los code spans (`...`) se quitan: el texto de un enlace suele ir en
  # backticks —[`../x.md`](../x.md)— y así no se confunde con prosa, pero el
  # DESTINO queda intacto porque va fuera de los backticks.
  gsub(/`[^`]*`/, "", s)

  # ---- enlaces markdown ----------------------------------------------
  # Se buscan también en tablas: una tabla puede enlazar igual que un párrafo.
  t = s
  while (match(t, /\]\([^()]*\)/)) {
    print "LINK\t" FNR "\t" substr(t, RSTART + 2, RLENGTH - 3)
    t = substr(t, RSTART + RLENGTH)
  }

  # ---- sembr: ¿más de una frase en esta línea? -----------------------
  # Lo que NO es prosa y por tanto no se juzga:
  if (s ~ /\|/)                 next   # tabla (sus filas van en una línea)
  if (s ~ /^[ \t]*\[[^]]+\]:/)  next   # definición de enlace de referencia
  if (s ~ /^[ \t]*<\/?[A-Za-z]/) next  # bloque HTML (<details>, <br>, ...)
  if (s ~ /^[ \t]*#/)           next   # encabezado
  if (s ~ /^ {4,}/)             next   # bloque de código indentado / salida

  p = s
  gsub(/https?:\/\/[^ )>]+/, "", p)    # las URLs llevan puntos y barras

  # Marcador de lista inicial: "1. Texto" no son dos frases.
  sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", p)

  # Abreviaturas y tokens con punto que NO cierran frase. Sin esto el 90%
  # de los avisos serían falsos positivos de este repo en concreto.
  gsub(/[Pp]\. ?ej\./, "", p)          # p. ej.
  gsub(/etc\./, "", p)
  gsub(/vs\./, "", p)
  gsub(/e\.g\./, "", p)
  gsub(/i\.e\./, "", p)
  gsub(/aprox\./, "", p)
  gsub(/[0-9]+(\.[0-9]+)+/, "", p)     # versiones: 1.5.0, 595.71.05
  # Rutas y nombres de fichero: boltctl.sh, docs/x.md, nvidia-drm-drv.c
  gsub(/[A-Za-z0-9_\/.-]+\.(md|sh|c|h|py|yaml|yml|json|conf|service|rules|deb|txt|cu|patch|ko|log)/, "", p)

  n = 0
  u = p
  # Fin de frase = puntuación + espacio(s) + inicio de frase nueva. Se exige
  # mayúscula (o apertura española) porque "x. y" casi siempre es una
  # abreviatura o una enumeración, no una frase nueva.
  # Los dos puntos quedan FUERA a propósito: "Aviso: El servicio..." es una
  # etiqueta, no dos frases, y ese patrón es constante en este repo.
  while (match(u, /[.!?] +([A-Z]|Á|É|Í|Ó|Ú|Ñ|¿|¡)/)) {
    n++
    u = substr(u, RSTART + RLENGTH)
  }

  # Punto y coma: solo molesta cuando además la línea es larga. Una cláusula
  # corta tras `;` es legible; una línea de 110+ columnas con `;` es un
  # párrafo sin partir.
  if (n == 0 && length(raw) > 110 && p ~ /; /) n = 1

  if (n > 0) print "SEMBR\t" FNR
}

END { if (nfence % 2 == 1) print "FENCE\t" nfence }
AWK_EOF

# Resuelve un destino de enlace y responde si falta. Devuelve 0 = colgado.
link_broken() { # $1=fichero .md que lo contiene  $2=destino crudo
  local src="$1" tgt="$2"
  tgt="${tgt#"${tgt%%[![:space:]]*}"}"   # recorta espacios por la izquierda
  tgt="${tgt%% *}"                       # corta el título opcional: (ruta "T")
  tgt="${tgt#<}"; tgt="${tgt%>}"         # destino entre <>
  tgt="${tgt%%#*}"                       # ancla: solo importa el fichero
  [ -n "$tgt" ] || return 1              # enlace puramente a un ancla
  case "$tgt" in
    http://*|https://*|mailto:*|ftp://*|tel:*|data:*) return 1 ;;  # externo
    /*) return 1 ;;                      # absoluto: no es un enlace del repo
    *'{'*|*'$'*|*'%'*) return 1 ;;       # plantilla/placeholder, no una ruta
  esac
  [ -e "$(dirname "$src")/$tgt" ] && return 1
  return 0
}

BROKEN=()      # "fichero:línea -> destino"
UNBALANCED=()  # "fichero (N fences)"
SEMBR=()       # "fichero: N líneas (12, 40, ...)#N"  (el #N ordena)
links_seen=0
sembr_total=0

for f in "${MD[@]}"; do
  sembr_lines=""; sembr_n=0
  while IFS=$'\t' read -r kind ln rest; do
    case "$kind" in
      LINK)
        links_seen=$((links_seen + 1))
        if link_broken "$f" "$rest"; then
          BROKEN+=("$f:$ln -> $rest")
        fi
        ;;
      SEMBR)
        sembr_n=$((sembr_n + 1))
        # Solo las 10 primeras: el objetivo es orientar, no volcar el fichero.
        if [ "$sembr_n" -le 10 ]; then
          sembr_lines="${sembr_lines:+$sembr_lines, }$ln"
        fi
        ;;
      FENCE)
        UNBALANCED+=("$f ($ln fences, debería ser par)")
        ;;
    esac
  done < <(awk "$AWK_MD" "$f")

  if [ "$sembr_n" -gt 0 ]; then
    [ "$sembr_n" -gt 10 ] && sembr_lines="$sembr_lines, ..."
    sembr_total=$((sembr_total + sembr_n))
    # El sufijo "#N" es solo la clave de ordenación; se recorta al imprimir.
    SEMBR+=("$f: $sembr_n línea(s) con más de una frase — líneas $sembr_lines#$sembr_n")
  fi
done

# ---------------------------------------------------------------------------
# Enlaces internos colgados — FALLO
# ---------------------------------------------------------------------------
ci_section "Enlaces internos (relativos)"
if [ "${#BROKEN[@]}" -eq 0 ]; then
  ci_ok "$links_seen enlaces relativos comprobados, todos resuelven"
else
  # Un FAIL por fichero, con el detalle en argumentos (ci_fail no lee stdin).
  prev=""; detail=""
  for entry in "${BROKEN[@]}"; do
    file="${entry%%:*}"
    if [ "$file" != "$prev" ]; then
      [ -n "$prev" ] && ci_fail "$prev: enlaces relativos colgados" "$detail"
      prev="$file"; detail=""
    fi
    detail="${detail:+$detail$'\n'}${entry}"
  done
  [ -n "$prev" ] && ci_fail "$prev: enlaces relativos colgados" "$detail"
  ci_warn "${#BROKEN[@]} de $links_seen enlaces relativos no resuelven"
fi

# ---------------------------------------------------------------------------
# Fences balanceadas — FALLO
# ---------------------------------------------------------------------------
ci_section "Fences de código balanceadas"
if [ "${#UNBALANCED[@]}" -eq 0 ]; then
  ci_ok "todos los ficheros cierran sus bloques de código"
else
  ci_fail "bloques de código sin cerrar (el resto del documento no renderiza)" \
    "$(printf '%s\n' "${UNBALANCED[@]}")"
fi

# ---------------------------------------------------------------------------
# sembr — AVISO (nunca fallo: ver cabecera)
# ---------------------------------------------------------------------------
ci_section "Semantic line breaks (sembr.org)"
if [ "${#SEMBR[@]}" -eq 0 ]; then
  ci_ok "ninguna línea de prosa con más de una frase"
elif [ "${#SEMBR[@]}" -le 8 ]; then
  for entry in "${SEMBR[@]}"; do ci_warn "${entry%#*}"; done
else
  # Más de 8 ficheros: un aviso por fichero sería ruido. Se agrupa, se ordena
  # por nº de líneas (primero lo que más renta arreglar) y se acota el detalle;
  # CI_DOCS_SEMBR_ALL=1 lo imprime entero.
  tope="${CI_DOCS_SEMBR_ALL:+99999}"; tope="${tope:-20}"
  detalle="$(printf '%s\n' "${SEMBR[@]}" | sort -t'#' -k2 -rn | head -n "$tope" | cut -d'#' -f1)"
  resto=$(( ${#SEMBR[@]} - tope ))
  [ "$resto" -gt 0 ] && detalle="$detalle"$'\n'"… y $resto fichero(s) más (CI_DOCS_SEMBR_ALL=1 los lista todos)"
  ci_warn_with "$sembr_total línea(s) de prosa con más de una frase en ${#SEMBR[@]} fichero(s) — aviso, no fallo" \
    "$detalle" \
    "Arreglar solo si ya estás editando el fichero por otro motivo: CLAUDE.md prohíbe reflowear por reflowear." \
    "Con el binario instalado: mdslw --max-width=80 <fichero>."
fi

# ---------------------------------------------------------------------------
# markdownlint — OMITIDA si no está
# ---------------------------------------------------------------------------
ci_section "markdownlint (estructura)"
ML=""
for cand in markdownlint markdownlint-cli2; do
  if command -v "$cand" >/dev/null 2>&1; then ML="$cand"; break; fi
done
if [ -z "$ML" ] && command -v mdl >/dev/null 2>&1; then
  # mdl (Ruby) existe pero NO entiende .markdownlint.yaml: usa .mdlrc con
  # otra sintaxis de reglas, así que correrlo ignoraría nuestras exclusiones
  # (MD013 sobre todo) y escupiría cientos de falsos positivos de sembr.
  ci_skip "solo hay 'mdl', que no lee .markdownlint.yaml — instala: npm install -g markdownlint-cli"
elif [ -z "$ML" ]; then
  # Nota: ci/lib/report.sh ya NO exporta ci_need (lo tenía una versión
  # anterior); se reporta la ausencia con ci_skip, que es lo que ci_need
  # hacía por dentro. Omitir no es fallar: un portátil sin node no debe
  # pintar el CI en rojo.
  ci_skip "falta 'markdownlint' — instálalo con: npm install -g markdownlint-cli (sin instalar nada: npx markdownlint-cli@0.42.0 --config .markdownlint.yaml .)"
else
  ml_out="$("$ML" --config .markdownlint.yaml "${MD[@]}" 2>&1)"
  if [ -z "$ml_out" ]; then
    ci_ok "$ML sin hallazgos (configuración: .markdownlint.yaml)"
  else
    ci_fail "$ML encontró problemas de estructura" "$ml_out"
  fi
fi

# ---------------------------------------------------------------------------
# Coherencia de versiones: docs ↔ DEBIAN/control
# ---------------------------------------------------------------------------
# La tabla de docs/packages/README.md tiene una columna "Versión" explícita:
# es comprobable a máquina y por eso un desajuste es FALLO. El README raíz no
# cita versiones (solo estados), así que de él solo se comprueba que nombre
# los 5 paquetes.
ci_section "Coherencia doc ↔ DEBIAN/control"
TABLA="docs/packages/README.md"
RAIZ="README.md"

if [ ! -f "$TABLA" ]; then
  ci_fail "falta $TABLA (la tabla de verdad única del estado de los paquetes)"
else
  for ctl in packaging/*/DEBIAN/control; do
    [ -f "$ctl" ] || continue
    pkg="$(sed -n 's/^Package:[[:space:]]*//p' "$ctl" | head -1)"
    ver="$(sed -n 's/^Version:[[:space:]]*//p' "$ctl" | head -1)"
    if [ -z "$pkg" ] || [ -z "$ver" ]; then
      ci_fail "$ctl: sin campo Package: o Version:"
      continue
    fi

    row="$(grep -n -- "^|[[:space:]]*\`$pkg\`[[:space:]]*|" "$TABLA" | head -1)"
    if [ -z "$row" ]; then
      ci_warn "$TABLA no tiene fila para \`$pkg\` (hay 5 paquetes en packaging/)"
    else
      lineno="${row%%:*}"
      docver="$(printf '%s' "${row#*:}" | awk -F'|' '{ gsub(/[ `*]/, "", $3); print $3 }')"
      if [ "$docver" = "$ver" ]; then
        ci_ok "$pkg $ver — la doc coincide"
      else
        ci_fail "$TABLA:$lineno dice que \`$pkg\` es $docver, pero $ctl declara $ver" \
          "Arregla la tabla (o la versión del control, si lo que está mal es el paquete)."
      fi
    fi

    grep -q -- "\`$pkg\`" "$RAIZ" || ci_warn "$RAIZ no menciona \`$pkg\`"

    # Versiones citadas en prosa, en cualquier doc: "pkg 1.4.0",
    # "pkg_1.4.0_all.deb". Aviso y no fallo porque una doc puede citar
    # legítimamente una versión histórica al narrar una regresión.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      mver="$(printf '%s' "$hit" \
        | grep -oE -- "${pkg}[ _-]v?[0-9][0-9.]*" | head -1 \
        | sed -E "s/^${pkg}[ _-]v?//")"
      [ -z "$mver" ] && continue
      [ "$mver" = "$ver" ] && continue
      case "$ver" in "$mver"*) continue ;; esac   # 595.71.05 en 595.71.05-aorus17
      ci_warn "${hit%%:*} cita '$pkg $mver'; el control declara $ver"
    done < <(grep -rnE --include='*.md' -- "${pkg}[ _-]v?[0-9]+\.[0-9]+" . 2>/dev/null || true)
  done
fi

ci_summary
exit $?
