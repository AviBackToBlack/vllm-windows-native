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

## Install the accepted managed runtime

`install.ps1` is the supported top-level runtime installer for the accepted Windows x64 milestone. The project wheel is still caller-supplied until release publication is implemented:

```powershell
.\install.ps1 `
  -WheelPath 'C:\path\to\vllm-0.27.2.dev0+g6e448d0ea.d20260909-cp313-cp313-win_amd64.whl'
```

With `-InstallationRoot` omitted, the installer uses `D:\AI\vLLM`; `-ModelsRoot` defaults to `<InstallRoot>\models`. Before any runtime mutation, the installer verifies the canonical release manifest, every owned distribution-file size/SHA-256, and the exact project-wheel identity. It materializes a self-contained copy of the runtime distribution under the installation root, then resumes the proven CPython -> uv -> unseeded venv -> 28-package predecessor -> 160-distribution final-runtime chain from the highest independently verified receipt. A completed installation is committed atomically as `<InstallRoot>\state\install-state.json`, binding release ownership, upstream/patchset identity, wheel identity, Python/uv provenance, runtime receipts, `InstallRoot`, and `ModelsRoot`.

Interrupted installation is resumable without treating directory presence as proof of success. Existing distribution drift, malformed/contradictory install state, invalid downstream provenance, an unrecognized runtime state, or a wheel mismatch fails closed. Successful reruns are idempotent and validate the final runtime without rebuilding earlier layers. `-Offline` requires pinned Python/uv archives when those layers are not already present and requires all Python dependency artifacts to exist in the contained uv cache. The exact owned runtime payload is recorded in [`manifests/release/v0.27.1-windows-x86_64.json`](manifests/release/v0.27.1-windows-x86_64.json).

## Build from source / inspect individual bootstrap layers

The lower-level commands remain supported for development, forensic validation, and release engineering. They expose each independently receipt-backed layer explicitly.

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

The portable base interpreter is intentionally separate from its environment tooling. The next layers use the pinned uv binary below to create the build/runtime virtual environment, materialize the accepted CUDA dependency graph, and finally assemble the verified managed vLLM runtime.

### 3. Bootstrap the pinned portable uv tool

```powershell
.\bootstrap-uv.ps1
```

`bootstrap-uv.ps1` acquires uv `0.12.13` for Windows x64, verifies the pinned size and SHA-256, requires the exact three-file archive layout (`uv.exe`, `uvw.exe`, `uvx.exe`), and atomically materializes it under `tools/uv/0.12.13/`. It uses the lifecycle operation lock and transactional receipt/rollback rules used by the Python bootstrap.

The exact release commit, asset URL, size, digest and acceptance provenance are pinned in [`manifests/bootstrap/uv-0.12.13-windows-x86_64.json`](manifests/bootstrap/uv-0.12.13-windows-x86_64.json). A verified local archive may be supplied with `-ArchivePath`; `-Force` is required to replace an existing managed uv target. This step does not create a virtual environment or mutate the user's PATH.

### 4. Create the contained runtime virtual environment

```powershell
.\bootstrap-venv.ps1
```

`bootstrap-venv.ps1` requires the pinned CPython and uv layers from steps 2 and 3, validates both managed identities, and creates an unseeded `runtime\venv` directly at its final path using uv `0.12.13` and CPython `3.13.15`. The command runs offline, disables project/config discovery and Python downloads, contains the uv cache below the installation root, neutralizes inherited `UV_*`/Python/virtual-environment overrides for the child operation, and restores the caller process environment exactly before returning.

The venv is intentionally created without `pip`, setuptools, wheel, Torch or Triton. `-Force` performs transactional replacement with rollback of the previous `runtime\venv` if creation, final validation, or forensic receipt commit fails. The machine-readable contract is [`manifests/bootstrap/venv-v0.27.1-windows-x86_64.json`](manifests/bootstrap/venv-v0.27.1-windows-x86_64.json).

### 5. Inspect the accepted dependency lock

The accepted Windows/cp313 build/runtime dependency graph is pinned in [`requirements/runtime-v0.27.1.lock.txt`](requirements/runtime-v0.27.1.lock.txt), generated from [`requirements/runtime-v0.27.1.in`](requirements/runtime-v0.27.1.in) by the productized uv `0.12.13`. The lock contains exactly 28 package versions and SHA-256 hashes. Acceptance-time regeneration with the pinned CPython `3.13.15` and uv inputs reproduced the committed lock byte-for-byte; the committed lock and its digest are canonical because the public package index is not an immutable snapshot.

The CUDA `13.0` PyTorch trio is pinned to direct official wheel URLs so the resolver cannot drift to non-CUDA builds. The exact accepted package set, lock/input digests, generator identity, and accepted Torch/Triton binary provenance are recorded in [`manifests/runtime/dependencies-v0.27.1-windows-x86_64.json`](manifests/runtime/dependencies-v0.27.1-windows-x86_64.json). The dependency validator requires all 28 packages at their exact versions and rejects unexpected third-party distributions; the separately governed project wheel (`vllm`) is the sole allowed extra when validating a complete runtime. The accepted `ninja` distribution version is `1.13.2`; its Windows wheel contains a `ninja.exe` that reports the build string `1.13.2.git.kitware.jobserver-pipe-1`.

### 6. Materialize the accepted dependency graph

```powershell
.\bootstrap-dependencies.ps1
```

`bootstrap-dependencies.ps1` requires the receipt-backed unseeded `runtime\venv`, the pinned managed CPython and uv layers, and the exact committed dependency-lock digest. It never syncs in place and no longer removes the live venv before the replacement is ready: a relocatable replacement is fully materialized and validated in managed staging first, then a short activation swap moves the live venv to a deterministic backup and promotes staging. `uv pip sync` requires hashes, wheels only, `link-mode=copy`, contained uv cache/config state, and disables Python downloads. The replacement must match the accepted dependency set exactly and pass `uv pip check` before activation and receipt commit.

A receipt-backed dependency-ready environment is idempotent without `-Force`; unexpected distributions or receipt drift fail closed. `-Force` performs a full transactional replacement rather than mutating the live environment. A durable transaction receipt and generation ID make interrupted materialization recoverable on the next invocation: an uncommitted generation rolls back to the deterministic backup, while a generation whose dependency receipt was already committed only cleans leftover staging/backup state. `-Offline` is available when every required artifact is already present in the contained uv cache.

### 7. Materialize the managed vLLM runtime

```powershell
.\bootstrap-vllm.ps1 `
  -WheelPath 'C:\path\to\vllm-0.27.2.dev0+g6e448d0ea.d20260909-cp313-cp313-win_amd64.whl'
```

