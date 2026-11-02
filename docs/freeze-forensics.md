# Forense de cuelgues del host al probar la eGPU

## El problema

Probar la eGPU AORUS RTX 5060 Ti por Thunderbolt congela el host de vez en
cuando.
No es un Xid, no es un panic, no es un oops:
la máquina se queda muerta y hay que reiniciarla a mano.
Al volver, **no queda ningún registro**.
El buffer de `dmesg` vivía en RAM y el kernel nunca llegó a volcarlo;
journald es persistente (`/var/log/journal`, 422 MB) pero su último tramo se
quedó en memoria sin sincronizar.
Resultado: imposible saber qué paso mató la máquina.

Este documento describe la estrategia para que eso deje de pasar,
qué cubre cada pieza,
y —sobre todo— qué sigue sin cubrir.

## La idea en una frase

No se puede depurar un cuelgue mirando lo que el sistema escribió *después*,
porque no hay después;
hay que escribir **antes** (migas de pan en disco con `fsync`)
y hay que conseguir que el kernel **grabe al morir** en un sitio que sobreviva
al reinicio (ramoops/pstore),
para lo cual primero hay que convertir el cuelgue en un panic.

## Las capas

| Capa | Qué captura | Qué NO captura | ¿Reiniciar? |
|---|---|---|---|
| 1. Migas de pan en disco (`aorus-egpu-probe`) | El último paso ejecutado antes de morir, con `fsync` previo | Nada del estado interno del kernel | No |
| 2. Muestreador de hardware | Enlace PCIe, driver y runtime PM de cada GPU hasta el último instante vivo | Lo que pase entre dos muestras (por defecto 2 s) | No |
| 3. ramoops/pstore + lockup→panic | El `dmesg` del kernel en el instante del panic, incluidos backtraces de las 24 CPUs | Cuelgues en los que el detector de lockups tampoco llega a correr | Sí |
| 4. netconsole (opcional, no instalada) | Cada línea de `printk` en otra máquina, en tiempo real | Lo que ocurra después de que muera la red | Sí |

Las capas 1 y 2 son las que **no dependen de nada**:
están en disco, con `fsync`, antes del paso que mata.
La capa 3 es la que da el diagnóstico de verdad cuando funciona,
pero depende de que el kernel conserve el control lo justo para hacer panic.

## Capas 1 y 2: migas de pan

Implementadas en `src/adapters/trace/durable.sh` y expuestas por
`aorus-egpu-probe`.
Cada paso se escribe en tres destinos a la vez,
porque cada uno falla de una forma distinta:

1. un fichero en disco con `fsync` —
   sobrevive al cuelgue, y es el que importa;
2. journald —
   correlaciona con los mensajes del kernel, pero se pierde si no sincronizó;
3. `/dev/kmsg` —
   entra en el buffer del kernel, así que lo recoge ramoops **si** hay panic.

El punto 3 es el puente entre las capas:
las migas de pan aparecen *también* dentro del volcado de pstore,
así que el volcado dice en qué paso de nuestra prueba estaba la máquina.
Por eso `60-aorus-egpu-lockup.conf` pone `kernel.printk_devkmsg = on`:
con el rate limit por defecto se perderían escrituras justo cuando importan.

Uso:

```sh
sudo aorus-egpu-probe bandwidth        # prueba con traza forense completa
sudo aorus-egpu-probe load 120         # carga sostenida de 120 s
sudo aorus-egpu-probe run -- <comando> # envuelve cualquier comando
```

Las trazas quedan en `/var/log/aorus-egpu/traces/<fecha>-<nombre>/`.
La **última línea** de `10-breadcrumbs.log` es el paso sospechoso.

## Capa 3: que el `dmesg` sobreviva al reinicio

Esta capa son cuatro piezas, y las cuatro son necesarias.
Quitar una deja las otras tres sin efecto, en silencio.

### Pieza 1 — RAM reservada que el reinicio no limpia

`/etc/default/grub.d/97-aorus-egpu-forensics.cfg` añade al cmdline:

```
reserve_mem=16M:4096:aorusoops ramoops.mem_name=aorusoops
```

