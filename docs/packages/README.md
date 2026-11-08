# Estado de los paquetes

Tabla de verdad única sobre qué paquete usar.
La evidencia de por qué está en
[`../what-actually-works.md`](../what-actually-works.md).

| Paquete | Versión | Estado | Validado en vivo |
|---|---|---|---|
| `egpu-tb-fix` | 1.5.1 | **principal** | **sí** — es lo que hace funcionar la eGPU hoy |
| `aorus-egpu-forensics` | 0.1.0 | nuevo, recomendado al depurar | capas 1-2 sí; capa 3 (ramoops) por construcción |
| `aorus-egpu-health` | 0.1.0 | nuevo — detector de incidentes | las reglas y el `scan` sí; el servicio de vigilancia continua, no |
| `aorus-egpu-igpu-display` | 0.1.0 | nuevo — [diseño y medidas](../igpu-display.md) | el gate y el inventario sí; el cambio de modeset requiere reiniciar |
| `aorus-egpu-overclock` | 0.1.0 | **en desarrollo, no usar** — [palancas y perfiles medidos](../overclock.md); entrega `aorus-egpu-oc` (CLI) y `nvidia-oc` (TUI) | no |
| `aorus-egpu-config` | 0.5.9 | **superseded** (archivo) | lo estuvo hasta el 2026-06-28; purgado |
| `aorus-egpu-nvidia-dkms` | 595.71.05-aorus17 | **superseded + deuda de versión** | lo estuvo hasta el 2026-06-28; purgado |

## Qué instalar

Para que la eGPU funcione, solo esto:

```bash
make
sudo apt install ./dist/egpu-tb-fix_*.deb
sudo reboot
```

Si además quieres poder depurar los cuelgues:

```bash
sudo apt install ./dist/aorus-egpu-forensics_*.deb
```

## Qué NO instalar, y por qué

- **`aorus-egpu-config` junto a `egpu-tb-fix`.**
  Los dos reasignan el BAR0 desde reglas udev y se pisarían.
  El paquete declara `Conflicts: egpu-tb-fix`, así que `apt` lo impedirá.
- **`aorus-egpu-nvidia-dkms` tal cual.**
  Sus 34 parches están escritos contra el tag 595.71.05 y fijan
  `NV_VERSION_STRING` a esa versión, pero el driver instalado es el stock
  595.99.02:
  los módulos no cargarían.
  Necesita un rebase al tag nuevo antes de volver a usarse.
  La eGPU funciona sin ninguna de sus palancas.
- **`aorus-egpu-overclock`.**
  El núcleo y los tests están hechos, pero no se ha validado en hardware.
  Entrega dos entrypoints:
  `aorus-egpu-oc` (CLI) y `nvidia-oc` (el TUI de ncurses, pura presentación
  sobre la CLI).
  De sus perfiles entregados solo `efficient` tiene efecto real medido
  (+31% de eficiencia por -13% de rendimiento):
  el límite de potencia no se puede subir —`max_limit` == `default_limit` ==
  180 W— y la carga más pesada medida consume 139 W de esos 180,
  así que cualquier tope entre 140 y 180 W es decorativo.
  Lo que sí existe, y antes esta página daba por imposible, son los **offsets**
  de ±MHz por NVML:
  ventana de -1000 a +1000 MHz en el núcleo y de -2000 a +6000 MHz en la
  memoria, medida el 2026-11-02.
  Un offset POSITIVO no se aplica sin pasar el gate de verificación numérica
  bit-exacta, y dónde está su borde real se está midiendo con
  `tools/egpu-oc-edge`
  ([H25](../research/reliability-hypothesis-ledger.md#h25)).
  Las palancas que el caso de uso de IA sí necesita —persistencia del driver y
  modo de cómputo exclusivo— todavía no están implementadas:
  ver [`../overclock.md`](../overclock.md).

## Un paquete por capacidad

La división no es por componente del sistema sino por **capacidad**, para que
cada una se pueda instalar, revertir y razonar por separado:

- `egpu-tb-fix` — que la eGPU enumere y bindee.
- `aorus-egpu-forensics` — que un cuelgue deje evidencia.
- `aorus-egpu-health` — que un incidente se sepa cuando pasa, con veredicto de
  dónde mirar.
- `aorus-egpu-overclock` — que se pueda ajustar potencia, relojes y offsets.

Todas comparten el mismo núcleo `src/`, ensamblado en el payload por
`scripts/lib/bundle.sh`;
`egpu-tb-fix` es la excepción, porque es anterior al núcleo y está validado tal
cual (ver la deuda nº 1 en [`../architecture.md`](../architecture.md)).
