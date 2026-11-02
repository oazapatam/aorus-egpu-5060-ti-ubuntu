# Qué hace funcionar la eGPU (informe forense, 2026-11-02)

Este documento existe porque el repositorio describía como "solución vigente" un
stack que llevaba cuatro meses desinstalado.
Se escribió tras una investigación forense sobre la máquina de referencia con la
eGPU funcionando, para que la documentación deje de contradecir a la realidad.

## Respuesta corta

Lo que hace funcionar la eGPU hoy es **`egpu-tb-fix` 1.5.0** sobre el **driver
NVIDIA stock de Canonical 595.99.02**.
No interviene ninguno de los dos paquetes `aorus-egpu-*`, ni el driver
parcheado, ni ninguna palanca del catálogo de levers.

## Lo que NO está en juego

Ambos paquetes `aorus-egpu-*` fueron **purgados el 2026-06-28 a las 17:47**:

```
apt-get purge -y aorus-egpu-nvidia-dkms aorus-egpu-config
```

No queda ni un fichero suyo en disco:
cero units `aorus*`, cero reglas udev `aorus`, no existe `/run/aorus-egpu/`, no
hay binarios `aorus-egpu-*`.

El driver cargado es stock, verificado por cuatro vías independientes:

- `modinfo -n nvidia` apunta a `/lib/modules/7.0.0-1015-oem/kernel/nvidia-595-open/nvidia.ko`
  (en `kernel/`, no en `updates/dkms/`).
- `dpkg -S` atribuye ese fichero a `linux-modules-nvidia-595-open-7.0.0-1015-oem`.
- La versión es **595.99.02**, no el 595.71.05 al que el paquete DKMS fijaba
  `NV_VERSION_STRING`.
- Cero símbolos `tb_egpu`/`AORUS` en el `.ko` cargado, y ningún parámetro
  `NVreg_TbEgpu*`.

`dkms status` solo lista VirtualBox.

## La cadena causal real

La eGPU no estaba presente en el arranque (2026-10-28 12:16).
Entró por **hotplug el 2026-11-02 a las 00:24:03**, y el BAR0 **falló** en la
enumeración nativa del kernel:

```
pci 0000:b4:00.0: BAR 0 [mem size 0x04000000]: can't assign; no space
pci 0000:b4:00.0: BAR 0 [mem size 0x04000000]: failed to assign
```

Entonces actuó `egpu-tb-fix.service`, y en 19 s dejó la tarjeta bindeada:

| Hora | Evento |
|---|---|
| 00:24:03.420 | udev `tb-event add`: controlador TB `8a:00.0` runtime PM `auto → on` |
| 00:24:03.431 | **autoprobe PCI apagado** antes de que exista el device PCI |
| 00:24:04 | `boltd` autoriza la caja (policy `auto`, sin intervención humana) |
| 00:24:19.740 | diagnóstico: `b4:00.0` sin BAR0; puerto vacío detectado: `89:01.0` |
| 00:24:19.742 | `remove` de la caja (`b2:00.0`) y del puerto TB vacío (`89:01.0`) |
| 00:24:20.762 | `rescan` del bus y del puerto → ventana MMIO reasignada |
| 00:24:21.047 | enlace entrenado a **Gen3 8 GT/s x4**, sin ASPM ni runtime PM |
| 00:24:21.047 | autoprobe PCI **reabierto** → nvidia puede bindear |
| 00:24:23.015 | `BAR0 asignado, driver: nvidia` — bind limpio |
| 00:24:23.173 | `/dev/nvidia1` creado con `ub-device-create` |

El kernel confirma la reasignación:

```
pci 0000:b3:00.0: bridge window [mem 0xb0000000-0xb40fffff]: assigned
pci 0000:b4:00.0: BAR 0 [mem 0xb0000000-0xb3ffffff]: assigned
```

Los seis eslabones, todos automáticos:

1. `thunderbolt.host_reset=0 thunderbolt.clx=0` en el cmdline, puestos por
   `/etc/default/grub.d/egpu-tb-fix.cfg`.
   Son args de **estabilidad del enlace**, no de asignación de BAR.
2. Policy `auto` de boltd + enrolamiento guardado → autoriza en 1 s.
3. La regla udev `tb-event` apaga `drivers_autoprobe` **antes** de que exista el
   device PCI, así que `nvidia` no puede bindear una GPU sin BAR0.
4. `egpu-tb-fix.service`: `remove` de caja + puerto vacío, `rescan` → BAR0.
5. Reabre el autoprobe → bind limpio → `/dev/nvidia1`.
6. Reglas `power/control=on` y `ID_SEAT=seat-egpu`: no se duerme y el
   compositor no la toca.

### Sin intervención manual

Cero coincidencias de `fix-egpu|fix-bar0|aorus-egpu|setpci|rescan|boltctl` en el
historial del usuario, cuyo último `mtime` es ~24 h anterior al hotplug.
Cero `sudo`/`su`/`pkexec` en el journal entre el 2026-11-01 12:00 y el hotplug.
No existe `~/.local/bin/fix-egpu`.

## Qué aprendimos sobre el diseño

