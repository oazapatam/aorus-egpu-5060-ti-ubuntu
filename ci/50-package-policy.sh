#!/usr/bin/env bash
# ci/50-package-policy.sh — invariantes PROPIOS de los paquetes .deb de este
# repo. No es política Debian genérica (eso es ci/60-lintian.sh): es lo que
# este proyecto ha aprendido a golpes y no puede volver a romper.
#
# El invariante nº1 es la REVERSIBILIDAD. Un intento anterior de instalar el
# stack a mano dejó el portátil inestable, y de ahí sale una decisión
# deliberada: NINGÚN fichero empaquetado es un conffile de dpkg, para que
# `apt remove` los borre de verdad y el postrm pueda revertir el estado
# (update-grub, recargas de udev/sysctl). Lintian marca eso como ERROR
# (file-in-etc-not-marked-as-conffile) y aquí se comprueba justo lo contrario:
# ver docs/ci-package-policy.md.
#
# Contrato de etapa: se ejecuta desde la raíz del repo, recoge TODOS los
# fallos (sin `set -e`) y termina con ci_summary (0 pasa / 1 falla / 77 omitida).

set -uo pipefail
# shellcheck source=ci/lib/report.sh
. "$(dirname "$0")/lib/report.sh"

# --- datos del proyecto (fuente: CLAUDE.md, docs/what-actually-works.md) -----

# R4: la eGPU externa es la ÚNICA diana válida; la interna nunca lo es.
EGPU_DID=2d04        # AORUS RTX 5060 Ti (externa, Thunderbolt)
INTERNAL_DID=2c39    # RTX PRO 4000 Blackwell (interna) — PROHIBIDA como diana
INTERNAL_BDF='01:00.0'      # dirección PCI de la interna en esta máquina
INTERNAL_BDF_RE='01:00\.0'  # la misma, escapada para usarla en un ERE

# Excepción de nombre conocida y documentada: egpu-tb-fix es anterior a la
# convención `aorus-egpu-*` y es el único paquete verificado en vivo, así que
# renombrarlo sería cambiar lo único que funciona. Se reconoce, no se marca.
NAME_EXCEPTION=egpu-tb-fix

# Paquetes SUPERSEDED: deben llevar el marcador en la sinopsis para que nadie
# los instale por error leyendo solo `apt show`.
SUPERSEDED_PKGS="aorus-egpu-config aorus-egpu-nvidia-dkms"

# Árboles de payload que genera scripts/lib/bundle.sh en tiempo de build.
# Están gitignorados (o deberían estarlo) y jamás deben aparecer versionados.
GENERATED_PATHS="
packaging/aorus-egpu-overclock/usr/lib/aorus-egpu
packaging/aorus-egpu-overclock/usr/sbin/aorus-egpu-oc
packaging/aorus-egpu-health/usr/lib/aorus-egpu
packaging/aorus-egpu-health/usr/sbin/aorus-egpu-health
packaging/aorus-egpu-forensics/usr/lib/aorus-egpu
packaging/aorus-egpu-forensics/usr/sbin/aorus-egpu-probe
packaging/aorus-egpu-forensics/usr/sbin/aorus-egpu-postmortem
packaging/aorus-egpu-nvidia-dkms/usr
"

# --- utilidades ---------------------------------------------------------------

# Valor de un campo del control (la primera línea del campo, sin continuaciones).
ctrl_field() { # $1=fichero control  $2=campo
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1
}

# ¿Es un fichero de shell? Por extensión o por shebang; los binarios se saltan.
is_shell_file() { # $1=ruta
  case "$1" in *.sh) return 0 ;; esac
  grep -Iq . "$1" 2>/dev/null || return 1   # -I: binario -> no
  head -1 "$1" 2>/dev/null | grep -qE '^#!.*(bash|/bin/sh|env +sh)'
}

# Ficheros de shell del PAYLOAD de los paquetes (sin DEBIAN/) más el núcleo
# src/, que es el payload real de forensics y overclock: bundle.sh lo copia a
# usr/lib/aorus-egpu/ en tiempo de build, así que si no se escanea src/ esos
# dos paquetes quedarían sin revisar.
payload_shell_files() {
  {
    find packaging -path 'packaging/*/DEBIAN' -prune -o -type f -print 2>/dev/null
    find src -type f 2>/dev/null
  } | sort | while IFS= read -r f; do
    is_shell_file "$f" && printf '%s\n' "$f"
  done
}

# Líneas que NO son comentario de línea completa, con su número.
code_lines() { # $1=fichero
  grep -nvE '^[[:space:]]*(#|$)' "$1" 2>/dev/null
}

