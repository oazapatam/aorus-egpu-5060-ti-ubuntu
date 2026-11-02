# Defectos abiertos en la serie de parches del driver

Estado: vivo.
Última revisión: 2026-11-02.

Este documento recoge los defectos **conocidos y no arreglados** de los 37
parches de `kernel/patches/`, con su análisis y lo que falta para cerrarlos.
Existe para que un defecto conocido no se confunda con un defecto olvidado:
lo que está aquí se decidió no tocar, y la razón está escrita.

Procedencia:
nacen de una revisión estática de la serie hecha el 2026-11-02.
Los que **sí** se arreglaron ese día están en los parches `0036`, `0037` y
`0038`; lo que sigue es el resto.

Limitación que afecta a todo lo de abajo:
el paquete DKMS está *superseded* y pendiente del rebase 595.71.05 → 595.99.02,
así que **nada de esto está compilado ni ejecutado**.
Son lecturas del código, no observaciones.
La etapa 7b de `ci/40-kernel-patches.sh` verifica que los parches *apliquen*,
que no es lo mismo que que funcionen.

---

## D1 — El segundo ciclo de deadlock del work handler

**Gravedad: alta. Ruta: `pci_reset_bus` desde el work item de M-recover.**

`0038` cerró el ciclo que pasaba por `pci_rescan_remove_lock`.
Queda otro que no necesita ningún lock global:

- `pci_reset_bus()` → `pci_bus_lock()` → `device_lock(gpu)`.
- La ruta de `remove` del core PCI sostiene `device_lock(gpu)` y espera en
  `cancel_work_sync(&lm->reset_work)`.

Se dispara igual: recuperación en vuelo y desenchufe de la caja o `rmmod`.

Lo que haría falta, y por qué no se ha hecho:
la vida del work item tiene que dejar de depender de un `cancel_work_sync` bajo
`device_lock`.
Las dos salidas razonables son un refcount sobre `lm` en vez del `kfree()` de
`tb_egpu_lever_m_recover_stop`, o sacar el reset del work item.
Las dos son un rediseño del modelo de vida del objeto, y un refcount mal puesto
en una ruta de error de PCIe es un use-after-free.
Escribir eso a ciegas, contra un driver que hoy no se puede compilar, cambia un
cuelgue por una corrupción de memoria.
No es una mejora.

Precondición para arreglarlo: que el paquete compile (rebase hecho) y que haya
forma de provocar el escenario con la traza forense puesta.

## D2 — Fuga de referencia de `pci_dev` si el work se cancela sin ejecutarse

**Gravedad: media. Misma zona que D1.**

`lm->pdev_for_work = pci_dev_get(pdev)` se suelta **solo** en la etiqueta
`out_put` del handler.
`cancel_work_sync()` sobre un trabajo encolado y no ejecutado no invoca al
handler, así que la referencia no se suelta nunca y el `struct pci_dev` no se
libera.
`tb_egpu_lever_m_recover_stop` además hace `kfree(lm)` dejando
`pdev_for_work` colgando.

No se arregla aquí porque el arreglo correcto es el mismo rediseño de D1:
quien decide la vida del work decide también la de su referencia.
Parchearlo por separado (un `pci_dev_put` en `_stop`) es plausible pero
compite con el handler por la misma referencia sin exclusión, que es
exactamente el problema de D1.

## D3 — El gate de enlace no existe en el C, y la corrección obvia es incorrecta

**Gravedad: media-alta, pero el arreglo no es el que parece.**

`CLAUDE.md` fija como invariante que nada intrusivo se haga con el enlace
degradado: apretar la tarjeta por debajo de Gen3 congeló el host entero.
Ese gate vive en `src/domain/link.sh`, **no en el driver**.
En el C no hay ninguna comprobación del enlace antes de una acción intrusiva:

- `nv_pci_error_detected` devuelve `NEED_RESET` sin mirar el enlace.
- el work handler hace `pci_reset_bus(bridge)` sin mirarlo.
- `0022` escribe `PCI_ERR_UNCOR_MASK = 0` en `probe` sin mirarlo.

