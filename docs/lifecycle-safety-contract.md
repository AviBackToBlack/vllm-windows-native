# Lifecycle safety contract

Status: Accepted design contract; implementation pending.

This document defines the normative safety boundary for `install.ps1`, `update.ps1`, `uninstall.ps1`, and future background-process lifecycle work. It does not itself implement those operations.

## 1. Core invariants

Lifecycle tooling MUST:

- keep project-managed state beneath a configurable absolute install root, default `D:\AI\vLLM`;
- avoid persistent host PATH, PowerShell profile, or registry changes unless a later accepted design explicitly requires one;
- distinguish project-owned files from user-owned or external data;
- verify hashes and recorded provenance before activating downloaded runtime content;
- fail closed when path, state, process, or release ownership cannot be established; and
- never use recursive deletion of the installation root as an uninstall strategy.

When ownership or physical location is ambiguous, leaving recoverable files behind is safer than deleting them.

## 2. Installation root

`InstallRoot` MUST be a fully qualified absolute Windows path and MUST NOT be a volume root such as `C:\` or `D:\`.

If `InstallRoot` already exists, lifecycle tooling MUST verify the root itself is not a junction, symlink, mount alias, or other redirected filesystem location. A redirected installation root is unsupported and must fail closed.

Lifecycle code MUST normalize lexical paths before comparison. Existing destructive targets MUST also be checked by physical/final Windows path so junctions, symlinks, mount points, or other aliases cannot redirect an apparently contained path elsewhere.

When an expected managed path exists, its physical location MUST match the location implied by the normalized install root and expected relative path. Any mismatch is a hard failure.

The implementation SHOULD use handle-based Win32 final-path resolution such as `GetFinalPathNameByHandle`, not string-only reparse-point heuristics.

## 3. Ownership classes

### 3.1 Distribution files

Root-level lifecycle scripts, docs, manifests, patchsets, and other release payloads are distribution files. Install/update state MUST record the exact project-owned distribution files for the installed release, including hashes where applicable.

Update MUST NOT delete an unrecognized root-level file merely because it is under `InstallRoot`. Uninstall MUST remove distribution files only when ownership is established by installed release state/manifest. It MUST NOT recursively delete `InstallRoot` itself.

### 3.2 Generated managed directories

These top-level directories are reserved for project-managed generated/install state:

`runtime\`, `python\`, `tools\`, `cache\`, `config\`, `tmp\`, `downloads\`, `logs\`, `work\`, `forensic\`, and `state\`.

Before deleting or replacing any existing managed top-level directory, lifecycle tooling MUST verify its physical final location. A managed directory that resolves through an alias elsewhere is unsafe and MUST stop the operation.

### 3.3 User configuration

Root-level `config.psd1` is user-modifiable persistent configuration, not disposable generated cache. Update MUST preserve it and MUST NOT silently replace user changes with defaults.

Uninstall MUST preserve `config.psd1` by default. Any future option that removes user configuration must be explicit and covered by `ShouldProcess` confirmation semantics.

### 3.4 Models

The default `ModelsRoot` is `<InstallRoot>\models`.

An external `ModelsRoot` is allowed only when it is fully qualified and absolute, lexically non-overlapping with `InstallRoot` in either direction, and physically non-overlapping. If the target does not yet exist, the physical candidate MUST be derived from the final path of its nearest existing ancestor plus the unresolved lexical tail before overlap is evaluated.

Filesystem aliases MUST NOT make an external model path physically overlap the installation root, or vice versa.

External models are never project-owned merely because configuration references them. Update and uninstall MUST NOT delete an external `ModelsRoot`.

Default local models also MUST NOT be deleted by ordinary uninstall. Removing them requires an explicit future opt-in such as `-RemoveModels`, guarded by the same physical-path checks immediately before deletion.

## 4. Operation lock

All lifecycle mutations MUST serialize per installation root. The reserved lock path is `<InstallRoot>\.vllm-operation.lock`.

A mutating operation MUST acquire an exclusive OS file handle with no sharing before changing managed state. If the lock cannot be acquired, the operation MUST fail rather than run concurrently.

The lock covers install, repair, update, uninstall, and any future start/stop action that changes persistent lifecycle/process state. Read-only diagnostics may run without the mutation lock when they cannot race destructively with maintenance.

The lock file is coordination state, not proof of process ownership. Uninstall may remove the lock file only after destructive work is complete and the exclusive handle has been released.

## 5. Install state and release ownership

Canonical machine-readable install state is reserved at `<InstallRoot>\state\install-state.json`.

The eventual state schema MUST contain enough information to prove at least:

- schema version and installed project release/version;
- official vLLM upstream revision and Windows patchset revision/hash;
- installed wheel identity and SHA-256;
- Python ABI/version and managed Python identity;
- pinned runtime dependency versions and downloaded artifact hashes/provenance;
- `InstallRoot` and configured `ModelsRoot`;
- the project-owned distribution-file set for that installed release; and
- installation/update timestamps and active release generation when generations are used.

State writes MUST be atomic: write and validate a temporary file in the same managed filesystem, then replace active state.

Missing, malformed, or contradictory install state MUST NOT be treated as permission to delete unknown content. Destructive repair/update/uninstall must fail closed unless a documented repair procedure can reconstruct ownership from independently verified release metadata.

## 6. Process ownership

Foreground `start.ps1` does not currently persist process ownership state. If background or service-style execution is added later, lifecycle tooling MUST NOT terminate processes merely by executable name.

Persistent process ownership MUST resist PID reuse and include at minimum PID, process creation/start time, expected executable path, and installation identity or equivalent launch token/state.

Stop, update, repair, and uninstall MUST verify that identity before terminating a process. If ownership cannot be proved, the tool MUST refuse to kill it and report the conflict.

## 7. Install contract

Installation implementation MUST:

1. validate `InstallRoot` and `ModelsRoot` before materializing runtime content;
2. acquire the operation lock;
3. acquire only pinned/approved project inputs;
4. verify expected size/hash and available provenance before extraction or activation;
5. keep downloads, staging, Python runtimes, tools, caches, and runtime environments within managed paths;
6. never depend on a global Python installation;
7. avoid persistent host environment changes;
8. never silently install, remove, or mutate machine-wide prerequisites such as GPU drivers, Visual Studio Build Tools, or system CUDA;
9. write install state only after the installed payload passes required validation; and
10. leave enough staged/forensic evidence to diagnose an interrupted install without guessing ownership.

An interrupted install must be distinguishable from a complete installation. Presence of a directory alone is not proof of success.

For replace-in-place runtime transactions, materialization SHOULD complete and validate in a managed staging path before the live target is moved. If activation requires a backup/swap, the implementation MUST persist a managed transaction record before the first destructive rename. Recovery MUST use recorded generation identity and verified receipts to distinguish an uncommitted generation that requires rollback from a committed generation that requires cleanup only; it MUST NOT infer commit solely from the presence of a plausible target directory.

## 8. Update contract

Update MUST be an explicit, provenance-preserving transition between recorded releases.

Update implementation MUST acquire the operation lock, verify current state before mutation, refuse unsafe runtime/process conflicts, stage new assets without overwriting the active runtime in place, verify hashes/provenance before activation, preserve `config.psd1`, models, and unrelated user files, validate the staged runtime before switching active state, update install state with a PowerShell-edition-independent atomic Windows replace primitive, and preserve or restore the prior active runtime/state if activation fails.

Update MUST NOT convert an unknown or partially owned installation into a destructive cleanup operation.

Presence of `state\update-transaction.json` or the reserved `work\update-transaction` workspace is lifecycle-wide maintenance state, regardless of whether the journal is valid or parseable. Non-update entries that could launch the managed runtime or mutate the installation (including start, install, and uninstall) MUST refuse while either exists and direct recovery through the updater; they do not need journal-schema knowledge.

The concrete transaction state machine, crash-recovery rules, and implementation slicing are defined in docs/update-transaction-design.md.

## 9. Uninstall contract

`uninstall.ps1` MUST use `CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')` or equivalent explicit destructive-operation semantics.

