# CI de los paquetes Debian: qué se comprueba y por qué

Dos etapas revisan los `.deb` de este repo, y el reparto entre ellas no es
arbitrario:

| Etapa | Pregunta que contesta |
|---|---|
| [`ci/50-package-policy.sh`](../ci/50-package-policy.sh) | ¿cumple este paquete los invariantes de ESTE proyecto? |
| [`ci/60-lintian.sh`](../ci/60-lintian.sh) | ¿es un paquete Debian bien hecho, según lintian? |

Las dos siguen el contrato de `ci/lib/report.sh`:
se ejecutan desde la raíz del repo, recogen **todos** los fallos en vez de
morir en el primero, y terminan con `ci_summary`
(`0` pasa, `1` falla, `77` omitida por falta de herramienta o de material).

```bash
ci/50-package-policy.sh      # no necesita paquetes construidos
make                         # construye dist/*.deb
ci/60-lintian.sh             # sin .deb en dist/ se omite (77), no pasa en verde
```

La etapa 60 **no construye nada**:
el orden lo decide el orquestador `ci/run.sh`.

## Por qué existe la etapa 50

La restricción de diseño central del repo es que todo sea **reversible con
`apt remove`**
(ver [`../CLAUDE.md`](../CLAUDE.md) y
[`what-actually-works.md`](./what-actually-works.md)).
Un intento anterior de instalar el stack a mano dejó el portátil inestable, y
de ahí sale la regla nº 1:
**ningún fichero empaquetado es un conffile de dpkg**.

Eso choca de frente con la política Debian, que marca como *error* un fichero
en `/etc` que no sea conffile.
Es decir: lintian, por sí solo, empuja el repo exactamente en la dirección
contraria a la que lo mantiene vivo.
La etapa 50 existe para comprobar lo contrario, y la 60 para que el resto de
la política Debian siga vigilada.

## Etapa 50 — invariantes del proyecto

### 1. Ningún fichero empaquetado es conffile

Se comprueba que no existe `DEBIAN/conffiles` en ningún árbol de
`packaging/`, y además que ningún `.deb` de `dist/` lo trae dentro
(`dpkg-deb -I <deb> conffiles`).
Cualquier conffile es `ci_fail`.

Por qué:
un conffile sobrevive a `apt remove`.
Con ficheros en `/etc/default/grub.d/` y `/etc/sysctl.d/` eso significa que los
argumentos de kernel y los `sysctl` seguirían puestos después de desinstalar,
que es precisamente el estado del que este repo huye.
Al no ser conffiles, dpkg los borra y el `postrm` puede rematar el revert.

### 2. El `postrm` revierte lo que el paquete instala

Si un paquete trae ficheros en `etc/default/grub.d/`, `etc/sysctl.d/`,
`udev/rules.d/` o `systemd/system/`, su `postrm` tiene que mencionar
`update-grub`, `sysctl`, `udevadm` o `systemctl` respectivamente.
Falta de `postrm` entero es `ci_fail`;
falta de una de esas recargas es `ci_warn`.

Por qué:
dpkg borra el fichero, pero no deshace su efecto.
`grub.cfg` sigue con los argumentos hasta que alguien ejecute `update-grub`;
las reglas udev siguen cargadas en el `udevd` vivo;
los `sysctl` ya aplicados siguen en el kernel.
La reversibilidad se juega aquí, no en la lista de ficheros.

### 3. Maintainer scripts

Para cada `preinst`/`postinst`/`prerm`/`postrm` presente:

- **Shebang** `#!/bin/sh` o `#!/bin/bash`, y nada más — `ci_fail`.
- **Sintaxis** válida con el intérprete que declara el shebang
  (`sh -n` o `bash -n`) — `ci_fail`.
  Además, si declara `#!/bin/sh` pero solo pasa con `bash`, el shebang miente y
  es `ci_fail`:
  en Ubuntu `/bin/sh` es dash.
- **Permisos 0755 en el árbol** — `ci_fail`.
  `dpkg-deb --build` hornea el modo tal cual está en disco;
  sin `+x`, dpkg no puede ejecutar el script.
