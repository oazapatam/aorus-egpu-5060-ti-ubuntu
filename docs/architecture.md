# Arquitectura del núcleo: puertos y adaptadores

Este documento explica **cómo está construido `src/`** y, sobre todo, **qué
reglas hay que respetar al añadir código**.
Describe lo que hay en el repo hoy (2026-11-02), no un plan.
Para saber *qué hace funcionar la eGPU en esta máquina* ve a
[`what-actually-works.md`](./what-actually-works.md);
este fichero trata del diseño del software, no del hardware.

El objetivo de la estructura es concreto:
poder añadir capacidades a la eGPU —un perfil nuevo, un lever de ReBAR, control
de ventiladores— sin que cada una reinvente la detección de hardware ni los
gates de seguridad, y sin tener que enchufar la caja para saber si la lógica es
correcta.

---

## 1. Por qué no scripts monolíticos

El punto de partida honesto:
en el stack anterior la lógica crítica estaba enterrada dentro de scripts
largos.
`packaging/aorus-egpu-config/usr/sbin/aorus-egpu-fix-bar0` son **423 líneas** en
las que conviven, en el mismo fichero, la detección del device PCI, la decisión
de si ese device es la eGPU o la GPU interna, la aritmética de ventanas MMIO,
las escrituras destructivas al bus y el logging.

Eso tiene tres consecuencias medibles:

- **No se puede probar nada sin el hardware.**
  Para saber si el targeting era correcto había que conectar la caja,
  ejecutar como root y ver qué pasaba.
  Dado que el modo de fallo del proyecto es *congelar el host entero sin Xid ni
  panic*, "ejecutar y ver qué pasa" cuesta un reinicio duro por iteración.
- **La regla de seguridad se duplica.**
  Cada script que toca el bus necesita decidir por su cuenta "esta es la externa,
  esta no".
  Una copia de la comprobación que se olvida es exactamente cómo se acaba
  escribiendo en la GPU interna.
- **Cambiar de herramienta implica reescribir la regla.**
  La decisión ("acotar 250 W a 180 W") y la ejecución (`nvidia-smi -pl 180`)
  estaban pegadas, así que pasar de `nvidia-smi` a NVML obligaba a reescribir
  también el clamping.

Hoy el gate R4 y el gate de enlace son **funciones puras con tests**.
`make test` corre `tests/run.sh`:
**51 asserts en milisegundos, sin root, sin GPU y sin eGPU conectada.**
La cabecera del propio fichero de tests lo dice así:

```bash
# Esto es lo que compra la arquitectura hexagonal: las reglas que importan
# (el gate R4 y el gate de enlace) se verifican en milisegundos, en cualquier
# máquina, sin una eGPU conectada. Antes vivían enterradas en un script de 423
# líneas que solo se podía probar enchufando la caja y cruzando los dedos.
```

Esto **no** es una reescritura de `aorus-egpu-fix-bar0` ni de `egpu-tb-fix`.
Los scripts validados en vivo siguen donde están;
lo nuevo se escribe con esta estructura.
Ver §9 para el estado real de la migración.

---

## 2. La regla de dependencias

Es la única parte de este documento que es obligatoria.
Todo lo demás se deduce de ella.

| Capa | Depende de | Puede tocar el mundo exterior |
|---|---|---|
| `src/domain/` | **nada** | **no** |
| `src/ports/` | nada (solo declara) | no |
| `src/adapters/` | el puerto que implementa | **sí, en exclusiva** |
| `src/app/` | `domain/` + `ports/` | no (solo a través de puertos) |
| `src/bin/` | `app/` | no (solo argv y `sudo`) |
| `packaging/` | nada | — (es entrega, no código) |

En detalle:

- **`domain/` no depende de NADA.**
  Ni de `ports/`, ni de `adapters/`, ni de I/O.
  Funciones puras:
  reciben datos ya leídos, deciden e imprimen el veredicto.
  No abren `sysfs`, no invocan `nvidia-smi`, no escriben logs.
- **`ports/` solo declara contratos y los verifica.**
  Un puerto no implementa nada:
  enumera en un comentario las funciones que un adaptador debe ofrecer y expone
  un `port_*_assert` que falla con un mensaje explícito si falta alguna.
- **`adapters/` implementan un puerto y son los ÚNICOS que tocan el mundo
  exterior**:
  `sysfs`, `nvidia-smi`, `boltctl`, `journald`, `/dev/kmsg`, el disco.
