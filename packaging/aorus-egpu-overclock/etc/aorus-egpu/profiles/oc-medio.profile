# desc: +375 MHz de núcleo — el escalón intermedio de la escalera medida
#
# +375 es un punto REAL de la escalera de H25, medido bit-exacto el
# 2026-11-05: 3180 MHz bajo carga, 160.5 W, throttle 0x0, 0 errores.
# Son 300 MHz de margen hasta el +675 que colgó la tarjeta.
#
# Offset POSITIVO: pasa por el gate de verificación y no se aplica de forma
# desatendida. `sudo aorus-egpu-oc apply oc-medio`.
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
gpu_clock_offset_mhz=375
verify=gemm