# Quita el prefijo "NNN:" que pone code_lines, para poder aplicar expresiones
# ancladas en ^ al contenido real de la línea.
strip_lineno() { printf '%s' "$1" | sed 's/^[0-9][0-9]*://'; }

PKG_DIRS=()
for d in packaging/*/; do
  [ -f "${d}DEBIAN/control" ] && PKG_DIRS+=("${d%/}")
done

if [ "${#PKG_DIRS[@]}" -eq 0 ]; then
  ci_fail "no encuentro ningún packaging/*/DEBIAN/control" \
    "¿se está ejecutando la etapa desde la raíz del repo?"
  ci_summary; exit $?
fi

# =============================================================================
ci_section "1. Reversibilidad: ningún fichero empaquetado es conffile"
# =============================================================================
# POR QUÉ: un conffile sobrevive a `apt remove` (dpkg lo deja como .dpkg-old o
# lo conserva si fue modificado). Con ficheros en /etc/default/grub.d/ y
# /etc/sysctl.d/ eso significa que los args de kernel y los sysctl seguirían
# ahí después de desinstalar: exactamente el estado del que este repo huye.

for pkg in "${PKG_DIRS[@]}"; do
  name="$(basename "$pkg")"
  if [ -e "$pkg/DEBIAN/conffiles" ]; then
    ci_fail "$name declara conffiles" \
      "$pkg/DEBIAN/conffiles existe." \
      "Un conffile NO lo borra 'apt remove', así que el paquete deja de ser" \
      "reversible y el postrm no puede devolver el sistema a su estado." \
      "Si el fichero debe ser editable por el usuario, documéntalo y cópialo" \
      "desde el postinst, no lo declares conffile."
  else
    etc_files="$(find "$pkg/etc" -type f 2>/dev/null | wc -l)"
    if [ "$etc_files" -gt 0 ]; then
      ci_ok "$name: sin conffiles ($etc_files fichero(s) en /etc borrables al desinstalar)"
    else
      ci_ok "$name: sin conffiles"
    fi
  fi
done

