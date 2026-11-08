# Diagnostic / validation toolkit

These scripts are NOT installed by `apply.sh`. They are templates for manual diagnostic and validation work, kept in the repo so they survive context resets and can be reused for future testing (PyTorch validation, vLLM bring-up, kernel updates, etc).

## `cuda-driver-api-smoke-test.py`

A pure-`ctypes` CUDA Driver API smoke test. Runs the full driver-API roundtrip:

```
cuInit -> cuDeviceGet -> cuCtxCreate -> cuMemAlloc(4 KiB) ->
cuMemsetD8(0x5A) -> cuCtxSynchronize -> cuMemcpyDtoH -> verify ->
cuMemFree -> cuCtxDestroy
```

Exits 0 with `cuda_smoke=pass` on success, non-zero with the failed call name on any error.

No dependencies beyond `libcuda.so.1` (which ships with `xorg-x11-drv-nvidia-cuda-libs`). No CUDA toolkit, no PyTorch, no nvcc required.

Targets the eGPU, selected by PCI bus-id.
With no argument it picks the first NVIDIA GPU whose PCI device is marked
`removable` in sysfs, which is the topological confirmation CLAUDE.md
mandates;
pass a bus-id to override.
It used to call `cuDeviceGet(..., 0)`, and ordinal 0 on this machine is the
*internal* GPU, so it reported `pass` without ever touching the eGPU.

Run directly:

```bash
python3 tools/cuda-driver-api-smoke-test.py            # the eGPU
python3 tools/cuda-driver-api-smoke-test.py B4:00.0    # a specific bus-id
```

WARNING: do NOT run this directly without first verifying `nvidia_uvm` is loaded (`lsmod | grep nvidia_uvm`). A failed `cuInit` on this stack — caused by `nvidia_uvm` not being loadable — leaves the GPU in a partially-initialised state that has caused delayed kernel panics. The compute-load loader pre-stages `nvidia_uvm` at boot, but if you have manually unloaded it or are diagnosing, the precondition matters.

## `tty-cuda-test.sh`

Runs the smoke test in a controlled multi-user.target context with fsync'd progress markers. Use for any freeze-risk diagnostic where you want forensic data even if the kernel panics.

What it does:

1. Pre-flight: refuses to start if `nvidia_uvm` is not loaded or `nvidia-persistenced.service` is not active.
2. Captures pre-test state.
3. Runs `cuda-driver-api-smoke-test.py` with a 30 s timeout.
4. Captures post-test state, including a `nvidia-smi --query-gpu=memory.used` to detect leaks.
5. Idles 30 s to catch delayed panics while still in multi-user.target.
6. EXIT trap restores `graphical.target` no matter how the script ended.

Output: `/root/aorus-cuda-tty-test/` — overwritten each run.

To launch (drops you to a TTY for ~60-90 seconds, then GNOME returns):

```bash
nohup setsid /root/aorus-5090-egpu/tools/tty-cuda-test.sh </dev/null >/dev/null 2>&1 &
disown
sleep 1
sudo systemctl isolate multi-user.target
```

The `nohup setsid ... &` + `disown` detaches the script from the calling shell so it survives the session disconnection caused by `isolate`. The script's EXIT trap returns the system to graphical when done.

If anything hangs, switch to `Ctrl+Alt+F2`, login, and run `sudo systemctl isolate graphical.target` to recover manually.

## `pytorch-cuda-smoke-test.py`

PyTorch CUDA smoke test. Validates the path that vLLM actually uses:

```
import torch -> torch.cuda.is_available -> device_count / get_device_name ->
torch.ones() on cuda -> torch.mm() (cuBLAS GEMM) -> torch.cuda.synchronize ->
deterministic correctness check (every element of result == 1024.0)
```

Reports `torch_version`, `torch_cuda_version`, `compute_capability`, and post-test memory stats. Exits 0 with `pytorch_smoke=pass` on success.

Targets the eGPU by PCI bus-id, like the Driver API test.
It enumerates `torch.cuda.get_device_properties(i)` and matches
`pci_domain_id`/`pci_bus_id`/`pci_device_id` against the target BDF, printing
every GPU it saw and marking the one it chose, so a `pass` is auditable.