- **Despacho por el argumento de dpkg** (`case "$1" in … esac`) — `ci_warn` si
  no lo hace.
  Un `if [ "$1" = configure ]` funciona y se reconoce como tal, pero un `case`
  hace explícito qué verbos se ignoran.
- **Estado de salida final**:
  `exit 0` explícito, o un cierre de estructura (`esac`/`fi`/`done`), que
  también devuelve 0 si no se toma ninguna rama.
  Cualquier otra cosa es `ci_warn` indicando cuál es la última línea
  ejecutable.

Por qué es `ci_fail` y no aviso:
un `postinst` roto rompe `apt install` **a medias**, y el paquete queda
`half-configured` — ficheros puestos y revert sin ejecutar, que es el peor
estado posible en este repo.

### 4. Campos obligatorios y formato Debian del `control`

- Presencia de `Package`, `Version`, `Architecture`, `Maintainer`,
  `Description`.
- `Package` igual al nombre del directorio
  (los build scripts componen el nombre del `.deb` con el directorio y
  empaquetan el campo).
- Sin CRLF;
  aviso si el fichero no termina en salto de línea.
- **Formato de `Description`**:
  la sinopsis va en la misma línea del campo;
  el cuerpo lleva líneas que empiezan por un espacio;
  los párrafos se separan con una línea que es **exactamente** `" ."`.
  Una línea vacía dentro de la descripción corta el campo y `dpkg-deb` rechaza
  el resto: es `ci_fail`.
- Sinopsis de más de 80 caracteres: `ci_warn`.

### 5. Convención de nombres

Userspace se llama `aorus-egpu-*` (CLAUDE.md), y los ejecutables instalados en
`usr/bin`/`usr/sbin` heredan la regla
(también vale el prefijo a secas, `aorus-egpu`, para el CLI principal de un
paquete).

**`egpu-tb-fix` es la excepción conocida y documentada**, y la etapa la
reconoce explícitamente en vez de marcarla:
es anterior a la convención y es el único paquete verificado en vivo, así que
renombrarlo sería cambiar lo único que funciona
(ver [`packages/README.md`](./packages/README.md)).

### 6. Coherencia de versión con el build script

Cada árbol de `packaging/` debe tener un `scripts/build-*.sh` que lo
construya (si no, el paquete no es reproducible: `ci_fail`), y ese script debe
nombrar el `.deb` con la versión **sacada del `control`**, no escrita a mano.
Si hay un `.deb` en `dist/`, se compara su nombre y su campo `Version` con el
`control`:
un descuadre entre el nombre y el contenido es `ci_fail`;
un `.deb` viejo con otra versión en el nombre es `ci_warn`
(`dist/` está gitignorado y `make clean` lo limpia).

### 7. Gate R4 — la GPU interna nunca es diana

Es el invariante de seguridad más importante del proyecto.
La eGPU externa es `10de:2d04`;
la interna es `10de:2c39` y **nunca** es un target válido.
Tocarla ya rompió la máquina una vez (Xid 79 durante un resume RTD3/GC6
normal), y la regla vive en
[`../src/domain/target.sh`](../src/domain/target.sh) para que esté testeada una
sola vez.

La etapa escanea los ficheros de shell del payload de los paquetes **y de
`src/`** — `src/` es el payload real de `forensics` y `overclock`, porque
`scripts/lib/bundle.sh` lo copia a `usr/lib/aorus-egpu/` en tiempo de build, y
sin escanearlo esos dos paquetes quedarían sin revisar.
Busca tres cosas:

- **`nvidia-smi` dirigido por ÍNDICE de GPU** (`-i 0`, `-i 1`, `--id=0`):
  `ci_fail`.
  Los índices se reordenan entre arranques, así que un `-i 0` que hoy apunta a
  la eGPU mañana apunta a la interna.
  Es exactamente así como se acabaría tocando lo que no se puede tocar.
  Lo correcto es el PCI bus-id;
  `gpu_find_by_device_id` devuelve la cadena exacta que `-i` acepta.
  Un `-i "$algo_index"` (variable cuyo nombre suena a índice) es `ci_warn`:
  no prueba nada por sí solo, pero es la pista.