La diferencia de diseño más visible frente al `aorus-egpu-config` purgado:

- El trigger udev **no** usa VID:PID ni un flag `hotplug-ready`, usa
  `ATTR{removable}=="removable"`.
  Es genérico (cualquier GPU NVIDIA externa, cualquier puerto) y más temprano.
- La **compuerta de autoprobe** se cierra en el evento Thunderbolt, antes de la
  autorización, en vez de carrera contra el bind de nvidia.
- **Nunca desenlaza `nvidia` de una GPU.**
  Hacerlo es justo lo que congelaba el equipo:
  nvidia retira la GPU de `nvidia-modeset`/`nvidia-drm` en caliente y no espera
  a que nadie la suelte.

*Hipótesis, no confirmada:*
la compuerta de autoprobe (paso 3) es la razón más probable de que esta versión
no necesite ni Secondary Bus Reset ni ReBAR bump.
Aislar la palanca imprescindible requiere un test controlado con n>=3
(ver `docs/research/reliability-hypothesis-ledger.md`).

## Los dos "problemas" que la forense creyó encontrar — y no lo son

La primera pasada de la forense marcó dos problemas abiertos leyendo registros.
Medir los desmontó a los dos.
Es la misma lección que ya dejó la hipótesis H18 (ver
`docs/research/tb4-tunnel-gen1-investigation.md`):
**en una eGPU los puentes del túnel Thunderbolt virtualizan sus registros PCIe;
hay que medir, no leer `lspci`.**

### Medición (2026-11-02, este hardware, `tools/egpu-bandwidth`)

```
host -> eGPU (H2D)       3.06 GB/s   (24.5 Gb/s)
eGPU -> host (D2H)       3.38 GB/s   (27.0 Gb/s)
```

Para comparar, el referente Fedora con la RTX 5090 midió 2.80 / 3.29 GB/s y se
declaró "túnel TB saturado, no hay techo que levantar".
**Esta máquina va igual o mejor.**

### "El enlace se degradó a Gen1" — FALSO

El enlace **reentrana bajo demanda**.
Muestreando `current_link_speed` cada segundo durante la medición:

```
2.5 2.5 8.0 8.0 8.0 8.0 8.0 8.0 5.0 5.0 2.5 2.5 2.5 2.5
```

Sube a 8.0 GT/s (Gen3, exactamente su tope) mientras hay tráfico y vuelve a
2.5 GT/s en reposo.
El 2.5 GT/s en idle es gestión dinámica de velocidad, no una degradación, y el
tope Gen3 que pone `egpu-tb-fix` está correctamente aplicado:
`cooling_device36` (`PCIe_Port_Link_Speed_0000:b3:00.0`) está en `cur_state=1`
de `max_state=3`, es decir un escalón por debajo del máximo = Gen3.

**No hay nada que arreglar aquí.**
Leer `current_link_speed` con la GPU en reposo y concluir "degradado" es el
error que este repo ya cometió una vez.

### "BAR1 clavada en 256 MiB" — real, pero no es un cuello de botella

El dato es cierto:
la BAR1 está en 256 MiB y la tarjeta soporta hasta 16 GiB.

```
Capabilities: [134 v1] Physical Resizable BAR
    BAR 1: current size: 256MB, supported: 64MB ... 8GB 16GB
```

`egpu-tb-fix` 1.5.0 no implementa el ReBAR bump (su único `setpci` es una
lectura de Link Status); el `aorus-egpu-config` purgado sí lo tenía (v0.5.7).

Pero **no puede ser el limitante de las transferencias masivas**: esas ya
saturan el túnel Thunderbolt a 3.06/3.38 GB/s.
Subir la BAR1 no ensancha el túnel.
Importa para patrones de acceso concretos (memoria mapeada al host, acceso
directo a VRAM desde la CPU), no para el `cudaMemcpy` a granel.

Queda anotado como mejora **opcional y de prioridad baja**, no como avería.
Antes de implementarlo habría que demostrar con una medición qué carga real
mejora — la metodología del repo exige hipótesis escrita y n>=3 antes de tocar
una palanca (`docs/research/reliability-hypothesis-ledger.md`).

## Veredicto de estado

La eGPU no está "funcionando a medias": está funcionando **bien**, con el
ancho de banda saturando el túnel Thunderbolt y el enlace reentrenando a su
tope cuando hay trabajo.
El stack mínimo que lo consigue es `egpu-tb-fix` 1.5.0 + driver stock, y no
necesita ninguna de las palancas del catálogo de levers.

## Implicaciones para este repositorio

- `egpu-tb-fix` es el paquete **principal y soportado**.
- `aorus-egpu-config` queda como **archivo documentado**: construible, pero no
  se instala junto a `egpu-tb-fix` (ambos gestionan el BAR0 por udev y se
  pisarían).
- `aorus-egpu-nvidia-dkms` queda **archivado y con deuda declarada**:
  sus 34 parches están escritos contra 595.71.05 y el driver instalado es
  595.99.02, así que no cargaría sin un rebase previo.
  La eGPU funciona sin ninguno de ellos.