# Y lo mismo contra los .deb ya construidos: el árbol puede estar limpio y el
# build script añadir el conffile.
shopt -s nullglob
DEBS=(dist/*.deb)
shopt -u nullglob
if [ "${#DEBS[@]}" -eq 0 ]; then
  ci_skip "no hay .deb en dist/ — la comprobación de conffiles sobre el binario necesita 'make'"
elif ! command -v dpkg-deb >/dev/null 2>&1; then
  ci_skip "falta 'dpkg-deb' — no puedo inspeccionar los .deb de dist/"
else
  for deb in "${DEBS[@]}"; do
    # dpkg-deb sale con 2 y escribe en stderr cuando el componente no existe:
    # eso es justo lo que queremos ver.
    out="$(dpkg-deb -I "$deb" conffiles 2>/dev/null)"
    if [ -n "$out" ]; then
      ci_fail "$(basename "$deb") trae conffiles dentro del .deb" "$out"
    else
      ci_ok "$(basename "$deb"): el .deb no declara conffiles"
    fi
  done
fi

# =============================================================================
ci_section "2. Revert declarado en postrm (lo que apt remove no borra solo)"
# =============================================================================
# POR QUÉ: dpkg borra los ficheros, pero no deshace sus efectos. Si un paquete
# pone args de kernel en /etc/default/grub.d/, grub.cfg sigue con ellos hasta
# que alguien ejecute update-grub; igual con las reglas udev y los sysctl ya
# cargados en el kernel vivo. El postrm es el único sitio donde eso se revierte.

for pkg in "${PKG_DIRS[@]}"; do
  name="$(basename "$pkg")"
  postrm="$pkg/DEBIAN/postrm"
  missing=""
  [ -d "$pkg/etc/default/grub.d" ] && needs_grub=1 || needs_grub=0
  [ -d "$pkg/etc/sysctl.d" ] && needs_sysctl=1 || needs_sysctl=0
  if find "$pkg" -path '*/udev/rules.d/*' -type f -print -quit 2>/dev/null | grep -q .; then
    needs_udev=1
  else
    needs_udev=0
  fi
  if find "$pkg" -path '*/systemd/system/*' -type f -print -quit 2>/dev/null | grep -q .; then
    needs_systemd=1
  else
    needs_systemd=0
  fi

  if [ "$((needs_grub + needs_sysctl + needs_udev + needs_systemd))" -eq 0 ]; then
    continue
  fi
  if [ ! -f "$postrm" ]; then
    ci_fail "$name instala estado de sistema y no tiene postrm" \
      "Instala ficheros en grub.d/sysctl.d/udev pero no hay DEBIAN/postrm," \
      "así que 'apt remove' deja el efecto puesto (args de kernel en grub.cfg," \
      "sysctl aplicados, reglas udev cargadas en el udevd vivo)."
    continue
  fi
  [ "$needs_grub" = 1 ] && ! grep -q 'update-grub\|grub-mkconfig' "$postrm" && \
    missing="$missing update-grub"
  [ "$needs_sysctl" = 1 ] && ! grep -q 'sysctl' "$postrm" && \
    missing="$missing sysctl"
  [ "$needs_udev" = 1 ] && ! grep -q 'udevadm' "$postrm" && \
    missing="$missing udevadm"
  [ "$needs_systemd" = 1 ] && ! grep -q 'systemctl' "$postrm" && \
    missing="$missing systemctl"

  if [ -n "$missing" ]; then
    ci_warn_with "$name: el postrm no revierte todo lo que instala" \
      "falta(n) en DEBIAN/postrm:$missing" \
      "dpkg borra el fichero, pero el efecto (grub.cfg regenerado, sysctl" \
      "recargado, reglas udev releídas) no se deshace solo."
  else
    ci_ok "$name: el postrm revierte el estado que instala"
  fi
done

# =============================================================================
ci_section "3. Maintainer scripts: sintaxis, permisos, shebang, salida"
# =============================================================================
# POR QUÉ: un postinst roto rompe `apt install` A MEDIAS — el paquete queda
# "half-configured", y en este repo eso es el peor estado posible: ficheros
# puestos y revert sin ejecutar. Se comprueba antes de construir nada.

for pkg in "${PKG_DIRS[@]}"; do
  name="$(basename "$pkg")"
  for s in preinst postinst prerm postrm; do
    f="$pkg/DEBIAN/$s"
    [ -f "$f" ] || continue

    # 3.a sintaxis como POSIX sh (es el intérprete que dpkg usará si el
    # shebang es /bin/sh, y en Ubuntu /bin/sh es dash, no bash).
    shebang="$(head -1 "$f")"
    case "$shebang" in
      '#!/bin/sh'*)        checker="sh"   ;;
      '#!/bin/bash'*)      checker="bash" ;;
      '#!/usr/bin/bash'*)  checker="bash" ;;
      *)
        ci_fail "$name/$s: shebang no soportado en un maintainer script" \
          "primera línea: $shebang" \
          "dpkg ejecuta los maintainer scripts con el intérprete del shebang;" \
          "usa '#!/bin/sh' (y sintaxis POSIX) o '#!/bin/bash' si usas bashismos."
        checker=""
        ;;
    esac
    if [ -n "$checker" ]; then
      err="$("$checker" -n "$f" 2>&1)"
      if [ -n "$err" ]; then
        ci_fail "$name/$s: error de sintaxis ($checker -n)" "$err"
      else
        ci_ok "$name/$s: sintaxis válida con $checker"
      fi
      # Si declara /bin/sh pero solo pasa con bash, el shebang miente.
      if [ "$checker" = "sh" ]; then
        if ! sh -n "$f" >/dev/null 2>&1 && bash -n "$f" >/dev/null 2>&1; then
          ci_fail "$name/$s: declara #!/bin/sh pero solo es válido como bash" \
            "en Ubuntu /bin/sh es dash: el script fallaría en el apt install."
        fi
      fi
    fi

    # 3.b permisos en el ÁRBOL. dpkg-deb hornea el modo tal cual está en disco;
    # un maintainer script sin +x hace fallar la configuración del paquete.
    mode="$(stat -c '%a' "$f")"
    if [ "$mode" != "755" ]; then
      ci_fail "$name/$s: permisos $mode (se espera 0755)" \
        "dpkg-deb --build hornea el modo del árbol. Sin +x, dpkg no puede" \
        "ejecutar el script y el paquete queda a medio configurar."
    else
      ci_ok "$name/$s: permisos 0755"
    fi

    # 3.c idempotencia declarada: actuar según el argumento de dpkg.
    if grep -qE '^[[:space:]]*case[[:space:]]+"\$1"[[:space:]]+in' "$f"; then
      ci_ok "$name/$s: despacha con case \"\$1\""
    elif grep -q '"\$1"' "$f"; then
      ci_warn_with "$name/$s: filtra \$1 sin un case" \
        "dpkg llama al script con configure/remove/purge/upgrade/abort-*." \
        "Un 'if [ \"\$1\" = configure ]' funciona, pero un case hace explícito" \
        "qué verbos se ignoran y evita actuar en un abort-upgrade."
    else
      ci_warn_with "$name/$s: no mira el argumento de dpkg" \
        "actúa a ciegas en cualquier verbo (configure, abort-upgrade, purge…)," \
        "que es la forma clásica de que una reinstalación duplique el efecto."
    fi

    # 3.d estado de salida final. Con `set -e`, el último comando determina el
    # código de salida del script, y un código != 0 marca el paquete como
    # fallido aunque el trabajo ya esté hecho.
    last="$(grep -vE '^[[:space:]]*(#|$)' "$f" | tail -1 | sed 's/[[:space:]]*$//')"
    case "$last" in
      'exit 0'|':'|'true')
        ci_ok "$name/$s: termina en '$last'" ;;
      'esac'|'fi'|'done')
        # Una estructura de control sin rama tomada devuelve 0: es seguro,
        # pero depende del último comando de la rama que SÍ se tome.
        ci_ok "$name/$s: termina en '$last' (estado 0 si no se toma rama)" ;;
      *)
        ci_warn_with "$name/$s: no termina en 'exit 0' explícito" \
          "última línea ejecutable: $last" \
          "el estado de salida es el de ese comando; si falla, dpkg considera" \
          "que el paquete no se pudo configurar." ;;
    esac
  done
done

# =============================================================================
ci_section "4. Campos obligatorios y formato Debian del control"
# =============================================================================
# POR QUÉ: un control mal formado hace fallar dpkg-deb --build, o peor, produce
# un .deb cuya descripción dpkg trunca. El formato del campo Description es el
# que más se rompe a mano: sinopsis en la MISMA línea del campo, cuerpo con
# líneas que empiezan por UN espacio, y párrafos separados por una línea que
# es exactamente " ." (espacio + punto).

for pkg in "${PKG_DIRS[@]}"; do
  name="$(basename "$pkg")"
  ctrl="$pkg/DEBIAN/control"

  # 4.a campos obligatorios
  miss=""
  for field in Package Version Architecture Maintainer Description; do
    [ -n "$(ctrl_field "$ctrl" "$field")" ] || miss="$miss $field"
  done
  if [ -n "$miss" ]; then
    ci_fail "$name/control: faltan campos obligatorios:$miss" \
      "dpkg-deb rechaza un control sin ellos (Debian Policy 5.3)."
  else
    ci_ok "$name/control: Package, Version, Architecture, Maintainer, Description presentes"
  fi

  # 4.b CRLF y último byte: dpkg no perdona los finales de línea de Windows.
  if grep -qU $'\r' "$ctrl" 2>/dev/null; then
    ci_fail "$name/control: contiene CRLF" \
      "dpkg trata el \\r como parte del valor del campo."
  fi
  if [ -n "$(tail -c1 "$ctrl")" ]; then
    ci_warn "$name/control: no termina en salto de línea"
  fi

  # 4.c el nombre del directorio y el campo Package deben coincidir: los build
  # scripts componen el nombre del .deb con uno y empaquetan el otro.
  pkgname="$(ctrl_field "$ctrl" Package)"
  if [ "$pkgname" != "$name" ]; then
    ci_fail "$name/control: Package es '$pkgname' y el directorio es '$name'" \
      "scripts/build-*.sh nombra el .deb a partir del directorio."
  fi

  # 4.d formato del campo Description
  syn="$(ctrl_field "$ctrl" Description)"
  if [ -z "$syn" ]; then
    ci_fail "$name/control: Description sin sinopsis en su propia línea" \
      "la primera línea (sinopsis) va en la MISMA línea del campo."
  else
    if [ "${#syn}" -gt 80 ]; then
      ci_warn_with "$name/control: sinopsis de ${#syn} caracteres (> 80)" "$syn"
    else
      ci_ok "$name/control: sinopsis de ${#syn} caracteres"
    fi
  fi

  # Cuerpo: desde la línea siguiente a Description: hasta el siguiente campo.
  body_err="$(awk '
    /^Description:/ { ind=1; next }
    ind && /^[A-Za-z][A-Za-z0-9-]*:/ { ind=0 }
    ind {
      if ($0 == "") { printf "%d: línea VACÍA (termina la descripción y dpkg rechaza el resto)\n", NR; next }
      if ($0 !~ /^ /) { printf "%d: la línea no empieza por un espacio: %s\n", NR, $0; next }
      if ($0 ~ /^ +$/) { printf "%d: línea de solo espacios (el separador de párrafo es exactamente \" .\")\n", NR; next }
      if ($0 ~ /^ \.+.+/ && $0 != " .") { printf "%d: separador de párrafo malformado: %s\n", NR, $0; next }
      if ($0 ~ /^\t/ || $0 ~ /^ \t/) { printf "%d: la continuación empieza por tabulador\n", NR; next }
    }
  ' "$ctrl")"
  if [ -n "$body_err" ]; then
    ci_fail "$name/control: cuerpo de Description mal formado" "$body_err"
  else
    ci_ok "$name/control: cuerpo de Description con formato Debian correcto"
  fi
done

# =============================================================================
ci_section "5. Convención de nombres (CLAUDE.md)"
# =============================================================================
# POR QUÉ: userspace se llama `aorus-egpu-*`; el prefijo es lo que permite
# auditar el sistema con un solo glob ("¿queda algo instalado?").
# egpu-tb-fix es la excepción conocida: es anterior a la convención y es el
# único paquete verificado en vivo, así que se reconoce explícitamente.

for pkg in "${PKG_DIRS[@]}"; do
  name="$(basename "$pkg")"
  case "$name" in
    aorus-egpu-*)
      ci_ok "$name: sigue la convención aorus-egpu-*" ;;
    "$NAME_EXCEPTION")
      ci_ok "$name: excepción documentada (anterior a la convención, validado en vivo)" ;;
    *)
      ci_fail "$name: no sigue la convención de nombres" \
        "userspace se llama 'aorus-egpu-*' (CLAUDE.md). La única excepción" \
        "aceptada es '$NAME_EXCEPTION'." ;;
  esac

  # Los ejecutables instalados en PATH heredan la misma regla.
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    base="$(basename "$b")"
    case "$base" in
      # El prefijo a secas es el CLI principal del paquete; también vale.
      aorus-egpu|aorus-egpu-*|egpu-tb-fix) ;;
      *) ci_warn_with "$name: ejecutable fuera de convención: $base" "$b" ;;
    esac
  done < <(find "$pkg/usr/bin" "$pkg/usr/sbin" -type f 2>/dev/null)
done

# =============================================================================
ci_section "6. Coherencia de versión con el build script"
# =============================================================================
# POR QUÉ: los build scripts sacan la versión del control con awk y la meten en
# el nombre del .deb. Si el nombre se fija a mano, se publica un .deb cuyo
# nombre miente sobre lo que lleva dentro.

for pkg in "${PKG_DIRS[@]}"; do
  name="$(basename "$pkg")"
  ver="$(ctrl_field "$pkg/DEBIAN/control" Version)"

  if ! printf '%s' "$ver" | grep -qE '^[0-9]'; then
    ci_fail "$name: Version '$ver' no empieza por un dígito" \
      "Debian Policy 5.6.12: la versión upstream debe empezar por un dígito."
  fi

  # ¿Qué script construye este paquete?
  bs="$(grep -lE "packaging/$name([\"/ ]|\$)" scripts/build-*.sh 2>/dev/null | head -1)"
  if [ -z "$bs" ]; then
    ci_fail "$name: ningún scripts/build-*.sh lo construye" \
      "cada árbol de packaging/ debe tener su build script (fuente única de" \
      "cómo se empaqueta); si no, el paquete no es reproducible."
    continue
  fi

  # El nombre del .deb debe venir de una variable, no escrito a mano.
  if grep -qE "${name}_\\\$\{?[A-Za-z_]+\}?_all\.deb" "$bs"; then
    ci_ok "$name: $bs nombra el .deb con la versión del control"
  elif grep -qE "${name}_${ver//./\\.}_all\.deb" "$bs"; then
    ci_fail "$name: $bs lleva la versión escrita a mano en el nombre del .deb" \
      "se descuadrará en cuanto cambie Version en DEBIAN/control."
  else
    ci_warn_with "$name: no reconozco cómo nombra el .deb $bs" \
      "se esperaba algo como ${name}_\${VER}_all.deb"
  fi
  # Y que la versión salga del control, no de otra fuente.
  if ! grep -q "'/\^Version:/" "$bs" && ! grep -q '\^Version:' "$bs"; then
    ci_warn_with "$name: $bs no extrae Version de DEBIAN/control" \
      "el resto del repo lo hace con awk -F': ' '/^Version:/{print \$2; exit}'"
  fi

  # Si hay .deb construido, el nombre real debe cuadrar con el control.
  shopt -s nullglob
  found=(dist/"$name"_*_all.deb)
  shopt -u nullglob
  for deb in "${found[@]}"; do
    want="dist/${name}_${ver}_all.deb"
    if [ "$deb" != "$want" ]; then
      ci_warn_with "$name: hay un .deb obsoleto en dist/" \
        "encontrado: $deb" "control dice Version: $ver (esperado $want)" \
        "dist/ está gitignorado; 'make clean' lo limpia."
    elif command -v dpkg-deb >/dev/null 2>&1; then
      dver="$(dpkg-deb -f "$deb" Version 2>/dev/null)"
      if [ "$dver" = "$ver" ]; then
        ci_ok "$name: dist/$(basename "$deb") coincide con Version: $ver"
      else
        ci_fail "$name: el .deb declara Version '$dver' y el control '$ver'" \
          "$deb"
      fi
    fi
  done
done

# =============================================================================
ci_section "7. Gate R4: la GPU interna (10de:$INTERNAL_DID) nunca es diana"
# =============================================================================
# POR QUÉ (CLAUDE.md, src/domain/target.sh): tocar la GPU interna ya rompió la
# máquina una vez (Xid 79 en 10de:2c39 durante un resume RTD3/GC6 normal).
# Toda escritura se dirige por PCI bus-id, NUNCA por índice de GPU: los
# índices de nvidia-smi se reordenan entre arranques, así que un `-i 0` que
# hoy apunta a la eGPU mañana apunta a la interna. Es exactamente así como se
# acabaría tocando lo que no se puede tocar.

r4_idx_hits=""
r4_var_hits=""
r4_did_hits=""
r4_bdf_hits=""
r4_scanned=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  r4_scanned=$((r4_scanned + 1))

  # 7.a nvidia-smi dirigido por ÍNDICE literal
  hits="$(code_lines "$f" | grep -E '(nvidia-smi|[^a-zA-Z_]_?smi)[^#]*([[:space:]](-i|--id)[[:space:]]+[0-9]|[[:space:]]-i[0-9]|--id=[0-9])' || true)"
  [ -n "$hits" ] && r4_idx_hits="$r4_idx_hits
$f:
$hits"

  # 7.a-bis la misma trampa con una variable que SE LLAMA índice: no prueba
  # nada por sí sola, pero es la pista de que el target no es un bus-id.
  hits="$(code_lines "$f" | grep -E '(-i|--id)[= ]+"?\$\{?[A-Za-z_]*([Ii]dx|[Ii]ndex|INDEX|IDX)' || true)"
  [ -n "$hits" ] && r4_var_hits="$r4_var_hits
$f:
$hits"

  # 7.b el device-id de la interna usado en una línea de código. Se permite
  # SOLO como constante prohibida o como guarda de aborto (eso es el gate).
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if printf '%s' "$l" | grep -qiE 'INTERNAL|INTERNA|prohibid|forbid|abort|!=|is_internal|never|jam[aá]s|nunca'; then
      continue
    fi
    r4_did_hits="$r4_did_hits
$f:$l"
  done <<< "$(code_lines "$f" | grep -iE "(0x)?$INTERNAL_DID" || true)"

  # 7.c escritura dirigida a la dirección PCI de la interna
  hits="$(code_lines "$f" | grep -E "(setpci[^#]*${INTERNAL_BDF_RE}|${INTERNAL_BDF_RE}[^#]*/(remove|rescan|reset|d3cold_allowed|power/control))" || true)"
  [ -n "$hits" ] && r4_bdf_hits="$r4_bdf_hits
