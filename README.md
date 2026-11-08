# aorus-egpu-5060-ti-ubuntu

eGPU **AORUS RTX 5060 Ti** por Thunderbolt 5 en **Ubuntu 26.04**, empaquetada
como `.deb` reversibles.

Es un proyecto nuevo con **obra derivada** de otros repositorios.
No hereda su historial de git, así que la procedencia de cada parte está
documentada ruta por ruta en [`CREDITS.md`](./CREDITS.md), y cada directorio de
terceros lleva su propio `PROVENANCE.md`.

Todo lo que este repo instala se desinstala con `apt remove`.
Esa es la restricción de diseño principal: un intento anterior dejó el portátil
inestable, así que nada se instala "a mano" en el sistema.

> **Estado (2026-11-02):** funcionando y medido.
> `3.06 GB/s` host→eGPU y `3.38 GB/s` eGPU→host, con el túnel Thunderbolt
> saturado.
> El stack mínimo que lo consigue es `egpu-tb-fix` + el driver NVIDIA **stock**
> de Ubuntu: ni driver parcheado, ni ninguna palanca del catálogo de levers.
> La investigación que lo establece está en
> [`docs/what-actually-works.md`](./docs/what-actually-works.md).

## Hardware de referencia

| Pieza | Valor |
|---|---|
| Host | Lenovo ThinkPad P16 Gen 3 (21RR), BIOS N4FET49W 1.30 |
| GPU interna | NVIDIA RTX PRO 4000 Blackwell (`10de:2c39`, `01:00.0`) — **nunca se toca** |
| eGPU | AORUS RTX 5060 Ti 16 GB (`10de:2d04`) en caja AI BOX, TB5 |
| OS | Ubuntu 26.04, kernel 7.0.0-1015-oem |
| Driver | `nvidia-driver-595-open` **595.99.02** (stock de Canonical) |
| Secure Boot | desactivado |

Dos particularidades de esta máquina que condicionan todo el diseño:

1. **El portátil no arranca con la eGPU conectada** (se queda en el logo, con
   pitidos). Es firmware, antes del kernel, y la BIOS no expone ningún toggle de
   Above-4G, ReBAR ni Thunderbolt. Por eso el flujo es **solo hotplug**:
   arrancar sin la caja y conectarla con el sistema ya en marcha.
2. **Hay una segunda GPU NVIDIA que funciona** (pantalla + cómputo). Toda acción
   debe confinarse a la eGPU externa; romper la interna ya pasó una vez
   (Xid 79). En el repo esa invariante se llama **R4** y tiene un gate propio.

## Instalación

```bash
git clone git@github.com:oazapatam/aorus-egpu-5060-ti-ubuntu.git
cd aorus-egpu-5060-ti-ubuntu
make                       # construye los .deb en dist/
sudo apt install ./dist/egpu-tb-fix_*.deb
sudo reboot                # necesario: añade args de kernel vía GRUB
```

Tras reiniciar, **conecta la caja**. Debería enumerar sola en unos 20 s:

```bash
nvidia-smi                 # la eGPU aparece como una GPU más
journalctl -t egpu-tb-fix  # qué hizo exactamente
```

La primera vez, Thunderbolt tiene que autorizar la caja.
Si `boltctl list` la muestra `connected` pero `authorized: 0`:

```bash
sudo boltctl enroll --policy auto <uuid>
```

Con `policy: auto` la autorización es automática en cada conexión.
**No uses `policy iommu`**: con esa política el túnel PCI no se crea, la GPU
nunca enumera y nada más se dispara.

### Desinstalar

```bash
sudo apt remove egpu-tb-fix
sudo reboot
```

## Paquetes