`reserve_mem=<tamaño>:<alineación>:<etiqueta>` reserva memoria física y le pone
un nombre;
`ramoops.mem_name=` hace que ramoops la busque por ese nombre.
Se usa esto en lugar de una dirección física fija (`memmap=` +
`ramoops.mem_address=`) porque la dirección fija hay que acertarla contra el
mapa de memoria real de la máquina,
y equivocarse significa romper el arranque o corromper memoria ajena.

`reserve_mem` se añadió en Linux 6.12 y este kernel es 7.0.0-1015-oem,
pero no se da por supuesto:
está **verificado en esta máquina** de dos formas independientes.
`/proc/kallsyms` exporta `reserve_mem_find_by_name` y
`reserve_mem_release_by_name`,
y el `ramoops.ko` de este kernel referencia `reserve_mem_find_by_name` y declara
el parámetro `mem_name` (`modinfo -p ramoops`).

**Limitación declarada**, y la dice la propia documentación del kernel:
`reserve_mem` es *best effort* y no garantiza caer en la misma dirección física
en cada arranque.
Si cambia de sitio, el contenido del arranque anterior se pierde.
Hay que comprobarlo en vivo una vez (ver "Validar la cadena").
Por eso también se activa `ramoops.ecc=1`:
ECC software para que un puñado de bits volteados al releer la RAM tras un
reinicio por hardware no invalide el volcado entero.

### Pieza 2 — cargar ramoops, porque nadie lo carga

En este kernel ramoops es un módulo (`CONFIG_PSTORE_RAM=m`)
y su único alias de autocarga es de Device Tree,
que en una máquina x86/ACPI no coincide nunca.
Verificado: `/sys/fs/pstore` está montado y vacío,
y `lsmod | grep ramoops` no devuelve nada.
De ahí `/usr/lib/modules-load.d/aorus-egpu-ramoops.conf`.

### Pieza 3 — reclamar el único hueco de backend que tiene pstore

Esta es la trampa menos obvia de todo el montaje.
pstore admite **un solo backend a la vez**:
`fs/pstore/platform.c` rechaza el segundo con `-EBUSY` y el mensaje
`backend '%s' already loaded: ignoring '%s'`.
Y en esta máquina ese hueco ya está ocupado por `efi_pstore`
(se comprueba en `/sys/module/pstore/parameters/backend`).
Sin hacer nada, ramoops llegaría más tarde y pstore lo rechazaría:
la reserva de RAM quedaría inútil y sin un error visible en ningún sitio obvio.
Por eso el cmdline lleva `pstore.backend=ramoops`,
que hace que sea el registro de `efi_pstore` el que se rechace,
sea cual sea el orden de carga.

Efecto colateral esperado y benigno:
`modprobe@efi_pstore.service` puede quedar en `failed`.
No se pierde nada útil.
`efi_pstore` guarda en la NVRAM del firmware, con registros diminutos,
y también necesita un panic para escribir;
si no hay panic ninguno de los dos graba nada,
y si hay panic ramoops ofrece 16 MiB en vez de unos pocos KiB.

### Pieza 4 — convertir el cuelgue en un panic

Esto es **el centro del diseño**, y sin esto nada de lo anterior sirve.

ramoops **no graba de forma continua**:
solo escribe cuando el kernel dispara un `kmsg_dump`,
y eso ocurre en panic, oops o reinicio de emergencia.
La grabación continua la daría `CONFIG_PSTORE_CONSOLE`,
y este kernel **no la trae**
(`# CONFIG_PSTORE_CONSOLE is not set` en `/boot/config-7.0.0-1015-oem`,
y no existen símbolos `pstore_register_console` en `/proc/kallsyms`).
Tampoco trae `PSTORE_PMSG` ni `PSTORE_FTRACE`.
Consecuencia directa:
un cuelgue duro sin panic —exactamente lo documentado en este repo para los
incidentes anteriores— **no deja nada en pstore**,
por mucha RAM que se haya reservado.
(Por eso `ramoops.console_size` se queda en 0:
reservaría una zona que nadie escribiría.)

