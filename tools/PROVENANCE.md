# Procedencia de las herramientas

| Ruta | Autoría |
|---|---|
| `egpu-bandwidth.cu` | **Propio de este proyecto.** Mide el ancho de banda real host↔eGPU sin dependencias (solo CUDA runtime). Existe porque los registros PCIe del túnel Thunderbolt son virtuales y leerlos ya llevó a una hipótesis falsificada. |
| Todo lo demás | **Terceros**: [`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu) vía [`iecxiv/aorus-5060-egpu`](https://github.com/iecxiv/aorus-5060-egpu). Incluye `event-capture/`, `perf-capture/`, `state-capture/`, `lint-identifiers.sh`, los smoke tests de CUDA/PyTorch y los probes de close-path/UVM. |

Licencia **GPL-2.0**.

Las herramientas de terceros se conservan porque la metodología que implementan
(captura de evidencia reproducible, diffs de estado, un experimento por
variable) sigue siendo la del proyecto —
ver [`../docs/research/`](../docs/research/).
Están escritas para la topología Fedora/NUC, así que **espera rutas y BDFs que
no coinciden con esta máquina**;
revísalas antes de ejecutarlas.