| Paquete | Estado | Qué hace |
|---|---|---|
| **`egpu-tb-fix`** | **principal, verificado en vivo** | Prepara la eGPU al conectarla: cierra la compuerta de autoprobe PCI, libera los puertos TB vacíos, re-enumera para que el kernel le asigne el BAR0, limita el enlace interno a Gen3 sin ASPM y se la entrega a `nvidia`. Boot args `thunderbolt.host_reset=0 clx=0`. |
| **`aorus-egpu-core`** | **nuevo** | El núcleo compartido (`domain/`, `ports/`, `adapters/`, `app/`) en `/usr/lib/aorus-egpu/`. No trae ejecutables: lo arrastran como dependencia los paquetes de capacidad. Existe porque antes cada uno entregaba su propia copia en la misma ruta y dpkg se negaba a instalar el segundo ([detalle](./docs/packages/README.md)). |
| **`aorus-egpu-forensics`** | **nuevo, probado en vivo** | Deja rastro en disco para depurar los cuelgues del host: migas de pan con `fsync` antes de cada paso, muestreador de hardware, y `ramoops` para preservar el dmesg del kernel a través del reinicio. |
| **`aorus-egpu-health`** | **nuevo** | Detecta los incidentes de la eGPU y dice DÓNDE mirar: distingue "se cayó la caja Thunderbolt entera" de "falló la GPU" correlacionando USB, PCIe, túnel y Xid, agrupa los 237 mensajes de un incidente en una línea con veredicto y la escribe con `fsync`. Trae `aorus-egpu-health` (`scan`/`check`/`status`/`explain`) y un servicio que vigila el journal en continuo. |
| **[`aorus-egpu-igpu-display`](./docs/igpu-display.md)** | **nuevo** | Deja el escritorio en la iGPU Intel y las dos GPUs NVIDIA libres para cómputo: pone `nvidia_drm modeset=0` para que el compositor Wayland no las abra, con lo que además se puede descargar el driver. Trae `aorus-egpu-display` (`status`/`check`/`unload`/`reload`). El `postinst` sólo activa la configuración si el gate de pantalla pasa, para no dejar la máquina ciega. |
| `aorus-egpu-overclock` | **en desarrollo, no usar aún** | Perfiles de potencia, bloqueo de relojes y offsets de ±MHz por NVML para la eGPU. Trae `aorus-egpu-oc` (CLI) y `nvidia-oc` (TUI). Un offset positivo no se aplica sin pasar un verificador numérico bit-exacto, porque esta tarjeta no tiene ECC y un offset agresivo no se cae: calcula mal. El núcleo y los tests están hechos; ningún perfil ni offset validado en hardware. |
| `aorus-egpu-config` | **superseded (archivo)** | El port del stack Fedora. Reemplazado por `egpu-tb-fix`. No instalar junto a él: ambos gestionan el BAR0 por udev y se pisan. |
| `aorus-egpu-nvidia-dkms` | **superseded + deuda** | Driver NVIDIA parcheado (34 levers) vía DKMS. Fijado a 595.71.05 mientras el instalado es 595.99.02: **necesita rebase antes de volver a usarse**. La eGPU funciona sin él. |

`make` construye `egpu-tb-fix` y `aorus-egpu-forensics`.
Los demás se construyen explícitamente
(`make health`, `make igpu-display`, `make overclock`, `make config`,
`make dkms`).

## Cómo está organizado el repo

El orden de los directorios no es decorativo: separa **reglas**, **contratos**,
**herramientas** y **entrega**, para poder añadir capacidades a la eGPU sin que
cada una reinvente la detección de hardware ni los gates de seguridad.
La justificación completa está en
[`docs/architecture.md`](./docs/architecture.md) y las reglas obligatorias en
[`CLAUDE.md`](./CLAUDE.md).

```
src/                 núcleo (arquitectura hexagonal) — fuente ÚNICA de lógica
  domain/              reglas puras, sin I/O: gate R4, salud del enlace, tuning
  ports/               contratos que un adaptador debe cumplir
  adapters/            implementaciones: sysfs, nvidia-smi, boltctl, log
  app/                 casos de uso (orquestan domain + ports)
  bin/                 entrypoints CLI finos
packaging/           un árbol .deb por paquete — SOLO entrega, cero lógica
scripts/             build-*.sh (empaquetado) + lib/bundle.sh (ensambla src/)
kernel/              patches/ (levers del driver) + dkms/
tests/               tests del dominio: sin root, sin GPU
tools/               diagnóstico y medición (no se empaqueta)
docs/                arquitectura, paquetes y research/ (investigación histórica)
legacy/fedora/       el stack Fedora original, tal cual, como referencia
```

## Medir antes de concluir

La lección más caras de este proyecto, y vale repetirla:
**los puentes del túnel Thunderbolt virtualizan sus registros PCIe.**
Anuncian `Gen1 2.5GT/s` sea cual sea la capacidad real, y el mensaje del kernel
`"N Gb/s available PCIe bandwidth, limited by 2.5 GT/s"` lee esos registros
virtuales — no mide nada.

Leer `lspci` y concluir que había un techo de Gen1 ya costó una investigación
entera que terminó falsificada (hipótesis H18).
Para medir de verdad:

```bash
nvcc -O2 -o tools/egpu-bandwidth tools/egpu-bandwidth.cu
tools/egpu-bandwidth B4:00.0
```

