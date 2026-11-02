# Procedencia de la serie de parches

Los parches son **diffs contra** el árbol upstream
[NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
en el tag `595.71.05`.
No contienen código de NVIDIA:
`scripts/build-dkms.sh` clona el upstream y los aplica encima.

| Parches | Autoría |
|---|---|
| `0001`–`0030`, `disabled/`, `.disabled-for-rollback/` | **Terceros**: [`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu) vía [`iecxiv/aorus-5060-egpu`](https://github.com/iecxiv/aorus-5060-egpu). Levers I/J/M/O/P/Q, máquina de recuperación WPR2, watchdog Q y telemetría PCIe/AER. |
| `0031`–`0035` | **Omar Zapata**: gate R4 (confinar toda palanca a la eGPU externa), modo solo-cómputo saltando el registro DRM/KMS, y limitación de los volcados de diagnóstico. |
| `0036` | **Omar Zapata** (con Claude Code): corrección de orden en `tb_egpu_qwatchdog_init` — publicar `nvl->qwd` antes de arrancar el kthread. Nace de una revisión estática de la serie; no hay incidente asociado. |
| `0037` | **Omar Zapata** (con Claude Code): gate R4 en las cuatro rutas de diagnóstico que `0032` no cerró, y el gate de `nv_pci_error_detected` por delante del volcado AER. |
| `0038` | **Omar Zapata** (con Claude Code): retirar el `pci_lock_rescan_remove()` que envolvía `pci_reset_bus()` — cierra uno de los dos ciclos de deadlock. El otro queda abierto y documentado. |

## Deuda de versión — leer antes de usar

Estos parches fijan `NV_VERSION_STRING` a **595.71.05**, pero el driver
instalado en la máquina de referencia es el stock **595.99.02**.
Los módulos construidos con esta serie **no cargarían**:
hace falta un rebase al tag nuevo.

Y lo más importante:
**la eGPU funciona hoy sin ninguno de estos parches**, con el driver stock.
Ver [`../../docs/what-actually-works.md`](../../docs/what-actually-works.md).
