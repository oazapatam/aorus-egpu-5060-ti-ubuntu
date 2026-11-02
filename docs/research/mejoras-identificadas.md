# eGPU AORUS — backlog de cambios identificados (driver NVIDIA + `.deb`)

Lista viva de cambios concretos para que el eGPU AORUS RTX 5060 Ti funcione **bien**
(no solo "sin congelar"). Se va ampliando a medida que se corren pruebas en vivo.
Cada ítem: qué se observó → cambio propuesto → dónde → prioridad → estado.

Contexto de origen: sesión 2026-06-27 (force-load del eGPU + 3 tests CUDA escalados).
Driver en RAM esa sesión: **aorus15** (parcheado, gate `tb_egpu_pci_is_egpu_target` OK).
Enlace: **Gen1 2.5GT/s x4** (marginal, force-loaded), BAR1 **256 MiB** (sin ReBAR).

Leyenda estado: 🔴 pendiente · 🟡 en curso · 🟢 hecho (pend. verificar) · ✅ verificado vivo.

---

## A. Paquete `.deb` (`aorus-egpu-config`)

### A1 — Escalada SBR automática en hotplug  ·  P1  ·  🟢 hecho, pend. verificar vivo
- **Observado:** al hotplug el eGPU enumera y pasa el health-gate (enlace no muerto, x4,
  vendor legible) pero NO bindea: enlace marginal Gen1 → `Failed to enable MSI-X` →
  `RmInitAdapter failed`. El `remove+rescan` simple del `fix-bar0` NO lo bindea; lo que
  bindea (verificado a mano 2×) es `remove de funciones → Secondary Bus Reset del puente
  TB inmediato → rescan`.
- **Cambio:** añadido a `usr/sbin/aorus-egpu-fix-bar0` (v0.5.6) — escalada SBR hasta 2×,
  puente inmediato = padre sysfs (BDF dinámico). R4-safe (solo rama TB).
- **Pendiente:** verificar en un hotplug real que bindea solo, sin intervención a mano.

