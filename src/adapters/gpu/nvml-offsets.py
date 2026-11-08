#!/usr/bin/env python3
"""Offsets de reloj de la eGPU por NVML. Helper de adapters/gpu/nvml.sh.

Es la ÚNICA pieza del repo que escribe relojes POR ENCIMA de stock, así que
lleva el gate R4 dentro en vez de confiar en que la capa de arriba ya lo
aplicó: antes de cada operación resuelve el handle por PCI bus-id y CONFIRMA
que el device-id es el de la eGPU externa (0x2d04). Si resuelve a la GPU
INTERNA (0x2c39) aborta sin tocar nada — tocarla ya provocó un Xid 79.

POR QUÉ ESTA API Y NO LA NUEVA (medido el 2026-11-02 con nvidia-ml-py
13.615.71 sobre 0000:B4:00.0):

    nvmlDeviceGetGpcClkVfOffset       = 0      ventana (-1000, 1000) MHz
    nvmlDeviceGetMemClkVfOffset       = 0      ventana (-2000, 6000) MHz
    nvmlDeviceGetClockOffsets                  la función EXISTE en el binding
                                               pero el struct
                                               c_nvmlClockOffset_v1_t NO, así
                                               que no es usable todavía.

`nvidia-settings` no es una alternativa en esta máquina: necesita NV-CONTROL
sobre un servidor X y la sesión es Wayland.

Uso (lo invoca el adaptador, no una persona):
    nvml-offsets.py caps <busid>              supported=... / window=...
    nvml-offsets.py get  <busid>              gpu_offset=... mem_offset=...
    nvml-offsets.py set  <busid> <gpu|mem> <mhz>

Códigos de salida:
    0   ok
    1   error de operación (la escritura no se confirmó al releer)
    2   error de uso
    3   NVML no disponible, o esta GPU no soporta offsets
    77  GATE R4: el bus-id no resuelve a la eGPU externa (nada se ha tocado)
"""
import sys

EGPU_DEVICE_ID = 0x2D04  # AORUS RTX 5060 Ti (externa, Thunderbolt) — la única
INTERNAL_DEVICE_ID_FORBIDDEN = 0x2C39  # RTX PRO 4000 interna — PROHIBIDA: abortar

RC_OK, RC_FAIL, RC_USAGE, RC_UNSUPPORTED, RC_R4 = 0, 1, 2, 3, 77


def die(rc, msg):
    print(msg, file=sys.stderr, flush=True)
    raise SystemExit(rc)


def load_nvml():
    """pynvml, o rc 3. No tenerlo NO es un error: es 'no soportado'."""
    try:
        import pynvml
    except Exception as exc:  # ImportError y cualquier fallo de carga del .so
        die(RC_UNSUPPORTED, f"nvml_import=FAIL {type(exc).__name__}: {exc}")
    try:
        pynvml.nvmlInit()
    except Exception as exc:
        die(RC_UNSUPPORTED, f"nvml_init=FAIL {type(exc).__name__}: {exc}")
    return pynvml


def open_egpu(nvml, bus_id):
    """Handle de la GPU en bus_id, con el gate R4 aplicado.

    Se resuelve por bus-id y NUNCA por índice: los índices se reordenan entre
    arranques, y en esta máquina el 0 es la GPU interna. Y aun resolviendo por
    bus-id se CONFIRMA el device-id: un bus-id equivocado (un copy-paste, una
    regla udev con el BDF viejo) tiene que abortar aquí, no escribir.
    """
    try:
        handle = nvml.nvmlDeviceGetHandleByPciBusId(bus_id.encode())
    except Exception as exc:
        die(RC_R4, f"r4_resolve=FAIL {bus_id} {type(exc).__name__}: {exc}")
    try:
        pci = nvml.nvmlDeviceGetPciInfo(handle)
        # pciDeviceId es 0xDDDDVVVV: device en la mitad alta, vendor en la baja.
        device_id = (pci.pciDeviceId >> 16) & 0xFFFF
    except Exception as exc:
        die(RC_R4, f"r4_device_id=FAIL {type(exc).__name__}: {exc}")

    if device_id == INTERNAL_DEVICE_ID_FORBIDDEN:
        die(RC_R4, f"r4_abort=GPU_INTERNA {bus_id} device=0x{device_id:04x} "
                   "— jamás es un target válido; no se ha tocado nada")
    if device_id != EGPU_DEVICE_ID:
        die(RC_R4, f"r4_abort=NO_ES_LA_EGPU {bus_id} device=0x{device_id:04x} "
                   f"(se esperaba 0x{EGPU_DEVICE_ID:04x}); no se ha tocado nada")
    return handle