$f:
$hits"
done < <(payload_shell_files)

if [ "$r4_scanned" -eq 0 ]; then
  ci_fail "no he encontrado ningún fichero de shell de payload que escanear" \
    "payload_shell_files() no devolvió nada: la comprobación R4 sería un falso verde."
else
  if [ -n "$r4_idx_hits" ]; then
    ci_fail "R4: nvidia-smi dirigido por ÍNDICE de GPU en el payload" \
      "${r4_idx_hits#
}" \
      "Los índices de nvidia-smi se reordenan entre arranques: un '-i 0' puede" \
      "apuntar a la GPU INTERNA (10de:$INTERNAL_DID). Diríjase por PCI bus-id" \
      "(gpu_find_by_device_id en src/adapters/gpu/nvidia-smi.sh devuelve la" \
      "cadena exacta que -i acepta)."
  else
    ci_ok "R4: ningún nvidia-smi dirigido por índice ($r4_scanned ficheros de shell escaneados)"
  fi

  if [ -n "$r4_var_hits" ]; then
    ci_warn_with "R4: posible target por índice a través de una variable" \
      "${r4_var_hits#
}" \
      "si la variable lleva un índice de GPU, se reordena entre arranques;" \
      "si lleva un bus-id, renómbrala para que se lea como tal."
  else
    ci_ok "R4: ningún '-i \$...index' sospechoso"
  fi

  if [ -n "$r4_did_hits" ]; then
    ci_fail "R4: 10de:$INTERNAL_DID aparece fuera de una guarda de aborto" \
      "${r4_did_hits#
}" \
      "El device-id de la interna solo puede aparecer como constante prohibida" \
      "o en una comprobación que ABORTA (domain_target_is_internal), nunca" \
      "como diana de una acción."
  else
    ci_ok "R4: 10de:$INTERNAL_DID solo aparece como constante prohibida o guarda de aborto"
  fi

  if [ -n "$r4_bdf_hits" ]; then
    ci_fail "R4: escritura dirigida a la dirección PCI de la interna" \
      "${r4_bdf_hits#
}"
  else
    ci_ok "R4: ninguna escritura dirigida a la dirección PCI de la interna ($INTERNAL_BDF)"
  fi