`0020`/`0021` **leen** `LnkSta` con todo detalle, y solo para imprimirlo.

**La recomendación evidente —gatear con `PCI_EXP_LNKSTA_CLS >= 3`— es un
error**, y es el mismo error que este repo acaba de quitar de su gate de
userspace el 2026-11-02.
`PCI_EXP_LNKSTA_CLS` es exactamente lo que expone `current_link_speed`, y está
**medido** en esta máquina: en reposo marca `2.5 GT/s` siempre, porque el
enlace baja de velocidad solo y vuelve a subir con tráfico
(`2.5 2.5 8.0 8.0 … 2.5`).
Un evento AER es precisamente un momento sin tráfico.
Gatear ahí convertiría el gate en un "no recuperes nunca", que es el fallo que
`domain/link.sh` tenía y que [`what-actually-works.md`](../what-actually-works.md)
ya documenta como cometido una vez.

Lo que el userspace usa en su lugar es `pcie.link.gen.max` de `nvidia-smi`, la
capacidad **negociada**, que en esta máquina vale 3 y no baja en reposo.
En el kernel ese dato no está disponible tal cual:
`PCI_EXP_LNKCAP` del endpoint anuncia la capacidad de la *tarjeta* (32 GT/s) y
los puentes del túnel tienen los registros **virtualizados** y anuncian
`2.5 GT/s` (`b2:00.0` marca `max=2.5 GT/s`).
Las dos lecturas mienten, cada una en un sentido.

La vía que queda, y que habría que diseñar antes de escribir código, es una
**marca de agua**: registrar en el estado por dispositivo la generación máxima
vista entrenada —`0020`/`0021` ya leen ese dato en los sitios adecuados— y
gatear contra ella.
Eso deja una decisión de política sin resolver:
si nunca se vio Gen3, ¿se bloquea la recuperación o se permite?
Bloquear deja una eGPU muerta; permitir reintroduce el riesgo de cuelgue.
La regla del repo ("no bindea es aceptable, bindea y congela no") apunta a
bloquear, pero aplicada a la *recuperación* la consecuencia es distinta de
aplicada al *bind*, y esa decisión no es de quien escribe el parche.

Por eso aquí no hay parche: hay un diseño pendiente.
Cuando se haga, es un lever nuevo y necesita su entrada en
[`lever-catalog.md`](./lever-catalog.md) y su hipótesis escrita.

## D4 — Q-active y Q-watchdog declaran fallo permanente con una sola lectura

**Gravedad: alta en consecuencia, y contradice al Lever I.**

El Lever I (`0001`) existe porque una lectura de `NV_PMC_BOOT_0` **no es
fiable** sobre Thunderbolt: reintenta 10 veces con 100 µs.
Pero `0013` (Q-active) y `0014` (Q-watchdog) se comprometen con n=1: una
lectura que devuelva `0xFFFFFFFF` lleva a `os_pci_set_disconnected()`, que
escribe `pci_channel_io_perm_failure` — un estado **sumidero sin transición de
salida**.

Dos consecuencias:

1. Un glitch transitorio del túnel —el mismo que el Lever I perdona— mata la
   eGPU de forma definitiva hasta recargar el módulo.
2. Con `pci_channel_io_perm_failure` puesto, el core PCI rechaza accesos de
   configuración, así que `pci_reset_bus()` y `pci_restore_state()` de
   M-recover ya no pueden recuperar nada.
   **Q sabotea a M-recover**, y los dos levers compiten por el mismo
   dispositivo con políticas opuestas sin coordinarse en ningún punto.

Añadido: `0xFFFFFFFF` es un valor legítimo para registros de máscara, y
Q-active dispara una lectura de verificación en cada uno.