La salida es el detector de lockups del kernel,
que sigue vivo durante el cuelgue:
`/etc/sysctl.d/60-aorus-egpu-lockup.conf` pone
`kernel.hardlockup_panic=1`, `kernel.softlockup_panic=1`,
`kernel.panic_on_rcu_stall=1` y `kernel.nmi_watchdog=1`,
de modo que el detector dispare un panic
y **entonces** ramoops grabe.

Los tres detectores cubren huecos distintos:

- **hardlockup** (NMI): CPU en bucle con las interrupciones apagadas.
  Es la forma típica de un cuelgue por bus/MMIO, y el único que puede hablar en
  ese estado.
  Disponible porque `CONFIG_HARDLOCKUP_DETECTOR_PERF=y`.
- **softlockup**: CPU en bucle en modo kernel sin ceder la CPU.
- **RCU stall**: CPU clavada con las interrupciones abiertas,
  que puede no disparar ninguno de los dos anteriores.

### Ventana del watchdog

`kernel.watchdog_thresh` se deja en su **default, 10 s**, a propósito.
Con ese valor el hardlockup salta a los ~10 s
y el softlockup a los ~20 s (el umbral es `2*watchdog_thresh`).

No se baja porque un cuelgue de verdad es permanente:
los 10 s se cumplen siempre,
y bajar el umbral solo añade falsos positivos.
Y aquí los falsos positivos son especialmente probables:
la inicialización del driver nvidia, un reentreno del enlace PCIe o la
recuperación de AER sobre un enlace Thunderbolt marginal pueden tener tramos
largos sin atender interrupciones.
Un falso positivo con `softlockup_panic=1` es un reinicio gratis en mitad de una
prueba.
Si en una sesión concreta quieres reaccionar antes, bájalo solo durante la
prueba:

```sh
sudo sysctl -w kernel.watchdog_thresh=5    # hard ~5 s, soft ~10 s
sudo sysctl -w kernel.watchdog_thresh=10   # volver al default
```

### Reinicio automático: por qué `kernel.panic = 20` es parte del forense

`kernel.panic=N` hace que el kernel reinicie solo N segundos después del panic,
y eso no es comodidad: es lo que **salva el volcado**.

- Un **reinicio** (warm reboot), que es lo que hace `kernel.panic`,
  no corta la alimentación:
  el contenido de la DRAM se mantiene y con él la región de ramoops.
  El volcado sobrevive.
- Un **corte de corriente** no:
  mantener pulsado el botón de encendido, un apagado forzado o quitar la
  alimentación vacían la DRAM en instantes,
  y el volcado se pierde **aunque el panic lo haya grabado**.
  Por eso interesa que el reinicio lo haga el kernel y no el dedo.
- Si la máquina se congela y el panic nunca llega,
  el reinicio "bueno" es por SysRq (también warm reboot), no el botón.

20 s es un término medio:
da tiempo a fotografiar la pantalla si el panic se ve (sin `splash`)
y no deja el equipo colgado esperando.
El default de Ubuntu es 10.

### SysRq: el salvavidas manual

El fichero de sysctl sube `kernel.sysrq` de 176 (el valor de Ubuntu) a **184**,
que es lo mismo más el bit `SYSRQ_ENABLE_DUMP` (`0x8`).
Eso habilita, **desde el teclado y con la máquina congelada**:

| Tecla | Qué hace |
|---|---|
| `Alt+SysRq+l` | backtrace de todas las CPUs activas, al buffer del kernel |
| `Alt+SysRq+t` | estado de todas las tareas |
| `Alt+SysRq+c` | provocar un panic a propósito → dispara el volcado de ramoops |
| `Alt+SysRq+b` | reiniciar en caliente (ya estaba habilitado en 176) |

**La secuencia útil durante un cuelgue**, si el teclado responde, es `l` y luego
`c`:
primero metes los backtraces en el buffer del kernel,
después fuerzas el panic que los graba en ramoops.
Si ni eso responde, `b` al menos reinicia en caliente sin perder la DRAM.

Riesgo asumido:
cualquiera con acceso físico al teclado puede tirar la máquina con
`Alt+SysRq+c`.
Para volver al valor de Ubuntu: `sudo sysctl -w kernel.sysrq=176`.

### Vaciar pstore en cada arranque