fi

# La eGPU debe estar identificada en algún sitio del payload: si no aparece
# ningún 2d04, el targeting por device-id no existe y R4 no está implementado.
if grep -rqiE "(0x)?$EGPU_DID" packaging src 2>/dev/null; then
  ci_ok "R4: la eGPU (10de:$EGPU_DID) sí está identificada explícitamente en el payload"
else
  ci_warn "R4: no encuentro el device-id de la eGPU ($EGPU_DID) en el payload"
fi

# =============================================================================
ci_section "8. nvidia-smi siempre acotado por timeout"
# =============================================================================
# POR QUÉ (CLAUDE.md): un eGPU semi-roto cuelga nvidia-smi en estado-D
# indefinidamente, y martillearlo lo deja wedged. Toda invocación va envuelta
# en `timeout`, y un rc 124 obliga a abortar sin reintentar.

smi_naked=""
# Posición de comando: inicio de línea, tras un separador o tras una palabra
# clave. Así no se marca un "nvidia-smi" que solo aparece dentro de un mensaje.
SMI_CMDPOS='(^|[;&|({`]|&&|\|\||\bif\b|\belif\b|\bthen\b|\belse\b|\bdo\b|\bexec\b|\bsudo\b|\$\()[[:space:]]*nvidia-smi'