- **`2c39` fuera de una guarda de aborto**: `ci_fail`.
  El device-id de la interna solo puede aparecer como constante prohibida o en
  una comprobación que **aborta** (`domain_target_is_internal`), nunca como
  diana de una acción.
- **Escrituras dirigidas a la dirección PCI de la interna** (`01:00.0`):
  `setpci` contra ella, o un `remove`/`rescan`/`reset`/`power/control` de su
  nodo sysfs.

Y al revés:
si el device-id de la eGPU (`2d04`) no apareciera por ningún sitio, el
targeting por device-id no existiría y R4 no estaría implementado — eso es
`ci_warn`.

### 8. `nvidia-smi` siempre acotado por `timeout`

Toda invocación en el payload debe ir envuelta en `timeout`;
las que no, `ci_warn` con fichero y línea.

Por qué:
un eGPU semi-roto cuelga `nvidia-smi` en estado-D indefinidamente y arrastra al
servicio que lo llamó;
martillearlo lo deja *wedged*.
El patrón del repo es el de
[`../src/adapters/gpu/nvidia-smi.sh`](../src/adapters/gpu/nvidia-smi.sh):
`_smi() { timeout "$AORUS_SMI_TIMEOUT" nvidia-smi "$@"; }`, y un `rc` 124
obliga a abortar sin reintentar.

La detección mira **posición de comando**:
un `nvidia-smi` que solo aparece dentro de un mensaje o de un comentario no se
marca, y `command -v nvidia-smi` se descarta porque es una comprobación de
existencia, no una invocación.

### 9. Paquetes SUPERSEDED

- `aorus-egpu-config` y `aorus-egpu-nvidia-dkms` deben llevar `[SUPERSEDED]` al
  principio de la sinopsis — `ci_fail` si falta.
  Es el único aviso que ve quien lee `apt show` antes de instalar.
- `aorus-egpu-config` debe declarar `Conflicts: egpu-tb-fix` — `ci_fail` si
  falta.
  El conflicto es **real**, no burocrático:
  los dos reasignan el BAR0 desde reglas udev y se pisarían.
- `aorus-egpu-nvidia-dkms` debe seguir declarando su **deuda de versión** en la
  descripción — `ci_fail` si desaparece.
  Sus 35 parches están escritos contra 595.71.05 y el driver instalado es el
  stock 595.99.02:
  los módulos no cargarían.
  Si alguien borra ese aviso sin rebasar los parches, el paquete vuelve a
  parecer instalable.

### 10. Árboles de payload generados, fuera de git

`packaging/aorus-egpu-overclock/usr/lib/aorus-egpu/`,
`packaging/aorus-egpu-forensics/usr/lib/aorus-egpu/` y los binarios que
`scripts/lib/bundle.sh` deja en `usr/sbin/` son **generados**.
Que `git ls-files` liste alguno es `ci_fail`:
significaría que hay una copia versionada de `src/`, y entonces ya no hay una
única fuente de verdad —
el `.deb` se construiría con la copia vieja y nadie se daría cuenta.

Además se comprueba que `.gitignore` los cubra, como `ci_warn`:
hoy pueden no estar versionados y aun así colarse en el próximo `git add -A`
después de un build.
(La comprobación prueba la ruta con y sin barra final porque un patrón como
`…/aorus-egpu/` solo matchea directorios, y el árbol no existe hasta que corre
el build.)

## Etapa 60 — lintian, con dos mecanismos distintos

lintian 2.129 juzga paquetes pensados para **subir a un archivo Debian**.
Estos no van a ningún archivo:
se construyen en esta máquina, para esta máquina.
Parte de lo que dice no aplica, y hay que separar dos cosas que es tentador
mezclar:

**Exclusión** —
la etiqueta no puede aplicar **nunca** a este tipo de paquete, o contradice un
invariante del proyecto.
Es una decisión permanente;
la lista vive en la propia etapa, con el motivo al lado de cada una.

