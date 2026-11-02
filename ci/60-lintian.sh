#!/usr/bin/env bash
# ci/60-lintian.sh — política Debian ESTÁNDAR sobre los .deb construidos.
#
# Reparto de trabajo con la etapa 50: aquí no se comprueba nada propio del
# proyecto. Esta etapa pregunta a lintian "¿esto es un paquete Debian bien
# hecho?" y filtra las respuestas que no aplican a un paquete LOCAL, que se
# construye en esta máquina y nunca va a subir a un archivo Debian.
#
# Dos mecanismos, a propósito distintos:
#
#   EXCLUSIÓN (LINTIAN_EXCLUDE) — la etiqueta no puede aplicar NUNCA a este
#   tipo de paquete, o contradice un invariante del proyecto. Es una decisión
#   permanente y cada una lleva su motivo al lado.
#
#   BASELINE (ci/baselines/lintian-known.txt) — la etiqueta SÍ aplica y el
#   hallazgo concreto está aceptado hoy. Se apunta cuántas veces aparece por
#   paquete y la etapa solo falla si EMPEORA: una etiqueta nueva en un paquete
#   es FAIL, más apariciones de una conocida es WARN.
#
# El razonamiento de cada exclusión está en docs/ci-package-policy.md.
#
# Esta etapa NO construye paquetes: el orquestador se encarga del orden. Sin
# .deb en dist/, se omite (77) pidiendo un `make`.

set -uo pipefail
# shellcheck source=ci/lib/report.sh
. "$(dirname "$0")/lib/report.sh"

BASELINE="ci/baselines/lintian-known.txt"

# --- etiquetas excluidas, con el motivo en una línea -------------------------
# El motivo largo (y por qué NO se excluyen otras que también disparan) está en
# docs/ci-package-policy.md. Formato: "etiqueta|motivo".
LINTIAN_EXCLUDE=(
  "file-in-etc-not-marked-as-conffile|INVARIANTE INVERSO: aquí ningún fichero es conffile para que apt remove lo borre de verdad (lo comprueba ci/50)"
  "no-copyright-file|requisito de archivo Debian; el repo tiene LICENSE en la raíz y el .deb no se redistribuye"
  "no-changelog|idem: el historial de versiones es el git de este repo, no un changelog.gz"
  "changelog-file-missing-in-native-package|misma etiqueta en otras versiones de lintian"
  "no-manual-page|las herramientas se documentan en docs/ y con --help; una man page de un paquete local no la lee nadie"
  "extended-description-line-too-long|las descripciones son expedientes forenses deliberados; ci/50 valida lo que sí rompe dpkg (sinopsis y formato del cuerpo)"
  "depends-on-essential-package-without-using-version|higiene de archivo; listar bash/coreutils explícitamente documenta la intención en un paquete local"
  "maintainer-script-calls-systemctl|estos paquetes se construyen sin debhelper y recargar systemd/udev es justo el mecanismo de reversibilidad"
  "maintainer-address-causes-mail-loops-or-bounces|el Maintainer es el dueño de la máquina, no un buzón del archivo Debian"
)

# --- herramienta --------------------------------------------------------------
if ! ci_need lintian "sudo apt install lintian"; then
  ci_summary; exit $?
fi