while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    # Se quita el "NNN:" de code_lines (si no, ninguna expresión anclada en ^
    # encontraría una llamada al principio de la línea) y 'command -v
    # nvidia-smi', que es una comprobación de existencia, no una invocación.
    probe="$(strip_lineno "$l" | sed 's/command -v nvidia-smi//g')"
    printf '%s' "$probe" | grep -qE "$SMI_CMDPOS" || continue
    printf '%s' "$probe" | grep -q 'timeout' && continue
    smi_naked="$smi_naked
$f:$l"
  done <<< "$(code_lines "$f" | grep -F 'nvidia-smi' || true)"
done < <(payload_shell_files)

if [ -n "$smi_naked" ]; then
  ci_warn_with "nvidia-smi invocado sin 'timeout' en el payload" \
    "${smi_naked#
}" \
    "Un eGPU semi-roto deja nvidia-smi en estado-D para siempre y arrastra al" \
    "servicio que lo llamó. Envuélvelo como hace src/adapters/gpu/nvidia-smi.sh:" \
    "_smi() { timeout \"\$AORUS_SMI_TIMEOUT\" nvidia-smi \"\$@\"; }"
else
  ci_ok "toda invocación de nvidia-smi del payload va acotada por timeout"
fi

# =============================================================================
ci_section "9. Paquetes SUPERSEDED: marcador y conflicto declarados"
# =============================================================================
# POR QUÉ: el conflicto de aorus-egpu-config con egpu-tb-fix es REAL, no
# burocrático: los dos reasignan el BAR0 desde reglas udev y se pisarían. Y el
# marcador [SUPERSEDED] en la sinopsis es lo único que ve quien hace
# `apt show` antes de instalar.

for name in $SUPERSEDED_PKGS; do
  ctrl="packaging/$name/DEBIAN/control"
  if [ ! -f "$ctrl" ]; then
    ci_warn "$name: no existe $ctrl (¿retirado del repo?)"
    continue
  fi
  syn="$(ctrl_field "$ctrl" Description)"
  case "$syn" in
    '[SUPERSEDED]'*)
      ci_ok "$name: la sinopsis empieza por [SUPERSEDED]" ;;
    *)
      ci_fail "$name: la sinopsis no empieza por [SUPERSEDED]" \
        "sinopsis actual: $syn" \
        "es el único aviso que ve quien lee 'apt show' antes de instalarlo." ;;
  esac
  # El cuerpo debe explicar el estado, no solo marcarlo.
  if grep -qE '^ \[SUPERSEDED' "$ctrl"; then
    ci_ok "$name: el cuerpo de la descripción explica la retirada"
  else
    ci_warn "$name: el cuerpo de la descripción no explica por qué está superseded"
  fi
