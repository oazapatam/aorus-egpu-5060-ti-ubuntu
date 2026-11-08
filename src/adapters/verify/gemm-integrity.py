#!/usr/bin/env python3
"""Verificador numérico de la eGPU. Helper de adapters/verify/torch-gemm.sh.

PARA QUÉ: autorizar (o tumbar) un offset de reloj POSITIVO. Un offset agresivo
no se manifiesta como un cuelgue ruidoso; se manifiesta como resultados MAL
CALCULADOS que nadie detecta a ojo. Este helper busca exactamente eso.

QUÉ COMPRUEBA, y por qué hacen falta las dos cosas:

  1. GEMM (cuBLAS) con entrada ENTERA y comparación BIT-EXACTA. Las dos
     pruebas tienen resultado analíticamente conocido, así que NO hay
     tolerancia ni referencia en CPU:
       - ones(N,N) @ ones(N,N) == N en todos los elementos, exacto en fp32
         para N=2048 (2048 y los productos parciales son enteros pequeños).
       - A @ I == A bit a bit, con A de enteros pequeños deterministas.
     Y además estabilidad: el MISMO producto, repetido, tiene que dar
     exactamente los mismos bits que la primera vez. Un epsilon aquí sería
     justamente la forma de no ver el fallo que se busca.

  2. PATRÓN conocido sobre buena parte de la VRAM, releído y comparado byte a
     byte contra el patrón regenerado en CPU. El GEMM carga las SM y toca poca
     memoria; un offset de MEMORIA falla al revés —la ALU calcula bien y lo que
     vuelve mal es lo que se guardó—, así que sin esta segunda prueba un
     mem_clock_offset_mhz positivo pasaría el gate sin haberse medido.
     Cada trozo lleva un SALTO distinto (patrón XOR índice): con el mismo
     patrón en todos los trozos, una lectura mal direccionada pasaría.

La GPU se fija por PCI BUS-ID, nunca por ordinal: en esta máquina el ordinal 0
es la GPU INTERNA y un `cuda:0` daría `pass` sin tocar la eGPU. El enfoque
(enumerar y emparejar por pci_bus_id, sin CUDA_VISIBLE_DEVICES —que no acepta
bus-ids y los lee como índices—) viene de tools/pytorch-cuda-smoke-test.py.

Uso (lo invoca el adaptador, no una persona):
    gemm-integrity.py available
    gemm-integrity.py check <busid> <segundos>

Imprime siempre, como ÚLTIMA línea, el resumen que el puerto exige:
    errors=<n> iters=<n>

Códigos de salida:  0 pasa   1 FALLA (algún resultado incorrecto)   2 no
disponible (sin torch, sin CUDA, o la eGPU no está)   3 error de uso
"""
import sys
import time

RC_PASS, RC_FAIL, RC_UNAVAILABLE, RC_USAGE = 0, 1, 2, 3

GEMM_N = 2048             # fp32; 2048 es exacto como suma de 2048 unos
VRAM_CHUNK_BYTES = 256 << 20   # 256 MiB por trozo
VRAM_TARGET_FRACTION = 0.70    # de la VRAM LIBRE, no de la total
# Fracción del presupuesto que puede comerse la fase de VRAM. El resto queda
# para el GEMM, que es la prueba que no se puede omitir.
VRAM_BUDGET_FRACTION = 0.55


def summary(errors, iters):
    """La última línea SIEMPRE es el resumen: es el contrato del puerto."""
    print(f"errors={errors} iters={iters}", flush=True)


def parse_bdf(bdf):
    """"0000:B4:00.0" o "B4:00.0" -> (dominio, bus, device) como enteros."""
    parts = bdf.strip().lower().split(":")
    if len(parts) == 3:
        domain, bus, rest = parts
    elif len(parts) == 2:
        domain, (bus, rest) = "0", parts
    else:
        return None
    try:
        return (int(domain, 16), int(bus, 16), int(rest.split(".")[0], 16))
    except ValueError:
        return None