No se arregla aquí porque el arreglo tiene dos mitades y una es política:
reutilizar el patrón de reintento del Lever I es mecánico, pero decidir **quién
manda cuando Q y M discrepan** es una decisión de diseño que afecta a la
máquina de estados de los dos levers.
Además la mitad que habría que tocar (`0013`) está en el árbol RM, que la etapa
7b del CI **no cubre**: se escribiría sin red.

## D5 — El watchdog no sabe nada de PM/D3

**Gravedad: media, condicionada a la configuración.**

Ningún hunk de `0014`/`0015`/`0023` toca `nv_pm_ops`, `nv_pci_suspend/resume`
ni `runtime_suspend`.
El kthread lee `nv->regs->map[0]` a 5 Hz indefinidamente, y el único argumento
de seguridad es un comentario que dice que la máquina fuerza
`NVreg_DynamicPowerManagement=0` y `d3cold_allowed=0` por `modprobe.d` y udev.

El problema es que **el `.deb` de DKMS no entrega esos ficheros**.
Con el dispositivo en D3hot/D3cold el `ioread32` del kthread devuelve
`0xFFFFFFFF` → `os_pci_set_disconnected` → eGPU marcada como fallo permanente
al despertar, sin vuelta atrás (ver D4).
O sea: la palanca de seguridad del watchdog es un fichero de configuración
externo, no una invariante del código.

## D6 — `kthread_stop` puede bloquear un intervalo completo bajo `device_lock`

**Gravedad: baja hoy, alta si alguien sube el intervalo.**

`0014` usa `msleep_interruptible(interval_ms)`, que solo aborta ante
`signal_pending(current)`.
`kthread_stop()` pone `KTHREAD_SHOULD_STOP` y despierta el hilo, pero sin señal
pendiente el hilo **vuelve a dormir el resto del intervalo**.
Con los 200 ms por defecto es tolerable; el intervalo es escribible en caliente
(`module_param(..., 0644)`) y el clamp llega a 60000 ms, así que un desenchufe
puede bloquear `nv_pci_remove_helper` hasta 60 s **con `device_lock` tomado**,
lo que además amplía la ventana de D1.

Arreglo conocido y de una línea:
`wait_event_interruptible_timeout(wq, kthread_should_stop(), msecs_to_jiffies(interval))`.
No se hace en este pase porque requiere añadir una `wait_queue_head_t` al
estado del watchdog, y el estado del watchdog es lo que `0036` acaba de tocar:
conviene no apilar dos cambios de concurrencia sobre la misma estructura sin
poder compilar entre uno y otro.

## D7 — Lectura del VFS desde `nv_pci_probe`

**Gravedad: media. Y describe una capa que en Ubuntu no existe.**

`0024` llama `kernel_read_file_from_path("/var/lib/aorus-egpu/lever-m-killswitch", …)`
desde `tb_egpu_lever_m_recover_init()`, que corre **dentro de `nv_pci_probe`**,
con `device_lock(&pci_dev->dev)` tomado y, en un hotplug de Thunderbolt,
también con `pci_rescan_remove_lock`.
Una E/S de VFS ahí es de duración no acotada: un `/var` lento, cifrado o en red
cuelga la ruta de probe con los dos locks retenidos.

Y en el arranque `nvidia.ko` puede cargarse antes de montar la raíz, así que el
kill switch persistente es inerte precisamente cuando haría falta.

Lo más serio es otra cosa:
**el fichero y su CLI no existen en este repo para Ubuntu.**
`aorus-egpu-lever-m-killswitch-restore` solo está en `legacy/fedora/`, y ningún
paquete de `packaging/` crea `/var/lib/aorus-egpu/` ni la regla udev.
El driver lee estado de una ruta que ningún `.deb` posee ni limpia con
`apt remove`, lo que choca con la restricción principal del repo.
Decidir si eso se entrega o se quita del driver es anterior a cualquier parche.

## D8 — Los levers del lado RM no tienen gate por dispositivo

**Gravedad: baja para R4, real para la contabilidad.**

