# desc: +600 MHz de núcleo — el escalón más alto que pasó, y el de evidencia MÁS DÉBIL
# LEE ESTO ANTES DE DEJARLO PUESTO.
#
# +600 es el último escalón de la escalera de H25 que pasó limpio, pero su
# cobertura es **n=1 de 20 s**, no el n>=3 de 90 s que la metodología del repo
# exige: el barrido abortó al colgarse la tarjeta en el paso siguiente, así que
# la confirmación nunca llegó a correr. Medido en ese paso el 2026-11-05:
# 3405 MHz bajo carga, 167.9 W, 78 °C, throttle 0x0, 0 errores.
#
# El escalón siguiente, +675, produjo un fallo DURO: `Xid 109 CTX SWITCH
# TIMEOUT` (x12), `NV_ERR_RESET_REQUIRED`, la tarjeta dejó de responder a NVML
# y a nvidia-smi, y hubo que reconectar el Thunderbolt. Así que este perfil
# deja solo **75 MHz de margen** hasta un estado que cuesta una recuperación.
#
# Y el margen de reloj no es el único riesgo. Esta tarjeta no tiene ECC, y hay
# un caso documentado en Blackwell/GDDR7 donde un GEMM de entradas fijas
# devolvió un resultado distinto en la iteración 274.400 mientras un memtest de
# VRAM pasaba 1.252 pasadas limpias. Las 44 327 iteraciones bit-exactas de toda
# la escalera son dos órdenes de magnitud menos que eso: el gate de
# verificación detecta una tarjeta que YA calcula mal, no garantiza que no
# empiece a calcular mal en la hora 3 de un entrenamiento.
#
# Uso honesto: para medir, comparar y exprimir una tanda corta. Para servir
# modelos en producción, `oc-normal` o directamente `efficient`.
#
# Memoria fijada a 0 como en el resto de los oc-*. Ver oc-normal.profile.
gpu_clock_offset_mhz=600
mem_clock_offset_mhz=0
verify=gemm
