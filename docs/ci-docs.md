# Etapa de CI de documentación

`ci/70-docs.sh` es la etapa que audita el markdown del repo.
Comprueba cinco cosas, y solo tres de ellas pueden pintar el CI en rojo.

Ejecutarla:

```bash
ci/70-docs.sh                 # solo esta etapa
ci/run.sh 70                  # igual, a través del orquestador
CI_DOCS_SEMBR_ALL=1 ci/70-docs.sh   # lista entera de avisos de sembr
```

Códigos de salida, iguales que en el resto de etapas:
`0` pasa, `1` falla, `77` omitida por falta de herramientas.

## Qué ficheros audita

Todos los `.md` versionados **más los que aún no están en el índice**,
vía `git ls-files --cached --others --exclude-standard`.

Lo de `--others` no es un detalle:
sin él solo se auditaría lo ya versionado,
y una doc recién creada —la que más falta hace revisar— pasaría invisible.
Se descubrió en vivo con `docs/freeze-forensics.md`,
que quedaba fuera del inventario.

Fuera del árbol de git se cae a `find`,
para que la etapa siga funcionando sobre un tarball exportado.

## Las cinco comprobaciones

| # | Comprobación | Severidad | Por qué esa severidad |
|---|---|---|---|
| 1 | Semantic line breaks (sembr) | aviso | `CLAUDE.md` prohíbe reflowear ficheros existentes sin motivo |
| 2 | Enlaces relativos colgados | **fallo** | un enlace roto es un defecto objetivo, no una opinión de estilo |
| 3 | `markdownlint` | omitida si falta | la herramienta no es una dependencia del repo |
| 4 | Fences de código balanceadas | **fallo** | un `` ``` `` sin cerrar oculta el resto del documento al renderizar |
| 5 | Versiones doc ↔ `DEBIAN/control` | **fallo** | una doc que miente sobre la versión instala lo que no dice |

### 1. Semantic line breaks — AVISO

Busca líneas de prosa con más de una frase.
La convención del repo es [sembr.org](https://sembr.org):
una frase por línea como suelo y una cláusula como techo,
para que `git diff` muestre la cláusula cambiada en vez del párrafo reflowado.
Está documentada en [`CLAUDE.md`](../CLAUDE.md).

**Cómo se arregla:**
parte la línea en el límite de frase.
Con el binario instalado lo hace la herramienta:

```bash
mdslw --max-width=80 docs/mi-fichero.md
```

**Es un aviso y no un fallo a propósito.**
`CLAUDE.md` dice explícitamente que no hay que reflowear ficheros existentes
sin un motivo sustantivo,
porque hacerlo churnea el diff sin beneficio funcional.
Así que el criterio es:
arregla el aviso solo si ya estabas editando ese fichero por otra razón.

Cuando hay más de ocho ficheros con avisos,
la etapa los agrupa en un solo `WARN` ordenado por número de líneas,
recorta el detalle a los veinte primeros
y deja la lista completa detrás de `CI_DOCS_SEMBR_ALL=1`.
Mil avisos sueltos no son una señal, son ruido.

**Qué NO se cuenta como frase nueva,**
para que el aviso no se ahogue en falsos positivos:

- bloques de código delimitados por `` ``` `` o `~~~`
  (se lleva la cuenta de las fences en una máquina de estados,
  no basta con un `grep`);
- tablas, por la misma razón por la que `mdslw` las excluye:
  una fila va obligatoriamente en una línea;
- definiciones de enlace de referencia, bloques HTML y encabezados;
- bloques de código indentados con cuatro espacios o más;
- `code spans` entre backticks, y las URL;
- abreviaturas: `p. ej.`, `etc.`, `vs.`, `e. g.`, `i. e.`, `aprox.`;
- números de versión como `1.5.0` o `595.71.05`,
  y rutas o nombres de fichero como `boltctl.sh`;
- el marcador inicial de una lista numerada,
  que si no haría que `1. Texto` contase como dos frases.

Los dos puntos quedan fuera del criterio a propósito:
`Aviso: El servicio...` es una etiqueta, no dos frases,
y ese patrón es constante en este repo.
El punto y coma solo avisa cuando además la línea pasa de 110 columnas.

### 2. Enlaces relativos colgados — FALLO

Todo enlace markdown relativo tiene que resolver a algo que exista en disco.
Se resuelve relativo al directorio del fichero que lo contiene,
así que `[x](./y.md)` dentro de `docs/research/` apunta a
`docs/research/y.md`.

Se ignoran los enlaces externos (`http`, `https`, `mailto`, `tel`, `data`),
las anclas puras (`[x](#seccion)`),
las rutas absolutas —que no son enlaces de este repo—
y los marcadores de plantilla con `{`, `$` o `%`.
De un enlace con ancla solo se comprueba el fichero, no el ancla.

**Cómo se arregla:**
el fallo lista `fichero:línea -> destino`,
así que la corrección es mecánica.
Las dos causas reales vistas en este repo:

- **el destino se movió.**
  La reestructura a monorepo llevó las docs de investigación a
  `docs/research/`,
  y los enlaces que apuntaban al sitio viejo quedaron colgando.
  Se arreglan rebajando el `../`:
  `../docs/lever-catalog.md` pasa a ser `./lever-catalog.md`.