done

# El conflicto es específico de aorus-egpu-config.
cfg="packaging/aorus-egpu-config/DEBIAN/control"
if [ -f "$cfg" ]; then
  if ctrl_field "$cfg" Conflicts | grep -qw "$NAME_EXCEPTION"; then
    ci_ok "aorus-egpu-config: declara Conflicts: $NAME_EXCEPTION"
  else
    ci_fail "aorus-egpu-config: no declara Conflicts: $NAME_EXCEPTION" \
      "ambos reasignan el BAR0 de la eGPU desde reglas udev y se pisarían." \
      "Sin el Conflicts, apt permitiría instalarlos juntos."
  fi
fi

# La deuda de versión del DKMS está declarada en la descripción: si alguien la
# quita sin rebasar los parches, el paquete vuelve a parecer instalable.
dkms="packaging/aorus-egpu-nvidia-dkms/DEBIAN/control"
if [ -f "$dkms" ]; then
  if grep -qiE 'VERSION DEBT|deuda de versi' "$dkms"; then
    ci_ok "aorus-egpu-nvidia-dkms: la deuda de versión sigue declarada"
  else
    ci_fail "aorus-egpu-nvidia-dkms: ya no declara su deuda de versión" \
      "sus parches están escritos contra 595.71.05 y el driver instalado es" \
      "595.99.02: los módulos no cargarían (docs/what-actually-works.md)."
  fi