**Baseline** —
la etiqueta **sí** aplica y el hallazgo concreto está aceptado hoy.
Se apunta en [`../ci/baselines/lintian-known.txt`](../ci/baselines/lintian-known.txt)
y la etapa solo falla si **empeora**.

La diferencia importa:
una exclusión dice "esta regla no es para nosotros";
el baseline dice "esta regla sí, y de momento la incumplimos tanto".
Mezclarlas es cómo un CI acaba en verde sin comprobar nada.

### Etiquetas excluidas, y por qué

| Etiqueta | Por qué no aplica |
|---|---|
| `file-in-etc-not-marked-as-conffile` | **Invariante inverso.** Es la etiqueta que choca con la regla nº 1 del repo: aquí ningún fichero de `/etc` es conffile, a propósito, para que `apt remove` lo borre de verdad. La etapa 50 comprueba justamente lo contrario. |
| `no-copyright-file` | Requisito de archivo (Policy 12.5) para paquetes que se redistribuyen. El repo tiene `LICENSE` en la raíz y estos `.deb` no se publican. |
| `no-changelog` | Lo mismo: el historial de versiones es el git de este repo, no un `changelog.gz` dentro del paquete. |
| `changelog-file-missing-in-native-package` | La misma etiqueta con otro nombre en otras versiones de lintian; se excluye para que la decisión no dependa de la versión instalada. |
| `no-manual-page` | Las herramientas se documentan en `docs/` y con `--help`. Una man page de un paquete local no la lee nadie, y mantenerla sería documentación duplicada que se desincroniza. |
| `extended-description-line-too-long` | Las descripciones de este repo son expedientes forenses deliberados (el `control` de `aorus-egpu-config` son 7,9 KB de historia de regresiones). Lo que de verdad rompe `dpkg-deb` —sinopsis y formato del cuerpo— lo valida la etapa 50, que es más estricta que lintian en eso. |
| `depends-on-essential-package-without-using-version` | Higiene de archivo: Debian no quiere `Depends: bash` repetido en miles de paquetes. En un paquete local, listar `bash`, `coreutils` y `findutils` documenta qué necesita el payload y no cuesta nada. |
| `maintainer-script-calls-systemctl` | lintian espera maintainer scripts generados por debhelper (`deb-systemd-invoke`). Estos se escriben a mano y **recargar systemd/udev es el mecanismo de reversibilidad**: es el comportamiento buscado, no un descuido. |
| `maintainer-address-causes-mail-loops-or-bounces` | El `Maintainer` es el dueño de la máquina, no un buzón del archivo Debian. |

Qué **no** se excluye, aunque sería cómodo:

- `maintainer-address-malformed` y `maintainer-address-missing` siguen activas.
  Hoy no disparan, y un `Maintainer` malformado hace que `apt` muestre basura:
  no hay motivo para taparlas.
- `extended-description-is-empty` sigue activa:
  es una malformación real, no una cuestión de estilo.
- `non-standard-dir-perm`, `script-not-executable`, `udev-rule-in-etc`,
  `systemd-service-in-odd-location`, `arch-independent-package-contains-binary-or-object`,
  `missing-dependency-on-libc`, `unstripped-binary-or-object` y
  `command-with-path-in-maintainer-script` **aplican perfectamente** a un
  paquete local.
  Son permisos, rutas y dependencias, que es lo que sí importa aquí.
  Van al baseline, no a la lista de exclusiones.

La etapa comprueba también que cada etiqueta excluida **siga existiendo** en el
lintian instalado (`lintian-explain-tags`), y avisa si no:
una exclusión obsoleta es una regla que creías tapada y ya no tapa nada.
El filtrado se hace sobre la salida y no con `--suppress-tags` porque un nombre
de etiqueta desconocido hace que lintian aborte con `fatal`, y una etapa de CI
que muere por un renombrado aguas arriba no sirve de nada.

### El baseline

Formato: `<paquete> <etiqueta> <nº de apariciones>`.