- **`app/` orquesta `domain` + `ports`.**
  No conoce herramientas concretas.
  Aquí viven el orden de los gates, la carga del perfil y la secuencia de
  llamadas.
- **`bin/` son entrypoints finos**:
  parsean argumentos, deciden si hace falta `sudo` y llaman a un caso de uso.
- **`packaging/` es SOLO entrega:
  cero lógica.**
  El payload se ensambla desde `src/` con `scripts/lib/bundle.sh`.

### Diagrama de capas

```
                    LAS DEPENDENCIAS APUNTAN SIEMPRE HACIA DENTRO
                              (nunca al revés)

   +--------------------------------------------------------------------+
   |  bin/            aorus-egpu-oc                                     |
   |                  argv, --dry-run/--force, need_root, un caso de uso |
   |                                  |                                  |
   |                                  v                                  |
   |  +--------------------------------------------------------------+  |
   |  |  app/        overclock.sh            forensics.sh            |  |
   |  |              oc_apply/oc_status      forensics_probe/        |  |
   |  |              oc_resolve_target        forensics_postmortem   |  |
   |  |                      |                        |              |  |
   |  |                      v                        v              |  |
   |  |  +--------------------------------------------------------+  |  |
   |  |  |  domain/     target.sh    link.sh    overclock.sh      |  |  |
   |  |  |              gate R4      salud del  validación,       |  |  |
   |  |  |                           enlace     clamping, PLAN    |  |  |
   |  |  |                                                        |  |  |
   |  |  |              FUNCIONES PURAS - NO DEPENDE DE NADA      |  |  |
   |  |  +--------------------------------------------------------+  |  |
   |  +--------------------------------------------------------------+  |
   +--------------------------------------------------------------------+
```

### El borde: puertos y adaptadores

`app/` nunca nombra una herramienta.
Nombra un puerto;
el adaptador se elige en el arranque del caso de uso.

```
        FUERA (mundo real, efectos)        |       EL CONTRATO (dentro)
   -------------------------------------------------------------------------
    adapters/gpu/nvidia-smi.sh      --implementa-->  ports/gpu.port.sh
    adapters/pci/sysfs.sh           --implementa-->  ports/pci.port.sh
    adapters/thunderbolt/boltctl.sh --implementa-->  ports/thunderbolt.port.sh
    adapters/log/stderr.sh          --implementa-->  ports/log.port.sh
    adapters/trace/durable.sh       --implementa-->  ports/trace.port.sh

    nvidia-smi, /sys/bus/pci, boltctl,              app/ llama SOLO a
    journald, /dev/kmsg, disco                      gpu_*, pci_*, tb_*,
                                                    log_*, trace_*
```

### El cargador: `bootstrap.sh`

`src/bootstrap.sh` es la única forma de cargar una capa.
Resuelve la raíz de las librerías en los dos escenarios —el checkout
(`<repo>/src/`) y el paquete instalado (`/usr/lib/aorus-egpu/`)— de modo que el
mismo código corre en ambos sin ramas:

```bash
# aorus_use <capa>/<modulo> [...]
#   aorus_use domain/overclock adapters/gpu/nvidia-smi
aorus_use() {
```

`aorus_use` es **idempotente** (lleva registro en `_AORUS_LOADED`), así que cada
caso de uso puede declarar todas sus dependencias sin preocuparse de que otro
módulo ya las haya cargado.

---

## 3. Cómo se mapea a SOLID en shell

SOLID se escribió para objetos, pero las cinco ideas se traducen a módulos de
bash sin forzarlas.
Un ejemplo real de cada una:

### S — Responsabilidad única

Un módulo, una responsabilidad.
`src/domain/link.sh` **solo** juzga el enlace:
convierte `"8.0 GT/s PCIe"` en `3` y emite `healthy|degraded|dead`.
No sabe qué se va a hacer con ese veredicto, no sabe leer `current_link_speed`
y no sabe qué es un perfil de overclock.
Simétricamente, `src/domain/target.sh` solo responde "¿es esta la eGPU?", y
`src/domain/overclock.sh` solo valida, acota y genera el plan.

### O — Abierto/cerrado

Añadir una capacidad = **añadir** un caso de uso y un adaptador,
**sin tocar** el dominio.
`src/app/forensics.sh` es la prueba:
reutiliza `domain/target.sh` y `domain/link.sh` tal cual —ni una línea cambió en
`domain/` para que apareciera la captura forense— y lo nuevo que necesitaba
(traza con `fsync`) entró como puerto + adaptador nuevos
(`ports/trace.port.sh`, `adapters/trace/durable.sh`).