Before deleting anything, uninstall MUST acquire the operation lock, read and validate install state, prove owned runtime processes are stopped (or stop only a verified owned process), validate `ModelsRoot` safety, validate the physical final location of every managed deletion target, and build an explicit deletion plan from known project ownership.

Immediately before each destructive removal, the target MUST be revalidated. Time-of-check/time-of-use gaps should be kept as small as practical.

The validated ownership/deletion plan MUST remain available in memory for the whole operation. Managed `state\` MUST be removed only after other owned payload targets, and the operation lock MUST remain held until destructive work is complete.

Uninstall MAY remove project-owned generated directories and distribution files proven by state. It MUST preserve external models, default local models unless explicitly requested, `config.psd1` unless explicitly requested, unrecognized files under `InstallRoot`, and host/global components not installed inside the project root and recorded as project-owned.

Global GPU drivers, Visual Studio Build Tools, system CUDA installations, and other machine-wide prerequisites are never inferred to be project-owned and MUST NOT be removed.

If any managed path resolves outside its expected physical location, uninstall MUST stop before deleting that path or later targets.

## 10. Repair and recovery

A future repair mode may recreate missing project-owned content, but it MUST follow the same path, lock, provenance, and ownership rules as install/update.

Repair MUST NOT adopt arbitrary pre-existing files into project ownership solely because names or locations look plausible. Ownership reconstruction requires verified project metadata and hash/provenance checks.

Forensic records and failed staging content may be retained when useful for recovery. Cleanup of that evidence must itself obey owned-path safety checks.

## 11. Validation requirements for implementation PRs

Any PR that implements or changes lifecycle mutation logic MUST include adversarial tests for the affected boundary. As applicable, tests should cover relative paths and volume roots, lexical `..` normalization, junction/symlink/reparse redirection, alias-based InstallRoot/ModelsRoot overlap, external-model preservation, operation-lock contention, missing/corrupt/contradictory install state, interrupted staging/activation, PID reuse or unowned-process refusal, `ShouldProcess` / `-WhatIf`, and proof that unrelated files are preserved.

Happy-path installation alone is not lifecycle acceptance.

## 12. Design provenance

The hardening approach was informed by the project author's separate `AviBackToBlack/unsloth-studio-windows-native` implementation, reviewed at Git tree `9df9219ce85f3536f6b40e95662c997ba53b42d2` (`feat/public-v01`). Relevant patterns include handle-based Windows final-path resolution, non-overlapping external model storage, exclusive operation locking, state-backed ownership, and fail-closed uninstall.

That project is a design/reference source only. This contract creates no runtime or release dependency on it. No implementation code is introduced by this documentation-only contract; any future copied implementation material must retain applicable license and attribution as required by this repository's provenance policy.
