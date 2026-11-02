# desc: techo de reloj 2400 MHz y potencia 150 W — el más conservador
# El que acota de verdad es el TECHO DE RELOJ: con 139 W medidos bajo GEMM
# sostenido, el tope de 150 W no llega a actuar en esta carga. Se mantiene por
# si otra carga sí sube de ahí.
#
# Medido el 2026-11-02 en esta tarjeta frente a stock: 43.0 TFLOP/s fp16 contra
# 49.7 (-13%) con 91 W contra 138 (-34%), o sea 0.472 TFLOP/W contra 0.360:
# +31% de eficiencia. Es el único perfil con efecto real medido.
#
# SIN gpu_clock_min_mhz a propósito. Antes había que poner un suelo de 500 que
# nadie quería, porque un techo a solas se traducía en `-lgc 2400,2400` y
# anclaba el reloj en duro también en reposo. Corregido: el suelo por defecto
# es ahora el mínimo de la tarjeta (180 MHz), así que en reposo baja de verdad.
power_limit_w=150
gpu_clock_max_mhz=2400