`aorus-egpu-pstore-archive.service` copia lo que haya en `/sys/fs/pstore/` a
`/var/log/aorus-egpu/pstore/<fecha>/` y **borra el original**.
Hay que borrarlo:
pstore es pequeño y es un anillo,
y si no se vacía el siguiente cuelgue puede no tener dónde escribir
(borrar el fichero en `pstorefs` es la forma documentada de liberar el registro
en el backend).

La unit corre en el arranque temprano,
después de `systemd-modules-load.service` (sin ramoops cargado los registros no
son visibles)
y **antes de `systemd-pstore.service`**,
que también archiva pstore y por defecto borra los ficheros.
Yendo primero nosotros, `systemd-pstore` queda además como red de seguridad
(archiva en `/var/lib/systemd/pstore`) por si esta unit fallara.
Es idempotente —copia y borra fichero a fichero—
y nunca rompe el arranque:
si no hay nada, lo dice en el journal y termina bien.

## Lo que NO cubre ninguna capa

Dicho sin adornos:
**si el cuelgue es tan duro que el detector de lockups tampoco corre,
no habrá panic ni volcado del kernel.**
Casos reales en los que esto pasa:

- el NMI no llega porque el bus se lleva a la máquina entera;
- el firmware se queda clavado y el reinicio tras el panic no completa
  (y entonces hay que apagar a mano, lo que vacía la DRAM y se lleva el
  volcado);
- `reserve_mem` cayó en otra dirección física que el arranque anterior;
- la BIOS inicializó o limpió la RAM al reiniciar.

Para todos esos casos lo único que queda son las capas 1 y 2,
las migas de pan en disco con `fsync`,
y por eso son las que no dependen de nada instalado.

Si hiciera falta más, el siguiente escalón es **netconsole**:
mandar cada `printk` por UDP a otra máquina en tiempo real,
de modo que lo último transmitido se vea en el receptor aunque aquí no quede
nada.
`CONFIG_NETCONSOLE=m` está disponible en este kernel.
No se incluye en el paquete porque necesita una segunda máquina escuchando,
la IP y la MAC del receptor,
y que el cuelgue no se lleve antes la tarjeta de red.
Montaje mínimo, en la máquina que cuelga:

```sh
# 10.0.0.2 = receptor; eth0 = interfaz de salida
sudo modprobe netconsole netconsole=6666@10.0.0.1/eth0,6666@10.0.0.2/aa:bb:cc:dd:ee:ff
# en el receptor:  nc -u -l 6666 | tee netconsole.log
```

Con netconsole conviene además quitar `quiet` de la línea de kernel,
porque ahí sí importa el nivel de consola.
Para ramoops **no** importa:
`quiet` solo cambia lo que se imprime en pantalla,
no lo que se guarda en el buffer del kernel, que es lo que se vuelca.

## Activar

### 1. Instalar

```sh
cd /ruta/al/repo/aorus-5060-egpu
make forensics
sudo apt install ./dist/aorus-egpu-forensics_*_all.deb
```

El `postinst` crea `/var/log/aorus-egpu/{traces,pstore,postmortem}`,
habilita `aorus-egpu-pstore-archive.service`,
aplica los sysctl **al instante**
y ejecuta `update-grub`.

Las capas 1 y 2 funcionan ya, sin reiniciar.
Los sysctl de lockup→panic, también.

### 2. Reiniciar

```sh
sudo reboot
```

El reinicio es obligatorio **solo** para la reserva de RAM de ramoops:
los argumentos de kernel no se pueden aplicar en caliente.

### 3. Validar la cadena

Tras el reinicio, cinco comprobaciones.
Si alguna falla, la capa 3 no está capturando nada y conviene saberlo **ahora**,
no después del cuelgue.