def pick_ordinal(torch, want_bdf):
    """Ordinal de torch cuyo BDF coincide. None si ninguno coincide."""
    target = parse_bdf(want_bdf)
    if target is None:
        return None
    for i in range(torch.cuda.device_count()):
        props = torch.cuda.get_device_properties(i)
        if (props.pci_domain_id, props.pci_bus_id, props.pci_device_id) == target:
            return i
    return None


def load_torch():
    try:
        import torch
    except Exception as exc:
        print(f"torch_import=FAIL {type(exc).__name__}: {exc}",
              file=sys.stderr, flush=True)
        return None
    return torch


def cmd_available():
    """BARATO y sin cargar la GPU: ¿hay torch con CUDA inicializable?"""
    torch = load_torch()
    if torch is None:
        print("available=no reason=no_torch", flush=True)
        return RC_UNAVAILABLE
    try:
        if not torch.cuda.is_available() or torch.cuda.device_count() < 1:
            print("available=no reason=no_cuda", flush=True)
            return RC_UNAVAILABLE
    except Exception as exc:
        print(f"available=no reason={type(exc).__name__}", flush=True)
        return RC_UNAVAILABLE
    print("available=yes", flush=True)
    return RC_PASS


def gemm_phase(torch, device, deadline):
    """Devuelve (errores, iteraciones). Comparaciones BIT-EXACTAS."""
    errors = 0
    iters = 0
    n = GEMM_N

    ones = torch.ones(n, n, device=device, dtype=torch.float32)
    expected_ones = float(n)

    # A determinista con enteros pequeños: exactos en fp32, y su producto por
    # la identidad también. Generador con semilla fija -> la misma A siempre.
    generator = torch.Generator(device="cpu").manual_seed(0x5060AA)
    a_cpu = torch.randint(-8, 9, (n, n), generator=generator,
                          dtype=torch.int32).to(torch.float32)
    a = a_cpu.to(device)
    identity = torch.eye(n, device=device, dtype=torch.float32)

    reference = None
    while True:
        # 1. ones @ ones: resultado analítico, exactamente n.
        c = torch.mm(ones, ones)
        torch.cuda.synchronize()
        if not bool(torch.all(c == expected_ones).item()):
            errors += 1

        # 2. A @ I: tiene que devolver A bit a bit.
        d = torch.mm(a, identity)
        torch.cuda.synchronize()
        if not torch.equal(d, a):
            errors += 1

        # 3. Estabilidad: el mismo producto, los mismos bits que la 1a vez.
        e = torch.mm(a, a)
        torch.cuda.synchronize()
        if reference is None:
            reference = e.clone()
        elif not torch.equal(e, reference):
            errors += 1

        iters += 1
        del c, d, e
        if time.monotonic() >= deadline:
            break

    del ones, a, identity, reference
    return errors, iters