### L — Sustitución

Todo adaptador del mismo puerto es intercambiable.
La sustitución se hace por entorno, con `aorus_adapter` (en `bootstrap.sh`):

```bash
aorus_adapter() { # $1=puerto (gpu|pci|thunderbolt|log) $2=adaptador por defecto
  local var="AORUS_ADAPTER_${1^^}"
  aorus_use "${!var:-$2}"
}
```

`app/overclock.sh` declara el *default*, no la implementación obligatoria:

```bash
aorus_adapter gpu adapters/gpu/nvidia-smi
aorus_adapter pci adapters/pci/sysfs
aorus_adapter log adapters/log/stderr
```

Así, `AORUS_ADAPTER_GPU=adapters/gpu/fake aorus-egpu-oc status` corre el mismo
caso de uso contra un doble de test.
El contrato que ese doble debe cumplir está escrito en `ports/gpu.port.sh`, y
`port_gpu_assert` lo comprueba función por función.

### I — Segregación de interfaces

Cinco puertos pequeños —`gpu`, `pci`, `thunderbolt`, `log`, `trace`— en vez de
un `port_sistema` gigante.
Importa porque los consumidores difieren:
`app/forensics.sh` necesita `pci`, `log` y `trace`, y **no** necesita `gpu`;
cargar un puerto monolítico le obligaría a satisfacer `nvidia-smi` para escribir
migas de pan en disco.

La granularidad también deja espacio para métodos opcionales.
`ports/gpu.port.sh` declara `gpu_set_clock_offset` y le da un default honesto:

```bash
# Default del método opcional: declarar "no soportado" es más honesto que
# omitirlo y que el caso de uso descubra el hueco por un error de bash.
gpu_set_clock_offset() { return 3; }
```

Nótese que `port_gpu_assert` **no** exige `gpu_set_clock_offset`:
los nueve métodos obligatorios se verifican, el opcional tiene fallback.

### D — Inversión de dependencias

`app/` depende del **contrato**, no de `nvidia-smi`.
`oc_execute_plan` llama a `gpu_set_power_limit "$bus" "$a"`;
que detrás haya `nvidia-smi -i <busid> -pl` envuelto en `timeout` es asunto de
`adapters/gpu/nvidia-smi.sh`.
La inversión se materializa con `aorus_adapter` + variables de entorno
(§L), que es lo que da bash en lugar de un contenedor de inyección.

---

## 4. El patrón clave: el dominio produce un PLAN, el adaptador lo ejecuta

Es la decisión de diseño más importante del repo, y la que más conviene imitar
al añadir código.

**El dominio no toca el hardware ni describe cómo se toca.**
Recibe perfil + capacidades leídas y emite un **plan**:
líneas `op<TAB>args`, datos puros.

`domain_oc_plan` (en `src/domain/overclock.sh`) es toda la "inteligencia":

```bash
if [ -n "${OC_power_limit_w:-}" ]; then
  v="$(domain_oc_clamp "$OC_power_limit_w" "$pmin" "$pmax")"
  printf 'power_limit\t%s\n' "$v"
fi
```

Su salida para un perfil que pide 250 W sobre una tarjeta de 150–180 W es,
literalmente, la cadena `power_limit<TAB>180`.
Nada más.
No hay proceso lanzado, no hay fichero abierto, no hay root.

`oc_execute_plan` (en `src/app/overclock.sh`) es el otro lado:
un `while read` con un `case` que traduce cada línea a una llamada al puerto y
la registra:

```bash
power_limit) log_info "  power limit -> ${a} W"
             gpu_set_power_limit "$bus" "$a" || { log_err "  falló power limit"; rc=1; } ;;
```

El `case` **falla cerrado**:
una `op` que no reconoce no se ignora, se reporta
(`"operación desconocida en el plan: $op"`) y marca `rc=1`.

### Qué compra exactamente

**Toda la aritmética y todo el clamping se testean sin hardware.**
Estos son los asserts reales de `tests/run.sh`:

```bash
OC_profile=test OC_power_limit_w=250 OC_gpu_clock_max_mhz=9999 OC_mem_clock_mhz=99999
plan="$(domain_oc_plan 150 180 3090 14001)"
is "plan acota potencia a 180" "$(printf '%s' "$plan" | awk -F'\t' '/power_limit/{print $2}')" "180"
is "plan acota reloj a 3090"   "$(printf '%s' "$plan" | awk -F'\t' '/gpu_clock/{print $3}')"   "3090"
is "plan acota memoria a 14001" "$(printf '%s' "$plan" | awk -F'\t' '/mem_clock/{print $2}')"  "14001"
```