```sh
# a) los argumentos llegaron al kernel
grep -o 'reserve_mem=[^ ]*\|ramoops\.[^ ]*\|pstore\.[^ ]*' /proc/cmdline

# b) el módulo está cargado (y arrastró reed_solomon)
lsmod | grep -E 'ramoops|reed_solomon'

# c) ramoops encontró la región reservada  <-- LA COMPROBACIÓN CLAVE
sudo dmesg | grep -i ramoops
#    esperado:  ramoops: using 0x1000000@0x<dirección>, ecc: 16
#    si sale "The memory size and the record/console size must be non-zero",
#    ramoops NO encontró la etiqueta de reserve_mem

# d) ramoops ganó el hueco de backend (debe decir "ramoops", no "efi_pstore")
cat /sys/module/pstore/parameters/backend
cat /sys/module/pstore/parameters/kmsg_bytes      # esperado: 262144

# e) los sysctl están puestos
sysctl kernel.hardlockup_panic kernel.softlockup_panic kernel.panic \
       kernel.watchdog_thresh kernel.sysrq

# y la unit de archivado está habilitada
systemctl status aorus-egpu-pstore-archive.service
```

`dmesg` necesita `sudo` en esta máquina (`kernel.dmesg_restrict=1`).

## Provocar una prueba

Validar la cadena de verdad exige un panic de verdad.
Las dos formas, de menos a más destructiva.

### Prueba A — un volcado sin provocar un panic

Grabar también en el apagado limpio, solo para esta vez:
en el menú de GRUB pulsa `e`,
añade `ramoops.max_reason=4` al final de la línea del kernel
y arranca (no toca ningún fichero, se olvida al siguiente reinicio).
Después, `sudo reboot`,
y al volver debe haber un volcado archivado del apagado anterior.
Prueba la cadena completa —reserva, módulo, backend, persistencia de la DRAM a
través del reinicio, y la unit de archivado—
sin un solo panic.

`ramoops.max_reason=4` no se deja fijo en el paquete porque grabaría un registro
en cada apagado,
y "hay un volcado" dejaría de significar "hubo un cuelgue".
El valor que sí se deja es 3
(`1=PANIC`, `2=OOPS`, `3=EMERG`, `4=SHUTDOWN` en `enum kmsg_dump_reason`).

### Prueba B — un panic real

**Esto tira la máquina de inmediato.
Guarda todo antes.**

```sh
sudo sh -c 'echo c > /proc/sysrq-trigger'
```

La máquina hace panic y se reinicia sola a los 20 s
(`kernel.panic=20`).
Escribir en `/proc/sysrq-trigger` funciona siempre que seas root,
incluso con el bit `DUMP` apagado en la máscara:
la ruta de `/proc` no consulta `kernel.sysrq`,
que solo manda en el teclado.

Al volver a arrancar debe existir
`/var/log/aorus-egpu/pstore/<fecha>/dmesg-ramoops-0`
con el final del `dmesg` y el backtrace del panic.
Si existe, **la capa 3 funciona en esta máquina** y el próximo cuelgue dejará
rastro.

## Leer el resultado tras un cuelgue

Lo primero, y hace casi todo el trabajo:

```sh
sudo aorus-egpu-postmortem
```

Junta en un único directorio la última traza, el volcado de pstore y el journal
del arranque anterior,
con un `00-RESUMEN.txt` por el que empezar.

A mano, si prefieres mirar las fuentes:

```sh
# 1. el dmesg del kernel en el instante de morir (lo más valioso)
ls -lt /var/log/aorus-egpu/pstore/
sudo tail -n 200 /var/log/aorus-egpu/pstore/<fecha>/dmesg-ramoops-0
#    el registro de número MÁS BAJO es el más reciente,
#    y lo interesante está al FINAL del fichero

# 2. las migas de pan: el último paso que ejecutamos antes de morir
tail -n 20 /var/log/aorus-egpu/traces/<fecha>-<nombre>/10-breadcrumbs.log
tail -n 40 /var/log/aorus-egpu/traces/<fecha>-<nombre>/30-watch.log

# 3. el journal del arranque anterior (lo que sí llegó a disco)
journalctl -b -1 -k --no-pager | tail -n 200
journalctl -b -1 -k --no-pager | grep -iE 'nvrm|xid|aer|thunderbolt|pcieport'

# 4. nuestras propias marcas, que viajan en el buffer del kernel
grep -i 'AORUS-TRACE' /var/log/aorus-egpu/pstore/<fecha>/dmesg-ramoops-0
journalctl -b -1 -k --no-pager | grep -i 'AORUS-TRACE'

# 5. ¿detectó el kernel algún lockup en este arranque?
cat /sys/kernel/hardlockup_count /sys/kernel/softlockup_count \
    /sys/kernel/oops_count /sys/kernel/warn_count
```

