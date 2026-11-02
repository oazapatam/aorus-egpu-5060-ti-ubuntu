#!/usr/bin/env python3
"""PyTorch CUDA smoke test SOBRE LA eGPU.

Valida el camino que usa vLLM de verdad: init del runtime de torch.cuda,
asignación de tensores en device, kernels CUDA reales (GEMM de cuBLAS), sync y
una comprobación determinista del resultado.

POR QUÉ FIJA LA GPU POR BUS-ID: este test usaba `cuda:0`, y en esta máquina el
ordinal 0 es la GPU INTERNA (RTX PRO 4000). Daba `pytorch_smoke=pass` sin haber
tocado la eGPU. La regla del repo (CLAUDE.md, gate R4) es direccionar por PCI
bus-id y nunca por índice: los índices se reordenan entre arranques.

El pin se hace con CUDA_VISIBLE_DEVICES=<bus-id> ANTES de importar torch, que
es la única forma de fijar la GPU física sin depender del orden de enumeración
del runtime (que por defecto es FASTEST_FIRST, no por bus). Así `cuda:0` dentro
del proceso ES la eGPU, sin ambigüedad.

Sale 0 con 'pytorch_smoke=pass'. Si algo falla, dice qué paso y sale != 0.

Uso, desde un venv que tenga 'torch':
    python3 tools/pytorch-cuda-smoke-test.py              # la eGPU (removable)
    python3 tools/pytorch-cuda-smoke-test.py 0000:B4:00.0 # un bus-id concreto

O con el runner de TTY:
    tools/tty-pytorch-test.sh
"""
import os
import sys
from pathlib import Path

SYSFS_PCI = Path("/sys/bus/pci/devices")
PCI_CLASS_VGA = "0x030000"
PCI_VENDOR_NVIDIA = "0x10de"


def fail(stage, exc=None):
    if exc is None:
        print(f"{stage}=FAIL", flush=True)
    else:
        print(f"{stage}=FAIL {type(exc).__name__}: {exc}", flush=True)
    sys.exit(1)


def _read(path):
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def find_egpu_bus_id():
    """Bus-id de la primera GPU NVIDIA marcada `removable` en sysfs.

    `removable` es la confirmación topológica que fija CLAUDE.md: el
    controlador Thunderbolt es un HERMANO en el árbol PCI, no un ancestro, así
    que subir el árbol buscando el driver `thunderbolt` da un falso negativo.
    La GPU interna tiene este atributo VACÍO; la externa dice "removable".
    """
    for device in sorted(SYSFS_PCI.iterdir()):
        if _read(device / "class") != PCI_CLASS_VGA:
            continue
        if _read(device / "vendor") != PCI_VENDOR_NVIDIA:
            continue
        if _read(device / "removable") != "removable":
            continue
        return device.name.upper()
    return None


def pin_to_egpu():
    """Fija CUDA_VISIBLE_DEVICES al bus-id de la eGPU. Antes de importar torch."""
    want = sys.argv[1] if len(sys.argv) > 1 else None

    preset = os.environ.get("CUDA_VISIBLE_DEVICES")
    if preset and not want:
        # Respetar una decisión explícita del entorno, pero dejarla registrada:
        # si apunta a la interna, el 'pass' no valdría para la eGPU.
        print(f"cuda_visible_devices=heredado:{preset}", flush=True)
        return preset

    bus_id = want or find_egpu_bus_id()
    if not bus_id:
        fail("find_egpu", RuntimeError(
            "no hay ninguna GPU NVIDIA 'removable' en sysfs; "
            "¿está conectada la eGPU? Pasa el bus-id a mano si lo sabes."))

    # CUDA_VISIBLE_DEVICES acepta bus-ids PCI, no solo índices.
    os.environ["CUDA_VISIBLE_DEVICES"] = bus_id
    print(f"cuda_visible_devices={bus_id}", flush=True)
    return bus_id


def main():
    # 0. Fijar la GPU física ANTES de importar torch: al importar, el runtime
    #    ya congela la lista de devices visibles.
    target_bus_id = pin_to_egpu()

    # 1. Import torch
    try:
        import torch
    except Exception as e:
        fail("import_torch", e)
    print(f"torch_version={torch.__version__}", flush=True)
    print(f"torch_cuda_version={torch.version.cuda}", flush=True)

    # 2. CUDA available
    if not torch.cuda.is_available():
        fail("cuda_available")
    print("cuda_available=ok", flush=True)

    # 3. Device enumeration
    try:
        dc = torch.cuda.device_count()
    except Exception as e:
        fail("device_count", e)
    print(f"device_count={dc}", flush=True)
    if dc < 1:
        fail("device_count_zero")

    # Con el pin por bus-id el proceso debe ver UNA sola GPU: la eGPU. Si ve
    # más, el pin no se aplicó y `cuda:0` podría ser la interna, así que el
    # resultado del test no significaría lo que dice significar.
    if dc != 1:
        fail("pin_not_applied", RuntimeError(
            f"esperaba 1 GPU visible tras fijar {target_bus_id}, veo {dc}"))
    print(f"target_bus_id={target_bus_id}", flush=True)

    try:
        name = torch.cuda.get_device_name(0)
    except Exception as e:
        fail("device_name", e)
    print(f"device_name={name}", flush=True)

    try:
        cap_major, cap_minor = torch.cuda.get_device_capability(0)
    except Exception as e:
        fail("device_capability", e)
    print(f"compute_capability={cap_major}.{cap_minor}", flush=True)

    d = torch.device("cuda:0")

    # 4. Allocate deterministic tensors on CUDA
    print("before_tensor_alloc=ok", flush=True)
    try:
        a = torch.ones(1024, 1024, device=d, dtype=torch.float32)
        b = torch.ones(1024, 1024, device=d, dtype=torch.float32)
    except Exception as e:
        fail("tensor_alloc", e)
    print("after_tensor_alloc=ok", flush=True)

    # 5. cuBLAS GEMM with deterministic input - product of two ones-matrices
    # of shape NxN is an NxN matrix where every element is N. This avoids
    # comparing against a CPU reference (slow, precision-dependent) while
    # still exercising the actual GEMM kernel.
    print("before_mm=ok", flush=True)
    try:
        c = torch.mm(a, b)
        torch.cuda.synchronize()
    except Exception as e:
        fail("mm_or_sync", e)
    print("after_mm=ok", flush=True)

    # 6. Verify result. Every element should be exactly 1024.0.
    expected = 1024.0
    try:
        actual = c[0, 0].item()
        max_val = c.max().item()
        min_val = c.min().item()
    except Exception as e:
        fail("read_result", e)
    print(f"mm_result_first_element={actual}", flush=True)
    print(f"mm_result_min={min_val} max={max_val}", flush=True)
    if abs(actual - expected) > 0.01 or max_val != actual or min_val != actual:
        fail("mm_result_mismatch")
    print("mm_correct=ok", flush=True)

    # 7. Memory stats
    try:
        alloc = torch.cuda.memory_allocated(0)
        reserved = torch.cuda.memory_reserved(0)
    except Exception as e:
        fail("memory_stats", e)
    print(f"memory_allocated_bytes={alloc}", flush=True)
    print(f"memory_reserved_bytes={reserved}", flush=True)

    # 8. Cleanup. Do NOT call torch.cuda.empty_cache() - we want to validate
    # that the normal del-and-let-GC path works without exercising the cache
    # release code path.
    del a, b, c

    print("pytorch_smoke=pass", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