def read_windows(nvml, handle):
    """((gmin, gmax), (mmin, mmax)) o None si la GPU no soporta offsets."""
    try:
        gpu_win = nvml.nvmlDeviceGetGpcClkMinMaxVfOffset(handle)
        mem_win = nvml.nvmlDeviceGetMemClkMinMaxVfOffset(handle)
    except Exception:
        return None
    try:
        return ((int(gpu_win[0]), int(gpu_win[1])),
                (int(mem_win[0]), int(mem_win[1])))
    except (TypeError, ValueError, IndexError):
        return None


def read_offsets(nvml, handle):
    try:
        return (int(nvml.nvmlDeviceGetGpcClkVfOffset(handle)),
                int(nvml.nvmlDeviceGetMemClkVfOffset(handle)))
    except Exception:
        return None


def cmd_caps(nvml, bus_id):
    handle = open_egpu(nvml, bus_id)
    windows = read_windows(nvml, handle)
    if windows is None or read_offsets(nvml, handle) is None:
        # Sin ventanas o sin lectura no se declara soporte: el adaptador lo
        # traduce a rc 3 y el dominio rechaza el perfil. Sin evidencia no se
        # escribe (misma filosofía que el 'unknown' del gate de enlace).
        print("supported=no", flush=True)
        return RC_UNSUPPORTED
    (gmin, gmax), (mmin, mmax) = windows
    print("supported=yes", flush=True)
    print(f"window={gmin} {gmax} {mmin} {mmax}", flush=True)
    return RC_OK


def cmd_get(nvml, bus_id):
    handle = open_egpu(nvml, bus_id)
    offsets = read_offsets(nvml, handle)
    if offsets is None:
        print("supported=no", flush=True)
        return RC_UNSUPPORTED
    print(f"gpu_offset={offsets[0]} mem_offset={offsets[1]}", flush=True)
    return RC_OK


def cmd_set(nvml, bus_id, domain, mhz):
    handle = open_egpu(nvml, bus_id)
    windows = read_windows(nvml, handle)
    if windows is None:
        print("supported=no", flush=True)
        return RC_UNSUPPORTED

    which = {"gpu": 0, "mem": 1}.get(domain)
    if which is None:
        die(RC_USAGE, f"uso: dominio '{domain}' desconocido (gpu|mem)")
    low, high = windows[which]
    if not low <= mhz <= high:
        # Segunda comprobación de la ventana, después de la del dominio. Fuera
        # de rango se RECHAZA, no se acota: acotar convertiría la petición en
        # otra distinta y el modo de fallo de esta palanca son números mal
        # calculados.
        die(RC_USAGE, f"offset {mhz} fuera de la ventana [{low},{high}] "
                      f"del dominio {domain}; no se escribe nada")

    setter = (nvml.nvmlDeviceSetGpcClkVfOffset if which == 0
              else nvml.nvmlDeviceSetMemClkVfOffset)
    try:
        setter(handle, mhz)
    except Exception as exc:
        die(RC_FAIL, f"set_{domain}=FAIL {type(exc).__name__}: {exc}")

    # Releer y comparar: NVML acepta la llamada sin que el driver haya aplicado
    # el valor (p. ej. con el perfil de reloj bloqueado). Decir "aplicado" sin
    # comprobarlo es exactamente el falso éxito que este paquete no puede dar.
    after = read_offsets(nvml, handle)
    if after is None or after[which] != mhz:
        got = "?" if after is None else after[which]
        die(RC_FAIL, f"set_{domain}=NO_CONFIRMADO pedido={mhz} leido={got}")
    print(f"set_{domain}={mhz}", flush=True)
    return RC_OK


def main(argv):
    if len(argv) < 3:
        die(RC_USAGE, __doc__.split("Uso")[-1].strip())
    command, bus_id = argv[1], argv[2]

    nvml = load_nvml()
    try:
        if command == "caps":
            return cmd_caps(nvml, bus_id)
        if command == "get":
            return cmd_get(nvml, bus_id)
        if command == "set":
            if len(argv) != 5:
                die(RC_USAGE, "uso: set <busid> <gpu|mem> <mhz>")
            try:
                mhz = int(argv[4], 10)
            except ValueError:
                die(RC_USAGE, f"uso: '{argv[4]}' no es un entero con signo")
            return cmd_set(nvml, bus_id, argv[3], mhz)
        die(RC_USAGE, f"uso: comando '{command}' desconocido (caps|get|set)")
    finally:
        try:
            nvml.nvmlShutdown()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