Los contadores de `/sys/kernel/` se reinician con cada arranque,
así que sirven para el arranque en curso, no para el anterior.

## Tabla: síntoma → dónde mirar

| Síntoma observado | Dónde mirar primero | Si está vacío, qué significa |
|---|---|---|
| Congelación total y la máquina se reinició **sola** a los ~20 s | `/var/log/aorus-egpu/pstore/<fecha>/dmesg-ramoops-0`, al final del fichero | El panic ocurrió pero el volcado no se grabó: revisa "Validar la cadena" (c) y (d) |
| Congelación total y hubo que **apagar a mano** | `10-breadcrumbs.log` (última línea) y `30-watch.log` de la traza | No hubo panic: el detector de lockups tampoco corrió. Límite declarado; mira netconsole |
| Congelación con el teclado vivo | Pulsa `Alt+SysRq+l` y luego `Alt+SysRq+c`, y lee el pstore al reiniciar | Si tras `c` no hay volcado, el problema es la capa 3, no el cuelgue |
| La máquina vuelve sola pero pstore está vacío | `journalctl -b -1 -k` | El reinicio no vino de un panic (watchdog de firmware, corte de corriente) |
| `nvidia-smi` clavado para siempre y el resto responde | `journalctl -b 0 -k \| grep -iE 'hung_task\|nvrm\|xid'` | Tarea en D: activa `kernel.hung_task_panic=1` para cazarlo con volcado |
| Caída del enlace Thunderbolt o tormenta de AER | `journalctl -b -1 -k \| grep -iE 'aer\|pcieport\|thunderbolt'` | El enlace murió sin dejar mensaje: mira `30-watch.log`, que muestrea `current_link_speed` |
| Xid de la GPU | `journalctl -b -1 -k \| grep -i xid` | Si hay Xid pero no cuelgue, no es este problema: es del driver |
| La eGPU no enumera / BAR0 a 0 | Otro problema, no un cuelgue | Ver `docs/what-actually-works.md` y el paquete `egpu-tb-fix` |

## Desactivar y revertir

Apagar solo los reinicios automáticos, en caliente, sin desinstalar nada:

```sh
sudo sysctl -w kernel.softlockup_panic=0
sudo sysctl -w kernel.hardlockup_panic=0
sudo sysctl -w kernel.panic_on_rcu_stall=0
```

Apagar la capa 3 de forma permanente pero conservar las capas 1 y 2:

```sh
sudo mv /etc/sysctl.d/60-aorus-egpu-lockup.conf{,.disabled}
sudo mv /etc/default/grub.d/97-aorus-egpu-forensics.cfg{,.disabled}
sudo update-grub && sudo reboot
```

Quitarlo todo:

```sh
sudo apt remove aorus-egpu-forensics
sudo reboot
```

El `postrm` devuelve los `_panic` a 0 en caliente y regenera GRUB,
así que la reserva de RAM desaparece del cmdline en el siguiente arranque.
Las trazas y los volcados ya recogidos **se conservan** en
`/var/log/aorus-egpu/`:
son evidencia, y borrarlos es decisión tuya.

Si un argumento de kernel rompiera el arranque:
en el menú de GRUB pulsa `e`,
borra los argumentos de esa línea,
arranca,
y luego `sudo apt remove aorus-egpu-forensics`.

## Ficheros que instala esta capa

| Fichero | Para qué |
|---|---|
| `/etc/default/grub.d/97-aorus-egpu-forensics.cfg` | Reserva de RAM y parámetros de ramoops/pstore en el cmdline |
| `/etc/sysctl.d/60-aorus-egpu-lockup.conf` | lockup → panic, backtraces de todas las CPUs, SysRq, `kernel.panic` |
| `/usr/lib/modules-load.d/aorus-egpu-ramoops.conf` | Cargar ramoops, que en x86 nadie carga |
| `/usr/lib/systemd/system/aorus-egpu-pstore-archive.service` | Archivar y vaciar pstore en cada arranque |

