# desc: +375 MHz de núcleo — el escalón intermedio de la escalera medida
# Memoria fijada a 0, igual que en el resto de los oc-*: sin escalera medida
# no se entrega un offset de memoria. Ver oc-normal.profile para el motivo
# completo.
#
# +375 es un punto REAL de la escalera de H25, medido bit-exacto el
# 2026-11-05: 3180 MHz bajo carga, 160.5 W, throttle 0x0, 0 errores.
# Son 300 MHz de margen hasta el +675 que colgó la tarjeta.
#
# Offset POSITIVO: pasa por el gate de verificación y no se aplica de forma
# desatendida. `sudo aorus-egpu-oc apply oc-medio`.
gpu_clock_offset_mhz=375
mem_clock_offset_mhz=0
verify=gemm
