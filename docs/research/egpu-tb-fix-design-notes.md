# eGPU Thunderbolt en Linux

Objetivo: que la eGPU (GIGABYTE AORUS RTX 5060 Ti AI BOX, Thunderbolt 5/USB4) funcione
junto con la GPU NVIDIA interna del portátil (RTX PRO 4000 Blackwell Laptop).

## Regla principal: todo cambio va en un .deb reversible

- Cualquier cambio al sistema (archivos en /etc o /usr, servicios systemd, reglas udev,
  parámetros de kernel/GRUB, módulos, initramfs) se hace **solo** mediante un paquete `.deb`
  construido en esta carpeta, para poder revertirlo con `sudo apt remove <paquete>` y dejar
  el PC como estaba.
- No editar a mano archivos del sistema fuera del paquete.
- Permitido sin paquete: diagnósticos de solo lectura (`lspci`, `dmesg`, `journalctl`,
  `nvidia-smi`, `boltctl`, lectura de /sys y /proc).
- Las operaciones en caliente sobre el árbol PCI (remove/rescan en sysfs) se ejecutan con el
  script del paquete, no con comandos sueltos. Se pierden al reiniciar.
- La GPU interna (`0000:01:00.0`) puede estar en uso (p. ej. vLLM como root): no descargar ni
  recargar el módulo `nvidia`, no tocar ese dispositivo y no reiniciar sin avisar.
- Si un cambio necesita reinicio, avisar antes de pedirlo.

## Hardware (Lenovo, Ubuntu 26.04, kernel 7.0.0-1015-oem, driver nvidia-595-open)

| Dispositivo | Dirección PCI | Notas |
|---|---|---|
| Intel Arrow Lake iGPU | 00:02.0 | i915 |
| RTX PRO 4000 Blackwell Laptop (interna) | 01:00.0 | bajo host bridge 0000:00 |
| Controlador TB5 Barlow Ridge (host) | 88:00.0 → puertos 89:00.0–89:03.0 | bajo 80:1b.4 |
| Caja eGPU (hub Barlow Ridge) | b2:00.0 → b3:00.0–b3:03.0 | detrás del puerto TB 89:03.0 |
| RTX 5060 Ti (eGPU) | b4:00.0 (+ audio b4:00.1) | 10de:2d04 |

## Diagnóstico del problema

Al conectar en caliente, el driver falla con:

```
pci 0000:b4:00.0: BAR 0 [mem size 0x04000000]: can't assign; no space
NVRM: BAR0 is 0M @ 0x0 (PCI:0000:b4:00.0)
nvidia 0000:b4:00.0: probe with driver nvidia failed with error -1
```

La ventana MMIO de 32 bits del controlador TB5 (88:00.0) es de solo 128 MB, fijada por la
BIOS (b0000000–b7ffffff). Al arrancar, el kernel la reparte a partes iguales entre los dos
puertos hotplug, y el puerto vacío 89:01.0 se queda con 63 MB. La caja eGPU necesita unos
71 MB alineados a 64 MB (BAR0 de 64 MB + ROM + audio + 3 puertos de la caja de 2 MB cada uno),
así que no cabe en lo que queda. La ventana prefetchable de 64 bits (64 GB) sí alcanza, así
que el BAR1 (VRAM) no es el problema.

### Segundo problema: el enlace se cae con nvidia activo (2026-10-02)

Con el BAR0 resuelto, el enlace USB4 a la caja se cae (`thunderbolt 1-3: device disconnected`)
al poco de que nvidia toma la GPU, o al conectar. Con el driver activo eso da
`NVRM: Xid 79, GPU has fallen off the bus` y el hilo `irq/*-pciehp` queda girando al 100 %
dentro del remove de nvidia con el lock de rescan PCI tomado: no hay más hotplug PCI hasta
reiniciar (y el 2026-10-02 el equipo se congeló entero). Casos parecidos en la red: la
regresión de `thunderbolt.host_reset` (6.8.8+), el bug 221699 (enlace que cae al inicializar
la GPU) y un estabilizador para AORUS RTX 5090 AI BOX en Fedora que limita el enlace a Gen3.

Medido ese día en 5 arranques: el enlace USB4 (Gen4, 2×40G = 80G, cable/caja TB5) cae a los
70–340 s de conectar, **sin carga y sin errores previos**, y cae también el túnel USB3 de la
caja (hub, Ethernet r8152): es el enlace USB4, no PCIe ni nvidia. El cuelgue posterior es de
nvidia-modeset: al quitar la GPU, nvidia-drm libera su dispositivo nvkms y nvkms espera para
siempre a la GPU desaparecida (`nvEvoMakeRoom`, binario, sin arreglo de nuestro lado;
`nvidia_drm.modeset=0` lo evitaría pero quita KMS a la GPU interna, que tiene HDMI/DP).
Sin firmware nuevo (LVFS, Gigabyte, Lenovo: caja NVM 64.81, host 62.02, BIOS 1.33).
Candidatos para la caída: (1) runtime PM del controlador TB: con el NHI suspendido el driver
pone a dormir los routers USB4 con los túneles activos (1.4.0 lo evita); (2) la señal a
80G: con un enlace Gen3 (puerto izquierdo = USB4 integrado de 40G, o cable TB4 de 40G) el
túnel PCIe rinde lo mismo, porque el enlace interno ya va limitado a Gen3 x4 (~3,2 GB/s).

## Solución: paquete `egpu-tb-fix`

Ubicación: `pkg/egpu-tb-fix/`. Para construirlo: `./build.sh` (genera `dist/*.deb`).

