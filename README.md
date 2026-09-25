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

`Prepare` requires a clean worktree and the selected project commit to be the checked-out `HEAD`. The final output path must not exist, and its parent directory must already exist as a regular canonical directory; `Prepare` never creates a missing parent, empties, or deletes a pre-existing final directory. Concurrent preparation into the same output directory is serialized by an exclusive persistent sibling `.\.<output-leaf>.vllm-release-prepare.lock` coordination file, which is outside the four release assets. An existing sidecar is reused only after its tool ownership schema/operation/root marker is validated; an unrecognized sidecar is refused without modification, and recognized legacy sidecars are upgraded to schema v1. The parent directory itself is also pinned by a non-delete-sharing handle, so preparations targeting different outputs under the same parent are intentionally serialized and report a retryable concurrency diagnostic. Canonical release-owned source files are materialized lazily from their exact Git blob object IDs, not by extracting an archive: each required parent directory is validated/pinned first and each blob is written through a CREATE_NEW, no-follow file handle before it becomes readable by path. Preparation builds and fully verifies the four assets in a unique sibling staging directory while DELETE-capable non-delete-sharing handles pin both the parent and staging directory objects against rename/replacement; each staged asset is likewise created through a pinned CREATE_NEW file stream that denies concurrent writers through the final pre-publication byte proof. Windows does not permit the staging directory itself to be renamed while child file handles remain open, so those four streams are closed only after their exact identities are re-proved; no further preparation write occurs after that boundary. Publication then renames the pinned staging directory to the final path through the still-open staging-directory handle and reruns full offline verification before `Prepare` can succeed. A mutation in the close-to-rename window therefore cannot redirect a write and is detected fail-closed by post-publication verification and guarded rollback. If that post-publish proof fails, the tool attempts to move the same directory object by handle into a private rejected quarantine and remove it with guarded object-bound cleanup; the requested final path is not considered valid until post-publish verification succeeds. If the final path appears before publication, preparation fails without cleaning or overwriting that foreign path. The generated set is exactly the wheel copied byte-for-byte, `vllm-windows-native-<release>.zip`, `release-index.json`, and `SHA256SUMS`. The ZIP uses the canonical STORE profile defined by the SM-19 design and is byte-identical across the supported PowerShell 7 / Windows PowerShell 5.1 preparation paths.

If you choose a custom `-ArtifactsDirectory` inside the repository, keep that path git-ignored; otherwise the clean-worktree gate will intentionally reject subsequent `Prepare` runs after artifacts or the retained coordination sidecar appear.

The release workspace is part of the trusted execution boundary. Prepare/Verify fail closed on stale state, path/reparse surprises, and cooperating concurrent release invocations, but they are not intended to sandbox a malicious same-user process that can create/delete/rename arbitrary files in the release parent directory. Run release preparation in an isolated trusted workspace with permissions that exclude untrusted local writers. The exact four-asset check is therefore a point-in-time verification boundary; mutate the directory afterwards and the previous verification is no longer authoritative.

A retained zero-length preparation sidecar is treated as an interrupted tool-created lock and is recovered automatically on the next Prepare. A non-empty malformed/truncated/foreign sidecar is preserved and refused; after confirming no preparation is active, inspect and remove that sidecar explicitly before retrying.

If a hard process termination or power loss leaves a private sibling .<output-leaf>.vllm-release-stage-* directory, confirm no preparation is active, inspect it, and remove it manually before retrying; Prepare never guesses that an arbitrary stale-looking directory is safe to delete. If post-publish verification fails, `Prepare` normally quarantines and removes the rejected directory before returning the error. If an external process prevents that rollback, preserve/inspect any remaining final or rejected directory as evidence and remove it explicitly before retrying.

Verify an existing offline set independently:

```powershell
.\release.ps1 -Mode Verify -ArtifactsDirectory '.\artifacts\release'
```

Verification re-derives the release/runtime manifests and all distribution bytes from the selected Git commit, validates the wheel contract, requires canonical ZIP/index/checksum encoding, and rejects extra, missing, aliased, or drifted content.

### Verify release authorization and a published immutable release

SM-19B adds verification only; it does not create tags or mutate GitHub Releases. The repository versions the publication-side v1 signer policy in `config/release-allowed-signers`: exactly principal `vllm-windows-native-release` and the authorized ECDSA-SK key with fingerprint `SHA256:ga7J6BbUAgsSVju3a6RZU4Vw4/7wvn2xL/MTLWy77ng`.

A consumer must obtain and pin the allowed-signers file independently of the release being verified. Do not bootstrap trust from the target release bundle. Pass that trusted copy explicitly:

```powershell
.\release.ps1 -Mode VerifySignedTag `
  -ProjectCommit '<expected-project-commit>' `
  -Tag 'release/v0.27.1-native-windows-single-gpu-sm120' `
  -AllowedSignersPath 'C:\trusted\vllm-windows-native-release-allowed-signers'