fi

# =============================================================================
ci_section "10. Árboles de payload generados: fuera de git"
# =============================================================================
# POR QUÉ: packaging/<pkg>/usr/lib/aorus-egpu/ lo genera scripts/lib/bundle.sh
# copiando src/. Si una copia se versiona, deja de haber una única fuente de
# verdad: el .deb se construiría con la copia vieja y nadie se daría cuenta.

if ! command -v git >/dev/null 2>&1 || [ ! -d .git ]; then
  ci_skip "sin repositorio git — no puedo comprobar los árboles generados"
else
  for p in $GENERATED_PATHS; do
    tracked="$(git ls-files -- "$p" 2>/dev/null)"
    if [ -n "$tracked" ]; then
      ci_fail "árbol generado VERSIONADO en git: $p" \
        "$tracked" \
        "lo genera scripts/lib/bundle.sh desde src/ en tiempo de build." \
        "Quítalo del índice (git rm --cached -r $p) y deja que .gitignore lo cubra."
    else
      ci_ok "no versionado: $p"
    fi
    # Y que .gitignore lo cubra, para que el próximo 'git add -A' no lo cuele.
    # Un patrón con barra final ("…/aorus-egpu/") solo matchea directorios, y
    # el árbol no existe hasta que corre el build: se prueba también la forma
    # con barra y un hijo cualquiera, que es lo que git vería de verdad.
    # (-q solo admite UN pathname, así que se prueban de uno en uno.)
    ignored=0
    for variant in "$p" "$p/" "$p/.probe"; do
      git check-ignore -q "$variant" 2>/dev/null && { ignored=1; break; }
    done
    if [ "$ignored" -eq 0 ]; then
      ci_warn_with "$p no está cubierto por .gitignore" \
        "hoy no está versionado, pero un 'git add -A' tras un build lo añadiría."
    fi
  done
fi

ci_section "11. Dobles de test: nunca en un .deb"
# =============================================================================
# POR QUÉ: los dobles (src/adapters/*/fake.sh) viven en src/ porque son
# adaptadores legítimos de su puerto y `aorus_adapter` los resuelve bajo
# AORUS_LIB_ROOT. Pero bundle_core copia src/ ENTERO, así que sin una
# exclusión explícita acaban dentro del paquete instalado.
#
# No es un problema de tamaño. `aorus-egpu-oc` eleva con `sudo -E`, que
# PRESERVA AORUS_ADAPTER_GPU, de modo que con el doble instalado
# `AORUS_ADAPTER_GPU=adapters/gpu/fake aorus-egpu-oc apply performance`
# reportaría "perfil aplicado" sin haber escrito nada en la tarjeta. Un falso
# éxito en una ruta de escritura es peor que no tener la herramienta.
# La exclusión está en scripts/lib/bundle.sh; esto impide que se caiga.

if ! command -v dpkg-deb >/dev/null 2>&1; then
  ci_skip "sin dpkg-deb — no puedo inspeccionar los .deb"
elif ! ls dist/*.deb >/dev/null 2>&1; then
  ci_skip "no hay .deb en dist/ — ejecuta los build-*.sh antes"
else
  for deb in dist/*.deb; do
    leaked="$(dpkg-deb -c "$deb" 2>/dev/null | awk '/\/fake\.sh$/ {print $NF}')"
    if [ -n "$leaked" ]; then
      ci_fail "doble de test ENTREGADO en $(basename "$deb")" \
        "$leaked" \
        "bundle_core copia src/ entero y la exclusión de fake.sh no se aplicó." \
        "Revisa el 'find -name fake.sh -delete' de scripts/lib/bundle.sh."
    else
      ci_ok "sin dobles: $(basename "$deb")"
    fi
  done
fi

ci_summary
