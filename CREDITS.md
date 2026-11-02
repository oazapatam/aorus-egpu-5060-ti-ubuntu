# Procedencia y atribuciones

Este repositorio es **obra derivada**.
Se creó con historial limpio, así que esta página es el registro de dónde viene
cada parte — porque el historial de git ya no lo cuenta.

Nada se tomó sin atribuir.
Si encuentras algo mal atribuido, es un error que quiero corregir: abre un
issue.

## Licencia

**GPL-2.0** (ver [`LICENSE`](./LICENSE)).

No es una elección libre:
el repositorio incluye obra derivada de `apnex/aorus-5090-egpu`, que es
GPL-2.0, así que el conjunto hereda esa licencia.
Las partes escritas desde cero aquí se publican bajo la misma licencia para que
el conjunto sea coherente.

## Procedencia ruta por ruta

### Obra propia de este proyecto

| Ruta | Qué es |
|---|---|
| `src/` | El núcleo con arquitectura hexagonal: dominio, puertos, adaptadores, casos de uso y entrypoints. Escrito para este repositorio. |
| `ci/` | El CI local: orquestador y etapas (sintaxis, shellcheck, tests, parches del kernel, construcción, política de paquetes, documentación). |
| `tests/` | Los asserts del dominio, que corren sin root y sin GPU. |
| `scripts/build-tb-fix.sh`, `build-config.sh`, `build-overclock.sh`, `build-forensics.sh`, `scripts/lib/bundle.sh` | Empaquetado y ensamblado del núcleo en el payload. |
| `packaging/aorus-egpu-forensics/` | Paquete de forense de cuelgues: migas de pan con `fsync`, muestreador de hardware y `ramoops`. |
| `packaging/aorus-egpu-overclock/` | Paquete de perfiles de potencia y reloj (en desarrollo). |
| `tools/egpu-bandwidth.cu` | Medidor de ancho de banda host↔eGPU, sin dependencias. |
| `docs/what-actually-works.md`, `architecture.md`, `freeze-forensics.md`, `ci-*.md`, `packages/README.md`, `research/README.md` | Documentación propia. |
| `README.md`, `CREDITS.md`, `CLAUDE.md`, `Makefile`, `.shellcheckrc` | Metadocumentación y automatización del repo. |

### Obra propia de Omar Zapata, traída de otros repositorios suyos

| Ruta | Origen |
|---|---|
| `packaging/egpu-tb-fix/` | <https://github.com/oazapatam/nvidia-egpu-aibox> — el paquete que de verdad hace funcionar la eGPU en Ubuntu. Enfoque propio: compuerta de autoprobe PCI, selección por `removable` y nunca desenlazar `nvidia`. |
| `packaging/aorus-egpu-config/` | Repositorio local `squadai-stable` (sin publicar). Port del stack Fedora a un `.deb` reversible. Hoy **superseded** por `egpu-tb-fix`. |
| `packaging/aorus-egpu-nvidia-dkms/` | Ídem. Empaqueta el driver parcheado vía DKMS. Hoy **superseded**. |
| `kernel/patches/0031`–`0035` | Ídem. Gate R4, modo solo-cómputo y limitación de volcados. |
| `kernel/dkms/nvidia-dkms.conf`, `scripts/build-dkms.sh` | Ídem. |

### Obra de terceros (GPL-2.0)

Estas partes **no son mías**.
Se incluyen porque el proyecto deriva de ellas, y se conservan íntegras para
que la atribución sea verificable.

| Ruta | Autoría original |
|---|---|
| `legacy/fedora/` | [`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu), vía [`iecxiv/aorus-5060-egpu`](https://github.com/iecxiv/aorus-5060-egpu). El stack Fedora completo: `apply.sh`, `remove.sh`, `status.sh`, `reset.sh`, los servicios `aorus-egpu-*`, las reglas udev y la configuración de `modprobe`. |
| `docs/research/` (salvo `README.md`) | Ídem. Los 47 documentos de investigación: catálogo de levers, ledger de hipótesis, metodologías de captura, análisis de topología Thunderbolt. |
| `kernel/patches/0001`–`0030`, `disabled/`, `.disabled-for-rollback/` | Ídem. La serie original de parches del driver (Levers I/J/M/O/P/Q, recuperación WPR2, watchdog Q, telemetría PCIe/AER). |
| `tools/` (salvo `egpu-bandwidth.cu`) | Ídem. `event-capture/`, `perf-capture/`, `state-capture/`, `lint-identifiers.sh`, los smoke tests de CUDA/PyTorch y los probes. |
| `LICENSE`, `.markdownlint.yaml`, `.pre-commit-config.yaml` | Ídem (la configuración de pre-commit se amplió aquí). |

### Linaje del proyecto

```
apnex/aorus-5090-egpu          AORUS RTX 5090 + Intel NUC + Fedora
        │                      (autoría del stack y de la metodología)
        ▼
iecxiv/aorus-5060-egpu         adaptación a la RTX 5060 Ti
        │
        ▼
oazapatam/nvidia-egpu-aibox    egpu-tb-fix: enfoque propio para Ubuntu
        │
        ▼
ESTE REPOSITORIO               port a Ubuntu empaquetado en .deb reversibles,
                               con núcleo hexagonal, CI local y forense de cuelgues
```

## Componentes de terceros que NO se redistribuyen aquí

| Proyecto | Relación |
|---|---|
| [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) (MIT/GPL-2.0) | Los parches de `kernel/patches/` son **diffs contra** ese árbol (tag `595.71.05`). No contienen código de NVIDIA: `scripts/build-dkms.sh` clona el upstream y aplica los parches encima. |
| [NVIDIA/nvbandwidth](https://github.com/NVIDIA/nvbandwidth) | Referencia de **metodología** de medición. `tools/egpu-bandwidth.cu` es una reimplementación mínima e independiente, sin código copiado. |
| Firmware GSP, `nvidia-smi`, NVML, CUDA | De NVIDIA. Se instalan desde los paquetes de la distribución. |
| Kernel Linux (GPL-2.0) | `thunderbolt.host_reset`, `thunderbolt.clx`, el control de velocidad por *cooling device* y `ramoops`/`pstore` son interfaces del kernel. El workaround `host_reset=0` responde a la regresión del commit `59a54c5f3dbd`. |
| [bolt](https://gitlab.freedesktop.org/bolt/bolt) | Se usa `boltctl` como herramienta externa. No se incluye ni se modifica su código. |
| `shellcheck`, `lintian`, `bats`, `checkpatch.pl`, `pre-commit`, `mdslw`, `markdownlint` | Herramientas de desarrollo que el CI invoca si están instaladas. No se incluyen. |