# --- paquetes a revisar -------------------------------------------------------
# Sin .deb la etapa se OMITE (77), no pasa: un verde sin haber mirado ningún
# paquete es exactamente el falso verde que esta etapa existe para evitar.
# Por eso la comprobación va ANTES del primer ci_ok (ci_summary devuelve 77
# cuando hay omitidos y ningún ok).
shopt -s nullglob
DEBS=(dist/*.deb)
shopt -u nullglob
if [ "${#DEBS[@]}" -eq 0 ]; then
  ci_skip "no hay .deb en dist/ — construye primero con 'make' (esta etapa no construye nada)"
  ci_summary; exit $?
fi

ci_ok "lintian presente: $(lintian --version 2>/dev/null)"

# --- deriva de la lista de exclusiones ---------------------------------------
# Si lintian renombra o retira una etiqueta, la exclusión se queda ahí
# silenciosamente tapando nada. Mejor saberlo.
ci_section "Exclusiones declaradas"
EXCLUDE_RE=""
for e in "${LINTIAN_EXCLUDE[@]}"; do
  tag="${e%%|*}"; why="${e#*|}"
  EXCLUDE_RE="${EXCLUDE_RE:+$EXCLUDE_RE|}$tag"
  if ! lintian-explain-tags "$tag" >/dev/null 2>&1; then
    ci_warn_with "exclusión obsoleta: lintian ya no conoce '$tag'" \
      "motivo registrado: $why" \
      "revísala en docs/ci-package-policy.md y en la lista de esta etapa."
  fi
done
ci_ok "${#LINTIAN_EXCLUDE[@]} etiquetas excluidas por no aplicar a un paquete local (ver docs/ci-package-policy.md)"

# --- baseline -----------------------------------------------------------------
# Formato: "<paquete> <etiqueta> <nº de apariciones>". Comentarios con '#'.
declare -A KNOWN=()
if [ -f "$BASELINE" ]; then
  while read -r bp bt bn _rest; do
    case "$bp" in ''|'#'*) continue ;; esac
    [ -n "${bt:-}" ] && [ -n "${bn:-}" ] || continue
    KNOWN["$bp/$bt"]="$bn"
  done < "$BASELINE"
  ci_ok "baseline cargado: ${#KNOWN[@]} pares (paquete, etiqueta) conocidos en $BASELINE"
else
  ci_warn "no existe $BASELINE: cualquier etiqueta contará como nueva"
fi

UPDATE="${CI_LINTIAN_UPDATE_BASELINE:-0}"
NEWBASE=""

# --- ejecución ----------------------------------------------------------------
for deb in "${DEBS[@]}"; do
  ci_section "lintian: $(basename "$deb")"

  # lintian sale con 2 cuando hay etiquetas de error: el código de salida no
  # sirve de señal, la salida sí. Se captura en una variable (nunca por tubería
  # hacia ci_fail: el lado derecho de una tubería corre en subshell y perdería
  # el contador — ver ci/lib/report.sh).
  raw="$(lintian --tag-display-limit 0 "$deb" 2>&1)"

  # Ruido de la herramienta (avisos de deprecación, líneas N:) fuera.
  lines="$(printf '%s\n' "$raw" | grep -E '^[EWIPXO]: ' || true)"
  other="$(printf '%s\n' "$raw" | grep -vE '^[EWIPXO]: ' | grep -vE '^[[:space:]]*$' || true)"
  if [ -n "$other" ]; then
    # Un fallo de lintian (no una etiqueta) tampoco puede pasar en silencio.
    if printf '%s' "$other" | grep -qiE 'warning: |error|cannot|unknown tag'; then
      ci_warn_with "lintian escribió algo que no es una etiqueta" "$other"
    fi
  fi

  # Filtro de exclusiones.
  kept="$(printf '%s\n' "$lines" | grep -vE ": ($EXCLUDE_RE)( |\[|$)" || true)"
  n_all="$(printf '%s\n' "$lines" | grep -c . || true)"
  n_kept="$(printf '%s\n' "$kept" | grep -c . || true)"
  ci_ok "$n_all etiquetas, $((n_all - n_kept)) excluidas, $n_kept a evaluar"

  if [ "$n_kept" -eq 0 ]; then
    ci_ok "$(basename "$deb"): limpio tras las exclusiones"
    continue
  fi

  # Agrupar por (paquete, etiqueta).
  declare -A seen=() detail=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rest="${line#*: }"            # quita "E: "
    lpkg="${rest%%:*}"            # nombre del paquete binario
    td="${rest#*: }"              # "etiqueta [detalle]"
    ltag="${td%% *}"
    key="$lpkg/$ltag"
    seen["$key"]=$(( ${seen["$key"]:-0} + 1 ))
    detail["$key"]="${detail["$key"]:-}${detail["$key"]:+
}$line"
  done <<< "$kept"

  for key in $(printf '%s\n' "${!seen[@]}" | sort); do
    count="${seen[$key]}"
    base="${KNOWN[$key]:-}"
    NEWBASE="$NEWBASE${key%%/*} ${key#*/} $count
"
    if [ -z "$base" ]; then
      ci_fail "etiqueta NUEVA: $key ($count)" \
        "${detail[$key]}" \
        "No está en el baseline. O es un problema real que hay que arreglar, o" \
        "una etiqueta que no aplica a un paquete local: decídelo, documéntalo" \
        "en docs/ci-package-policy.md y, si se acepta, apúntala con" \
        "CI_LINTIAN_UPDATE_BASELINE=1 ci/60-lintian.sh"
    elif [ "$count" -gt "$base" ]; then
      ci_warn_with "$key: $count apariciones (el baseline tenía $base)" \
        "${detail[$key]}"
    elif [ "$count" -lt "$base" ]; then
      ci_ok "$key: $count (mejoró; el baseline tenía $base)"
    else
      ci_ok "$key: $count, conocido y aceptado en el baseline"
    fi
  done
  unset seen detail
done

# Pares del baseline que ya no aparecen: no es un fallo (el paquete puede no
# estar construido), pero conviene verlo para poder adelgazar el baseline.
for key in "${!KNOWN[@]}"; do
  case "$NEWBASE" in
    *"${key%%/*} ${key#*/} "*) ;;
    *) ci_ok "baseline: ${key} ya no aparece (o su paquete no está en dist/)" ;;
  esac
done

if [ "$UPDATE" = "1" ]; then
  mkdir -p "$(dirname "$BASELINE")"
  {
    echo "# ci/baselines/lintian-known.txt — hallazgos de lintian YA CONOCIDOS."
    echo "#"
    echo "# Formato: <paquete> <etiqueta> <nº de apariciones>."
    echo "# ci/60-lintian.sh falla si aparece un par (paquete, etiqueta) que no"
    echo "# esté aquí, y avisa si una etiqueta conocida aparece MÁS veces. No"
    echo "# bendice nada: es la deuda medida, para que no crezca sin que se vea."
    echo "#"
    echo "# Regenerar:  CI_LINTIAN_UPDATE_BASELINE=1 ci/60-lintian.sh"
    echo "# El motivo de cada línea está en docs/ci-package-policy.md."
    printf '%s' "$NEWBASE" | sort
  } > "$BASELINE"
  ci_warn "baseline REESCRITO en $BASELINE (CI_LINTIAN_UPDATE_BASELINE=1)"
fi

ci_summary