Do **not** try to pin the GPU with `CUDA_VISIBLE_DEVICES=<bus-id>`.
That variable accepts only indices and `GPU-<uuid>`, never bus-ids:
CUDA parses the string as an integer, `strtol` stops at the first `:`, and
`"0000:B4:00.0"` becomes **index 0**.
Measured here on 2026-11-02, that produced `device_count=1` and
`device_name=NVIDIA RTX PRO 4000` — the pin appeared to work and selected the
*internal* GPU, with the test still reporting `pass`.

Requires `torch` in a venv.
Setup once, in a venv of its own — do not install ~3 GB of PyTorch into a
project venv:

```bash
uv venv ~/.venvs/egpu-torch-test
VIRTUAL_ENV=~/.venvs/egpu-torch-test uv pip install torch
```

Without `uv`, `python3 -m venv` plus `pip install torch` does the same job more
slowly.
Either way it pulls ~3 GB of PyTorch and CUDA runtime wheels.

Run directly (after venv setup):

```bash
~/.venvs/egpu-torch-test/bin/python3 tools/pytorch-cuda-smoke-test.py             # the eGPU
~/.venvs/egpu-torch-test/bin/python3 tools/pytorch-cuda-smoke-test.py 0000:B4:00.0
```

Verified on this host with torch 2.15.0+cu132: picks ordinal 1
(`0000:b4:00.0`, the GeForce RTX 5060 Ti), runs the GEMM and passes.
A bus-id that matches nothing exits 1 instead of falling back to another GPU.

WARNING: same precondition as the CUDA Driver API test - `nvidia_uvm` must be loaded. The TTY runner (`tty-pytorch-test.sh`) checks this before invoking the test.

## `tty-pytorch-test.sh`

TTY-with-fsync runner for the PyTorch smoke. Same methodology as `tty-cuda-test.sh`:

1. Pre-flight: `nvidia_uvm` loaded, `nvidia-persistenced.service` active, venv exists, `torch` importable.
2. Capture pre-test state (status, modules, `nvidia-smi`).
3. Run `pytorch-cuda-smoke-test.py` from the venv with a 60 s timeout.
4. Capture post-test state.
5. Idle 30 s for delayed-panic detection.
6. EXIT trap restores `graphical.target`.

Output: `/root/aorus-pytorch-tty-test/`.

To launch:

```bash
nohup setsid /root/aorus-5090-egpu/tools/tty-pytorch-test.sh </dev/null >/dev/null 2>&1 &
disown
sleep 1
sudo systemctl isolate multi-user.target
```

Configurable via env vars:

- `VENV_PATH` (default `/root/torch-test`)
- `TEST_SCRIPT` (default `/root/aorus-5090-egpu/tools/pytorch-cuda-smoke-test.py`)
- `OUT` (default `/root/aorus-pytorch-tty-test`)

## Compiling CUDA on this machine: always pass `-arch`

Measured 2026-11-02, and it bites silently:
this host has CUDA toolkit **13.4** and driver **595.99.02**, and the driver's
PTX JIT compiler rejects what that `nvcc` emits.

```
CUDA error the provided PTX was compiled with an unsupported toolchain.
```

Any binary that ships only PTX and relies on the driver to JIT it at load time
**fails on this machine**.
Compile for the real architecture so a cubin is embedded and no JIT is needed.
Both GPUs here are compute capability **12.0**:

```bash
nvcc -O2 -arch=sm_120 -o tools/egpu-bandwidth tools/egpu-bandwidth.cu
```

`tools/egpu-bandwidth.cu` escapes the problem by accident — it contains no
`__global__` kernels, only `cudaMemcpy` calls, so there is no PTX to JIT.
The next CUDA tool added here will not be so lucky.
Check with `nvidia-smi --query-gpu=compute_cap --format=csv` before assuming
`sm_120`.

## `egpu-oc-edge`

Finds the highest **positive** clock offset the eGPU sustains without returning
a single wrong bit, for the core and the memory separately.
It answers the question `aorus-egpu-oc` cannot:
that command knows how to apply an offset and how to refuse one without
evidence, but its gate is a yes/no question about a value somebody already
picked.
This tool searches for the value.

