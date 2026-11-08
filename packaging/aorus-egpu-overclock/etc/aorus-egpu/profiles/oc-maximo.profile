# desc: +525 MHz de núcleo — el escalón más alto que sigue en pie
# El +600 ESTUVO aquí y se cayó. Vale la pena leer por qué antes de subirlo.
#
# El 2026-11-07 a las 22:58 este perfil llevaba +600 MHz, y aplicarlo con
# `aorus-egpu-oc apply oc-maximo` colgó la tarjeta en SEIS segundos:
#   NVRM: Xid (PCI:0000:8d:00): 62
#   NVRM: _kgspRpcGspEventPmuHalted: Received signal from GSP that PMU has halted
#   NVRM: Xid (PCI:0000:8d:00): 154, recovery action 0x0 (None) -> 0x1 (GPU Reset Required)
# más un volcado del RISC-V del GSP. El verificador no completó NI UNA
# iteración (`errors=0 iters=0` en oc-verify.log), así que el fallo no fue
# numérico: la tarjeta murió antes de calcular nada. El gate funcionó —no
# persistió el perfil— pero la eGPU quedó en `Reset Required`.
#
# Y el +600 venía de una medición que pasó LIMPIA: la escalera de H25 lo
# registró a 3405 MHz con 0 errores. Con n=1 de 20 s. Esto es exactamente lo
# que el gate de n>=3 del repo existe para atrapar, y el valor se entregó
# igualmente con un aviso en el fichero. El aviso no bastó.
#
# +525 es el escalón inmediatamente inferior y el más alto con medición de
# duración completa: 3330 MHz, 165.4 W, throttle 0x0, 0 errores. Deja 150 MHz
# hasta el +675 que ya se sabía que colgaba, y 75 MHz hasta el +600 que ahora
# también se sabe que cuelga.
#
# NO SUBAS ESTE VALOR sin medir antes el escalón nuevo con
# `tools/egpu-oc-edge` y n>=3 de 90 s. La lección de este incidente es que un
# paso limpio una vez no es un paso limpio.
#
# Sigue siendo el perfil más agresivo del paquete y sigue sin ser para dejarlo
# puesto: esta tarjeta no tiene ECC y el gate de verificación detecta una
# tarjeta que YA calcula mal, no garantiza que no empiece a calcular mal en la
# hora 3 de un entrenamiento. Para servir modelos, oc-normal o efficient.
#
# Memoria fijada a 0 como en el resto de los oc-*. Ver oc-normal.profile.
gpu_clock_offset_mhz=525
mem_clock_offset_mhz=0
verify=gemm