`150 180 3090 14001` son las capacidades reales de esta RTX 5060 Ti, que en
producción salen de `gpu_caps` leyendo
`power.min_limit,power.max_limit,clocks.max.gr,clocks.max.mem`.
En el test son cuatro argumentos.
Eso es todo lo que hace falta para verificar que un perfil con un valor absurdo
se acota en vez de aplicarse.

El mismo patrón da el `--dry-run` **gratis**:
como el plan es texto y la ejecución está separada, `oc_apply` solo tiene que
imprimirlo en vez de pasárselo a `oc_execute_plan`.
No hay un segundo camino de código que pueda divergir del real.

Y permite cambiar de herramienta sin tocar una regla:
pasar de `nvidia-smi` a NVML es escribir `adapters/gpu/nvml.sh`;
`domain_oc_plan` ni se enteraría.

---

## 5. Cómo añadir una capacidad nueva

Receta, en este orden.
Los ejemplos entre paréntesis son "controlar los ventiladores de la caja" y
"un lever de ReBAR".

1. **Escribe la regla como función pura en `src/domain/`.**
   Un fichero por responsabilidad:
   `src/domain/fan.sh` (curva de ventilador: temperatura → % de PWM, acotado),
   `src/domain/rebar.sh` (dado el tamaño actual de la BAR1 y los tamaños
   soportados, ¿cuál se pide?).
   Si tu regla necesita leer algo, **no la has terminado de separar**:
   pasa ese dato como argumento.

2. **Escribe los tests ANTES del adaptador,** en `tests/run.sh`.
   Esto no es ceremonia:
   es la única forma de verificar la aritmética sin arriesgar un cuelgue del
   host.
   Si la regla produce un plan, afirma sobre el plan como en §4.
   `make test` tiene que pasar con el adaptador todavía sin escribir.

3. **Define o reutiliza un puerto en `src/ports/`.**
   Reutiliza si el contrato existente ya cubre lo que necesitas
   (ReBAR es topología y enlace: probablemente `ports/pci.port.sh`).
   Crea `src/ports/fan.port.sh` solo si de verdad es un mundo exterior nuevo.
   Un puerto nuevo = la lista de funciones en el comentario de cabecera + su
   `port_fan_assert`.
   Puertos pequeños (§I);
   si dudas, parte en dos.

4. **Escribe el adaptador en `src/adapters/<puerto>/<herramienta>.sh`.**
   Es el único sitio donde aparecen rutas de `sysfs`, `setpci` o binarios
   externos.
   Dos convenciones que vienen de incidentes reales:
   envuelve toda invocación externa en `timeout`
   (ver `_smi` en `adapters/gpu/nvidia-smi.sh`), y
   mantén los adaptadores de lectura estrictamente de lectura.

5. **Escribe el caso de uso en `src/app/`.**
   Aquí van los gates, en este orden:
   resolver el target con R4, confirmar la topología, consultar el gate de
   enlace, y solo entonces pedir el plan al dominio y ejecutarlo.
   Reutiliza `oc_resolve_target` como plantilla;
   no escribas tu propia versión de los gates (§6).

6. **Añade el entrypoint en `src/bin/`.**
   Fino:
   `set -uo pipefail`, localizar `bootstrap.sh`, `aorus_use app/<tu-caso>`,
   parsear argv, `need_root` solo para las operaciones que escriben, llamar.
   Mira `src/bin/aorus-egpu-oc`:
   `status` y `list` funcionan como usuario normal precisamente porque la
   elevación se decide por comando y no al principio del script.

7. **Entrega en `packaging/<pkg>/` y un `scripts/build-<pkg>.sh`.**
   Cero lógica en el árbol del paquete:
   unidades systemd, reglas udev, ficheros de `/etc` y maintainer scripts.
   El build llama a `bundle_bins "$ROOT" "$PKG" "$BIN"` y, al terminar,
   a `bundle_clean`.
   El núcleo **no** lo entrega tu paquete:
   lo entrega `aorus-egpu-core`, y tu `DEBIAN/control` lo declara en
   `Depends: aorus-egpu-core (>= 0.1.0)`.
   Añade el target al `Makefile` **con `lint` y `test` como prerrequisitos**,
   como hace `overclock: lint test`.