`0002`, `0003`, `0004`, `0006`, `0008`, `0011`, `0012` se gatean **solo** por
`PDB_PROP_GPU_IS_LOST` / `pci_dev_is_disconnected`, nunca por dispositivo.
No son "toques" en el sentido de R4 —ni escrituras ni resets—, así que no
reproducen el Xid 79, pero cambian el comportamiento sobre la interna.
En particular `0006` (Lever N) haría que la contabilidad host/GSP de la interna
divergiera de forma permanente si alguna vez se marca como perdida.

El mensaje de `0031` dice que gatea *"EVERY active lever"*;
con esta capa delante, es más fuerte de lo que el código entrega.
`0037` cerró lo equivalente en la mitad `kernel-open`.
Esta mitad está en el árbol RM, que el CI no cubre.

## D9 — El predicado R4 no usa el mecanismo que prescribe `CLAUDE.md`

**Gravedad: baja, con un riesgo de fail-silent.**

`0031` implementa el predicado así:

```c
if (pci_is_thunderbolt_attached(pdev)) return NV_TRUE;
if (pdev->vendor == 0x10de && pdev->device == 0x2d04) return NV_TRUE;
return NV_FALSE;
```

`CLAUDE.md` dice que la confirmación topológica se hace con el atributo
`removable`, **no** subiendo el árbol PCI.
`pci_is_thunderbolt_attached()` sube por `pci_upstream_bridge()` buscando
`parent->is_thunderbolt`.

Matiz a favor del parche:
no es el antipatrón que `CLAUDE.md` prohíbe.
La advertencia del repo es sobre buscar el *driver* `thunderbolt` como ancestro
(el NHI es hermano, no ancestro);
`is_thunderbolt` es un flag que el kernel pone en los *puentes PCIe* a partir
del DVSEC de Intel, y esos puentes sí son ancestros del dispositivo
tunelizado.

El riesgo que queda es de fail-silent:
si el switch de la caja o los puertos downstream del controlador TB no exponen
ese DVSEC, `is_thunderbolt` es 0 en toda la cadena y **el único que salva el
gate es el fallback por device-id `0x2d04`**.
La puerta primaria puede estar muerta sin que nadie lo note, porque el fallback
la tapa.
Y si se cambia de eGPU, el predicado pasa a devolver `NV_FALSE` en todo: todos
los levers se desactivan en silencio (fail-safe para R4, pero R3 desaparece sin
aviso).

Falta una comprobación en vivo de que `pci_is_thunderbolt_attached()` devuelve
`true` para esta eGPU.
Hasta entonces, el gate R4 depende de un solo `if` sobre un device-id.

Relacionado y de una línea:
`0032` usa `pci_get_device(0x10de, PCI_ANY_ID, pdev)` **sin filtrar por clase**,
así que el predicado es cierto para cualquier función 10de detrás del túnel,
incluida la de audio HDMI de la eGPU (`b4:00.1`).
Hoy gana la GPU por orden de enumeración, pero el código no lo garantiza.
Falta un `(pdev->class >> 16) == PCI_BASE_CLASS_DISPLAY`.

---

## Lo que sí se arregló el 2026-11-02

| Parche | Qué |
|---|---|
| `0036` | Publicar `nvl->qwd` antes de arrancar el kthread del watchdog. |
| `0037` | Gate R4 en las cuatro rutas de diagnóstico que aún tocaban la GPU interna, y el gate de `nv_pci_error_detected` por delante del volcado AER (que de paso deja de gastar el latch global en la interna). |
| `0038` | Quitar el `pci_lock_rescan_remove()` que envolvía `pci_reset_bus()`: cierra uno de los dos ciclos de deadlock. |

Y un hallazgo que resultó **falso**:
que `0032` no aplicara sobre la serie.
Aplica, con `--recount`, y su efecto se verificó en el árbol parcheado.
El reporte venía de un método de aplicación contaminado;
el detalle está en `docs/ci-kernel-patches.md`, sección 7b.