```

`VerifySignedTag` requires the signed release tag object to exist in the local clone (fetch `refs/tags/release/...` before verification if necessary). It requires an annotated SSH-signed tag, resolves `<tag>^{commit}` to the expected commit, and invokes Git with explicit SSH-signing configuration rather than relying on the operator's global Git trust configuration.

After downloading the four immutable release assets, compose offline verification, signed-tag authorization, and GitHub's release attestation. `VerifyPublished` has the same local-tag prerequisite and additionally requires an authenticated GitHub CLI (`gh auth status` must succeed):

```powershell
.\release.ps1 -Mode VerifyPublished `
  -ProjectCommit '<expected-project-commit>' `
  -ArtifactsDirectory 'C:\downloads\vllm-release' `
  -AllowedSignersPath 'C:\trusted\vllm-windows-native-release-allowed-signers'
```

`VerifyPublished` first performs the SM-19A exact-four local verification. It then verifies the signed tag and requires `gh release verify --format json` to bind the exact repository, annotated tag object, and exactly those four asset names/SHA-256 digests. The signed-tag check separately peels that authenticated tag object to the expected reviewed project commit. Finally it runs `gh release verify-asset` separately for the wheel, distribution ZIP, `release-index.json`, and `SHA256SUMS`. The immutable-release attestation proves release/asset integrity; it is not represented as build provenance for the prebuilt local GPU wheel.

### Stage and publish the guarded GitHub Release

SM-19C adds the mutation surface, but it deliberately does not create or sign the release tag and does not enable repository release immutability. Before staging, the repository must already have immutable releases enabled, the reviewed project commit must still be the remote `main` tip, and the canonical annotated SSH-signed release tag must already exist both locally and on GitHub. Run the commands from a clean checkout of `main` at that exact commit with an authenticated `gh` CLI and an independently pinned allowed-signers file.

Stage or resume the owned draft prerelease and upload only missing canonical assets:

```powershell
.\release.ps1 -Mode StageDraft `
  -ProjectCommit '<reviewed-main-commit>' `
  -Tag 'release/v0.27.1-native-windows-single-gpu-sm120' `
  -ArtifactsDirectory 'C:\trusted\vllm-release' `
  -AllowedSignersPath 'C:\trusted\vllm-windows-native-release-allowed-signers'
```

`StageDraft` reruns the complete offline four-asset verification and signed-tag verification before any GitHub mutation. It then rechecks repository immutability, remote `main`, and the remote annotated tag-object identity. A new draft receives a schema-v1 ownership marker binding repository, release id, tag, and project commit. Retries adopt only that exact owned draft. Existing remote assets must be a subset of the canonical four and must match their case-sensitive names, byte sizes, and `sha256:` digests; matching assets are retained and only missing assets are uploaded. Extra, duplicate, incomplete, or mismatched assets fail closed. The normal path never uses `--clobber`, deletes an asset, or repairs a published mismatch.

Publishing is a separate explicit operator action:

```powershell
.\release.ps1 -Mode PublishDraft `
  -ProjectCommit '<reviewed-main-commit>' `
  -Tag 'release/v0.27.1-native-windows-single-gpu-sm120' `
  -ArtifactsDirectory 'C:\trusted\vllm-release' `
  -AllowedSignersPath 'C:\trusted\vllm-windows-native-release-allowed-signers'
```

`PublishDraft` re-proves the same local and remote identities, requires the exact four-asset owned draft, rechecks the local asset bytes immediately before publication, and publishes it as a prerelease with `latest=false`. It then requires GitHub to report the release as immutable and runs the full `VerifyPublished` release-attestation and per-asset attestation chain. Retrying an already published exact-match immutable release is idempotent; a later metadata-only promotion from prerelease to stable does not change its ownership or asset identity.

Immediate post-publish attestation verification uses five bounded attempts with a 1.5-second delay to tolerate GitHub attestation propagation; ordinary VerifyPublished calls remain single-pass.

A failed owned draft can be removed only through the separate recovery operation:

```powershell
.\release.ps1 -Mode ResetDraft `
  -ProjectCommit '<reviewed-main-commit>' `
  -Tag 'release/v0.27.1-native-windows-single-gpu-sm120' `
  -AllowedSignersPath 'C:\trusted\vllm-windows-native-release-allowed-signers'
