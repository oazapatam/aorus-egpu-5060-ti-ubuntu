# Potencia, relojes y perfiles de la eGPU

Documento de `aorus-egpu-overclock`.
Estado del paquete: **en desarrollo, sin validar como paquete en hardware**
(ver [`packages/README.md`](./packages/README.md)).
Lo que sí está medido en esta tarjeta es lo que aplican sus perfiles, y eso es
lo que cuenta este documento.

El caso de uso de esta máquina es **IA**:
inferencia servida con vLLM y entrenamiento.
No hay nada gráfico en juego, así que ninguna decisión de aquí se justifica por
FPS ni por latencia de frame.

## Resumen en una frase

En esta tarjeta el overclock de **reloj** sí existe, y es grande:
los offsets de +MHz por NVML llevan el reloj gráfico de 2812 a **3405 MHz**
—por encima del `clocks.max.gr` que la tarjeta declara— sin un solo bit mal
calculado, y a +675 MHz se cuelga con un `Xid 109`
(ver [El borde del reloj, medido](#el-borde-del-reloj-medido)).
Lo que no existe es margen de **potencia**:
el límite no se puede subir, y de las palancas que el paquete escribía por
`nvidia-smi` solo el techo de reloj tiene efecto medible.
Y para servir modelos las palancas que de verdad faltan siguen sin ser de
reloj:
son `persistence_mode` y `compute_mode`.

## Lo que se midió, y cómo

Medición del **2026-11-02** sobre la eGPU (RTX 5060 Ti 16 GB en caja
Thunderbolt), con el enlace en su tope Gen3.
Carga: GEMM fp16 de 8192² sostenido, más una copia de 2 GiB dentro de VRAM para
el ancho de banda de memoria.
Potencia, temperatura y relojes muestreados con `nvidia-smi` durante la
ventana sostenida, no en el pico de arranque.

| perfil | power limit | TFLOP/s | W | TFLOP/W | VRAM GB/s | temp |
|---|---|---|---|---|---|---|
| `stock` | 180 W | 49.67 | 138.2 | 0.3595 | 387.2 | 60 °C |
| `performance` (retirado) | 180 W | 49.69 | 136.2 | 0.3648 | 387.2 | 60 °C |
| `balanced` (retirado) | 165 W | 49.67 | 138.0 | 0.3599 | 387.2 | 61 °C |
| `efficient` | 150 W | 43.03 | 91.1 | 0.4724 | 387.1 | 56 °C |

Y las capacidades que la tarjeta declara, que son las que acotan todo lo demás:

```
power.min_limit        = 150 W
power.max_limit        = 180 W
power.default_limit    = 180 W        <- max == default: NO se puede subir
clocks.max.gr          = 3090 MHz
clocks.max.mem         = 14001 MHz
mínimo gráfico real    = 180 MHz
mínimo de memoria real = 405 MHz
niveles de memoria     = 405 / 13801 / 14001 MHz   (tres, no un continuo)
ecc.mode.current       = [N/A]        <- esta tarjeta NO tiene ECC
persistence_mode       = Disabled
compute_mode           = Default

ventana de offsets NVML (nvidia-ml-py 13.615.71):
  GpcClkVfOffset       = 0,  ventana (-1000, +1000) MHz
  MemClkVfOffset       = 0,  ventana (-2000, +6000) MHz
```

Ojo con `clocks.max.gr = 3090 MHz`:
**no es un techo real**.
Con un offset de +600 MHz la tarjeta sostuvo 3405 MHz bajo carga, 315 MHz por
encima de ese "máximo".
Lo que la tabla declara es el máximo de la curva de fábrica, no el del
silicio.

`nvidia-persistenced` está **activo** en el sistema, pero **no cubre la eGPU**:
la persistencia sigue en `Disabled` en la tarjeta externa.

## Qué palancas existen de verdad en esta máquina

| Palanca | `nvidia-smi` | ¿Existe aquí? | Veredicto medido |
|---|---|---|---|
| Subir el límite de potencia | `-pl` por encima de 180 | **No** | `max_limit == default_limit == 180 W`: no hay margen que pedir |
| Bajar el límite de potencia | `-pl` hasta 150 | Sí | Útil solo a 150 W, y porque recorta reloj: +31% de eficiencia |
| Techo de reloj gráfico | `-lgc <min>,<techo>` | Sí | **La única palanca con efecto grande medido** (es lo que hace `efficient`) |
| Suelo de reloj gráfico | `-lgc <suelo>,...` | Sí | Contraproducente: no da rendimiento y sube consumo y temperatura **en reposo** |
| Lock de reloj de memoria | `-lmc` | Sí, pero **NO USAR** | Defecto conocido en Blackwell: −16.43% de rendimiento (ver abajo) |
| Offsets de +MHz sobre stock | — (NVML, no `nvidia-smi`) | **Sí** | Ventana núcleo ±1000 / memoria −2000..+6000 MHz. Medido: **+600 MHz limpio (3405 MHz), +675 cuelga con `Xid 109`**. Un offset positivo exige el gate de verificación |
| Persistencia del driver | `-pm 1` | Sí, y **sin usar** | Palanca real para vLLM; aún no implementada en el paquete |
| Modo de cómputo exclusivo | `-c EXCLUSIVE_PROCESS` | Sí, y **sin usar** | Palanca real para vLLM; aún no implementada en el paquete |
| ECC | `-e 1` | **No** | `ecc.mode.current=[N/A]`: la tarjeta no lo soporta (ver el riesgo abajo) |

## El borde del reloj, medido

Medición del **2026-11-05** con [`tools/egpu-oc-edge`](../tools/egpu-oc-edge).
Hipótesis, método y criterios de resolución en
[H25](./research/reliability-hypothesis-ledger.md#h25).
Una variable por prueba —la memoria quieta en 0 todo el tiempo—, escalera de
75 MHz, y en cada paso la comprobación **bit-exacta** del puerto `verify`:
GEMM de entrada entera con resultado analíticamente conocido, más un patrón
sobre el 70% de la VRAM libre releído y comparado byte a byte.

| offset núcleo | reloj SM real | potencia | temp | throttle | iteraciones bit-exactas | errores |
|---|---|---|---|---|---|---|
| control +0 | 2812 MHz | 144.6 W | 72 °C | `0x0` | 12 023 GEMM + 42 trozos (10.5 GiB) | **0** |
| +75 | 2880 MHz | 148.0 W | 73 °C | `0x0` | 5 134 | **0** |
| +150 | 2955 MHz | 151.7 W | 74 °C | `0x0` | 5 248 | **0** |
| +225 | 3030 MHz | 155.5 W | 75 °C | `0x0` | 5 349 | **0** |
| +300 | 3105 MHz | 158.8 W | 76 °C | `0x0` | 5 475 | **0** |
| +375 | 3180 MHz | 160.5 W | 76 °C | `0x0` | 5 613 | **0** |
| +450 | 3255 MHz | 163.3 W | 77 °C | `0x0` | 5 739 | **0** |
| +525 | 3330 MHz | 165.4 W | 78 °C | `0x0` | 5 854 | **0** |
| +600 | **3405 MHz** | 167.9 W | 78 °C | `0x0` | 5 915 | **0** |
| +675 | — | — | — | — | — | **`Xid 109` CTX SWITCH TIMEOUT** |

Tres resultados, y los tres contradicen algo que este documento daba por
sabido.

**El offset se traslada al reloj 1:1.**
+600 MHz pedidos dieron +593 MHz reales.
No hay curva que se aplane ni recorte progresivo:
la tarjeta sube lo que se le pide hasta que deja de funcionar.

**El límite no es la potencia ni la temperatura.**
A +600 MHz la tarjeta estaba en 167.9 W de los 180 disponibles, a 78 °C, con
`clocks_throttle_reasons.active = 0x0` en todos los pasos.
Se quedó sin margen de **reloj**, no de vatios:
ninguna de las dos protecciones que uno esperaría llegó a actuar.
Eso también significa que los 12 W que sobran no son margen aprovechable —a
+675 MHz no se gastaron, la tarjeta se colgó antes—.

**El fallo fue ruidoso, no silencioso.**
44 327 iteraciones de GEMM bit-exacto entre +75 y +600 MHz devolvieron **cero
bits distintos**;
no hubo una zona gris de resultados mal calculados antes del cuelgue.
El fallo de +675 fue un `Xid 109 CTX SWITCH TIMEOUT` nombrando al proceso de
la medición en `PCI:0000:b4:00`, seguido de `NV_ERR_RESET_REQUIRED`:
la tarjeta pidió un full-chip reset y dejó de responder a NVML y a
`nvidia-smi` (`[N/A]` en todo).

**Y el fallo es del reloj, no del túnel.**
`aorus-egpu-health` clasificó el incidente como `degraded` —avisos sin pérdida
del dispositivo— sin `Xid 79`, sin `Link Down` y sin `USB disconnect`:
nada de la firma de [H23](./research/reliability-hypothesis-ledger.md#h23).
Importa porque sin esa separación el borde medido sería atribuible a una
caída del túnel que no ocurrió.
La recuperación fue reconectar el Thunderbolt;
no se intentó ningún `remove`/`rescan`/FLR a propósito, porque
[H2](./research/reliability-hypothesis-ledger.md) documenta que esa secuencia
con descriptores abiertos cuelga el host.

### Lo que este número NO autoriza

La cobertura real del +600 MHz es **n=1 de 20 s**, no el n≥3 de 90 s que la
metodología del repo exige:
el barrido abortó al caerse la tarjeta, así que la confirmación no llegó a
correr y la **memoria no se midió en absoluto**.
El valor honesto de hoy es "el borde está entre +600 y +675 MHz, con una sola
pasada limpia en +600".

Y aunque estuviera confirmado, seguiría sin ser una licencia.
Esta tarjeta no tiene ECC, y el modo de fallo que importa para una carga de IA
no es el cuelgue —ese se ve— sino el resultado silenciosamente incorrecto.
El caso documentado en Blackwell/GDDR7 que cita el apartado de riesgo de este
mismo documento apareció en la iteración **274.400** con un memtest de VRAM
pasando 1.252 pasadas limpias, y su tasa de error **dependía de la potencia**.
44 327 iteraciones son dos órdenes de magnitud menos que eso.

Por lo que la recomendación operativa **no cambia**:
para servir modelos en esta máquina, la dirección segura del tuning sigue
siendo hacia abajo (`efficient`).
Lo que el borde medido aporta, sobre todo, es saber dónde está el precipicio:
a +675 MHz y no a +50.

Dicho eso, desde la versión 0.3.0 el paquete **sí entrega** tres perfiles con
offsets positivos —`oc-normal`, `oc-medio` y `oc-maximo`— y conviene ser claro
sobre qué cambió y qué no.
Lo que cambió es que existe una escalera medida, así que un perfil puede citar
un número en vez de inventarlo.
Lo que **no** cambió es nada de este apartado:
los tres siguen pasando por el gate de verificación, ninguno se aplica de forma
desatendida, y la recomendación para una carga de IA larga sigue siendo
`efficient` o `oc-normal`.
Entregarlos es reconocer que el operador va a querer el margen medido y que es
mejor que lo tome por un camino con gates que a mano por NVML sin ninguno.

## Por qué el power limit no es una palanca aquí

Tres datos, y los tres apuntan al mismo sitio.

La carga más pesada que se ha medido consume **139 W de los 180 W**
disponibles.
Un tope de potencia solo hace algo cuando la carga llega a tocarlo, así que
cualquier límite entre 140 y 180 W es decorativo:
es exactamente lo que le pasaba al perfil `balanced` con sus 165 W.

El límite **no se puede subir**:
`power.max_limit` es igual a `power.default_limit`, 180 W.
La tarjeta ya arranca en su máximo de fábrica y el vBIOS no ofrece más.
Escribir `power_limit_w=180` es escribir el valor que ya está puesto.

El único valor con efecto es el **mínimo, 150 W**, y su efecto no viene del
vatímetro sino de que fuerza a la tarjeta a recortar reloj:
es el mismo mecanismo que el techo de `-lgc`, por otra puerta.
Si lo que se quiere es eficiencia, el techo de reloj es la forma explícita de
pedirla y el `-pl` es el cinturón de seguridad por si otra carga sí sube de
139 W.

## Veredicto por perfil

### `stock` — el único default

Traducido por el dominio a un **reset completo**, no a escrituras:
relojes a default y límite de potencia a `power.default_limit`.
Es lo que aplica el servicio cuando `/etc/aorus-egpu/overclock.conf` está
vacío, y por tanto lo que el paquete hace si nadie decide nada.

### `efficient` — el único con efecto medido

150 W y techo de reloj gráfico en 2400 MHz.
Contra `stock`:
43.03 TFLOP/s frente a 49.67 (**−13%**) con 91.1 W frente a 138.2 (**−34%**),
o sea 0.4724 TFLOP/W frente a 0.3595:
**+31% de eficiencia** y 4 °C menos.

Para una caja Thunderbolt alimentada por su propia fuente y con el disipador en
un chasis pequeño, cambiar 13% de rendimiento por 34% de potencia es un trato
bueno en cualquier carga que no esté contra reloj.

No lleva `gpu_clock_min_mhz` a propósito.
El suelo por defecto es ahora el mínimo de la tarjeta (180 MHz), así que el
reloj baja de verdad en reposo;
el `gpu_clock_min_mhz=500` que este perfil llevaba antes era un parche a un
defecto del dominio, ya corregido.

### `oc-normal`, `oc-medio`, `oc-maximo` — los tres niveles de núcleo

Entregados en 0.3.0.
Los tres tocan **solo el núcleo** y fijan `mem_clock_offset_mhz=0`
explícitamente.

| Perfil | Offset de núcleo | Reloj medido | Potencia | Margen al fallo |
|---|---|---|---|---|
| `oc-normal` | +150 MHz | 2955 MHz | 151.7 W | 525 MHz |
| `oc-medio` | +375 MHz | 3180 MHz | 160.5 W | 300 MHz |
| `oc-maximo` | +600 MHz | 3405 MHz | 167.9 W | **75 MHz** |

Los tres valores son puntos **reales** de la escalera del 2026-11-05, cada uno
medido individualmente con comparación bit-exacta y `throttle 0x0`;
no son interpolaciones.
La referencia de reposo es 2812 MHz a offset 0.

**La memoria va a 0 a propósito, y no es una omisión.**
Su escalera no se ha medido nunca:
el +6000 MHz que circula por las notas del proyecto viene de un bench que
terminó en `Reset Required`, no de una comparación bit-exacta.
En una tarjeta sin ECC, un offset de memoria sin medir no se cae:
corrompe pesos en silencio.
Cuando [`tools/egpu-oc-edge`](../tools/egpu-oc-edge) mida ese dominio se
añadirá, con su número y su evidencia.

**`oc-maximo` es el de evidencia más débil de todo el paquete**, y su fichero
lo dice en la primera línea.
Su cobertura es n=1 de 20 s, no el n≥3 de 90 s de la metodología, porque el
barrido abortó al colgarse la tarjeta en el escalón siguiente;
y deja 75 MHz hasta un `Xid 109` que cuesta reconectar el Thunderbolt.
Es un perfil para medir y para tandas cortas, no para dejar puesto.

Ninguno de los tres se ha aplicado todavía por el camino del paquete
(`aorus-egpu-oc apply`):
los números vienen de `tools/egpu-oc-edge`, que escribe por el mismo adaptador
NVML pero con su propia orquestación.
Esa es la validación que falta.

### `performance` — **RETIRADO**, engañaba

Ganaba **+0.04%** sobre `stock` (49.69 frente a 49.67 TFLOP/s), que es ruido de
medición y no un resultado.
Dos de sus tres claves —`power_limit_w=180` y `gpu_clock_max_mhz=3090`—
escribían el valor que la tarjeta **ya tenía puesto**.
Su único efecto real era la tercera, `gpu_clock_min_mhz=1800`:
un suelo de reloj que no aporta rendimiento en una carga que ya satura el reloj
por sí sola, y que mantiene la tarjeta a 1800 MHz **en reposo**, con más
consumo y más temperatura mientras no se hace nada.

Eso no es neutral en esta máquina:
el régimen de reposo es justo donde pega
[H23](./research/reliability-hypothesis-ledger.md)
(el dispositivo Thunderbolt se cae en reposo, no bajo carga), así que el perfil
pagaba vatios y grados por quedarse más tiempo en el estado que más se
investiga por frágil.

Un perfil llamado `performance` que no da rendimiento es peor que no tener
perfil:
le cuesta al usuario la decisión de aplicarlo y le devuelve calor.

### `balanced` — **RETIRADO**, era inerte

Una sola clave, `power_limit_w=165`.
Un tope de 165 W no acota nada cuando la carga más pesada medida consume 139 W,
y la medición lo confirma:
49.67 TFLOP/s y 138.0 W, indistinguible de `stock`.
No hacía nada, con nombre de compromiso razonable.

## Perfiles retirados

Igual que las retiradas de servicio del repo:
motivo medido, fecha, y el criterio por el que volverían.

| Perfil | Retirado | Motivo medido | Resucitaría si… |
|---|---|---|---|
| `performance` | 2026-11-02 | +0.04% de rendimiento (ruido); 2 de 3 claves reescribían el valor vigente; su único efecto real era un suelo de 1800 MHz que sube consumo y temperatura en reposo | apareciera una carga donde el suelo de reloj mida una ganancia real, con hipótesis escrita y n>=3 |
| `balanced` | 2026-11-02 | tope de 165 W inerte: la carga más pesada medida consume 139 W | una carga midiera un consumo sostenido por encima de 165 W |

Los dos ficheros se borran en vez de conservarse comentados:
el payload del `.deb` es la lista que el usuario ve en `aorus-egpu-oc list`, y
un perfil presente es un perfil que alguien va a aplicar.
El registro de lo que hacían y de por qué se fueron es este documento.

**Ojo con las copias que queden en disco.**
Quitar un perfil del paquete no borra el fichero de una máquina donde ya
estuviera:
`/etc/aorus-egpu/profiles/` no es un conffile de dpkg (ver
[`ci-package-policy.md`](./ci-package-policy.md)) y dpkg solo retira lo que un
paquete posee.
El 2026-11-07, al instalar el paquete en esta máquina, `aorus-egpu-oc list`
seguía ofreciendo `performance` y `balanced` desde dos ficheros del 2 de
noviembre que **ningún paquete poseía** (`dpkg -S` no los reconocía).
Si `list` ofrece un perfil retirado, compruébalo así y borra a mano lo que
sobre:

```bash
dpkg -S /etc/aorus-egpu/profiles/*.profile   # lo que no salga, es huérfano
sudo rm /etc/aorus-egpu/profiles/<retirado>.profile
```

## Lo que de verdad le falta para IA: persistencia y modo de cómputo

Las dos palancas que importan para servir modelos en esta máquina no son de
reloj, ya se pueden escribir hoy con `nvidia-smi`, y **nadie las estaba
usando**.

### `persistence_mode` (`nvidia-smi -pm 1`)

Sin persistencia, el driver **descarga el estado de la GPU cuando no queda
ningún proceso con la tarjeta abierta**, y el siguiente proceso paga la
reinicialización completa del contexto del driver.
En esta máquina ese peaje está medido en otro contexto del repo:
aproximadamente **1.3 s de arranque de GSP** en el primer `open` tras el último
`close` (ver la reclasificación de `nvidia-persistenced` en
[`research/service-retirement-roadmap.md`](./research/service-retirement-roadmap.md)).

Para vLLM eso aparece en los dos sitios que más molestan:
el arranque del servidor, y cualquier reinicio del worker tras un despliegue o
un fallo.
Peor en una eGPU que en una tarjeta interna, porque la reinicialización
atraviesa el túnel Thunderbolt.

**Aviso importante:**
`nvidia-persistenced` ya está activo en este sistema.
Hoy no cubre la eGPU (la tarjeta externa sigue en `Disabled`), así que escribir
`-pm 1` aporta algo;
pero la palanca **no debe pelearse con el demonio**.
Si algún día el demonio pasa a cubrir la eGPU, `persistence_mode=1` es
redundante, y dos dueños del mismo bit es la clase de conflicto que este repo ya
pagó con el BAR0 (`aorus-egpu-config` y `egpu-tb-fix` pisándose).
La implementación tiene que **leer el estado antes de escribir** y no hacer nada
si ya está puesto, exactamente como el resto del paquete evita reescribir lo
vigente.

### `compute_mode` (`nvidia-smi -c EXCLUSIVE_PROCESS`)

Esta tarjeta tiene **16 GB contados**.
Un servidor vLLM reserva su caché KV como una fracción de la VRAM al arrancar y
cuenta con tenerla entera durante toda su vida.
En modo `Default` cualquier otro proceso puede abrir la misma GPU y empezar a
reservar:
un notebook olvidado, un script de prueba, un segundo worker lanzado por error.
El resultado no es una degradación suave sino un `CUDA out of memory` en el
proceso que ya estaba sirviendo, o en el que arranca, según quién llegue
primero.

`EXCLUSIVE_PROCESS` convierte eso en un error inmediato y claro en el intruso
—no puede abrir la GPU— en vez de un OOM en producción.
Es un gate, igual que los gates de seguridad del paquete:
prefiere "no arranca" a "arranca y rompe".

Para **entrenar** la elección es la contraria:
`Default`, porque conviene poder enganchar un profiler o un segundo proceso a la
misma tarjeta.

### Perfiles propuestos, y por qué **no** se entregan todavía

Las claves `persistence_mode` y `compute_mode` **no existen** hoy ni en
`domain/overclock.sh` (`AORUS_OC_KEYS`) ni en el adaptador.
El parser de perfiles es estricto a propósito:
una clave desconocida **rechaza el perfil entero** con
`clave desconocida '<k>'`, que es lo correcto —un typo en `/etc/` no debe dejar
la eGPU en un estado que nadie pidió— pero significa que entregar hoy estos
perfiles entregaría dos ficheros que fallan al aplicarse.

Se consideró entregarlos con las claves **comentadas**.
Se descartó:
el parser corta en `#`, así que el perfil cargaría con cero claves, el plan
saldría vacío y `aorus-egpu-oc apply serve` respondería
`perfil 'serve': nada que aplicar` con código de salida 0.
Un perfil entregado que no falla y no hace nada es el mismo engaño por el que se
retira `performance`, y además ocuparía su nombre en `aorus-egpu-oc list`.

Así que **se especifican aquí y se entregan cuando las claves existan**.
Contenido exacto, listo para copiar a
`packaging/aorus-egpu-overclock/etc/aorus-egpu/profiles/` en ese momento:

`serve.profile`

```
# desc: vLLM servido — persistencia del driver y la VRAM entera para un proceso
# Ninguna clave de reloj a propósito: en esta tarjeta no hay margen de potencia
# (max_limit == default_limit == 180 W) y la carga sostenida consume 139 W, así
# que cualquier tope sería decorativo. Ver docs/overclock.md.
#
# persistence_mode: sin ella el driver descarga el estado de la GPU cuando no
# queda ningún proceso con la tarjeta abierta, y el siguiente open paga la
# reinicialización del contexto del driver (~1.3 s de arranque de GSP aquí).
# Eso se paga en cada arranque del servidor y en cada reinicio de worker.
# OJO: nvidia-persistenced está activo en este sistema; hoy no cubre la eGPU,
# pero esta clave NO debe pelearse con el demonio.
#
# compute_mode: 16 GB contados. En Default cualquier otro proceso puede
# reservar VRAM y provocar un OOM en el vLLM que ya estaba sirviendo.
# EXCLUSIVE_PROCESS lo convierte en un error claro en el intruso.
persistence_mode=1
compute_mode=exclusive_process
```

`train.profile`

```
# desc: entrenamiento — persistencia del driver, GPU compartible con el profiler
# Mismo razonamiento que serve.profile para persistence_mode.
#
# compute_mode=default NO es redundante aunque sea el valor de fábrica: los
# perfiles no son diferencias, así que es lo que DEVUELVE la tarjeta a modo
# compartido después de haber aplicado serve. Entrenando conviene poder
# enganchar un profiler o un segundo proceso a la misma GPU.
#
# Sin techo de reloj: a 180 W la tarjeta se queda en 60 °C bajo GEMM sostenido,
# así que no hay un problema térmico que acotar. Si un entrenamiento de varias
# horas lo cambiara, `efficient` ya existe y da +31% de eficiencia por -13% de
# rendimiento — pero eso está sin medir a varias horas.
persistence_mode=1
compute_mode=default
```

Lo que hace falta para entregarlos, en el orden que manda `CLAUDE.md`
(el test antes del adaptador):

1. `domain/overclock.sh`:
   añadir `persistence_mode` y `compute_mode` a `AORUS_OC_KEYS`, validar sus
   valores (`persistence_mode` solo `0`/`1`;
   `compute_mode` solo `default`, `exclusive_process`, `prohibited`), y añadir
   las operaciones al plan y a `AORUS_OC_OPS`.
2. `tests/run.sh`:
   los asserts de esa validación, incluido el rechazo de valores fuera de la
   lista.
3. `ports/gpu.port.sh`:
   `gpu_set_persistence_mode` y `gpu_set_compute_mode`, más las lecturas para
   poder comparar antes de escribir.
4. `adapters/gpu/nvidia-smi.sh`:
   `-pm` y `-c`, acotados por `timeout` como todo lo demás, y **sin escribir si
   el valor vigente ya es el pedido**.
5. `gpu_reset_all`:
   el reset de `stock` tiene que cubrir también estas dos claves.
   Si no, reaparece el defecto que ya tuvo el límite de potencia —`reset`
   dejaba la tarjeta de-rated en silencio— esta vez dejando la GPU en
   `EXCLUSIVE_PROCESS` después de un `reset`, con el siguiente proceso
   incapaz de abrirla y sin nada que lo explique.
6. Solo entonces, los dos ficheros de perfil y la línea de la descripción del
   paquete.

## El panel vivo: un htop para las GPUs

`nvidia-oc` abre con un panel que se refresca **cada segundo** y muestra las
**dos** tarjetas, la externa primero:

```
  eGPU  GeForce RTX 5060 Ti                         Gen3 x4  P0  00000000:8D:00.0
  GPU  [████████████░░░░░░░░]  62%  ▁▂▂▃▄▅▆▇██▇▆▅▄▃▃▄▅▆▇██▇▆   2887 MHz
  VRAM [████████░░░░░░░░░░░░]  41%  ▁▁▂▂▃▃▄▄▄▅▅▅▅▆▆▆▆▆▆▆▆▆▆▆  6.5 GiB / 15.9 GiB
  PWR  [████████████████░░░░]  79%  ▂▃▃▄▅▅▆▆▇▇███▇▇▆▆▅▅▄▄▃▃▂  143.52 / 180.00 W
  TEMP  65 °C  ▂▂▃▃▃▄▄▄▅▅▅▅▆▆▆▆▆▇▇▇▇▇▇▇  FAN  48%  MEM 14001 MHz
  throttle  techo de potencia por SW (SW Power Cap)

  int   RTX PRO 4000 Blackwell Generation Laptop GPU  Gen5 x16  P8  00000000:01:00.0
  GPU  [░░░░░░░░░░░░░░░░░░░░]   0%  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁    180 MHz
  VRAM [░░░░░░░░░░░░░░░░░░░░]   0%  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  0 MiB / 15.9 GiB
  PWR  [····················]       7.53 W  (sin techo publicado)
  TEMP  53 °C  ▁▁▁▁▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂  FAN  n/d  MEM 405 MHz
  cable  NO desconectes: 2 proceso(s) tienen la eGPU abierta (cuelga el host, H28)
```

Cuatro decisiones de este panel no son cosméticas, y vale la pena justificarlas
porque las cuatro son trampas en las que ya se cayó antes.

**Salen las dos tarjetas, y el rol lo decide el device-id.**
No el orden en que `nvidia-smi` las liste:
los índices se reordenan entre arranques, y apuntar por índice es exactamente
cómo se acabaría hablando de la GPU equivocada.
Es el mismo criterio que usa el gate R4 para las escrituras.
Ver las dos a la vez es lo que delata que una carga aterrizó en la interna.

**Del enlace se muestra la CAPACIDAD, no la instantánea.**
El panel pone `Gen3 x4` en la eGPU porque `pcie.link.gen.max` dice 3;
`pcie.link.gen.current` dice `1` en reposo, y leer eso como techo es el error
que ya costó una investigación completa en este repo
([H18](./research/reliability-hypothesis-ledger.md)).
El **ancho**, en cambio, sí se toma del ahora (`x4`): es lo que el túnel da de
verdad, y no se degrada en reposo como la velocidad.
Esa pareja —generación de la capacidad, ancho del ahora— es la misma que
alimenta el gate de enlace.

**Un hueco se dibuja como hueco.**
La GPU interna no publica `power.limit` ni `fan.speed`:
devuelve `[N/A]`.
El panel pone `[····]` y `n/d` en vez de una barra al 0% y un ventilador al 0%,
porque un cero es una lectura tranquilizadora y ahí no hay lectura ninguna.

**El throttling llega traducido.**
`clocks_throttle_reasons.active` es una máscara de bits;
el panel la descodifica a texto y solo avisa cuando hay un recorte real.
El bit `0x1` (`GpuIdle`) se excluye a propósito:
significa que la tarjeta está en reposo, no que algo la esté frenando.
Una máscara que no se puede leer se muestra como ilegible, **no** como
"ninguno".

Y el panel contesta la pregunta que cuelga el host si se responde mal:
**si se puede tirar del cable ahora mismo.**
Desconectar el Thunderbolt con un proceso CUDA vivo hace que el cierre de
`/dev/nvidia-uvm` escriba en un BAR0 ya desmapeado, con el spinlock de ISR
tomado ([H28](./research/reliability-hypothesis-ledger.md)).
Mientras haya procesos con la eGPU abierta, el panel lo dice en rojo y con el
recuento;
si no se pueden contar, dice que no se puede afirmar, que no es lo mismo que
decir que es seguro.

### Dónde vive cada cosa

El TUI **no calcula nada de esto**.
Las barras, los niveles del sparkline, los umbrales de temperatura, la
traducción del throttling y el veredicto del cable llegan ya resueltos de
`aorus-egpu-oc telemetry`, que los pide a `domain/telemetry.sh` —puro y con
test— orquestado por `app/telemetry.sh`.
`nvidia-oc` elige el color y coloca caracteres.
El historial del sparkline sí vive en el TUI, porque es estado de presentación
como la posición del cursor;
el **mapeo** de valor a nivel no, porque es una regla, y tenerla en dos sitios
es tenerla dos veces mal.

La telemetría es **solo lectura** y va por `nvidia-smi`, no por NVML:
mirar el estado no debería depender del binding que hace falta para *escribir*
offsets, que en Ubuntu es incompatible por defecto.
Por lo mismo no pide root y no pasa por el gate de enlace:
no escribe nada, y bloquear la lectura con el enlace degradado solo cegaría al
operador justo cuando más necesita ver el estado.

## `nvidia-oc`: la misma funcionalidad, en una pantalla

El paquete entrega **dos** entrypoints, y la diferencia entre ellos es
deliberada:

| | `aorus-egpu-oc` | `nvidia-oc` |
|---|---|---|
| Qué es | la CLI: el sitio donde viven los gates y las decisiones | un TUI de ncurses, **pura presentación** |
| Para qué | scripts, `udev`, la unit de systemd, y el uso a mano | ver el estado completo y actuar sin recordar la sintaxis |
| Lógica propia | toda la del paquete (vía `app/` y `domain/`) | **ninguna** |

`nvidia-oc` no escribe en la tarjeta.
Cada acción que ofrece es literalmente una llamada a `aorus-egpu-oc`, así que
los gates R4, de enlace y de verificación numérica se aplican igual que a
mano, y sus rechazos se muestran **completos** en vez de resumidos en una
línea de estado.
Esa restricción no es estética:
un TUI que escribiera offsets por su cuenta sería un segundo camino de
escritura y, por tanto, un camino sin gates — y con dos pulsaciones.

Lo que aporta, que es el único motivo por el que existe:

- **El estado en una pantalla**, refrescado en segundo plano: enlace, rangos
  de potencia y reloj, ventana de offsets, offsets vigentes, estado
  instantáneo y perfil aplicado.
  Cuando la tarjeta pide un full-chip reset y devuelve `[N/A]` en todo, lo
  dice en vez de pintar ceros;
  y si el refresco tarda, marca los datos como "de hace N s" en lugar de
  mentir.
  Hace falta porque `aorus-egpu-oc status` encadena varias llamadas a
  `nvidia-smi` y a NVML, y con la tarjeta en el estado malo —pidiendo un
  full-chip reset— se midió tardando **más de 60 s** el 2026-11-05, justo
  después del `Xid 109`:
  el TUI nunca se bloquea esperándola.
- **El entorno resuelto**: los offsets necesitan `pynvml` y el verificador
  necesita `torch`, que en esta máquina viven en un venv.
  A mano eso es acordarse de
  `sudo AORUS_NVML_PYTHON=~/.venvs/egpu-torch-test/bin/python aorus-egpu-oc …`;
  aquí se detecta al arrancar y se reenvía solo.
  Y se reenvía con `env VAR=…` explícito, no con `sudo -E`, porque en este
  sudoers `-E` avisa y lo **ignora**.
- **Un compositor de offsets** con la ventana de la tarjeta como límite, que
  **no inventa un camino de escritura**: escribe un perfil efímero en un
  directorio temporal y llama a `aorus-egpu-oc apply` con
  `AORUS_OC_PROFILE_DIR` apuntando ahí.
  El perfil pasa por el mismo parser estricto y los mismos gates que uno de
  `/etc`, y la lista de perfiles del sistema no se queda con un `scratch` que
  alguien aplicaría mañana sin saber qué es.
- **La última medición de borde a la vista**, leída de
  `/var/log/aorus-egpu/oc-edge/*/90-summary.json`, con su cobertura real
  (`n=`, iteraciones) y la tecla `m` para cargar el valor recomendado en el
  compositor en vez de teclear un número de memoria.

Dependencias: solo la stdlib de python3 (`curses`).
Necesita un terminal interactivo;
si se invoca desde un script lo dice y remite a `aorus-egpu-oc`, que es su
backend y tiene la misma funcionalidad sin interfaz.

## Referencia de claves y formato de un perfil

Un perfil es un fichero `<nombre>.profile` en `/etc/aorus-egpu/profiles/`.
Lo lee un parser deliberadamente tonto:
nunca hace `source`, porque un fichero de `/etc/` no debe poder ejecutar código
como root.

Reglas del formato, todas con consecuencia práctica:

- Una clave por línea, `clave=valor`.
- **El parser elimina TODO el whitespace de la línea.**
  Ningún valor puede llevar espacios:
  `compute_mode=exclusive process` se convertiría en
  `compute_mode=exclusiveprocess`.
  Por eso los valores van con guion bajo.
- Todo lo que sigue a `#` se descarta, en cualquier posición de la línea.
  Una clave comentada no está:
  el perfil carga con una clave menos, sin aviso.
- La **descripción** que sale en `aorus-egpu-oc list` es la primera línea
  `# desc: <texto>` del fichero.
  No es un comentario cualquiera:
  es la única cosa que el usuario lee antes de aplicar el perfil.
- Una clave desconocida **rechaza el perfil completo** y no se escribe nada.
- Un valor que no es un entero se **rechaza**;
  uno fuera del rango soportado por la tarjeta se **acota** y se avisa.

Claves soportadas hoy:

| Clave | Unidad | Se traduce a | Notas |
|---|---|---|---|
| `power_limit_w` | W | `nvidia-smi -pl` | Acotada a `[150,180]` en esta tarjeta |
| `gpu_clock_max_mhz` | MHz | `nvidia-smi -lgc <suelo>,<techo>` | Techo de reloj gráfico; sin suelo explícito usa el mínimo real de la tarjeta (180 MHz) |
| `gpu_clock_min_mhz` | MHz | el suelo del `-lgc` anterior | **Requiere** `gpu_clock_max_mhz`; un suelo sube consumo y temperatura en reposo |
| `mem_clock_mhz` | MHz | `nvidia-smi -lmc` | **No usar en Blackwell** (ver abajo) |
| `gpu_clock_offset_mhz` | MHz | NVML `GpcClkVfOffset` | Ventana [−1000,+1000]. Acepta signo. Un valor **positivo** exige el gate de verificación numérica |
| `mem_clock_offset_mhz` | MHz | NVML `MemClkVfOffset` | Ventana [−2000,+6000]. Acepta signo. **Sin medir** en esta tarjeta todavía |

`stock` es especial:
el dominio lo traduce a un reset, no a escrituras, y por eso su fichero no
lleva ninguna clave.

El perfil que aplica el servicio al conectar la eGPU se elige en
`/etc/aorus-egpu/overclock.conf` (`PROFILE=`).

## Riesgo: sin ECC, una corrupción de cómputo no avisa

Esta tarjeta **no tiene ECC** (`ecc.mode.current=[N/A]`), y eso cambia por
completo lo que significa equivocarse con el tuning.

En una GPU de escritorio con carga gráfica, un error de memoria por overclock
se ve:
un artefacto en pantalla, un cuelgue del driver, un Xid en el journal.
En una carga de IA **no se ve nada**.
El GEMM devuelve números, el servidor responde, la pérdida baja, y la respuesta
es incorrecta.
No hay excepción, no hay error de API, no hay nada que un health check detecte.

No es un riesgo teórico.
Hay un caso documentado en Blackwell con GDDR7 donde un GEMM con **entradas
fijas** —misma entrada, mismo resultado esperado en cada iteración— devolvió un
resultado distinto en la iteración **274.400**, sin Xid y sin error de API,
mientras un memtest de VRAM pasaba **1.252 pasadas limpias** sobre la misma
tarjeta.
Y el detalle que más importa aquí:
**la tasa de error dependía de la potencia**.
80 de 80 pasadas correctas a 450 W;
27 de 80 a 600 W.
Fuente:
<https://forums.developer.nvidia.com/t/silent-cuda-compute-corruption-on-rtx-pro-6000-blackwell/381759>

Tres consecuencias para este paquete:

- Un memtest de VRAM que pasa **no valida** nada sobre la corrección del
  cómputo.
  La verificación tiene que ser un GEMM con entradas fijas comparando bit a bit
  a lo largo de cientos de miles de iteraciones, no `nvidia-smi` diciendo que
  todo está bien.
- La dirección segura del tuning en esta máquina es **hacia abajo**.
  `efficient` baja potencia y reloj;
  no hay ningún perfil que suba nada, y la imposibilidad de subir el límite de
  potencia deja de ser una limitación molesta para convertirse en una
  protección.
- Los offsets de +MHz **ya tienen adaptador** (`src/adapters/gpu/nvml.sh` por
  NVML), así que esto dejó de ser hipotético:
  cualquier perfil que los use necesita esta validación **antes** de
  considerarse entregable, y por eso el gate de `app/overclock.sh` la exige en
  el acto —aplicar, medir, revertir si calcula mal— y `--force` no lo abre.

## Riesgo: `--lock-memory-clocks` no se usa en Blackwell

`nvidia-smi -lmc` (la clave `mem_clock_mhz`) está implementada en el paquete y
**ningún perfil entregado la usa**, por un defecto conocido en Blackwell:
el lock de reloj de memoria **envenena el árbitro de relojes** y deja la
tarjeta rindiendo **−16.43%** con **142 W sin usar**, sin Xid y sin ninguna
flag de throttle que lo explique.
Es decir:
el síntoma es rendimiento perdido y la tarjeta afirma que no está limitada por
nada.
Fuente:
<https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1265>

Esto encaja con otra cosa que ya sabe este repo:
la memoria de esta tarjeta solo tiene **tres niveles** (405 / 13801 /
14001 MHz), así que `-lmc` no ofrece un ajuste fino que compense el riesgo.
Entre 13801 y 14001 MHz no hay nada que ganar.

La clave se conserva en el dominio porque el adaptador la implementa y está
testeada, no porque se recomiende.

## El contexto honesto: para IA, el OC es la palanca pequeña

Bajo GEMM fp16 sostenido esta tarjeta hace **49.67 TFLOP/s**.
El pico FP16 de la RTX 5060 Ti está alrededor de **94 TFLOP/s**, así que estamos
al **~53% del pico**:
la mitad del silicio que ya está pagado y alimentado no se está usando, y la
diferencia no la cierra ningún ajuste de reloj.
La mejor palanca de reloj medida aquí —`efficient`— va en la dirección
contraria a propósito:
renuncia a un 13% de rendimiento para ganar un 31% de eficiencia.

Para una carga de IA las palancas grandes están en otro sitio:

- **Cuantización.**
  `sm_120` tiene FP8 y NVFP4 en hardware.
  Pasar de FP16 a FP8 mueve el techo de cómputo en un factor, no en un
  porcentaje, y además **libera VRAM**, que en 16 GB contados suele ser el
  limitante antes que los TFLOP/s.
- **El tamaño del modelo y la caché KV.**
  Lo que decide si vLLM sirve bien en esta tarjeta es casi siempre si el
  modelo y su caché caben con holgura, no a qué reloj corre el SM.
- **El túnel Thunderbolt.**
  3.06 GB/s host→eGPU y 3.38 GB/s eGPU→host, medidos
  (ver [`what-actually-works.md`](./what-actually-works.md)).
  Eso lo paga la carga de pesos y cualquier patrón que vaya y venga del host
  durante la inferencia, y no hay perfil que lo arregle:
  la respuesta es mantener el trabajo dentro de la tarjeta.
- **La VRAM interna no es el cuello.**
  387 GB/s medidos, idénticos en los cuatro perfiles.
  Ningún perfil los mueve, que es otra forma de decir que el reloj de memoria
  no es donde está el problema.

El orden sensato de trabajo para esta máquina es:
primero cuantizar, luego medir, y solo entonces discutir perfiles.

## Antes de creer cualquier número de aquí: medirlo

La disciplina del repo aplica igual a esta capacidad.
No se afirma que una palanca hace algo porque `nvidia-smi` acepte la escritura;
se afirma cuando una medición lo muestra, con una variable por prueba y n>=3
(ver [`research/reliability-hypothesis-ledger.md`](./research/reliability-hypothesis-ledger.md)).

Dos reglas concretas:

- `current_link_speed` **no se lee** para juzgar nada.
  En reposo dice 2.5 GT/s siempre, porque el enlace baja de velocidad solo.
  El gate del paquete juzga por capacidad negociada (`pcie.link.gen.max`).
- Cualquier prueba que pueda congelar el host va envuelta:

  ```bash
  sudo aorus-egpu-probe run -- <comando>
  ```

  Un cuelgue duro pierde el journal, que vive en RAM
  (ver [`freeze-forensics.md`](./freeze-forensics.md)).

Y el gate que ya existe sigue siendo la última palabra:
con el enlace Thunderbolt por debajo de Gen3, el paquete **no escribe nada**.
Apretar la tarjeta con el enlace degradado congeló el host entero una vez, y
"no aplica el perfil" es un resultado aceptable mientras "aplica y congela" no
lo es.
