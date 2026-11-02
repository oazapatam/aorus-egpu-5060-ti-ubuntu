# Project conventions for Claude Code

This file is auto-loaded by Claude Code at session start when working in this
repository.
Conventions documented here apply to all work in this repo unless explicitly
overridden in a session.

## Markdown style — semantic line breaks (sembr)

Write all new markdown using semantic line breaks
([sembr.org](https://sembr.org)).
Each line ends at a clause or sentence boundary; the rendered output is
unchanged because markdown collapses single newlines into spaces.

Why:
edits land on a single line, so `git diff` shows only the changed clause instead
of reflowing the whole paragraph.
Code review and prose editing become much cleaner.

Rules:

- Break the line at every period, semicolon, em-dash, and most commas.
- One sentence per line is the floor; one clause per line is the ceiling.
- Don't break inside code fences, tables, link refs, or HTML blocks.
- Don't reflow existing files unless you're editing them for substantive
  reasons.
  Bulk-reformatting churns diffs without functional benefit.
- The `mdslw` tool (`pre-commit run mdslw --all-files`) enforces this on staged
  `.md` files; authoring directly in sembr matches what the tool produces.

The pre-commit hook will reformat staged markdown automatically; authoring in
sembr from the start avoids surprise diffs at commit time.

## Estructura del repositorio y reglas de arquitectura

Este repo existe para producir **paquetes Debian reversibles**.
Todo lo que se instale debe desinstalarse con `apt remove`:
es la restricción principal, porque un intento anterior de instalar a mano dejó
el portátil inestable.

El núcleo sigue **arquitectura hexagonal** (puertos y adaptadores) con
principios **SOLID**, para poder añadir capacidades a la eGPU sin que cada una
reinvente la detección de hardware ni los gates de seguridad.
La explicación razonada está en [`docs/architecture.md`](./docs/architecture.md);
lo que sigue son las reglas de cumplimiento obligatorio.

### Orden de los directorios

```
src/                 núcleo — fuente ÚNICA de lógica
  domain/              reglas puras, sin I/O
  ports/               contratos (*.port.sh)
  adapters/            implementaciones de un puerto (único sitio con I/O)
  app/                 casos de uso (orquestan domain + ports)
  bin/                 entrypoints CLI finos
packaging/           un árbol .deb por paquete — SOLO entrega, cero lógica
scripts/             build-*.sh + lib/bundle.sh (ensambla src/ en el payload)
kernel/              patches/ (levers del driver) + dkms/
tests/               tests del dominio: sin root, sin GPU
tools/               diagnóstico y medición (no se empaqueta)
docs/                arquitectura y paquetes; research/ = investigación histórica
legacy/fedora/       el stack Fedora original, tal cual, como referencia
```

### Regla de dependencias (la que no se negocia)

Las dependencias apuntan **hacia dentro**.
Nadie salta capas:

| Capa | Puede depender de | Nunca de |
|---|---|---|
| `domain/` | nada | ports, adapters, app, I/O de cualquier tipo |
| `ports/` | nada (solo declara) | adapters, app |
| `adapters/` | el puerto que implementa, `domain/` | app, otros adapters |
| `app/` | `domain/`, `ports/` | adapters concretos (se eligen con `aorus_adapter`) |
| `bin/` | `app/` | domain y adapters directamente |
| `packaging/` | nada | **cero lógica**: solo ficheros y maintainer scripts |

Consecuencias prácticas al escribir código nuevo:

- Si una función lee sysfs, invoca `nvidia-smi` o escribe en disco,
  **va en `adapters/`**, nunca en `domain/` ni en `app/`.
- Si una función decide algo (¿es esta la eGPU?, ¿está sano el enlace?,
  ¿cuánto hay que acotar este valor?), **va en `domain/`** y lleva test.
- Los casos de uso cargan adaptadores con `aorus_adapter <puerto> <default>`,
  nunca con un `.` directo a un adaptador concreto.
- `packaging/<pkg>/usr/lib/aorus-egpu/` es **generado** por
  `scripts/lib/bundle.sh`; está gitignorado y no se edita a mano.

### Añadir una capacidad nueva

En este orden, y el test antes del adaptador:

1. `domain/<capacidad>.sh` — las reglas, puras.
2. `tests/run.sh` — los asserts de esas reglas.
3. `ports/<cosa>.port.sh` — el contrato, si hace falta uno nuevo.
4. `adapters/<cosa>/<herramienta>.sh` — la implementación.
5. `app/<capacidad>.sh` — el caso de uso que orquesta.
6. `src/bin/aorus-egpu-<x>` — el entrypoint fino.
7. `packaging/aorus-egpu-<x>/` + `scripts/build-<x>.sh` — la entrega.

### Gates de seguridad: invariantes, no sugerencias

Viven en `domain/` para que sea imposible olvidarlos y estén testeados una sola
vez.

- **R4 — jamás tocar la GPU interna.**
  La externa es `10de:2d04`; la interna `10de:2c39` y nunca es un target
  válido.
  Tocarla ya provocó un Xid 79.
  Toda escritura se dirige por **PCI bus-id**, nunca por índice de GPU (los
  índices se reordenan entre arranques).
  La confirmación topológica se hace con el atributo `removable`, **no**
  subiendo el árbol PCI en busca del driver `thunderbolt`: el controlador TB es
  un *hermano*, no un ancestro, y buscar hacia arriba da un falso negativo.
- **Gate de enlace — nada intrusivo con el enlace degradado.**
  Apretar la tarjeta con el enlace entrenado por debajo de Gen3 congeló el host
  entero.
  "No bindea" es aceptable; "bindea y congela" no lo es.
  El gate juzga por **capacidad negociada** (`pcie.link.gen.max` de
  `nvidia-smi`, vía `gpu_link_gen_max`), **nunca** por `current_link_speed`:
  en reposo la instantánea siempre dice Gen1, así que usarla rechazaba el
  tuning siempre y dejaba `--force` —apagar el gate— como único camino.
  Si la capacidad no se puede leer el veredicto es `unknown` y el gate
  **cierra**.
- **nvidia-smi siempre con `timeout`.**
  Si devuelve 124 (colgado), **abortar sin reintentar**: martillear un eGPU
  semi-roto lo deja wedged en estado-D.

### Medir, no leer registros

Los puentes del túnel Thunderbolt **virtualizan** sus registros PCIe y anuncian
`Gen1 2.5GT/s` sea cual sea la capacidad real.
El mensaje del kernel `"N Gb/s available PCIe bandwidth, limited by 2.5 GT/s"`
lee esos registros virtuales y **no mide nada**.
Leer `lspci` y concluir que había un techo de Gen1 ya costó una investigación
completa que terminó falsificada (hipótesis H18).

Antes de afirmar que existe un techo de ancho de banda, **mídelo**:
`tools/egpu-bandwidth`.
Lo mismo con `current_link_speed`: en reposo marca `2.5 GT/s` porque el enlace
baja de velocidad solo, y sube a `8.0 GT/s` cuando hay tráfico.

### Probar la eGPU sin perder la evidencia

Un cuelgue duro del host pierde el journal, que vive en RAM.
Las pruebas que puedan congelar la máquina se ejecutan **siempre** envueltas:

```bash
sudo aorus-egpu-probe run -- <comando>
```

Cada paso se escribe en disco con `fsync` antes de ejecutarse, así que la última
línea de `10-breadcrumbs.log` es el paso culpable.
Tras reiniciar: `sudo aorus-egpu-postmortem`.
Detalle en [`docs/freeze-forensics.md`](./docs/freeze-forensics.md).

### Estado de los paquetes

Antes de tocar un paquete, comprueba su estado en
[`docs/what-actually-works.md`](./docs/what-actually-works.md).
Resumen:
`egpu-tb-fix` es el principal y el único verificado en vivo;
`aorus-egpu-config` y `aorus-egpu-nvidia-dkms` están **superseded** (archivo
documentado, y el DKMS además necesita rebase de sus 34 parches de 595.71.05 a
595.99.02);
`aorus-egpu-overclock` está **en desarrollo y sin validar en hardware**.

No "arregles" la documentación para que encaje con el catálogo de levers:
el catálogo describe el stack Fedora histórico, y en esta máquina la eGPU
funciona **sin ninguna** de esas palancas.

## Other repo-specific conventions

The full set of conventions is documented across `docs/`; load relevant docs
when the task touches the area:

- Service / file naming:
  `aorus-egpu-*` for userspace, `tb_egpu_*` / `NVreg_TbEgpu*` / `TB_EGPU_*` for
  driver-internal.
  Run `tools/lint-identifiers.sh` before commits to catch drift.
- Service retirements:
  preserve binary + unit on disk as documented archive; document retirement in
  `docs/research/service-retirement-roadmap.md` and a memory entry.
- Lever catalog discipline:
  every reliability lever gets a permanent spec entry in
  `docs/research/lever-catalog.md`.
- Reliability methodology:
  one variable per test, written hypothesis, n>=3 to resolve, cheaper
  experiments first.
  Living ledger at `docs/research/reliability-hypothesis-ledger.md`.
