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
