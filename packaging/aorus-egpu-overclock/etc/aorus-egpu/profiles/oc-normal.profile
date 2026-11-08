# desc: +150 MHz de núcleo — el escalón conservador de la escalera medida
# Los tres perfiles oc-* tocan SOLO el núcleo. La memoria va fijada a 0 a
# propósito: su escalera no se ha medido nunca (H25, "la memoria sin medir"),
# y el +6000 que circula por las notas viene de un bench que acabó en
# `Reset Required`, no de una comparación bit-exacta. En una tarjeta SIN ECC
# que sirve modelos, un offset de memoria sin medir no se cae: corrompe pesos
# en silencio. Cuando `tools/egpu-oc-edge` mida el dominio de memoria se
# añadirá, con su número y su evidencia.
#
# Por qué +150 y no un número redondo: es un punto REAL de la escalera de
# H25 (rejilla de 75 MHz), medido individualmente bit-exacto el 2026-11-05.
# Medido en ese paso: 2955 MHz bajo carga (contra 2812 en stock), 151.7 W,
# `clocks_throttle_reasons.active = 0x0`, 0 errores.
# Son 525 MHz de margen hasta el +675 que colgó la tarjeta con Xid 109.
#
# Aplicarlo exige el gate de verificación (GEMM bit-exacto + patrón sobre la
# VRAM) porque el offset es POSITIVO, y por eso NO se aplica desde udev ni
# desde el servicio: solo a mano, con `sudo aorus-egpu-oc apply oc-normal`.
#
# NO lleva `mem_clock_offset_mhz=0`, y la ausencia es deliberada. La llevaba, y
# es la sospechosa principal de los dos cuelgues del 2026-11-07 (+600 y +525,
# los dos con `Xid 62` + `_kgspRpcGspEventPmuHalted` + `Xid 154` en 4-6 s).
# Motivo: `tools/egpu-oc-edge`, que SÍ midió esta escalera limpia, omite la
# escritura cuando el valor no cambia (`Hardware.apply`: `if self.applied[which]
# == mhz: continue`), así que durante la escalera del núcleo **nunca escribe el
# offset de memoria**. El perfil sí lo escribía, y lo que se cuelga es el PMU,
# que es precisamente quien gestiona la curva V/F. Era una escritura añadida
# "por higiene" —para limpiar un offset de memoria previo— y esa higiene no
# justifica una escritura extra al hardware en la palanca más delicada del
# paquete. Para limpiar offsets está `aorus-egpu-oc reset`.
#
# Sigue siendo cierto que estos perfiles NO tocan la memoria: lo que cambia es
# que ahora no la tocan de verdad, en vez de escribirle un 0.
gpu_clock_offset_mhz=150
verify=gemm