### A2 — ReBAR por sysfs: subir BAR1 a 16 GiB sin boot args  ·  P1  ·  ✅ VERIFICADO + implementado (0.5.7)
- **Observado:** BAR1 clavada en **256 MiB** → el mayor limitante de rendimiento CUDA.
- **HALLAZGO 2026-06-27 (verificado en vivo):** el resize **in-place** del kernel
  (`echo 14 > resource1_resize`) **NO funciona aquí**: la ventana prefetchable del puente TB
  inmediato `8c:00.0` es solo ~288 MiB → `-ENOSPC`, y el kernel **revierte** el registro. PERO
  el root TB `80:1b.4`/`88:00.0` tienen **64 GiB casi libres**. Lo que SÍ funciona (probado
  2 veces): fijar el tamaño por **setpci en el registro ReBAR CTRL** (el kernel no lo revierte),
  **quitar el puente TB superior constreñido** (su ventana se re-asigna desde los 64 GiB) y
  **rescan** → el kernel da una ventana de 16 GiB y BAR1 = 16 GiB. Auto-rebindea sin SBR (un SBR
  reset­earía el ReBAR). Registro CTRL de BAR1 detectado dinámico vía lspci (cap "Physical
  Resizable BAR"); índice máx desde el bitmask de `resource1_resize` (0x7fc0 → 14 = 16 GiB).
- **Implementado** en `fix-bar0` (función `rebar_bump`, llamada desde `report_bound` SOLO tras
  bind limpio — un SBR reset­ea el ReBAR). Best-effort con fallback total (si falla, eGPU queda
  bindeada), idempotente (salta si ya 16 GiB), R4-safe (solo rama TB). Endurecido tras revisión
  adversarial (valida hex de setpci, anti-race del flock, anti-brick en `rebar_ensure_bound`).

### A3 — `pciutils` debe ser `Depends`, no `Recommends`  ·  P2  ·  ✅ hecho (0.5.7)
- **Observado:** la escalada SBR (A1) usa `setpci` (de pciutils). Hoy está en `Recommends`;
  el script degrada con aviso si falta, pero entonces la recuperación NO corre.
- **Cambio:** mover `pciutils` de `Recommends` a `Depends` en `DEBIAN/control` (dejar `bolt`
  en Recommends). Bump menor.

### A4 — `aorus-egpu-status`: detectar módulo-en-RAM ≠ DKMS instalado  ·  P2  ·  ✅ hecho+verificado (0.5.7, por srcversion)
- **Observado:** `dkms status` dice aorus16 instalado pero en RAM corre aorus15 (no hubo
  reboot tras el bump). No hay forma directa de saberlo salvo por la verbosidad de `[CLOSE]`.
- **Cambio:** que `usr/bin/aorus-egpu-status` compare la versión/firma del módulo cargado
  con el `PACKAGE_VERSION` del `dkms.conf` instalado y avise "REBOOT pendiente para cargar
  aorusNN" si difieren. Evita concluir mal en pruebas.

---

## B. Driver NVIDIA parcheado (`aorus-egpu-nvidia-dkms` / `egpu-driver/patches/`)

### B1 — Silenciar el `[CLOSE]` de nivel-RM  ·  P2  ·  ✅ hecho (aorus17, patch 0035: NV_DBG_ERRORS→NV_DBG_INFO; aorus16 NO lo cubría, confirmado)
- **Observado:** durante el Test 3, cada cierre de proceso CUDA emitió ~20 líneas
  `NVRM: GPU …: AORUS Lever M-recover [CLOSE]: usage_count=N` (312 en total en la sesión).
  aorus16 (anti-spam) movió a `pr_debug` el `[CLOSE]` de **UVM**, pero el `[CLOSE]` de
  **nivel-RM** (device close) parece NO estar cubierto.
- **Cambio (posible aorus17):** mover/rate-limit también el `[CLOSE]` usage_count de nivel-RM
  a `pr_debug` o `__ratelimit`. **Antes de tocar nada:** rebootear a aorus16 y RE-medir —
  puede que ya esté resuelto; este ítem se confirma o se descarta con aorus16 en RAM.

### B2 — (Investigación) auto-recuperación de enlace marginal en el probe  ·  P3  ·  🔴 idea
- **Observado:** el driver falla `RmInitAdapter` sobre el enlace Gen1 marginal y se rinde;
  la recuperación (SBR+rebind) la hace el `.deb` por fuera (A1).
- **Idea:** un "Lever" que, ante `RmInitAdapter`/MSI-X fail con enlace degradado, intente un
  retrain/SBR del puente inmediato y reintente el init **dentro** del driver. Eliminaría la
  dependencia del `.deb` para bindear. **Baja prioridad / alto riesgo** (reset PCIe desde el
  driver); el camino del `.deb` (A1) ya funciona. Documentar, no implementar aún.

---

## C. Verificaciones / pruebas pendientes

- **C1 — Hotplug real con A1:** desconectar/reconectar la caja y confirmar que `fix-bar0`
  bindea solo (sin force-load a mano).  🔴
- **C2 — Reboot → cargar aorus16:** re-correr los 3 tests CUDA y confirmar (a) gate R4 OK,
  (b) dmesg ya no inunda (B1), (c) si el enlace re-entrena mejor que Gen1 tras reboot.  🔴
- **C3 — Burn compute-bound:** test CUDA al 100% de utilización sostenida (térmica/motor),
  no solo memcpy/PCIe (los 3 tests de hoy quedaron ~5% util). Cierra la pregunta "¿aguanta
  carga IA real?".  🔴
- **C4 — ReBAR A2 a mano:** medir el resize por sysfs en vivo antes de empaquetarlo.  🔴

---

## Resultados ya verificados (no requieren cambio)

- **Gate R4 sólido:** bajo carga CUDA (3 tests, ~23 GB sostenidos) la interna `01:00.0`
  quedó cero-Xid / cero-recovery / cero-freeze. Es el opuesto del freeze sobre driver stock.
  El gate `tb_egpu_pci_is_egpu_target` aísla el eGPU correctamente.
- **Baseline de boot args correcto:** `iommu=pt` + `pcie_aspm.policy=performance` +
  `thunderbolt.clx=0` + `pcie_port_pm=off` (0.5.5) — se quedan.
- **Diseño compute-only (aorus15) correcto:** el eGPU no es device de display → no congela
  al caer el enlace; la interna conserva HDMI.