- `/usr/sbin/egpu-tb-fix`: espera a que la caja lleve 15 s enumerada sin caerse; si la GPU no
  tiene BAR0, quita la caja y los puertos TB hermanos vacíos y hace un rescan del bus del puerto
  (`/sys/class/pci_bus/<bus>/rescan`, que redimensiona la ventana) con el autoprobe PCI apagado,
  para que antes de que nvidia tome la GPU se limite el enlace interno caja↔GPU a Gen3 (control
  bwctrl `PCIe_Port_Link_Speed_<puente>` en /sys/class/thermal) y se quiten ASPM y runtime PM.
  **Nunca desenlaza nvidia** (desde 1.5.0): si nvidia ya tomó la GPU sin preparar (caja conectada
  desde el arranque), solo quita ASPM y runtime PM y avisa; para limitarla hay que reconectar.
  Opciones: `--dry-run`, `status`.
- Compuerta (desde 1.5.0, cualquier puerto): la regla udev `tb-event` ve el router USB4 nuevo
  antes que bolt (bolt recibe el evento cuando udev termina) y, si aún no está autorizado, apaga
  `/sys/bus/pci/drivers_autoprobe`; el túnel PCIe y la eGPU llegan sin driver, el servicio la
  prepara y la entrega a nvidia (`open_gate`). Si en 15 s no aparece ninguna eGPU, un temporizador
  transitorio (`egpu-tb-fix ungate`) la abre y enlaza lo que quedó sin driver detrás de
  Thunderbolt. No se cierra durante el arranque (`systemctl is-system-running` ≠ running/degraded)
  ni sin el módulo nvidia cargado. `egpu-tb-fix open-gate` la abre a mano.
- Regla udev + `egpu-tb-fix.service`: lo lanzan solos al conectar la eGPU. Cooldown de 30 s.
  Otra regla deja `power/control=on` en las funciones de la eGPU.
- `72-egpu-tb-fix-seat.rules`: pone `ID_SEAT=seat-egpu` a los nodos DRM de la eGPU para que
  KWin no la abra (sus salidas de video no se usan; CUDA va por /dev/nvidiaN).
- `/etc/default/grub.d/egpu-tb-fix.cfg` + `update-grub` en postinst/postrm: añade
  `thunderbolt.host_reset=0 thunderbolt.clx=0` a la línea de comandos del kernel (desde 1.2.0).
  Antes iba en `/usr/lib/modprobe.d`, pero thunderbolt **sí** está en el initramfs
  (`MODULES=most`, carga a los ~5 s, antes de montar la raíz) y no lo veía. Comprobar con
  `egpu-tb-fix status` o `cat /proc/cmdline`.
- `/usr/lib/systemd/system-shutdown/egpu-tb-fix.shutdown` (desde 1.3.0): tras una caída del
  enlace (Xid 79) el remove de nvidia queda colgado con el lock del dispositivo y el
  `device_shutdown()` del kernel se bloquea: el equipo no reinicia (pasó en todos los
  arranques con la eGPU del 2026-10-02). systemd-shutdown ejecuta este hook justo antes del
  `reboot(2)`, con los sistemas de archivos ya en solo lectura; si hay una NVIDIA removible
  en el árbol PCI, espera a `fwupd.shutdown` y reinicia con `echo b > /proc/sysrq-trigger`,
  que salta los callbacks de apagado. Solo al reiniciar: para apagar no hay vía equivalente.
- Regla udev `tb-pm` (desde 1.4.0): mientras haya un router USB4 de dispositivo conectado
  (`1-3`...), el controlador host del dominio (NHI, p. ej. 8a:00.0) queda en
  `power/control=on`; al desconectar el último vuelve a `auto`.
- `egpu-tb-fix hold` / `release` (desde 1.4.0): con `hold` la eGPU queda preparada pero sin
  driver (`driver_override=none`), así una caída del enlace no cuelga el equipo; sirve para
  probar la estabilidad. Se pierde al reiniciar. `debug on|off`: dyndbg del módulo thunderbolt.
- Puerto izquierdo (root port 00:07.0 bajo pci0000:00, USB4 integrado, caja = 20:00.0, GPU =
  22:00.0): ahí el BAR0 cabe (ventana de 194 MB) y, sin compuerta, nvidia tomaba la GPU al
  aparecer. Con 1.4.0 el script la iba a desenlazar a los ~15 s para limitar el enlace y el
  equipo se congeló entero (2026-10-02 20:40; el log se corta a los 48 s, nvidia tomó la GPU a
  los 35 s, sin Xid ni caída del enlace registrados). Causa más probable (no demostrada): ese
  desenlace; `nv_pci_remove` quita la GPU de nvidia-modeset/nvidia-drm en caliente y en una
  eGPU no espera a que la suelten. De ahí la compuerta y el "nunca desenlazar" de 1.5.0. BAR1 ahí es de 256 MB (ventana
  prefetchable de 448 MB, sin ReBAR), suficiente para CUDA.
- No toca el driver nvidia, el initramfs ni la GPU interna.

Prueba del enlace (tras instalar y reiniciar): `sudo egpu-tb-fix hold`, `sudo egpu-tb-fix
debug on`, conectar la caja y vigilar `journalctl -kf | grep -E 'thunderbolt [01]-|Link Down'`
20–30 min. Si aguanta: `sudo egpu-tb-fix release` y probar CUDA. Si cae: probar el puerto
izquierdo (Gen3) o un cable TB4 de 40G con la misma prueba.

Instalar: `sudo apt install ./dist/egpu-tb-fix_<versión>_all.deb`
Revertir: `sudo apt remove egpu-tb-fix` y reiniciar (el reinicio restaura la distribución PCI original).
