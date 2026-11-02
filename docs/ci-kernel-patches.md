# CI: validación de los parches del kernel

Etapa: [`ci/40-kernel-patches.sh`](../ci/40-kernel-patches.sh).
Baseline: [`ci/baselines/checkpatch-known.txt`](../ci/baselines/checkpatch-known.txt).

`kernel/patches/` contiene 37 parches activos (`0001`…`0038`, con el `0019`
desactivado en `kernel/patches/disabled/`) y dos parches retirados en
`kernel/patches/.disabled-for-rollback/`.
Son diffs contra el árbol upstream de
[NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
en el tag `595.71.05`;
el repo **no** contiene la fuente de NVIDIA, solo los diffs.
`scripts/build-dkms.sh` clona ese árbol y los aplica en orden.

Esa asimetría es la que define la etapa:
todo lo que se comprueba aquí se comprueba **sin** el árbol upstream, porque
clonarlo son ~1 GB de red que un CI local no debe gastar.
La única sección que sí lo necesita es opcional y se omite si el clon no está
ya cacheado.

```bash
ci/40-kernel-patches.sh                       # validar
CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh # refijar el baseline de checkpatch
CI_PATCH_APPLY=0 ci/40-kernel-patches.sh      # sin la aplicación real de la serie
```

Códigos de salida del contrato de etapa:
`0` pasa, `1` falla, `77` omitida por falta de herramienta.
En la práctica esta etapa nunca devuelve `77`:
las secciones 1 a 5 solo necesitan `awk`, `grep` y `sed`, así que siempre hay
algo que ejecutar.

## Qué comprueba

### 1. Integridad de la serie

- Hay exactamente `EXPECTED_ACTIVE` parches activos (hoy 34).
  Es un invariante escrito en la etapa a propósito:
  añadir o retirar un parche obliga a tocar esa línea, y el cambio aparece en
  el diff de la revisión en vez de pasar inadvertido.
- Nada que no sea `.patch` cuelga de `kernel/patches/`.
- Todos los nombres siguen `NNNN-descripcion.patch`.
- No hay números duplicados entre los activos.
- `disabled/` contiene exactamente los números declarados en
  `EXPECTED_DISABLED_NUMS` (hoy `0019`).
- Ningún número activo colisiona con uno desactivado.
- La unión de activos y desactivados es **contigua**:
  `0001`…`0035` sin huecos.
  Un hueco significa un parche borrado sin dejar rastro;
  `.disabled-for-rollback/` es archivo documentado y queda fuera del cálculo,
  por eso sus números (`0014`, `0015`) pueden repetir los de parches vivos.
- La excepción de `--recount` declarada en la etapa coincide con la que
  `scripts/build-dkms.sh` aplica de verdad.
  Si divergen, el CI perdonaría un parche que el build rechaza (o al revés), y
  el `.deb` fallaría con el CI en verde.

### 2. Sanidad del formato diff

Dos comprobaciones independientes, una sin herramientas y otra autoritativa.

La primera es un programa de `awk` que no necesita el árbol:
exige al menos un `--- a/`, un `+++ b/` y un `@@ ` por parche, que el número de
cabeceras `---` y `+++` cuadre, y que los contadores de cada hunk
(`@@ -a,b +c,d @@`) casen con el cuerpo que les sigue.
Un hunk se cierra en el momento exacto en que sus dos contadores se satisfacen,
así que un contador mal puesto se delata solo:
el hunk acaba antes de tiempo y la línea siguiente sale como «fuera de hunk»,
o se come la cabecera del fichero siguiente.

La segunda es `git apply --numstat`, que calcula las líneas tocadas **sin**
necesitar los ficheros destino.
`git apply --check` no sirve para esto:
exige que los ficheros existan, y aquí no existen.
`lsdiff`/`diffstat` harían el mismo papel, pero `git` ya es dependencia dura de
`scripts/build-dkms.sh`, así que usar el mismo binario que el build evita que
el CI valide con un parser distinto del que aplica.

**Excepción conocida:**
el parche `0032` se escribió a mano y los contadores de sus seis hunks quedaron
mal, así que `git apply` lo rechaza como *corrupt patch*.
`scripts/build-dkms.sh` lo aplica con `--recount`, que infiere los contadores
del cuerpo del parche sin dejar de validar el contexto.
La etapa conoce la excepción y la reporta como **aviso**, no como fallo:
el parche aplica, pero sigue arrastrando la deuda.
Si algún día deja de necesitar `--recount`, la etapa avisa de lo contrario
(que la excepción ya se puede quitar de los dos sitios).
Un parche distinto con los contadores mal **falla**:
el build solo pasa `--recount` a los parches de su propia lista.

### 3. Rutas tocadas

Todo parche debe tocar solo rutas plausibles del árbol upstream:
`kernel-open/**`, `src/**`, `version.mk`, `Kbuild`, `Makefile`.
Cuidado con la homonimia:
el `src/` de un parche es `src/nvidia/` del árbol NVIDIA, **no** el `src/`
hexagonal de este repo.
Una ruta fuera de la lista significa que el parche no es para este árbol, o que
se colaron ficheros del repo (`packaging/`, `docs/`…), y es **fallo**.

Hoy los 34 parches tocan 23 ficheros, todos dentro de `kernel-open/`,
`src/nvidia/` o `version.mk`.

### 4. Convención de identificadores

[`CLAUDE.md`](../CLAUDE.md) fija, para el código del driver:
`tb_egpu_*` en funciones y variables, `NVreg_TbEgpu*` en parámetros del módulo
y `TB_EGPU_*` en macros.
La etapa busca desviaciones **solo en las líneas añadidas** (las que empiezan
por `+`) y **solo en identificadores de C**:
antes de buscar quita los strings y los comentarios, porque un comentario o un
mensaje de log sí puede decir «AORUS» — la convención es para símbolos, no
para prosa.
`aorus_egpu_*` está permitido: son valores de `driver_override` de userspace,
no identificadores del driver.

Es **aviso**, no fallo.
Renombrar un símbolo exportado del driver es un cambio de ABI para los parches
que lo consumen (`0032` llama a lo que declara `0030`), así que se arregla con
un parche de renombrado deliberado y no al paso de otro cambio.

### 5. Procedencia

Cada lever debería explicar qué hace y por qué.
La etapa acepta cualquiera de las dos formas que usa la serie:
un comentario de C añadido junto al cambio, o una cabecera `Subject:` con
cuerpo al principio del `.patch`.
Un parche sin ninguna de las dos es **aviso**.

### 6. `checkpatch.pl` contra baseline

Es el gate de calidad de verdad.
Ver [la sección dedicada](#checkpatchpl-flags-exclusiones-y-baseline).

### 7. Aplicación real de la serie (opcional)

Si `scripts/build-dkms.sh` ya dejó el clon upstream cacheado en `build/ogkm`,
la etapa aplica los 34 parches en orden sobre él y comprueba que entran todos
(con `--recount` solo para `0032`, igual que el build).
Es la única comprobación que valida el **contexto** de los diffs y no solo su
forma.

Se aplica en sitio y se restaura al salir
(`git checkout -- . && git clean -fdq`),
porque duplicar el árbol costaría otro GB de disco y el build script hace
exactamente ese mismo reset antes de cada compilación.
Para no pisar trabajo de nadie, la sección se omite si el cache tiene cambios
sin commitear.
También se omite si `version.mk` del cache no está en la versión que declara el
build script:
sin esa guarda, un cache en otro tag daría un fallo de aplicación que parecería
culpa del parche cuando el problema es el árbol base.

**Nunca se clona nada.**
Sin cache, la sección se omite con la instrucción de cómo generarlo.

### 7b. Aplicación de la mitad `kernel-open` sobre el driver instalado

La sección 7 es la buena, y vive en `skip` **permanente**:
casi nadie tiene el clon de ~1 GB cacheado.
Un `skip` permanente es un agujero —
la serie puede dejar de aplicar y el CI sigue en verde —
y el agujero se hizo visible cuando una revisión externa reportó
*"`0032` no aplica, el paquete no se puede construir"*
y el CI no tenía forma ni de confirmarlo ni de desmentirlo.

Esta sección cierra la mayor parte de ese hueco **sin descargar nada**.
El paquete `nvidia-kernel-source-NNN-open` de Canonical ya deja en
`/usr/src/nvidia-<ver>/` el árbol `kernel-open` **aplanado**
(su contenido en la raíz, sin el prefijo `kernel-open/`), unos 29 MB que ya
están en disco.

El truco está en no hacerle cirugía al diff.
El árbol se copia dentro de `<tmp>/kernel-open/`, que reproduce el layout
upstream, y el parche se aplica **entero** con `-p1` y
`--include='kernel-open/*'`.
Filtrar con `--include` es trabajo de git, que entiende cabeceras
`diff --git`, diffs desnudos, `new file mode` y creaciones con
`--- /dev/null`.

Extraer la mitad `kernel-open` a mano con `awk` o `filterdiff` parece
equivalente y **no lo es**:
pierde las líneas de metadatos y produce fallos fantasma indistinguibles de un
defecto del parche.
Aplicar con `-p2` sobre el árbol plano tiene el mismo problema por otra vía:
`/dev/null` no se puede despojar de dos componentes, así que toda creación de
fichero falla.
Las dos trampas se recorrieron antes de dar con `--include`, y las dos
producían un "`0032` no aplica" que no era real.

Cobertura actual, sobre `595.99.02` instalado:

| Resultado | Parches |
|---|---|
| aplican en orden | 26 |
| fallan solo por la cadena de versión (`0005`, `0025`) | 2 |
| sin mitad `kernel-open` (solo RM, `src/nvidia/**`) | 9 |

Lo que **no** cubre, y no lo disimula:

- La mitad RM (`src/nvidia/**`).
  Ningún paquete de Canonical entrega ese árbol, así que esos 9 parches aquí
  solo se cuentan.
- `version.mk`, que upstream vive en la raíz del repo y no dentro de
  `kernel-open/`.
- El árbol instalado puede no ser del tag de la serie.
  Por eso la sección **clasifica** los fallos en vez de tratarlos todos igual.

La clasificación es la pieza que le da valor:

- `VERSION_DRIFT_OK="0005 0025"` son los parches cuyo único ancla es
  `NV_VERSION_STRING` hardcodeado en `Kbuild`.
  Si el árbol no es el del tag, fallan **por diseño** y se degradan a `WARN`.
- Cualquier otro fallo es `FAIL`, porque un parche cuyo contexto lo añade un
  parche **anterior** de la serie no depende de la versión del árbol:
  falla contra cualquier tag.

Variables:
`CI_PATCH_APPLY_LOCAL=0` la desactiva;
`CI_LOCAL_TREE=<ruta>` apunta a otro árbol.

### 8. `tools/lint-identifiers.sh`: por qué no se invoca

El script existe y comprueba justo lo que interesa
(`NVreg_Aorus*`, `aorus_lever_*`, `AORUS_*`…),
pero su lista de rutas es del layout **anterior** al monorepo:
busca `./patches/*.patch`.
Los parches viven hoy en `kernel/patches/`, así que su `find` no selecciona
ninguno y el script termina en verde anunciando `0 files scanned` — verde
vacío, que es peor que rojo.

Por eso esta etapa **no** lo invoca y hace la comprobación por su cuenta
(sección 4).
La detección es dinámica, no una decisión congelada:
la etapa mira si el script menciona `kernel/patches`, y en cuanto alguien
arregle sus rutas pasa a ejecutarlo y a propagar su resultado.

Arreglar `tools/lint-identifiers.sh` para el layout del monorepo queda como
deuda aparte;
afecta a más superficie que los parches
(`packaging/`, `src/`, unidades systemd), así que no es un cambio para esta
etapa.

## `checkpatch.pl`: flags, exclusiones y baseline

### Dónde se busca

Por orden:
`/usr/src/linux-headers-$(uname -r)/scripts/checkpatch.pl`,
`/usr/src/linux-oem-*/scripts/checkpatch.pl`,
`/usr/src/linux-headers-*/scripts/checkpatch.pl`,
y por último `command -v checkpatch.pl`.
Si no hay ninguno la sección se **omite**, no falla:
no tener los headers del kernel instalados no es un defecto de los parches.

### Se le pasa el parche por *stdin*, no por ruta

Esto no es un detalle de estilo, es un bug que hay que esquivar.
`checkpatch.pl` decide si lo que recibe es un parche o un fichero fuente
llamando a su `git_is_single_file()`:
si la ruta que le das la rastrea git, entra en modo `--file` y trata el
`.patch` **como si fuera código**, prefijando cada línea con `+`.
El resultado es basura:

```console
$ checkpatch.pl --no-tree --no-signoff kernel/patches/0001-*.patch
ERROR: trailing whitespace
#10: FILE: kernel/patches/0001-...patch:10:
+ $
```

Ese «trailing whitespace» es una línea de **contexto en blanco del propio
diff**.
Por stdin no hay ruta que confundir, checkpatch analiza en modo parche, y los
hallazgos salen con la ruta y el número de línea del fichero **destino**, que
es lo que se quiere revisar.

### Flags

```text
--no-tree          no estamos dentro de un árbol del kernel
--no-signoff       la serie es estilo quilt, no se manda a una lista de correo
--terse            una línea por hallazgo
--show-types       con el nombre del tipo, para poder razonar sobre él
--no-summary       el recuento lo hace la etapa
--ignore <lista>   ver abajo
```

`--max-line-length` se deja en el **default del kernel (100)**.
Subirlo sería tentador — las líneas largas de la serie son casi todas strings
de log de `NV_PRINTF`, y la más larga llega a 136 columnas — pero el baseline
ya las absorbe y subir el límite escondería también las líneas largas
**nuevas**.
El baseline es un trinquete; el límite de longitud no tiene por qué ser el
mismo instrumento.

### Qué se excluye y por qué

En bruto, los 34 parches dan **2893 hallazgos** (1059 errores, 1834 avisos).
Las exclusiones bajan eso a **295** (41 errores, 254 avisos).
Los 2598 excluidos caen en dos familias, y ninguna se excluye «porque
dispara»:

**(a) Estilo de la casa NVIDIA.**
El árbol destino indenta con **4 espacios** y pone la llave de apertura en su
propia línea (Allman).
Un parche tiene que casar con el fichero que edita:
«usa tabs» o «la llave va en la línea anterior» no son defectos aquí, son
instrucciones para romper la consistencia del fichero.
No es una suposición, se comprueba dentro del propio repo:
las líneas de **contexto** de los parches (las que empiezan por espacio, o sea
código upstream sin tocar) están indentadas con espacios.

- `LEADING_SPACE` — 1513 casos.
  El árbol indenta con espacios.
- `CODE_INDENT` — 945 casos.
  Lo mismo visto del otro lado:
  «debería usar tabs» no aplica a este árbol.
- `OPEN_BRACE` — 69 casos.
  Llaves Allman, estilo del árbol.
- `SUSPECT_CODE_INDENT` — 52 casos.
  Heurística que asume indentación con tabs;
  es consecuencia directa de las dos anteriores.
- `ELSE_AFTER_BRACE` — 2 casos.
  `}` y `else` en líneas distintas: la misma regla Allman.
- `POINTER_LOCATION` — 2 casos.
  El doble espacio que denuncia viene de la columna de `NV_API_CALL`.
- `NEW_TYPEDEFS` — 2 casos.
  No son typedefs nuevos:
  son `typedef struct nv_linux_state_s nv_linux_state_t;`, una declaración
  adelantada de un tipo que **ya existe** upstream, puesta en una cabecera
  nueva para no arrastrar `nv-linux.h`.

**(b) Política de envío a mainline.**
La serie se aplica con `git apply` desde `scripts/build-dkms.sh` y nunca se
manda a una lista de correo:
`Signed-off-by`, el formato del `Subject`, la longitud del cuerpo del commit, o
«¿hay que actualizar MAINTAINERS?» no tienen destinatario.
`MAINTAINERS`, de hecho, no existe en el árbol de NVIDIA.

- `COMMIT_LOG_LONG_LINE` — 11 casos.
  Formato del mensaje pensado para el correo.
- `FILE_PATH_CHANGES` — 2 casos.
  No hay `MAINTAINERS` que actualizar.
- `MISSING_SIGN_OFF`, `NO_AUTHOR_SIGN_OFF`, `BAD_SIGN_OFF` — 0 casos.
  Ya cubierto por `--no-signoff`;
  se declaran igual para que no reaparezcan.
- `EMAIL_SUBJECT`, `GIT_COMMIT_ID`, `UNKNOWN_COMMIT_ID`, `COMMIT_MESSAGE`,
  `COMMIT_LOG_USE_LINK`, `PREFER_LORE_ARCHIVE` — 0 casos.
  Misma familia, declaradas por adelantado:
  aparecerían en cuanto alguien añada una cabecera de commit a un parche.

### Qué NO se excluye, aunque dispare

Estos hallazgos se quedan **dentro** del baseline, visibles, porque son
discutibles o son deuda real — no ruido categórico — y esconderlos sería
mentir sobre el estado de la serie:

- `SPDX_LICENSE_TAG` (4):
  los cuatro ficheros nuevos que añade la serie
  (`nv-qwatchdog.c/.h`, `nv-lever-m-recover.c/.h`)
  llevan una cabecera explicativa pero **no** una etiqueta de licencia, que sí
  es la convención del árbol de NVIDIA.
  Es deuda, no ruido.
- `BAD_COMMIT_SEPARATOR` y `DIFF_IN_COMMIT_MSG` (1 cada uno, parche `0033`):
  el mensaje entra directo en `--- a/…` sin el separador `---`.
  `git apply` lo digiere, pero el aviso dice literalmente «some tools may have
  problems applying this» y eso es información, no molestia.
- `BLOCK_COMMENT_STYLE` (100) y `SPLIT_STRING` (51):
  son decisiones de estilo del propio repo, no del árbol upstream.
  `SPLIT_STRING` además es mutuamente excluyente con `LONG_LINE_STRING`:
  partir un string de log dispara el primero, no partirlo dispara el segundo.
  Que las dos caras estén contadas deja la elección a la vista.
- `SPACING` (27), `TRAILING_STATEMENTS` (11), `INITIALISED_STATIC` (5),
  `GLOBAL_INITIALISERS` (2), `LINE_SPACING` (34), `LONG_LINE*` (37),
  `DEVICE_ATTR_RO`/`WO` (10), `EMBEDDED_FUNCTION_NAME` (3), `VOLATILE` (2),
  `AVOID_EXTERNS` (2), `BRACES` (2), `FUNCTION_ARGUMENTS` (2),
  `TYPO_SPELLING` (1):
  hallazgos legítimos, de arreglo barato, que no justifican tumbar el CI hoy.

### El baseline, y por qué hay baseline

Con 295 hallazgos preexistentes, hacer que el CI salga rojo por ellos lo
convierte en un semáforo que nadie mira.
Y bajarlos a cero no es el objetivo:
esto es un fork de un driver fuera del árbol, con el estilo de la casa NVIDIA,
y la mayoría de lo que queda es cosmético.

Así que la regla es un **trinquete**:
`ci/baselines/checkpatch-known.txt` guarda el recuento por parche, y la etapa
**falla solo si un parche empeora**.

```text
# Formato:  <fichero.patch> <errores> <avisos>
0023-mode-b-telemetry-S1-S2-S3.patch 32 28
0024-Lever-M-recover-Commit3-hardening.patch 2 34
```

Comportamiento:

- Un parche sube de errores o de avisos: **FAIL**.
- Un parche baja: aviso, refresca el baseline.
- Parche nuevo sin línea en el baseline, con hallazgos:
  aviso, revísalos a mano y fija su línea.
- Línea del baseline que ya no tiene parche: aviso, baseline obsoleto.
- Falta el fichero de baseline:
  **FAIL**, con la orden para generarlo.

Encima del baseline hay una **lista fatal**:
21 tipos que son defecto de verdad y no estilo
(`ASSIGN_IN_IF`, `UNNECESSARY_ELSE`, `DEFAULT_NO_BREAK`, `MEMSET`,
`COMPLEX_MACRO`, `MACRO_ARG_PRECEDENCE`, `MACRO_ARG_REUSE`,
`MULTISTATEMENT_MACRO_USE_DO_WHILE`, `NON_OCTAL_PERMISSIONS`,
`UNSPECIFIED_INT`, `MALFORMED_INCLUDE`, `OPEN_ENDED_LINE`, `SIZEOF_ADDRESS`,
`SIZEOF_PARENTHESIS`, `ALLOC_*`, `HEXADECIMAL_BOOLEAN_TEST`, `STRCPY`,
`VSPRINTF_SPECIFIER_PX`, `MEMORY_BARRIER`).
Fallan **siempre**, estén o no en el baseline.
Hoy la serie da cero en todos, así que la lista es un trinquete limpio:
un parche nuevo no puede colar ninguno, y «estaba en el baseline» no es
excusa.

## Cómo interpretar los fallos

### `empeoran respecto al baseline de checkpatch: N parche(s)`

El mensaje trae el recuento nuevo y el del baseline.
Para ver **qué** hallazgo es nuevo, el propio fallo imprime la orden exacta;
en resumen:

```bash
perl /usr/src/linux-headers-$(uname -r)/scripts/checkpatch.pl \
  --no-tree --no-signoff --terse --show-types \
  --ignore "$(sed -n 's/^#   --ignore //p' ci/baselines/checkpatch-known.txt)" \
  - < kernel/patches/00NN-....patch
```

Lo normal es arreglar el hallazgo en el parche.
Refijar el baseline (`CI_CHECKPATCH_REGEN=1 ci/40-kernel-patches.sh`) es para
cuando el aumento es legítimo, y el diff del baseline queda en el commit para
que se vea quién subió el techo y cuánto.

### `checkpatch encontró defectos de los que NO se perdonan`

Uno de los 21 tipos de la lista fatal.
No se refija el baseline:
se arregla el parche.

### `contadores de hunk incoherentes`

Si es el `0032`, es **aviso** y está documentado arriba.
En cualquier otro parche es fallo:
corrige las cabeceras `@@ -a,b +c,d @@`, o — si el parche es correcto y se
escribió a mano — declara la excepción en los **dos** sitios
(`RECOUNT_EXPECTED` en la etapa y el `case` de `scripts/build-dkms.sh`).
La etapa comprueba que las dos listas coinciden, así que declararlo en uno solo
no cuela.

### `rutas fuera del árbol upstream`

El parche toca algo que no existe en `open-gpu-kernel-modules`.
Suele ser un `.patch` generado desde la raíz del repo en vez de desde el árbol
clonado:
los ficheros de `packaging/` o `docs/` no pertenecen a un parche del driver.

### `la serie se rompe en 00NN`

Solo aparece con el cache `build/ogkm` presente y verificado en la versión
upstream correcta.
Los parches anteriores sí aplicaron, así que el conflicto es de **ese** parche
contra el estado que dejan los previos:
hay que rebasarlo, no tocar el árbol.

### `identificadores de C añadidos que se desvían de la convención`

Aviso.
Hoy hay 8, en los parches `0009`, `0023`, `0030` y `0032`:

```text
aorus_uvm_status_at_entry   aorus_read_aer_full    aorus_read_dpc_state
aorus_walk_to_root_port     aorus_uvm_fd_count     aorus_uvm_close_path_diag
aorus_uvm_get_gpu_pdev      (y su uso en 0032)
```

Son el residuo exacto del cambio de nombres que `tools/lint-identifiers.sh`
nació para vigilar, y que se le escapó cuando los parches cambiaron de
directorio.
`aorus_uvm_get_gpu_pdev` se declara en `0030` y se consume en `0032`, así que
renombrarlos es un parche propio, no un apaño.

### `sin explicación de qué hacen ni por qué`

Aviso.
Hoy solo `0005-version-mark-aorus-build.patch`, que es un cambio de dos líneas
en `version.mk` y `kernel-open/Kbuild` para marcar el build:
no lleva comentario de C ni cabecera `Subject:`.

## Qué queda sin comprobar

- **Que los parches compilen.**
  Requiere el árbol upstream y un build de DKMS;
  queda para `scripts/build-dkms.sh`, no para el CI.
- **Que el contexto de la mitad RM (`src/nvidia/**`) case.**
  La mitad `kernel-open` sí se comprueba contra el driver instalado
  (sección 7b), y la serie completa contra el cache `build/ogkm`
  (sección 7) cuando existe.
  Pero el árbol RM no lo entrega ningún paquete, así que para 9 parches
  `git apply --numstat` sigue validando la *forma* del diff y no que las
  líneas de contexto existan.
  Un parche puede estar perfectamente formado y no aplicar.
- **El rebase pendiente de 595.71.05 a 595.99.02.**
  [`docs/what-actually-works.md`](./what-actually-works.md) marca
  `aorus-egpu-nvidia-dkms` como *superseded* precisamente por eso.
  La etapa valida la serie contra la versión que declara
  `scripts/build-dkms.sh`;
  cuando esa versión cambie, la sección 7 empezará a omitirse hasta que el
  cache se resincronice, y el rebase real seguirá siendo trabajo manual.
- **Semántica de los levers.**
  Que un parche gatee de verdad en la eGPU y no en la GPU interna (R4) es una
  propiedad de ejecución;
  se verifica en hardware, no leyendo el diff.
- **`tools/lint-identifiers.sh` sobre el resto del repo.**
  Su `find` apunta al layout pre-monorepo en toda su extensión, no solo en los
  parches;
  esta etapa solo cubre el hueco de `kernel/patches/`.