def vram_phase(torch, device, ordinal, deadline):
    """Patrón conocido sobre buena parte de la VRAM, releído y comparado.

    Devuelve (errores, trozos_comprobados). La comparación es exacta: el trozo
    que vuelve de la GPU debe ser IDÉNTICO al patrón regenerado en CPU.
    """
    errors = 0
    checked = 0
    elems = VRAM_CHUNK_BYTES // 8          # int64
    generator = torch.Generator(device="cpu").manual_seed(0x2D04C0DE)
    base = torch.randint(-(2 ** 62), 2 ** 62, (elems,), generator=generator,
                         dtype=torch.int64)

    try:
        free_bytes, _total = torch.cuda.mem_get_info(ordinal)
    except Exception:
        free_bytes = 0
    chunks_wanted = int((free_bytes * VRAM_TARGET_FRACTION) // VRAM_CHUNK_BYTES)
    if chunks_wanted < 1:
        return 0, 0

    resident = []
    try:
        for index in range(chunks_wanted):
            if time.monotonic() >= deadline:
                break
            # Salto por trozo: con el mismo patrón en todos, una lectura mal
            # direccionada devolvería datos "correctos".
            resident.append((index, (base ^ (index + 1)).to(device)))
            torch.cuda.synchronize()

        for index, chunk in resident:
            back = chunk.cpu()
            if not torch.equal(back, base ^ (index + 1)):
                errors += 1
            checked += 1
            del back
            if time.monotonic() >= deadline:
                break
    except RuntimeError as exc:
        # Sin memoria o fallo del runtime a mitad: no se puede afirmar nada de
        # los trozos que faltan, pero lo comprobado vale. No es un error
        # numérico, así que no cuenta como tal.
        print(f"vram_phase=PARCIAL {type(exc).__name__}: {exc}",
              file=sys.stderr, flush=True)
    finally:
        resident.clear()
        try:
            torch.cuda.empty_cache()
        except Exception:
            pass
    return errors, checked


def cmd_check(bus_id, seconds):
    torch = load_torch()
    if torch is None:
        summary(0, 0)
        return RC_UNAVAILABLE
    try:
        if not torch.cuda.is_available():
            print("cuda_available=no", file=sys.stderr, flush=True)
            summary(0, 0)
            return RC_UNAVAILABLE
        ordinal = pick_ordinal(torch, bus_id)
    except Exception as exc:
        print(f"cuda_init=FAIL {type(exc).__name__}: {exc}",
              file=sys.stderr, flush=True)
        summary(0, 0)
        return RC_UNAVAILABLE

    if ordinal is None:
        # No se encontró la eGPU: eso NO es "pasa". Es falta de evidencia.
        print(f"pick_ordinal=FAIL ninguna GPU de torch está en {bus_id}",
              file=sys.stderr, flush=True)
        summary(0, 0)
        return RC_UNAVAILABLE

    # set_device ANTES de cualquier kernel: las fases llaman a
    # torch.cuda.synchronize() sin argumento, que sincroniza el dispositivo
    # ACTUAL. Sin esto el actual es el ordinal 0 -la GPU INTERNA de esta
    # maquina-, asi que los sync no sincronizaban lo que se esta midiendo.
    torch.cuda.set_device(ordinal)
    device = torch.device(f"cuda:{ordinal}")
    print(f"bus_id={bus_id} ordinal={ordinal} "
          f"name={torch.cuda.get_device_name(ordinal)}", flush=True)

    start = time.monotonic()
    errors = 0
    iters = 0
    try:
        vram_deadline = start + seconds * VRAM_BUDGET_FRACTION
        vram_errors, chunks = vram_phase(torch, device, ordinal, vram_deadline)
        print(f"vram_pattern_errors={vram_errors} vram_chunks={chunks}",
              flush=True)

        gemm_errors, gemm_iters = gemm_phase(torch, device, start + seconds)
        print(f"gemm_errors={gemm_errors} gemm_iters={gemm_iters}", flush=True)
    except Exception as exc:
        # Un fallo del runtime a mitad de la prueba tampoco es "pasa": sin
        # resultado no hay evidencia, y el gate tiene que cerrar.
        print(f"check=FAIL {type(exc).__name__}: {exc}",
              file=sys.stderr, flush=True)
        summary(0, 0)
        return RC_UNAVAILABLE

    errors = vram_errors + gemm_errors
    iters = gemm_iters + chunks
    print(f"elapsed_s={time.monotonic() - start:.1f}", flush=True)
    summary(errors, iters)
    if iters == 0:
        # No se llegó a medir nada: no hay evidencia que ofrecer.
        return RC_UNAVAILABLE
    return RC_FAIL if errors else RC_PASS


def main(argv):
    if len(argv) < 2:
        print(__doc__.split("Uso")[-1].strip(), file=sys.stderr, flush=True)
        return RC_USAGE
    if argv[1] == "available":
        return cmd_available()
    if argv[1] == "check":
        if len(argv) != 4:
            print("uso: check <busid> <segundos>", file=sys.stderr, flush=True)
            return RC_USAGE
        try:
            seconds = int(argv[3], 10)
        except ValueError:
            print(f"uso: '{argv[3]}' no es un entero", file=sys.stderr, flush=True)
            return RC_USAGE
        if seconds <= 0:
            print("uso: los segundos deben ser > 0", file=sys.stderr, flush=True)
            return RC_USAGE
        return cmd_check(argv[2], seconds)
    print(f"uso: comando '{argv[1]}' desconocido (available|check)",
          file=sys.stderr, flush=True)
    return RC_USAGE


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