`bootstrap-vllm.ps1` requires the exact receipt-backed 28-package predecessor state from step 6 and a caller-supplied project wheel. Before mutation it verifies the committed 159-package runtime lock and accepted package map plus the wheel filename, size, SHA-256, tags, version, and nine expected native extensions. The canonical accepted wheel SHA-256 is `66201EF4566E7B312D3663786EB03FBA5F67E37981118322C581EDDAF98958B6`.

The final runtime is assembled in relocatable staging: uv synchronizes the 159 hash-locked dependency distributions, the verified project wheel is installed with `--no-deps --no-index`, and the staged environment must contain exactly 160 distributions and pass `uv pip check` before a short activation swap. A durable transaction receipt makes interrupted materialization recoverable; successful reruns are idempotent and do not rewrite the final receipt. `-Force` performs full replacement, while `-Offline` requires every dependency artifact to already exist in the contained uv cache.

The complete contract is [`manifests/runtime/vllm-runtime-v0.27.1-windows-x86_64.json`](manifests/runtime/vllm-runtime-v0.27.1-windows-x86_64.json); the exact 159-package map is [`manifests/runtime/vllm-runtime-packages-v0.27.1-windows-x86_64.json`](manifests/runtime/vllm-runtime-packages-v0.27.1-windows-x86_64.json).

### 8. Run the prerequisite doctor

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

### 9. Validate source reconstruction and toolchain

```powershell
.\build.ps1 `
  -PythonExe 'C:\path\to\build-venv\Scripts\python.exe' `
  -ValidateOnly
```