Interpretación en este hardware: `~2.5-3.3 GB/s` significa túnel saturado y que
no hay nada que levantar; `~1.0 GB/s` sí sería un techo real de Gen1 ×4.

Lo mismo aplica a `current_link_speed`: en reposo marca `2.5 GT/s` porque el
enlace baja de velocidad sola, y sube a `8.0 GT/s` cuando hay tráfico.
Medido: `2.5 2.5 8.0 8.0 8.0 8.0 8.0 8.0 5.0 5.0 2.5 2.5` durante una copia.

## Si el PC se congela al probar la eGPU

Pasa de vez en cuando, y sin Xid, sin panic y sin oops.
El problema de depurarlo es que un cuelgue duro **se lleva el journal por
delante**: vivía en RAM y el kernel nunca llegó a volcarlo, así que al reiniciar
no queda ni una pista.

La solución es no lanzar nunca la prueba a pelo:

```bash
sudo apt install ./dist/aorus-egpu-forensics_*.deb

sudo aorus-egpu-probe bandwidth       # prueba con traza forense
sudo aorus-egpu-probe load 120        # carga sostenida de 120 s
sudo aorus-egpu-probe run -- <cmd>    # envuelve cualquier comando
```

Cada paso se escribe en disco **con `fsync` antes de ejecutarse**, así que si la
máquina muere, la última línea del log es el paso culpable.
Y tras reiniciar:

```bash
sudo aorus-egpu-postmortem
```

que junta en un solo directorio la última traza, el volcado del kernel y el
journal del arranque anterior, con un `00-RESUMEN.txt` por el que empezar.

Las capas, y qué cubre cada una:

| Capa | Necesita reiniciar | Sobrevive a un cuelgue sin panic |
|---|---|---|
| Migas de pan en disco (`fsync`) | no | **sí** — es la garantía principal |
| Muestreador de hardware | no | **sí** |
| `ramoops`/`pstore` + lockup→panic | sí | solo si el kernel llega a hacer panic |

La tercera capa captura mucho más (el dmesg completo del kernel), pero este
kernel no trae `CONFIG_PSTORE_CONSOLE`, así que `ramoops` solo graba cuando hay
un panic — por eso el paquete convierte los lockups en panic.
Si el cuelgue es tan duro que el detector de lockups tampoco corre, las dos
primeras capas son lo único que queda, y de ahí que no dependan de nada.

Detalle completo en [`docs/freeze-forensics.md`](./docs/freeze-forensics.md).

## Desarrollo

```bash
make lint      # sintaxis de todo el shell (núcleo, builds, maintainer scripts)
make test      # tests del dominio: 51 asserts, sin root y sin GPU
make inspect   # dpkg-deb -I/-c de los .deb construidos
make clean
```

Los tests no necesitan la eGPU conectada:
el gate R4 y el gate de enlace son funciones puras, y eso es precisamente lo
que compra la separación en capas.
También verifican que cada adaptador cumple el contrato de su puerto y que la
traza forense llega de verdad a disco.

## Licencia y autoría

**GPL-2.0** — no es una elección libre:
el repositorio incluye obra derivada de
[`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu)
(vía [`iecxiv/aorus-5060-egpu`](https://github.com/iecxiv/aorus-5060-egpu)),
que es GPL-2.0, así que el conjunto hereda esa licencia.

Qué es de quién, en resumen:

| Parte | Autoría |
|---|---|
| `src/`, `ci/`, `tests/`, `packaging/aorus-egpu-{forensics,overclock}/`, `tools/egpu-bandwidth.cu`, la documentación propia | De este proyecto |
| `packaging/egpu-tb-fix/` | Omar Zapata — <https://github.com/oazapatam/nvidia-egpu-aibox> |
| `packaging/aorus-egpu-{config,nvidia-dkms}/`, `kernel/patches/0031-0035` | Omar Zapata |
| `legacy/fedora/`, `docs/research/`, `kernel/patches/0001-0030`, el resto de `tools/` | **Terceros**: `apnex/aorus-5090-egpu` vía `iecxiv/aorus-5060-egpu` |

Los parches del driver son **diffs contra**
[`NVIDIA/open-gpu-kernel-modules`](https://github.com/NVIDIA/open-gpu-kernel-modules)
(MIT/GPL-2.0);
no se redistribuye código de NVIDIA.

Detalle completo, incluido lo que se usa sin redistribuir, en
[`CREDITS.md`](./CREDITS.md).