8. **Documenta.**
   Si es un lever de fiabilidad, entrada permanente en
   `docs/research/lever-catalog.md`;
   si es una hipótesis que hay que medir, al ledger
   (`docs/research/reliability-hypothesis-ledger.md`), con n>=3.

Dos cosas que **no** se hacen:

- Añadir el caso nuevo dentro de `app/overclock.sh` porque "es parecido".
  Si tiene su propio ciclo de vida, es su propio fichero.
- Leer `sysfs` desde `app/` "solo esta vez".
  Eso convierte el caso de uso en intestable y es el primer paso de vuelta al
  script de 423 líneas.

---

## 6. Los gates de seguridad como invariante arquitectónico

Hay dos reglas que ninguna capacidad puede saltarse.
Las dos viven en `domain/`, y ahí está el punto:
**una regla que se implementa en cada script se olvida en alguno;
una regla que es una función del dominio está escrita una vez, testeada una vez
y es imposible de reimplementar mal.**

### Gate R4: jamás tocar la GPU interna

`src/domain/target.sh` fija los tres identificadores del proyecto:

```bash
readonly AORUS_VENDOR_NVIDIA=0x10de
readonly AORUS_EGPU_DEVICE=0x2d04      # AORUS RTX 5060 Ti  (externa, Thunderbolt)
readonly AORUS_INTERNAL_DEVICE=0x2c39  # RTX PRO 4000 Blackwell (INTERNA - prohibida)
```

`domain_target_verdict` devuelve `egpu` (rc 0), `internal` (rc 2) u `other`
(rc 1).
Que "es la interna" tenga un veredicto **propio** y no se confunda con "no es la
eGPU" es deliberado:
encontrarse la interna donde se esperaba la eGPU no es un caso normal a ignorar,
es un bug de targeting que merece abortar ruidosamente.
`app/overclock.sh` lo trata así:

```bash
internal) log_err "GATE R4: $bdf es la GPU INTERNA. Abortando (esto sería un bug de targeting)."; return 2 ;;
```

El motivo está en la cabecera del módulo:
tocar la GPU interna ya rompió la máquina una vez (Xid 79 en `10de:2c39`
durante un resume RTD3/GC6 normal).

**El VID:PID es la primera mitad del gate;
la segunda es la topología.**
`oc_resolve_target` exige además que el device cuelgue de un controlador
Thunderbolt/USB4:
la eGPU está siempre detrás de TB, la interna nunca.
Dos señales independientes para la misma conclusión.

Y aquí hay un detalle que conviene no re-descubrir por las malas, explicado en
el propio adaptador (`src/adapters/pci/sysfs.sh`):
**`pci_is_behind_thunderbolt` NO puede resolverse subiendo el árbol PCI buscando
el driver `thunderbolt`.**
El túnel PCIe se presenta como una cadena de `pcieport` normales y el
controlador TB (NHI) es un **hermano**, no un ancestro.
En esta máquina la eGPU cuelga de
`80:1b.4 -> 88:00.0 -> 89:03.0 -> b2:00.0 -> b3:00.0`
y el NHI está en `8a:00.0`, fuera de esa rama:
buscar hacia arriba da un **falso negativo**.

La señal correcta es **`removable`**, la misma que usa la regla udev de
`egpu-tb-fix`:
el kernel marca `removable` los endpoints que están tras un puerto
hot-pluggable (TB/USB4), y la GPU interna **no tiene ese fichero siquiera**, así
que el discriminador es nítido en ambos sentidos.
Es también la lección de diseño que `what-actually-works.md` destaca de
`egpu-tb-fix` frente al stack purgado:
el trigger genérico por `ATTR{removable}=="removable"` es más temprano y más
robusto que uno por VID:PID.

### Gate de enlace: nada intrusivo con el enlace enfermo

`src/domain/link.sh` fija el umbral y lo justifica:

```bash
readonly AORUS_LINK_MIN_GEN=3
readonly AORUS_LINK_MIN_WIDTH=1
```

Hay **dos** veredictos, y confundirlos rompía el gate.

`domain_link_verdict <speed> <width>` es **descriptivo**:
dice a qué velocidad está entrenado el enlace en el instante de la lectura.
Sirve para un informe y **no es un gate**:

- `dead` — sin width o width 0:
  el túnel no existe;
  expulsar, no insistir.