The build driver reconstructs the accepted Windows source tree from official `vllm-project/vllm` Git objects plus this repository's versioned patchset, then rejects source or toolchain drift before compilation. Git long-path handling is enabled per invocation rather than by changing the user's global Git configuration.

### 10. Build the wheel

Run the same command without `-ValidateOnly`. Long CUDA builds should be run detached with dedicated log and exit files.

The resulting wheel and `build-result.json` are written under the selected artifact directory (by default `artifacts/<milestone>`).

## Prepare deterministic offline release assets

`release.ps1` is the SM-19A offline preparation/verification surface. It performs no GitHub mutation, tag creation, signing, upload, or network acquisition. Release bytes are sourced from an explicit Git commit rather than the mutable worktree.

Validate the current repository release contract without requiring the accepted wheel:

```powershell
.\release.ps1 -Mode ValidateRepository
```

Prepare the four deterministic offline assets from the accepted caller-supplied wheel:

```powershell
.\release.ps1 -Mode Prepare `
  -WheelPath 'C:\path\to\vllm-0.27.2.dev0+g6e448d0ea.d20260909-cp313-cp313-win_amd64.whl' `
  -ArtifactsDirectory '.\artifacts\release'
```

`Prepare` requires a clean worktree and the selected project commit to be the checked-out `HEAD`. The output directory must be empty and resolve without filesystem aliases/reparse points. Concurrent preparation into the same output directory is serialized by an exclusive persistent sibling `.\.<output-leaf>.vllm-release-prepare.lock` coordination file, which is outside the four release assets. Preparation builds and fully verifies the four assets in a unique sibling staging directory, then publishes them with a same-parent atomic directory rename; if the final path appears or changes before publication, preparation fails without cleaning or overwriting that path. The generated set is exactly the wheel copied byte-for-byte, `vllm-windows-native-<release>.zip`, `release-index.json`, and `SHA256SUMS`. The ZIP uses the canonical STORE profile defined by the SM-19 design and is byte-identical across the supported PowerShell 7 / Windows PowerShell 5.1 preparation paths.

Verify an existing offline set independently:

```powershell
.\release.ps1 -Mode Verify -ArtifactsDirectory '.\artifacts\release'
```

Verification re-derives the release/runtime manifests and all distribution bytes from the selected Git commit, validates the wheel contract, requires canonical ZIP/index/checksum encoding, and rejects extra, missing, aliased, or drifted content. Signing and GitHub Release publication remain later SM-19 slices.

## Run the accepted Windows runtime

`start.ps1` launches vLLM in the foreground and applies process-local containment before the server starts.

```powershell
.\start.ps1 -Model 'Qwen/Qwen3.5-0.8B' -VllmArgs @('--max-model-len', '2048', '--gpu-memory-utilization', '0.6')
```

By default it expects `runtime\venv\Scripts\vllm.exe` below the install root and keeps Hugging Face, vLLM, Torch/Inductor, Triton, DeepGEMM JIT and temporary state below that root. `-VllmExe` and `-ContainmentRoot` are explicit development overrides. `-ListenHost` and `-ListenPort` own the server endpoint; `VllmArgs` may not override `--host` or `--port`. `-ValidateOnly` materializes the contained directory tree and checks setup without starting vLLM, restores the caller process environment before returning, and never prints raw passthrough values. Background process ownership/service management is intentionally deferred to later lifecycle work.

If Windows legacy `MAX_PATH` behavior is active (`LongPathsEnabled=0`), keep the install/containment root short. PyTorch AOT cache filenames can otherwise cross the 260-character boundary. The canonical `D:\AI\vLLM` root is intentionally short; the validation record documents the reproduced boundary.

## Remaining lifecycle work

The lifecycle safety boundary is specified in [`docs/lifecycle-safety-contract.md`](docs/lifecycle-safety-contract.md). Portable CPython, uv, the contained runtime venv, the accepted dependency graph, managed vLLM materialization, canonical runtime distribution ownership, install, update, and uninstall are now productized. The next release-engineering milestone is the project-owned artifact publication/signing contract in [`docs/release-publication-design.md`](docs/release-publication-design.md); service/process ownership remains later work.
