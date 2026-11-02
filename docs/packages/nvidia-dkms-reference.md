# Referencia del driver DKMS del eGPU AORUS (Levers) y plan R4-safe

> Doc de referencia para **no repetir** la investigación. Capturado 2026-06-19.
> Resume el repo Fedora de referencia + la auditoría de nuestros 30 parches +
> la causa raíz por la que el driver parcheado **rompió la dGPU interna** (Xid 79)
> y el plan para corregirlo sin volver a tocarla (requisito de aceptación **R4**).

## Repos de referencia

| Qué | Dónde |
|---|---|
| **Canónico (upstream)** | https://github.com/iecxiv/aorus-5060-egpu |
| **Fork local (de trabajo)** | `git@github.com:omazapa/aorus-5060-egpu.git` |
| **Clon local en disco** | `/home/oazapatam/aorus-5060-egpu` (@ `25f68e6`); ver `docs/`, `patches/`, `lib/`, `tools/` |
| **Inputs de build en este repo** | `egpu-driver/patches/` (33 parches: los 30 originales + 0031–0034) + `egpu-driver/nvidia-dkms.conf` |
| **Paquete DKMS** | `packaging/aorus-egpu-nvidia-dkms/` (build: `make egpu-dkms`, **REQUIERE RED**: clona open-gpu-kernel-modules tag `595.71.05`) |

**Diferencia de hardware crítica:** el repo de referencia (Fedora) es de un sistema
**single-GPU** — la eGPU AORUS es la **única** GPU NVIDIA (host = Intel NUC con iGPU).
Por eso los levers de recuperación **nunca necesitaron acotarse a un device**: cualquier
GPU NVIDIA *es* la eGPU. Nuestro equipo es **dual-GPU** (interna RTX PRO 4000 `10de:2c39`
en `01:00.0` + eGPU RTX 5060 Ti `10de:2d04` detrás del puente TB), y ahí esa suposición
**rompe la interna**. Esa es toda la historia del Xid 79.

## Arquitectura de "Levers" (driver NVIDIA open parcheado)

Niveles de recuperación ante caídas del enlace PCIe del eGPU (Thunderbolt). La mayoría
viven dentro del fork de `nvidia.ko`.

| Lever | Clase | Falla que ataca | Qué hace |
|---|---|---|---|
| **I** | recovery | lecturas PCIe transitorias glitcheadas | reintenta `NV_PMC_BOOT_0` 10×100 µs antes de declarar GPU-lost |
| **J-2** | señalización | deadlock de crash-dump en GPU-lost | shortcircuita `rcdbAddRmGpuDump`/`nvDumpAllEngines`/asserts resserv |
| **N** | recovery | cleanup de RPC GSP cuelga | `rpcRmApiFree` retorna `NV_OK` y drena en vez de bloquear |
| **O** | recovery | cualquier dispatch RPC sobre GPU perdida | `_issueRpcAndWait` retorna `NV_ERR_GPU_IS_LOST` sin despachar |
| **M-base** | infra | AER sin manejar | registra `struct pci_error_handlers` en el `pci_driver` |
| **M-recover** | recovery | WPR2 atascado tras rmInit-FAIL; AER en runtime | máquina de estado in-driver: trigger → workqueue → `pci_reset_bus(puente padre)` → re-probe; gates H1–H4 (MaxAttempts, rate-limit, kill-switch, error_detected) |
| **P-probe** | diag transitorio | locus de cuelgue en close de UVM | marcadores en `uvm_va_space_destroy` (retirado tras hallar el sitio) |
| **Q-passive** | señalización | freeze silencioso Modo-B (hilo colgado en MMIO) | envuelve `osDevReadReg{8,16,32}`: si disconnected, retorna `0xFFFFFFFF` sin leer |
| **Q-active** | señalización | 1ª lectura MMIO colgada en bus muerto | tras leer `0xFFFFFFFF`, revalida `PMC_BOOT_0`; si confirma, `gpuSetDisconnectedProperties()` + `os_pci_set_disconnected()` ya |
| **Q-watchdog** | señalización | fallos Modo-B sin lecturas MMIO (DMA puro) | kthread por-device lee `PMC_BOOT_0` cada 200 ms; marca disconnected si `0xFFFFFFFF` |
| **R** | recovery | WPR2 atascado entre boots (hipótesis FALSADA) | helper userspace `remove+rescan+reset`; reemplazado por M-recover Tier 3 |

### Mapa de los 30 parches (`egpu-driver/patches/`)