- `degraded` — enlace vivo pero entrenado por debajo del mínimo.
  En reposo esto es lo **normal**, no una avería.
- `healthy` — entrenado a Gen3 o mejor ahora mismo.

`domain_link_cap_verdict <gen_max> <width>` es **el gate** de las acciones
intrusivas.
Recibe la generación máxima que el enlace puede **negociar**
(`pcie.link.gen.max`, vía `gpu_link_gen_max`), que en esta máquina vale 3 y no
baja en reposo:

- `dead` — igual que arriba.
- `unknown` — no hay lectura de capacidad utilizable.
  **No autoriza**: sin el dato no se puede afirmar que sea seguro.
- `degraded` — el enlace solo puede negociar por debajo de Gen3.
  Este es el caso real del 2026-06-27, el que congeló el host.
- `healthy` — puede negociar Gen3 o mejor, aunque ahora esté en reposo a
  2.5 GT/s.

`domain_link_allows_tuning` toma la **capacidad**, no la instantánea.

El motivo, en la cabecera del módulo:
con el enlace marginal, bindear la eGPU o apretarla ha **congelado el host
entero** (hard-hang sin Xid ni panic, 2026-06-27).
La regla del proyecto es que *"no bindea"* es aceptable y *"bindea y congela"*
no lo es, así que toda acción intrusiva se cierra tras este gate.

Dos consecuencias visibles en `app/overclock.sh`:

- `oc_status` llama al resolver con `AORUS_OC_READONLY=1`, porque leer el estado
  debe funcionar **sobre todo** cuando el enlace no está sano.
  No simula un `--force`:
  antes lo hacía, y el mensaje decía *"`--force` activo: continúo BAJO TU
  RIESGO"* a quien no había pasado ningún flag ni corría ningún riesgo.
- `--force` es el **único** gate relajable, y queda registrado con `log_warn`.
  Se puede relajar porque su riesgo es del usuario;
  R4 no se relaja porque violarlo siempre es un bug.

Hay un tercer gate, de robustez más que de seguridad:
si `nvidia-smi` se cuelga, el adaptador propaga `rc 124` y el caso de uso
**aborta sin reintentar**.
Viene de la v0.5.4 del paquete:
un eGPU semi-roto dejaba a `nvidia-smi` en estado-D y martillearlo lo dejaba
*wedged*.

### Lo que el gate de enlace NO dice

Un `2.5 GT/s` leído en reposo **no** es un enlace degradado.
`what-actually-works.md` documenta la medición:
el enlace reentrena bajo demanda (`2.5 2.5 8.0 8.0 ... 2.5`) y sube a su tope
Gen3 cuando hay tráfico.

Durante un tiempo el gate ignoró eso y leyó la instantánea, con una
consecuencia que nadie había comprobado:
en reposo rechazaba **siempre**, así que `--force` —es decir, apagar el gate—
era el único camino para usar `aorus-egpu-overclock`.
Una protección que solo se puede satisfacer desactivándola no protege nada.
Peor: `tests/run.sh` fijaba ese comportamiento como esperado
(*"estado real actual (Gen1 x4) rechazado"*), así que el CI en verde lo
**certificaba** en vez de detectarlo.

El arreglo no es "generar tráfico antes de leer":
está **medido** que un bucle de `nvidia-smi -q` no reentrena el enlace (sigue
en 2.5 GT/s), así que daría el mismo falso negativo con más complejidad.
Tampoco vale `max_link_speed` de sysfs:
en el endpoint anuncia la capacidad de la **tarjeta** (32 GT/s), y en los
puentes del túnel los registros están virtualizados y anuncian 2.5 GT/s
(`b2:00.0` marca `max=2.5 GT/s` en esta máquina).
Las dos lecturas mienten, cada una en un sentido distinto.

La señal que sí distingue es `pcie.link.gen.max` de `nvidia-smi`:
la capacidad **negociada** del enlace, 3 en esta máquina, que no baja en
reposo.

Con eso, cada veredicto tiene su trabajo:
el de capacidad autoriza o cierra la escritura,
el instantáneo informa,
y para la salud del túnel sigue haciendo falta **medir** ancho de banda
(`tools/egpu-bandwidth`), no leer `current_link_speed`.

---

## 7. Del `src/` al `.deb`: `packaging/` es solo entrega

`scripts/lib/bundle.sh` es la frontera entre el núcleo y la entrega.
Fuente **única**: `src/`.
Lo que queda bajo `packaging/<pkg>/usr/lib/` es **generado y gitignorado**:

```
Mapeo:  src/{bootstrap.sh,domain,ports,adapters,app}  ->  usr/lib/aorus-egpu/
        src/bin/<x>                                   ->  usr/sbin/<x>
```

`bundle_payload` hace `rm -rf` del árbol destino, instala `bootstrap.sh` a
0644, copia las cuatro capas y normaliza permisos (0755 directorios, 0644
ficheros).
Lo llama **solo** `scripts/build-core.sh`:
el núcleo compartido se entrega una vez, en `aorus-egpu-core`.
`bundle_bins` instala los entrypoints pedidos a 0755 en `usr/sbin/`, y es lo
único que ejecutan los builds de las capacidades.
`bundle_clean` lo borra todo al terminar el build, para que lo generado no se
cuele en git ni en el build siguiente —
`scripts/build-overclock.sh` lo llama justo después de `dpkg-deb --build`.

**Por qué el núcleo tiene paquete propio.**
Hasta el 2026-11-07 cada paquete de capacidad entregaba su propia copia del
núcleo en `/usr/lib/aorus-egpu/`, y dpkg no permite que dos paquetes se pisen un
fichero:
instalar `aorus-egpu-overclock` con `aorus-egpu-igpu-display` ya puesto fallaba
en seco con
`trying to overwrite '/usr/lib/aorus-egpu/adapters/drm/sysfs.sh', which is also
in package aorus-egpu-igpu-display`.
El solape era de 45 de 46 ficheros:
el payload entero.
No se había notado porque nunca hubo dos instalados a la vez.
Los atajos no servían:
un `Conflicts` prohibiría la combinación útil (el forense y el detector de
incidentes a la vez), y un `Replaces` sin paquete común rompería la
reversibilidad, porque `apt remove` del último instalado se llevaría el núcleo
del que los otros dependen.
Lo impide ahora la sección 12 de `ci/50-package-policy.sh`, que falla si dos
`.deb` comparten un fichero.

**Copia en vez de symlinks** a propósito:
`dpkg-deb` hornea el contenido, y un symlink al checkout dejaría el paquete roto
en cualquier otra máquina.

Esto es también lo que hace que `AORUS_LIB_ROOT` funcione sin ramas:
la estructura de directorios dentro del `.deb` es idéntica a la de `src/`, así
que `aorus_use domain/target` resuelve igual en el repo
(`<repo>/src/domain/target.sh`) y en el sistema instalado
(`/usr/lib/aorus-egpu/domain/target.sh`).

Lo que `packaging/aorus-egpu-overclock/` aporta de suyo es exactamente lo que
debe aportar un árbol de entrega, y nada más:
el `control`, los tres maintainer scripts, los cuatro perfiles de `/etc`,
la unidad systemd y la regla udev.
La regla engancha a `bind` y no a `add` —en `add` la GPU todavía no tiene driver
y `nvidia-smi` no la ve—, y la unidad hace `ExecStop=/usr/sbin/aorus-egpu-oc
reset`, que es la reversibilidad del paquete expresada en systemd en lugar de en
código.

---

## 8. Puertas de calidad

El `Makefile` encadena lo que hay que pasar antes de empaquetar:

- `make lint` — `bash -n` sobre **todo** el shell del repo (núcleo, scripts de
  build, `tests/`), más `sh -n` sobre los maintainer scripts.
  Está así porque un error de sintaxis en un `postinst` rompe el `apt install` a
  medias.
  Si hay `shellcheck`, pasa `-S warning` sobre `domain/`, `app/` y `adapters/`
  (no bloqueante).
- `make test` — `tests/run.sh`:
  51 asserts, sin root y sin GPU, en seis grupos —
  gate R4, gate de enlace, clamping y plan, allowlist de operaciones,
  **conformidad de cada adaptador con su puerto** (los cinco
  `port_*_assert`) y **durabilidad de la traza** (que `trace_mark` deje el dato
  en disco antes de volver, verificado en un `mktemp -d`).
  Los dos últimos grupos son los que convierten los contratos de `ports/` de
  documentación en comprobación.
- `make overclock` — depende de **`lint test`**, así que no se construye un
  `.deb` con el dominio en rojo.
  Nótese que `make tb-fix` y `make forensics` solo dependen de `lint`:
  `egpu-tb-fix` es anterior al núcleo `src/`, y `aorus-egpu-forensics` no añade
  reglas al dominio (captura estado, no decide nada), así que no hay dominio
  nuevo que testear en ninguno de los dos.

