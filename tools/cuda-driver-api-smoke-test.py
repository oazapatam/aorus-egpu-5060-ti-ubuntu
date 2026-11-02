#!/usr/bin/env python3
"""Smoke test del driver API de CUDA SOBRE LA eGPU.

POR QUÉ SELECCIONA POR BUS-ID: este test usaba `cuDeviceGet(..., 0)`, es decir
el ordinal 0, que en esta máquina es la GPU INTERNA (RTX PRO 4000). Daba
`cuda_smoke=pass` sin haber tocado la eGPU ni una vez: un pase que no probaba
nada de lo que se quería probar.

La regla del repo (CLAUDE.md, gate R4) es que el hardware se direcciona por
PCI bus-id y NUNCA por índice de GPU, porque los índices se reordenan entre
arranques. Aquí no hay escrituras, así que no era una violación de R4, pero
como prueba de la eGPU valía cero.

Uso:
    cuda-driver-api-smoke-test.py              # primera GPU EXTERNA que haya
    cuda-driver-api-smoke-test.py B4:00.0      # un bus-id concreto

Sin argumento se elige la primera GPU cuyo device PCI esté marcado `removable`
en sysfs, que es la confirmación topológica que fija CLAUDE.md (el controlador
Thunderbolt es un HERMANO en el árbol PCI, no un ancestro, así que subir el
árbol buscando el driver `thunderbolt` da un falso negativo).

No añade dependencias: solo ctypes, libcuda.so.1 y sysfs.
"""
import ctypes
import sys
from pathlib import Path

SYSFS_PCI = Path("/sys/bus/pci/devices")


def pci_is_removable(bus_id):
    """¿El device PCI de este bus-id está marcado `removable` en sysfs?

    cuDeviceGetPCIBusId devuelve "0000:B4:00.0"; sysfs usa minúsculas.
    """
    try:
        value = (SYSFS_PCI / bus_id.lower() / "removable").read_text().strip()
    except OSError:
        return False
    return value == "removable"


def pick_device(cuda, want):
    """Devuelve (ordinal, bus_id) de la GPU elegida, o levanta SystemExit."""
    cu_device_get_count = cuda.cuDeviceGetCount
    cu_device_get_count.argtypes = [ctypes.POINTER(ctypes.c_int)]
    cu_device_get_count.restype = ctypes.c_int

    cu_device_get_pci_bus_id = cuda.cuDeviceGetPCIBusId
    cu_device_get_pci_bus_id.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
    cu_device_get_pci_bus_id.restype = ctypes.c_int

    count = ctypes.c_int(0)
    check("cuDeviceGetCount", cu_device_get_count(ctypes.byref(count)))
    if count.value == 0:
        print("no hay GPUs CUDA.", file=sys.stderr)
        raise SystemExit(1)

    chosen = None
    for ordinal in range(count.value):
        buf = ctypes.create_string_buffer(64)
        rc = cu_device_get_pci_bus_id(buf, ctypes.sizeof(buf), ordinal)
        if rc != 0:
            print(f"cuDeviceGetPCIBusId={rc} (ordinal {ordinal})", file=sys.stderr)
            raise SystemExit(rc)
        bus_id = buf.value.decode()
        if want:
            # Coincidencia por sufijo: acepta "B4:00.0" y "0000:B4:00.0".
            match = bus_id.lower().endswith(want.lower())
        else:
            match = pci_is_removable(bus_id)
        mark = "   <-- elegida" if match and chosen is None else ""
        print(f"gpu {ordinal}  {bus_id}{mark}", flush=True)
        if match and chosen is None:
            chosen = (ordinal, bus_id)

    if chosen is None:
        detalle = f"bus-id {want}" if want else "ninguna GPU externa (removable)"
        print(f"no encontré {detalle}.", file=sys.stderr)
        raise SystemExit(1)
    return chosen


def get_symbol(cuda, name):
    try:
        return getattr(cuda, name)
    except AttributeError:
        return getattr(cuda, f"{name}_v2")


def check(name, rc):
    print(f"{name}={rc}", flush=True)
    if rc != 0:
        raise SystemExit(rc)


def main():
    cuda = ctypes.CDLL("libcuda.so.1")

    cu_init = cuda.cuInit
    cu_init.argtypes = [ctypes.c_uint]
    cu_init.restype = ctypes.c_int

    cu_device_get = cuda.cuDeviceGet
    cu_device_get.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_int]
    cu_device_get.restype = ctypes.c_int

    cu_ctx_create = get_symbol(cuda, "cuCtxCreate")
    cu_ctx_create.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_uint, ctypes.c_int]
    cu_ctx_create.restype = ctypes.c_int

    cu_ctx_destroy = get_symbol(cuda, "cuCtxDestroy")
    cu_ctx_destroy.argtypes = [ctypes.c_void_p]
    cu_ctx_destroy.restype = ctypes.c_int

    cu_ctx_synchronize = cuda.cuCtxSynchronize
    cu_ctx_synchronize.argtypes = []
    cu_ctx_synchronize.restype = ctypes.c_int

    cu_mem_alloc = get_symbol(cuda, "cuMemAlloc")
    cu_mem_alloc.argtypes = [ctypes.POINTER(ctypes.c_uint64), ctypes.c_size_t]
    cu_mem_alloc.restype = ctypes.c_int

    cu_mem_free = get_symbol(cuda, "cuMemFree")
    cu_mem_free.argtypes = [ctypes.c_uint64]
    cu_mem_free.restype = ctypes.c_int

    cu_memset_d8 = get_symbol(cuda, "cuMemsetD8")
    cu_memset_d8.argtypes = [ctypes.c_uint64, ctypes.c_ubyte, ctypes.c_size_t]
    cu_memset_d8.restype = ctypes.c_int

    cu_memcpy_dtoh = get_symbol(cuda, "cuMemcpyDtoH")
    cu_memcpy_dtoh.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t]
    cu_memcpy_dtoh.restype = ctypes.c_int

    size = 4096
    pattern = 0x5A
    device = ctypes.c_int(-1)
    context = ctypes.c_void_p()
    device_ptr = ctypes.c_uint64(0)

    check("cuInit", cu_init(0))

    want = sys.argv[1] if len(sys.argv) > 1 else None
    ordinal, bus_id = pick_device(cuda, want)
    check("cuDeviceGet", cu_device_get(ctypes.byref(device), ordinal))
    print(f"device={device.value}", flush=True)
    print(f"bus_id={bus_id}", flush=True)
    check("cuCtxCreate", cu_ctx_create(ctypes.byref(context), 0, device.value))

    try:
        check("cuMemAlloc", cu_mem_alloc(ctypes.byref(device_ptr), size))
        try:
            check("cuMemsetD8", cu_memset_d8(device_ptr.value, pattern, size))
            check("cuCtxSynchronize", cu_ctx_synchronize())

            host_buffer = (ctypes.c_ubyte * size)()
            check("cuMemcpyDtoH", cu_memcpy_dtoh(host_buffer, device_ptr.value, size))

            mismatches = sum(1 for value in host_buffer if value != pattern)
            print(f"bytes_checked={size}", flush=True)
            print(f"mismatches={mismatches}", flush=True)
            if mismatches:
                raise SystemExit(98)
        finally:
            rc = cu_mem_free(device_ptr.value)
            print(f"cuMemFree={rc}", flush=True)
    finally:
        rc = cu_ctx_destroy(context)
        print(f"cuCtxDestroy={rc}", flush=True)

    print("cuda_smoke=pass", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