Pasivos (telemetría/detección, seguros): 0001 0002 0003 0004 0005 0008 0009 0010
0011 0012 0015 0016 0017 0018 0020 0021 0023 0025 0028 0029 0030.
**Activos (disparan acciones — peligrosos sin gate de device):**
- **0007** M-base — registra `err_handler` en el `pci_driver` (todas las GPUs).
- **0013** Q-active — llama `os_pci_set_disconnected()` al ver `0xFFFFFFFF`.
- **0014** Q-watchdog — kthread que llama `os_pci_set_disconnected()`.
- **0022** G3-H — **escribe** config space (limpia AER UncMask) en cada GPU en probe.
- **0024** M-recover Commit 3 — agenda `pci_reset_bus(pci_upstream_bridge)` por AER/rmInit-FAIL.
- **0026** force-trigger sysfs; **0027** slot_reset+resume dispatch (siguen a 0024).

## ⚠️ CAUSA RAÍZ R4: por qué el parcheado tumbó la interna (Xid 79)

**No existe NINGÚN gate por device en los 30 parches.** Búsqueda exhaustiva: cero checks
de `0x2d04`/`0x2c39`, cero "is_external", cero "detrás de puente Thunderbolt". Los levers
se registran como **hooks per-driver** (`struct pci_driver nv_pci_driver.err_handler`) y/o
con **module params globales** (`NVreg_TbEgpuLeverMRecoverEnable`, `NVreg_TbEgpuWatchdogEnable`).
Resultado: **disparan sobre CUALQUIER GPU NVIDIA que el driver bindee**, incluida la interna.

**Secuencia del fallo (verificada en vivo 2026-06-19, sin el eGPU conectado):**
1. La interna `2c39` hace un resume RTD3/GC6 normal.
2. En el unlock, `kbifPollBarFirewallDisengage_GB202` deja el BAR firewall cerrado un
   instante → lecturas MMIO/`PMC_BOOT_0` devuelven `0xFFFFFFFF` **transitoriamente**.
3. Los levers lo interpretan como "GPU perdida":
   - **0014** (kthread cada 200 ms) o **0013** (Q-active) → `os_pci_set_disconnected()` sobre la **interna**.
   - peor: **0024** → `pci_reset_bus()` sobre el **root port de la interna** (`00:06.0`), que afecta a todo lo que cuelga de él.
4. → **Xid 79 "GPU has fallen off the bus"** + Xid 143 FSP `0xffffffff`. `nvidia-smi` deja de ver la interna.

Además: ruido en dmesg (`AORUS Lever M-recover`/`Mode-B`/`UVM [CLOSE]`) en cada open/close
de UVM, con `pdev=0000:04:00.0` **erróneo** (04:00.0 es el NVMe).

**Sitios de peligro concretos para la interna en RTD3/GC6:**
- `0014` kthread: `boot_0 = regs32[PMC_BOOT_0]; if (==0xFFFFFFFF) os_pci_set_disconnected()`.
- `0013` Q-active: tras `0xFFFFFFFF`, revalida y `gpuSetDisconnectedProperties()`+`os_pci_set_disconnected()`.
- `0024` M-recover: `tb_egpu_lever_m_trigger_post_rminit_fail()` desde `nv_start_device()` → `pci_reset_bus(pci_upstream_bridge(pdev))` **sin** verificar que el puente sea TB.
- `0022` G3-H: `pci_write_config_dword(... PCI_ERR_UNCOR_MASK, 0)` en probe → la interna reporta más AER.

## Plan R4-safe (opción **B2** del CLAUDE.md): acotar TODO lever al eGPU

Objetivo: que **ningún** lever toque jamás la interna. Idea: un único predicado
`tb_egpu_is_target(pdev/pGpu)` y gatear **toda** ruta activa con él.

Definición del gate (cualquiera robusto; preferir topología sobre device-id hardcodeado):
- **device-id** `pdev->device == 0x2d04` (simple, pero frágil si cambia el SKU), **y/o**
- **topología**: el device cuelga (vía `pci_upstream_bridge` recursivo) de un controlador
  **Thunderbolt/USB4** (`is_thunderbolt`/clase de puente TB), es decir "externo".
- Marcar el flag **una vez en probe** (`nvl->is_egpu_target`) y consultarlo en cada lever.

Puntos a gatear (todos los "activos"):
- `0007`/`0024` `nv_pci_error_detected`/`slot_reset`/`resume`: si `!is_egpu_target` → comportamiento
  M-base stock (`PCI_ERS_RESULT_DISCONNECT`), **nunca** `NEED_RESET`/`pci_reset_bus`.
