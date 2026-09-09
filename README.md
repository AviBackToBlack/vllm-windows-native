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

There is no one-click installer yet. The current supported development workflow stays explicit while bootstrap/install productization is being completed.

### 1. Run the prerequisite doctor

Provide the build Python and external cuSOLVER root, then run the read-only preflight before spending hours compiling CUDA:

```powershell
.\doctor.ps1 `
  -PythonExe 'C:\path\to\build-venv\Scripts\python.exe' `
  -CuSolverRoot 'C:\path\to\libcusolver-windows-x86_64-12.0.4.66-archive'
```

`doctor.ps1` reads the runtime manifest as its source of truth and checks:

- native Windows x64, Git and `tar.exe`;
- accepted patch SHA/size;
- exact Python, Torch, torchvision, torchaudio and Triton-Windows versions;
- Torch CUDA version and the currently accepted SM120 GPU target;
- exact CUDA Toolkit, MSVC, CMake and Ninja versions;
- the required external cuSOLVER headers and import library.

For automation, use `-Json`. Build-blocking failures return a non-zero exit code.

### 2. Validate source reconstruction and toolchain

```powershell
.\build.ps1 `
  -PythonExe 'C:\path\to\build-venv\Scripts\python.exe' `
  -CuSolverRoot 'C:\path\to\libcusolver-windows-x86_64-12.0.4.66-archive' `
  -ValidateOnly
```

The build driver reconstructs the accepted Windows source tree from official `vllm-project/vllm` Git objects plus this repository's versioned patchset, then rejects source or toolchain drift before compilation.

### 3. Build the wheel

Run the same command without `-ValidateOnly`. Long CUDA builds should be run detached with dedicated log and exit files.

The resulting wheel and `build-result.json` are written under the selected artifact directory (by default `artifacts/<milestone>`).

## Not automated yet

The next release-engineering work will productize acquisition/bootstrap for the pinned Python environment, CUDA/MSVC prerequisites, CMake/Ninja/Torch/Triton-Windows, and especially the external cuSOLVER package. Wheel installation/lifecycle tooling follows after that.

`install.ps1` therefore remains intentionally unimplemented instead of pretending an unverified installer is supported.