El prefijo `97-` del fichero de GRUB es deliberado:
se lee **después** de `egpu-tb-fix.cfg`,
y la línea empieza por `${GRUB_CMDLINE_LINUX_DEFAULT}`
para añadirse a lo que ya pusieron ese paquete y el default de Ubuntu,
en vez de pisarlo.

## Evidencia y referencias

Hechos verificados en esta máquina (kernel 7.0.0-1015-oem, Ubuntu 26.04):

- `/boot/config-7.0.0-1015-oem`:
  `CONFIG_PSTORE=y`, `CONFIG_PSTORE_RAM=m`, `CONFIG_PSTORE_COMPRESS=y`,
  `CONFIG_PSTORE_DEFAULT_KMSG_BYTES=10240`, `CONFIG_LOG_BUF_SHIFT=18`,
  `CONFIG_HARDLOCKUP_DETECTOR_PERF=y`, `CONFIG_NETCONSOLE=m`;
  y **sin** `CONFIG_PSTORE_CONSOLE`, `CONFIG_PSTORE_PMSG` ni
  `CONFIG_PSTORE_FTRACE`.
- `/proc/kallsyms` exporta `reserve_mem_find_by_name` y
  `reserve_mem_release_by_name`
  (también `reserve_mem_kho_revive`, o sea que es la versión reciente del
  mecanismo);
  y **no** tiene símbolos `pstore_register_console`.
- `modinfo -p ramoops` declara `mem_name`, `record_size`, `console_size`,
  `max_reason`, `ecc`, `mem_type` y el obsoleto `dump_oops`;
  el `.ko` referencia `reserve_mem_find_by_name` y depende de `reed_solomon`.
- `/sys/module/pstore/parameters/backend` = `efi_pstore`,
  `kmsg_bytes` = `10240`.
- `/sys/fs/pstore` montado y vacío;
  `lsmod` sin `ramoops`.
- `kernel.sysrq` = 176 (de `/usr/lib/sysctl.d/55-magic-sysrq.conf`);
  `kernel.dmesg_restrict` = 1;
  `kernel.panic` = 10;
  `kernel.watchdog_thresh` = 10;
  `hardlockup_panic` y `softlockup_panic` = 0.
- `systemd-pstore.service` está **enabled** (de ahí el `Before=` de nuestra
  unit).

Documentación del kernel:

- Ramoops oops/panic logger —
  <https://docs.kernel.org/admin-guide/ramoops.html>
  (de ahí el ejemplo `reserve_mem=2M:4096:oops ramoops.mem_name=oops`,
  la tabla de `max_reason`,
  la recomendación de `ecc` tras un reinicio por hardware,
  y el aviso de que `reserve_mem` es *best effort*).
- Softlockup y hardlockup detectors —
  <https://docs.kernel.org/admin-guide/lockup-watchdogs.html>
  (`watchdog_thresh`, el umbral de softlockup `2*watchdog_thresh`,
  y la combinación de `*_panic` con `kernel.panic`).
- Magic SysRq key —
  <https://docs.kernel.org/admin-guide/sysrq.html>.
- `reserve_mem=` en `Documentation/admin-guide/kernel-parameters.txt`,
  formato `nn[KMG]:<align>:<label>`,
  añadido en Linux 6.12 por el commit `1e4c64b71c9b` de `mm/memblock.c`.
- `ramoops.mem_name=`, commit `d9d814ee` de `fs/pstore/ram.c`.
- Backend único de pstore: `fs/pstore/platform.c`,
  `pstore_register()` devuelve `-EBUSY` con
  `backend '%s' already loaded: ignoring '%s'`.
- `enum kmsg_dump_reason` en `include/linux/kmsg_dump.h`:
  `UNDEF=0`, `PANIC=1`, `OOPS=2`, `EMERG=3`, `SHUTDOWN=4`.
- Bits de SysRq en `include/linux/sysrq.h`:
  `DUMP=0x8`, `SYNC=0x10`, `REMOUNT=0x20`, `BOOT=0x80`.
- `/proc/sysrq-trigger` ignora la máscara:
  `write_sysrq_trigger()` llama a `__handle_sysrq(c, false)` en
  `drivers/tty/sysrq.c`.