- **el destino ya no está en el repo.**
  `archive/` y `patches/` desaparecieron en la reestructura.
  Un enlace a algo que no se publica no se arregla recolocándolo:
  se convierte en texto, normalmente un `code span`,
  que informa igual sin prometer un clic que no funciona.

### 3. `markdownlint` — OMITIDA si falta

Comprueba estructura, no prosa:
niveles de encabezado incoherentes, marcadores de lista mezclados,
bloques de código mal formados.
Respeta [`.markdownlint.yaml`](../.markdownlint.yaml),
que desactiva `MD013` (longitud de línea; con sembr la longitud varía por
cláusula) y `MD040`, entre otras.

Se acepta `markdownlint` o `markdownlint-cli2`.
Si solo está `mdl`, la etapa se **omite** y lo dice:
`mdl` no lee `.markdownlint.yaml` sino `.mdlrc`, con otra sintaxis de reglas,
así que correrlo ignoraría nuestras exclusiones
y escupiría cientos de falsos positivos de longitud de línea.

**Cómo se instala:**

```bash
npm install -g markdownlint-cli
# o, sin instalar nada:
npx markdownlint-cli@0.42.0 --config .markdownlint.yaml .
```

Omitir no es fallar.
Un portátil sin node no debe pintar el CI en rojo,
y por eso esta comprobación devuelve `skip` y no `FAIL`.

### 4. Fences de código balanceadas — FALLO

El número de `` ``` `` de cada fichero tiene que ser par.
Un bloque sin cerrar se come todo lo que viene después al renderizar:
media doc invisible, sin ningún aviso del propio markdown.

**Cómo se arregla:**
el fallo dice cuántas fences tiene el fichero.
Al ser impar, falta exactamente una,
y lo más rápido es buscar el último `` ``` `` y mirar qué bloque abre.

### 5. Versiones de la doc contra `DEBIAN/control` — FALLO

[`docs/packages/README.md`](./packages/README.md) es la tabla de verdad única
sobre qué paquete usar,
y tiene una columna `Versión` explícita.
La etapa compara esa columna con el campo `Version:` de cada
`packaging/*/DEBIAN/control`.
Los `control` se **leen**;
esta etapa nunca los modifica.

**Cómo se arregla:**
el fallo dice qué versión declara la tabla y qué versión declara el `control`.
Decide cuál de las dos está mal.
Si acabas de subir la versión de un paquete, la tabla va detrás;
si la tabla lleva razón, lo que está sin actualizar es el `control`.

Además, como **avisos**:

- un paquete de `packaging/` que no aparece en la tabla,
  o que el [README raíz](../README.md) no menciona;
- cualquier `.md` que cite una versión concreta de un paquete
  que no coincide con su `control`.
  Es aviso y no fallo porque una doc puede citar legítimamente una versión
  histórica al narrar una regresión.

## Relación con los hooks de pre-commit

[`.pre-commit-config.yaml`](../.pre-commit-config.yaml) reparte el trabajo así:

| Etapa | Qué lleva | Criterio |
|---|---|---|
| `pre-commit` | `mdslw`, `bash -n`, `shellcheck`, `lint-identifiers`, tests del dominio | milisegundos, y solo sobre los ficheros tocados |
| `pre-push` | `markdownlint`, `ci/70-docs.sh` | necesita red o barre el repo entero |
| `ci/run.sh` | todas las etapas `ci/NN-*.sh` | el barrido completo, con severidad fina |

Esta etapa va en `pre-push` y no en `pre-commit` por una razón concreta:
un enlace roto casi nunca lo rompe el fichero que lo contiene,
lo rompe el commit que **mueve el destino**.
Un hook que solo mirase los ficheros tocados no lo vería nunca.
Hay que barrer.

Instalar los dos ganchos:

```bash
pre-commit install
pre-commit install --hook-type pre-push
```

Los dos hacen falta.
`pre-commit install` a secas no escribe `.git/hooks/pre-push`,
y los hooks de esa etapa no se dispararían nunca.

El hook de `mdslw` se **auto-omite** si el binario no está:
es un binario de Rust que no se empaqueta para Ubuntu
(`cargo install mdslw`),
y una herramienta opcional no debe matar un commit.
`shellcheck` sí es una dependencia dura, porque está en main de Ubuntu.

## Qué no comprueba

Límites declarados, para que nadie confíe en la etapa más de lo que debe:

- **anclas**.
  De `[x](./y.md#seccion)` se comprueba `y.md`, no que exista `#seccion`.
- **enlaces externos**.
  No se piden URLs por red:
  un CI que depende de internet falla por motivos ajenos al repo.
- **enlaces partidos entre líneas por el destino**.
  El texto del enlace sí puede estar en otra línea —el patrón normal en
  sembr—, pero `](` y su `)` tienen que acabar en la misma línea.
- **prosa dentro de bloques HTML**.
  Se salta por completo, así que un `<details>` con párrafos largos no avisa.
- **la columna `Estado`** de las tablas de paquetes.
  Se comprueba la versión, no que el estado de la tabla y el del
  `Description:` del `control` cuenten la misma historia.