- Un par (paquete, etiqueta) **nuevo** es `ci_fail`.
- Una etiqueta conocida que aparece **más** veces es `ci_warn`.
- Menos veces, o ausente, es `ci_ok`
  (el paquete puede no estar construido en `dist/`).

Se agrupa por etiqueta y no por fichero a propósito:
con el detalle completo, añadir un fichero a `src/` dispararía un fallo nuevo
por cada `script-not-executable` del payload ensamblado, que es ruido;
con la cuenta, un problema **de otra clase** sigue siendo rojo y el crecimiento
de uno conocido queda visible en ámbar.

Regenerarlo después de decidir que un hallazgo nuevo se acepta:

```bash
CI_LINTIAN_UPDATE_BASELINE=1 ci/60-lintian.sh
```

El baseline no bendice nada:
es la deuda **medida**, para que no crezca sin que se vea.
El motivo de cada línea se documenta aquí, no en el fichero.

## Estado el 2026-11-02 (instantánea)

Con los cuatro `.deb` que se pueden construir hoy:

- **`egpu-tb-fix` 1.5.0 queda completamente limpio**:
  8 etiquetas, las 8 excluidas, 0 que evaluar.
  El paquete que hace funcionar la eGPU no tiene ni un hallazgo real.
- `aorus-egpu-forensics` y `aorus-egpu-overclock` arrastran `non-standard-dir-perm
  0775 != 0755` en sus directorios.
  Sus build scripts normalizan los **ficheros** (`find -type f -exec chmod
  0644`) pero no los **directorios**;
  `scripts/build-tb-fix.sh` sí hace el `find -type d -exec chmod 0755`, y por
  eso es el único sin el aviso.
- `aorus-egpu-forensics` empaqueta el binario compilado `egpu-bandwidth` dentro
  de un paquete `Architecture: all`
  (`arch-independent-package-contains-binary-or-object`,
  `missing-dependency-on-libc`, `unstripped-binary-or-object`).
  Es deliberado — viaja solo si está compilado — pero el paquete debería ser
  `Architecture: amd64` cuando lo lleva.
- `aorus-egpu-config` (SUPERSEDED) instala sus units en
  `/etc/systemd/system/` y sus reglas en `/etc/udev/rules.d/`
  (`systemd-service-in-odd-location`, `udev-rule-in-etc`).
  Los paquetes nuevos usan `usr/lib/…`, que es lo correcto:
  la lección está aprendida y el archivo lo conserva como estaba.
- Avisos abiertos de la etapa 50:
  seis invocaciones de `nvidia-smi` sin `timeout` en el payload de
  `aorus-egpu-config` (`aorus-egpu-status`, `aorus-egpu-connect`,
  `aorus-egpu-fix-bar0`), y el `postinst` de `egpu-tb-fix`, que filtra `$1` con
  un `if` en vez de un `case`.

## Lo que estas etapas NO comprueban

- **No instalan nada.**
  Que el `postinst` sea sintácticamente válido e idempotente *por inspección*
  no demuestra que `apt install` + `apt remove` devuelva la máquina a su
  estado.
  Eso sigue siendo una prueba manual con la caja enchufada.
- **No construyen paquetes.**
  La etapa 60 se omite (77) si `dist/` está vacío.
- **El gate R4 se comprueba por lectura de código, no por comportamiento.**
  Los tests del dominio (`tests/run.sh`) prueban los predicados;
  estas etapas buscan los patrones peligrosos en el payload.
  Un targeting incorrecto que no se parezca a `-i <n>`, a `2c39` ni a `01:00.0`
  no se detectaría.
- **`aorus-egpu-nvidia-dkms` casi no se mira.**
  Su payload (`usr/src/<nombre>-<versión>/`) lo stagea
  `scripts/build-dkms.sh` clonando el upstream, y no está presente al correr
  el CI;
  solo se revisan su `control` y sus maintainer scripts.
  El paquete además necesita un rebase de sus 35 parches antes de volver a ser
  instalable.
- **La deuda del baseline no se arregla sola.**
  Las líneas de `lintian-known.txt` son problemas reales aceptados;
  quitarlos de ahí es trabajo de quien toque esos build scripts.
