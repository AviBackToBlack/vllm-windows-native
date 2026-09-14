# vLLM Windows Native

Native Windows distribution and patchset for running vLLM on Windows 11 x64 without WSL or Docker.

> Status: first native-Windows single-GPU wheel candidate accepted on RTX 5090 / SM120; no supported public release yet.

## Project intent

This repository treats [`vllm-project/vllm`](https://github.com/vllm-project/vllm) as the authoritative upstream. Existing community Windows ports are research and reference sources, not runtime or release dependencies.

The project aims to provide:

- native Windows 11 x64 execution;
- reproducible, versioned Windows patchsets against official vLLM releases;
- project-owned Windows wheels and release artifacts;
- strongly contained runtime state under a configurable install root;
- explicit provenance, hashes, and update state;
- safe install, start, doctor, update, and uninstall lifecycle scripts.

## Current target

Initial development target:

- Windows 11 x64
- NVIDIA RTX 5090 / Blackwell SM120
- single GPU first
- default install root: `D:\AI\vLLM`

See [`docs/decisions/0001-upstream-and-patch-ownership.md`](docs/decisions/0001-upstream-and-patch-ownership.md) for upstream ownership and [`docs/lifecycle-safety-contract.md`](docs/lifecycle-safety-contract.md) for the normative install/update/uninstall safety boundary.

## First accepted native-Windows candidate

The `v0.27.1` Windows patchset has completed pristine wheel, offline-generation, and OpenAI-compatible HTTP acceptance on an RTX 5090 / Blackwell SM120 system.

- validation record: [`docs/validation/v0.27.1-rtx5090-sm120.md`](docs/validation/v0.27.1-rtx5090-sm120.md)
- machine-readable manifest: [`manifests/runtime/v0.27.1-rtx5090-sm120.json`](manifests/runtime/v0.27.1-rtx5090-sm120.json)
- reproducible patch: [`patches/windows/v0.27.1/0001-native-windows-cuda-sm120.patch`](patches/windows/v0.27.1/0001-native-windows-cuda-sm120.patch)

The accepted scope is single-GPU native Windows serving. Multi-GPU/NCCL work is explicitly not part of this milestone.
## Support matrix

The first accepted milestone is intentionally narrow: it is a proven baseline, not a claim that every upstream vLLM capability is already supported on Windows.

| Area | Accepted baseline |
| --- | --- |
| OS | Windows 11 x64, native (no WSL) |
| GPU | NVIDIA RTX 5090 / Blackwell SM120 |
| GPU count | Single GPU |
| Python | 3.13.15 |
| CUDA Toolkit | 13.0.88 |
| MSVC | 19.44.35228 |
| Torch | 2.13.0+cu130 |
| Triton-Windows | 3.7.1.post27 |
| FlashAttention | FA2 accepted on SM120; FA3 intentionally absent |
| DeepGEMM | Windows plumbing accepted; upstream kernels do not provide an SM120 GEMM backend |
| Multi-GPU / NCCL / TP / PP | Not accepted yet |

The exact machine-readable pins live in [`manifests/runtime/v0.27.1-rtx5090-sm120.json`](manifests/runtime/v0.27.1-rtx5090-sm120.json).

## Build from source: current workflow

There is no one-click installer yet. The supported development workflow is intentionally explicit while bootstrap/install productization is completed.

### 1. Bootstrap the pinned external cuSOLVER package

```powershell
.\bootstrap.ps1
```

`bootstrap.ps1` acquires the accepted Windows cuSOLVER `12.0.4.66` archive directly from NVIDIA's CUDA 13.0.1 redistribution service, verifies its pinned size and SHA-256, caches the archive, and materializes it under `tools/nvidia/`. Existing valid cache/install content is reused. Use `-Refresh` to re-download and rematerialize the archive, or `-Force` to rematerialize from the verified cache and replace an incomplete managed extraction.

The provenance pin is machine-readable in [`manifests/bootstrap/cusolver-12.0.4.66-windows-x86_64.json`](manifests/bootstrap/cusolver-12.0.4.66-windows-x86_64.json). For automation, `bootstrap.ps1 -Json` emits the resolved root and archive metadata.

### 2. Bootstrap the pinned portable CPython base

```powershell
.\bootstrap-python.ps1
```

`bootstrap-python.ps1` acquires the accepted `python-build-standalone` CPython `3.13.15` Windows x64 archive, verifies its pinned size and SHA-256, preflights the tar layout, and atomically materializes the clean base interpreter under `python/managed/cpython-3.13.15-windows-x86_64-none/`. Downloads, staging and forensic receipt state stay under the installation root and are protected by the lifecycle operation lock.
With `-InstallationRoot` omitted, the canonical `D:\AI\vLLM` install root is used; CI and development workflows may override it explicitly. If the machine has no `D:` volume, the bootstrap fails with an explicit instruction to pass `-InstallationRoot` rather than silently choosing another location.

The exact source release, commit, asset URL, size, digest and archive shape are pinned in [`manifests/bootstrap/cpython-3.13.15-windows-x86_64.json`](manifests/bootstrap/cpython-3.13.15-windows-x86_64.json). A verified local archive can be supplied with `-ArchivePath`; `-Force` is required to replace an existing managed Python target. `-Json` emits the resolved interpreter and provenance receipt.

The portable base interpreter is intentionally separate from its environment tooling. The next layer uses the pinned uv binary below to create the build/runtime virtual environment; Torch, Triton-Windows and the project vLLM wheel remain subsequent release-engineering steps.

### 3. Bootstrap the pinned portable uv tool

```powershell
.\bootstrap-uv.ps1
```

`bootstrap-uv.ps1` acquires uv `0.12.13` for Windows x64, verifies the pinned size and SHA-256, requires the exact three-file archive layout (`uv.exe`, `uvw.exe`, `uvx.exe`), and atomically materializes it under `tools/uv/0.12.13/`. It uses the lifecycle operation lock and transactional receipt/rollback rules used by the Python bootstrap.

The exact release commit, asset URL, size, digest and acceptance provenance are pinned in [`manifests/bootstrap/uv-0.12.13-windows-x86_64.json`](manifests/bootstrap/uv-0.12.13-windows-x86_64.json). A verified local archive may be supplied with `-ArchivePath`; `-Force` is required to replace an existing managed uv target. This step does not create a virtual environment or mutate the user's PATH.

### 4. Run the prerequisite doctor

Provide the exact build Python, then run the read-only preflight before spending hours compiling CUDA. The doctor automatically discovers the managed cuSOLVER root created by `bootstrap.ps1`; `-CuSolverRoot` remains available for custom locations.

```powershell
.\doctor.ps1 `
  -PythonExe 'C:\path\to\build-venv\Scripts\python.exe'
```

`doctor.ps1` reads the runtime manifest as its source of truth and checks:

- native Windows x64, Git and `tar.exe`;
- accepted patch SHA/size;
- exact Python, Torch, torchvision, torchaudio and Triton-Windows versions;
- Torch CUDA version and the currently accepted SM120 GPU target;
- exact CUDA Toolkit, MSVC, CMake and Ninja versions;
- the required external cuSOLVER headers and import library.

For automation, use `-Json`. Build-blocking failures return a non-zero exit code.

### 5. Validate source reconstruction and toolchain

```powershell
.\build.ps1 `
  -PythonExe 'C:\path\to\build-venv\Scripts\python.exe' `
  -ValidateOnly
```

The build driver reconstructs the accepted Windows source tree from official `vllm-project/vllm` Git objects plus this repository's versioned patchset, then rejects source or toolchain drift before compilation. Git long-path handling is enabled per invocation rather than by changing the user's global Git configuration.

### 6. Build the wheel

Run the same command without `-ValidateOnly`. Long CUDA builds should be run detached with dedicated log and exit files.

The resulting wheel and `build-result.json` are written under the selected artifact directory (by default `artifacts/<milestone>`).

## Run the accepted Windows runtime

`start.ps1` launches vLLM in the foreground and applies process-local containment before the server starts.

```powershell
.\start.ps1 -Model 'Qwen/Qwen3.5-0.8B' -VllmArgs @('--max-model-len', '2048', '--gpu-memory-utilization', '0.6')
```

By default it expects `runtime\venv\Scripts\vllm.exe` below the install root and keeps Hugging Face, vLLM, Torch/Inductor, Triton, DeepGEMM JIT and temporary state below that root. `-VllmExe` and `-ContainmentRoot` are explicit development overrides. `-ListenHost` and `-ListenPort` own the server endpoint; `VllmArgs` may not override `--host` or `--port`. `-ValidateOnly` materializes the contained directory tree and checks setup without starting vLLM, restores the caller process environment before returning, and never prints raw passthrough values. Background process ownership/service management is intentionally deferred to later lifecycle work.

If Windows legacy `MAX_PATH` behavior is active (`LongPathsEnabled=0`), keep the install/containment root short. PyTorch AOT cache filenames can otherwise cross the 260-character boundary. The canonical `D:\AI\vLLM` root is intentionally short; the validation record documents the reproduced boundary.

## Not automated yet

The lifecycle safety boundary is now specified in [`docs/lifecycle-safety-contract.md`](docs/lifecycle-safety-contract.md). The pinned portable CPython base and uv tool are now productized; the next release-engineering work is the pinned build/runtime virtual environment and remaining CUDA/MSVC/CMake/Ninja/Torch/Triton-Windows dependency layer. Wheel installation/lifecycle implementation follows incrementally.

`install.ps1` therefore remains intentionally unimplemented instead of pretending an unverified installer is supported.
