# El escritorio en la iGPU, las dos NVIDIA para cómputo

Estado: implementado, pendiente de reinicio para verificar en vivo.
Medido el 2026-11-02 en la máquina de referencia (Lenovo 21RRS22P00).

Lo entrega el paquete [`aorus-egpu-igpu-display`](./packages/README.md).

## El problema, medido

Esta máquina tiene **tres** GPUs:

| Tarjeta DRM | Driver | BDF | Papel |
|---|---|---|---|
| `card2` | `i915` | `0000:00:02.0` | iGPU Intel (Arrow Lake) |
| `card1` | `nvidia` | `0000:01:00.0` | dGPU NVIDIA interna (RTX PRO 4000) |
| `card0` | `nvidia` | `0000:b4:00.0` | eGPU NVIDIA por Thunderbolt (RTX 5060 Ti) |

Con la configuración de fábrica, `kwin_wayland` tenía abiertos
`/dev/nvidia0`, `/dev/nvidiactl` y `/dev/nvidia-modeset`.
Es decir: el compositor estaba usando una GPU NVIDIA para trabajo de pantalla.

Dos consecuencias:

- las NVIDIA no están limpias para cómputo;
- el driver **no se puede descargar**, porque el compositor lo retiene.
  `modprobe -r nvidia` falla con *Module in use* y el refcount no baja.

## Por qué `prime-select` no lo arregla

PRIME ya estaba en **`on-demand`** cuando se midió esto, y el problema persistía.

`prime-select on-demand` afecta al arranque de Xorg y a los defaults de GLX.
No decide qué dispositivos KMS abre un compositor **Wayland**.
Y `nvidia_drm` con `modeset=1` registra un dispositivo KMS por cada GPU NVIDIA,
así que el compositor los enumera y conduce cualquier salida conectada que
encuentre.

Esa es la pieza que había que cambiar, y no está en PRIME.

## El cambio

```
options nvidia_drm modeset=0 fbdev=0
```

Sin KMS, las tarjetas DRM de las NVIDIA desaparecen, el compositor sólo ve la
Intel, y el driver queda libre.

**CUDA no se entera**: el cómputo no usa KMS.
Verificado en esta sesión con la eGPU a 100 % de uso y 180 W, 47,6 TFLOPS fp16
en cuBLAS, con `modeset=1` activo;
quitar el KMS no toca ninguna de las rutas que eso usa.
Los render nodes siguen existiendo, así que PRIME render offload
(`__NV_PRIME_RENDER_OFFLOAD=1`) sigue disponible para lanzar una aplicación
concreta sobre la NVIDIA.

### El nombre del fichero es parte del arreglo

El fichero se instala como
`/etc/modprobe.d/zz-aorus-egpu-igpu-display.conf`,
y el prefijo `zz-` **no es decorativo**.
En esta máquina hay otros dos ficheros que ponen `modeset=1`:

```
/etc/modprobe.d/nvidia-graphics-drivers-kms.conf   (nvidia-driver-595)
/usr/lib/modprobe.d/nvidia-kms.conf                (nvidia-prime)
```

En los parámetros de módulo gana la **última** asignación, así que el orden de
lectura decide quién manda.
No se supuso: se midió con `modprobe --showconfig`, y con el prefijo `zz-` la
línea sale en la posición 547, después de las dos de `modeset=1` (536 y 539).

Si alguien renombra el fichero a algo que ordene antes, el cambio deja de tener
efecto **en silencio**.

## El gate: por qué el postinst puede negarse a activar

Si la iGPU no tuviera ninguna salida conectada, quitarle el KMS a NVIDIA deja la
máquina **sin ninguna pantalla**, y eso no se descubre hasta después de
reiniciar.

Por eso el fichero viaja en `/usr/share/aorus-egpu/` y el `postinst` lo copia a
`/etc/modprobe.d/` **sólo si** `aorus-egpu-display check` pasa.
Una instalación no puede dejar la máquina ciega.

El gate es una función pura con test (`src/domain/display.sh`,
`tests/run.sh`), no una comprobación improvisada en un maintainer script:

| Veredicto | rc | Cuándo |
|---|---|---|
| `ok` | 0 | la iGPU tiene salidas y NVIDIA ninguna |
| `nvidia-outputs-lost` | 2 | la iGPU tiene salidas, pero NVIDIA conduce alguna que se apagará |
| `no-display` | 1 | la iGPU no tiene ninguna salida: **bloquea** |
| `unknown` | 3 | no se pudo contar: no se afirma que sea seguro |

## El coste, y cómo se resolvió aquí

Las pantallas cableadas a una salida de la NVIDIA **dejan de dar imagen**.

En este equipo el **HDMI va a la dGPU interna**, no a la Intel.
Al medirlo, `card1-HDMI-A-1` estaba `connected` y `enabled` a 1920x1080:
el monitor externo lo pintaba la NVIDIA.

La solución no fue renunciar al monitor:
se pasó a un puerto **USB-C/Thunderbolt**, que sale por la iGPU.
Tras moverlo, el inventario quedó así:

```
card2  i915    0000:00:02.0  escritorio  2 salidas: eDP-1 (panel) + DP-1 (monitor)
card1  nvidia  0000:01:00.0  cómputo     0 salidas
card0  nvidia  0000:b4:00.0  cómputo     0 salidas
```

Con eso el gate pasa a `ok` y no se pierde nada.

## Verificar después de reiniciar

```bash
aorus-egpu-display status
```

Lo que debe salir:

- las dos `nvidia` con **0 salidas conectadas**;
- `nvidia_drm modeset: N` — o que `nvidia_drm` no esté cargado, que también
  vale;
- la `i915` con el panel y el monitor.

Y lo que motivó todo esto:

```bash
sudo aorus-egpu-display unload    # ahora sí debe soltar el driver
sudo aorus-egpu-display reload
```

`unload` para antes `nvidia-persistenced`, que es quien retiene el driver:
lo arrastra `sys-bus-pci-drivers-nvidia.device`, así que vuelve a levantarse en
cuanto el driver bindea.
Si algo más lo retiene, `unload` dice **qué proceso** y con qué PID, en vez de
dejar un *Module in use* sin dueño.

## Revertir

```bash
sudo apt remove aorus-egpu-igpu-display
sudo reboot
```

El `postrm` borra la configuración y regenera el initramfs, con lo que NVIDIA
vuelve a su `modeset=1`.
El initramfs importa: los módulos de nvidia viajan dentro (3 `.ko` en el de
este kernel), así que un cambio en `modprobe.d` que no se regenere ahí no surte
efecto en el arranque.
