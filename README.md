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

See [`docs/decisions/0001-upstream-and-patch-ownership.md`](docs/decisions/0001-upstream-and-patch-ownership.md) once the bootstrap commit lands.

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

### 2. Run the prerequisite doctor

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

### 3. Validate source reconstruction and toolchain

```powershell
.\build.ps1 `
  -PythonExe 'C:\path\to\build-venv\Scripts\python.exe' `
  -ValidateOnly
```

The build driver reconstructs the accepted Windows source tree from official `vllm-project/vllm` Git objects plus this repository's versioned patchset, then rejects source or toolchain drift before compilation. Git long-path handling is enabled per invocation rather than by changing the user's global Git configuration.

### 4. Build the wheel

Run the same command without `-ValidateOnly`. Long CUDA builds should be run detached with dedicated log and exit files.

The resulting wheel and `build-result.json` are written under the selected artifact directory (by default `artifacts/<milestone>`).

## Run the accepted Windows runtime

`start.ps1` launches vLLM in the foreground and applies process-local containment before the server starts.

```powershell
.\start.ps1 -Model 'Qwen/Qwen3.5-0.8B' -VllmArgs @('--max-model-len', '2048', '--gpu-memory-utilization', '0.6')
```

By default it expects `runtime\venv\Scripts\vllm.exe` below the install root and keeps Hugging Face, vLLM, Torch/Inductor, Triton, DeepGEMM JIT and temporary state below that root. `-VllmExe` and `-ContainmentRoot` are explicit development overrides; `-ValidateOnly` checks setup without starting vLLM. Background process ownership/service management is intentionally deferred to later lifecycle work.

If Windows legacy `MAX_PATH` behavior is active (`LongPathsEnabled=0`), keep the install/containment root short. PyTorch AOT cache filenames can otherwise cross the 260-character boundary. The canonical `D:\AI\vLLM` root is intentionally short; the validation record documents the reproduced boundary.

## Not automated yet

The next release-engineering work will productize the pinned Python environment and the remaining CUDA/MSVC/CMake/Ninja/Torch/Triton-Windows prerequisites. Wheel installation/lifecycle tooling follows after that.

`install.ps1` therefore remains intentionally unimplemented instead of pretending an unverified installer is supported.