Why bit-exactness is the criterion and not "it didn't crash":
this card has **no ECC** (`ecc.mode.current=[N/A]`).
An offset that is too aggressive does not fall over — it **computes wrong**.
The CUDA kernel finishes, nobody sees an error, and the result carries
different bits than it should.
See the ECC risk section of [`docs/overclock.md`](../docs/overclock.md).

Method (one variable per test, cheapest experiment first, n>=3 to resolve):

1. Control at offset 0. Without a passing control nothing downstream measures
   the offset, so the run aborts.
2. Coarse ladder until the first failure — core in 75 MHz rungs, memory in
   500 MHz rungs — then a fine bisection (15 / 100 MHz) between the last good
   rung and the first bad one.
3. Confirmation of the candidate with 3 passes of 90 s.
   One failure means the edge is lower, and it steps down one notch.
4. The combination of both edges is a **third** variable and is measured last.

It reuses, deliberately, instead of reimplementing:

- `src/adapters/gpu/nvml-offsets.py` to write the offset (R4 gate and
  write-then-reread confirmation live inside it).
- `src/adapters/verify/gemm-integrity.py` for the bit-exact phases.
  They have to be **the same** ones the package's gate uses; an edge measured
  with a different verifier would not authorise anything.

Parent/child by design: the parent orchestrates and is the only process that
writes to the hardware; every measurement runs in a child that imports torch
and writes nothing, because an aggressive offset **poisons the CUDA context**
and in a single process the next step would measure a broken one.

Safety invariants: R4 gate inside the NVML helper; link gate by negotiated
capability revalidated **before every step** (H23 drops the tunnel at idle, and
writing right after a drop is what froze the host); no `--force`; offsets back
to 0 on normal exit, exception, Ctrl-C or SIGTERM, **confirmed by rereading**;
offsets reread after each step, because a GPU reset clears them and a step
measured without the offset applied says nothing about the offset; if the child
does not come back, abort **without retrying**.

```bash
tools/egpu-oc-edge --dry-run --attended          # the plan, touching nothing
sudo ~/.venvs/egpu-torch-test/bin/python -I \
  tools/egpu-oc-edge --attended                  # the full measurement
```

Needs `torch` + CUDA and `pynvml` in the same interpreter, and root (NVML
offset writes do).
Pass `--attended` when a person is watching:
on a modern desktop the terminal emulator is itself a systemd unit, so an
interactive session inherits `INVOCATION_ID` and the unattended heuristic
would otherwise refuse to run.
The package's own gate has no such escape hatch, and must not have one.

Run it wrapped, like any freeze-risk test:

```bash
sudo src/bin/aorus-egpu-probe run -- \
  ~/.venvs/egpu-torch-test/bin/python -I tools/egpu-oc-edge --attended
```

Evidence lands in `/var/log/aorus-egpu/oc-edge/<timestamp>/`:
`10-breadcrumbs.log` (fsync'd, last line is the suspect step),
`20-steps.jsonl` (one JSON per step with clock/power/temperature samples) and
`90-summary.json`.

Read the result with its coverage, never as a licence:
"zero errors in N iterations over T seconds, n=3" is what it measures.
There is a documented Blackwell/GDDR7 case where corruption first appeared at
iteration **274,400** while a VRAM memtest passed 1,252 clean passes, so no
window of minutes can rule out that tail.
Hypothesis and resolution criteria:
[H25](../docs/research/reliability-hypothesis-ledger.md#h25).

## Future tools

This directory is the right place for:

- A vLLM warmup test (next step after PyTorch is validated).
- An `NVreg_DynamicPowerManagement=0` experiment (see `docs/future-investigations.md`).
- A kernel/driver-update validation runner.

Each tool should follow the same pattern as `tty-cuda-test.sh` / `tty-pytorch-test.sh`:
- Refuse to start if preconditions are not met.
- fsync progress markers.
- Capture pre- and post-test state.
- EXIT trap to restore `graphical.target` if launched from there.