---

## 9. Deuda y asuntos abiertos

Cosas que el código dice y que no son coherentes, o que están a medio camino.
Están aquí en vez de documentadas como si fueran diseño.

1. **La migración está empezada, no hecha.**
   El paquete principal y verificado en vivo es `egpu-tb-fix`, y **no** usa el
   núcleo `src/`;
   `aorus-egpu-fix-bar0` (423 líneas) sigue en
   `packaging/aorus-egpu-config/` como archivo documentado.
   Los consumidores reales del núcleo son `aorus-egpu-forensics` (probado en
   vivo) y `aorus-egpu-overclock` (sin validar en hardware).
   La arquitectura es la forma de escribir lo nuevo, no una descripción del
   stack que arranca la eGPU.

2. **La cadena completa de cuelgue no se ha ejercitado de punta a punta.**
   `aorus-egpu-probe` y `aorus-egpu-postmortem` están probados en vivo por
   separado —traza, snapshots, muestreador, marcadores en `/dev/kmsg` y resumen
   del postmortem— y `tests/run.sh` cubre la durabilidad de la traza.
   Lo que **no** se ha podido probar es el caso que motiva todo:
   provocar un cuelgue real, reiniciar y recuperar el volcado de `pstore`.
   Hasta que eso ocurra, la capa 3 (ramoops) está verificada por construcción,
   no por experimento.

3. **El puerto `thunderbolt` no tiene consumidor.**
   `ports/thunderbolt.port.sh` y `adapters/thunderbolt/boltctl.sh` están
   escritos y ningún caso de uso los carga;
   solo los tests comprueban que el adaptador cumple el contrato.
   Es un puerto especulativo:
   correcto, pero sin la presión de un consumidor que valide el contrato de
   verdad.

4. **`AORUS_LINK_MIN_WIDTH=1` es un umbral inerte.**
   Con el mínimo en x1, el término de anchura solo rechaza casos que la rama
   `dead` ya atrapa (width vacío o 0).
   Es intencionado como marcador explícito del contrato, pero conviene saber que
   hoy el gate de enlace discrimina **por generación**, no por anchura.

5. **El bundler copia todas las capas, pero ya solo a un paquete.**
   `bundle_payload` lleva `domain/`, `ports/`, `adapters/` y `app/` completos a
   `aorus-egpu-core`, así que ahí va también `app/overclock.sh` para una máquina
   que solo quiera el forense.
   Sigue siendo deliberado —una sola fuente de verdad y cero lógica de selección
   por paquete— y ahora el coste se paga una vez, no por paquete.
   Lo que costó de verdad la copia por paquete no fueron los KB:
   fue que dpkg se negara a instalar el segundo paquete, con el núcleo entero
   solapado (ver la sección del bundler más arriba).

6. **El OC ya tiene documento, pero le faltan las palancas que importan.**
   [`overclock.md`](./overclock.md) existe desde el 2026-11-02 con la medición
   de los cuatro perfiles, así que las referencias de `domain/overclock.sh` y
   del texto de ayuda de `aorus-egpu-oc` ya resuelven.
   Lo que queda abierto es otra cosa:
   de las palancas medidas solo `efficient` tiene efecto —`performance` y
   `balanced` se retiraron por inertes— y las dos que el caso de uso de IA
   necesita de verdad, `persistence_mode` y `compute_mode`, **no existen en el
   dominio ni en el adaptador**.
   Sus perfiles están especificados en el documento y deliberadamente **no
   entregados**:
   el parser rechaza una clave desconocida, así que entregarlos hoy entregaría
   dos perfiles que fallan al aplicarse.

### Resuelto después de la primera redacción de este documento

Se deja constancia para que no se vuelva a documentar como deuda:
`tb_device_uuid` ya devuelve un solo UUID con desempate topológico;
los `port_*_assert` se invocan al cargar `app/overclock.sh` y `app/forensics.sh`,
no solo en los tests;
el comentario del fallback de `pci_is_behind_thunderbolt` ya describe lo que el
código hace (`removable` hacia arriba, no `is_hotplug_bridge`);
la allowlist del plan es una sola (`domain_oc_op_is_valid`, que el ejecutor
consulta);
`AORUS_OC_CONF` muerto, eliminado;
`verdict` separado en `r4_verdict` y `link_verdict`;
y las rutas de `docs/research/` corregidas en `CLAUDE.md`.