- `0014` Q-watchdog: no arrancar el kthread si `!is_egpu_target` (o salir temprano).
- `0013` Q-active y `0011/0012` Q-passive: el short-circuit que **escribe estado**
  (`os_pci_set_disconnected`) solo si `is_egpu_target`. (La rama puramente pasiva de leer
  `0xFFFFFFFF` sin marcar estado es inofensiva, pero por claridad gatearla igual.)
- `0022` G3-H UncMask clear: solo sobre el eGPU.
- `0024`/`0026`/`0027` triggers de reset: idem.

**Verificación de aceptación antes de dar B2 por bueno:**
1. Construir DKMS con el gate, instalar (Secure Boot OFF hoy → carga sin MOK).
2. Reboot **sin** eGPU → confirmar que la interna sobrevive su RTD3/GC6 (sin Xid 79,
   `nvidia-smi` la ve sana) y que dmesg **no** muestra levers disparando sobre `2c39`.
3. Solo entonces, con el eGPU **en uso**, provocar un disconnect y comprobar que los
   levers **sí** actúan sobre el eGPU sin congelar el PC (R3) y sin tocar la interna (R4).

**Orden global (CLAUDE.md):** esto es paso 2/3. Antes hay que tener **R2 verde** (eGPU
enumera y nvidia bindea en stock con `aorus-egpu-config` 0.5.1 — reboot pendiente).
No probar el DKMS hasta tener una eGPU realmente bindeada contra la cual desarrollar.

## Notas operativas

- `make egpu-dkms` clona de la red; el módulo se firma con la MOK «squadai Secure Boot
  Module Signature key» (no enrolada → solo carga porque Secure Boot está **OFF**).
- Fallback siempre disponible: `apt remove aorus-egpu-nvidia-dkms` restaura el `nvidia.ko`
  stock firmado por Canonical (DKMS regenera initramfs; efecto al rebootear).
- Suspender con el eGPU activo **no** sobrevive (el túnel TB cae) — solo reboot lo recupera.
- Detalle profundo de cada lever en `~/aorus-5060-egpu/docs/` (p.ej. `lever-M-recover-design.md`).

## Parches 0031–0034 (el plan B2 implementado + endurecido)

El plan R4-safe de arriba se materializó en cuatro parches; el predicado único
`os_pci_is_egpu_target()` / `tb_egpu_pci_is_egpu_target()` (topología TB/USB4 **o**
device-id `0x2d04`) es la fuente de verdad de todos:

| Parche | aorus | Qué hace |
|---|---|---|
| **0031** | aorus13 | **R4 gate de levers ACTIVOS.** Gatea con el predicado: `error_detected`→DISCONNECT (no `pci_reset_bus`) salvo eGPU; kthread Q-watchdog solo para el eGPU; `trigger_post_rminit_fail`, G3-H UncMask, Q-active `set_disconnected` solo eGPU. Mató el Xid 79 de la interna. |
| **0032** | aorus14 | **R4 gate de paths de DIAGNÓSTICO.** `[CLOSE]` close-path, `mmio_enabled`/`cor_error_detected`, y el lookup UVM (deja el **BDF hardcoded `04:00.0`** = NVMe → busca el eGPU por topología). Exporta `tb_egpu_pci_is_egpu_target` para nvidia-uvm/nvidia-drm. |
| **0033** | aorus15 | **eGPU compute-only.** `nv_drm_register_drm_device()` **omite el registro DRM/KMS solo del eGPU** → ningún compositor (KWin/greeter) lo toma como display → mata el freeze de unplug/carga **sin** sacrificar el HDMI de la interna (que sí conserva su DRM device). CUDA va por el char device, intacto. |
| **0034** | aorus16 | **Anti-spam.** `__ratelimit` (30 s) a los 3 dumpers pesados + `[CLOSE]` UVM a `pr_debug`. El eGPU con enlace muerto inundaba dmesg (323 líneas/boot); ahora el 1.er fallo se loguea entero y el resto colapsa. El gate AER del watchdog (`out!=NULL`) **no** se throttlea. Cero cambio de lógica de recuperación. |

**Verificado 2026-06-27 con aorus15 en RAM:** R4 sólido en vivo — bajo el eGPU con
enlace muerto (`PMC_BOOT_0=0xFFFFFFFF`, AER `channel state=3`), **todas** las líneas de
error son del eGPU `8d:00.0` y la interna `01:00.0` tuvo **cero Xid**. El eGPU no bindea
(`RmInitAdapter failed`) por el **enlace en sí** (Gen1, `DLActive-`), no por los parches:
ningún cambio de driver levanta un enlace TB muerto (requiere re-plug/power-cycle/reboot).