```

`ResetDraft` is `ShouldProcess`-guarded and deletes only a draft whose ownership marker exactly matches the requested release transaction. Published releases are never deleted, reset, or repaired by this tooling. Use `-WhatIf` on any mutation mode to inspect the operator action without performing it.

Recovery authority is the exact ownership marker plus draft state. Reset therefore remains available even if prerelease metadata was edited externally; published releases are still never deleted or repaired.

### Run the trusted SM-19D non-production publication acceptance

SM-19D is a trusted operator ceremony, not PR CI. Run it only from a clean reviewed main checkout whose HEAD still equals remote main. The repository must already have immutable releases enabled. The acceptance workspace must be outside the repository.

Choose a unique one-shot acceptance id. Its tag lives below acceptance/sm19d/ and must never be reused. Prepare rejects non-lowercase or git-ref-invalid ids, creates four clearly non-production synthetic assets, an ephemeral Ed25519 signing key, an annotated SSH-signed local tag, and an atomically replaced state file. The tag is verified against the generated acceptance-only trust root, then the private key is deleted before any remote mutation. If a previous process died during preparation, the next harness invocation first removes any residual safe regular private-key file before doing anything else.

    .\release-acceptance.ps1 -Mode Prepare -AcceptanceId 20260925-bb4231f021f2-01 -Workspace C:\AI\vLLM-build\acceptance\sm19d-20260925-bb4231f021f2-01

Exercise the real draft transaction before the irreversible boundary. The tag push is bound to the canonical https://github.com/AviBackToBlack/vllm-windows-native.git URL rather than the checkout origin and refuses git URL rewriting. It then stages all four assets, repeats StageDraft to prove retry idempotence, resets the exact marker-owned draft, and proves the release is absent. The remote tag remains as the identity that will be published.

    .\release-acceptance.ps1 -Mode ExerciseDraft -Workspace C:\AI\vLLM-build\acceptance\sm19d-20260925-bb4231f021f2-01

Publish is a separate high-impact ShouldProcess action and refuses to run until the trusted local acceptance state records the completed draft round trip. State updates are atomic and preserve the previous valid record if publication of a replacement state file fails before the rename boundary. The state file remains inside the trusted operator workspace; it is not a cryptographic defense against a same-rights process that can rewrite that workspace. Publish recreates the exact draft, publishes it as prerelease/latest=false, requires immutable=true, and verifies the GitHub release attestation plus every local asset with the same release-verification primitives used by production.

    .\release-acceptance.ps1 -Mode Publish -Workspace C:\AI\vLLM-build\acceptance\sm19d-20260925-bb4231f021f2-01

Run verification again as a separate consumer-style proof. Verification binds the canonical percent-encoded package PURL to the exact repository/tag, tag object, and four asset digests. If immutable publication already succeeded but the prior process failed before local state persistence, a successful Verify atomically reconciles acceptance-state.json to that verified published release:

    .\release-acceptance.ps1 -Mode Verify -Workspace C:\AI\vLLM-build\acceptance\sm19d-20260925-bb4231f021f2-01

If a pre-publication attempt leaves an owned draft, ResetDraft may remove only that exact marker-owned draft. Published acceptance releases are never reset, deleted, repaired, or clobbered by this harness.

    .\release-acceptance.ps1 -Mode ResetDraft -Workspace C:\AI\vLLM-build\acceptance\sm19d-20260925-bb4231f021f2-01

The published fixture is intentionally preserved as audit evidence. Its assets are synthetic and are not the production GPU wheel or production bundle. The acceptance signer is separate from config/release-allowed-signers and never exercises the production hardware-backed private key.

## Run the accepted Windows runtime

`start.ps1` launches vLLM in the foreground and applies process-local containment before the server starts.

```powershell
.\start.ps1 -Model 'Qwen/Qwen3.5-0.8B' -VllmArgs @('--max-model-len', '2048', '--gpu-memory-utilization', '0.6')
```

By default it expects `runtime\venv\Scripts\vllm.exe` below the install root and keeps Hugging Face, vLLM, Torch/Inductor, Triton, DeepGEMM JIT and temporary state below that root. `-VllmExe` and `-ContainmentRoot` are explicit development overrides. `-ListenHost` and `-ListenPort` own the server endpoint; `VllmArgs` may not override `--host` or `--port`. `-ValidateOnly` materializes the contained directory tree and checks setup without starting vLLM, restores the caller process environment before returning, and never prints raw passthrough values. Background process ownership/service management is intentionally deferred to later lifecycle work.

If Windows legacy `MAX_PATH` behavior is active (`LongPathsEnabled=0`), keep the install/containment root short. PyTorch AOT cache filenames can otherwise cross the 260-character boundary. The canonical `D:\AI\vLLM` root is intentionally short; the validation record documents the reproduced boundary.

## Remaining lifecycle work

The lifecycle safety boundary is specified in [`docs/lifecycle-safety-contract.md`](docs/lifecycle-safety-contract.md). Portable CPython, uv, the contained runtime venv, the accepted dependency graph, managed vLLM materialization, canonical runtime distribution ownership, install, update, and uninstall are now productized. The next release-engineering milestone is the project-owned artifact publication/signing contract in [`docs/release-publication-design.md`](docs/release-publication-design.md); service/process ownership remains later work.
