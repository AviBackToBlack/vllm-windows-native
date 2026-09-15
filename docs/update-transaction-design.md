# Safe update transaction design

Status: SM-18 design gate. This document defines the required semantics for a future `update.ps1`; it does not implement update behavior.

## 1. Goal

`update.ps1` will perform an explicit, provenance-preserving transition from one fully recorded vLLM Windows Native release to another without adopting unknown content or mutating the active runtime in place.

The updater is a lifecycle transaction, not an installer rerun. The old generation remains the committed generation until the target generation has been staged, validated, activated, and committed by an atomic install-state replacement.

## 2. Baseline constraints

The current repository has these constraints:

- the installed runtime uses fixed live paths such as `runtime\venv`;
- `state\install-state.json` schema v1 records a release and a unique `generation_id`;
- the canonical repository currently contains only one real release manifest, `v0.27.1-windows-x86_64.json`, so cross-release regression must initially use synthetic release fixtures;
- `bootstrap-dependencies.ps1` already demonstrates the preferred persisted transaction-receipt / staging / backup / recovery pattern;
- the Python, uv, and base-venv bootstraps have local rollback behavior, but that is not a substitute for a top-level update transaction spanning the whole release;
- `start.ps1` currently does not hold the lifecycle operation lock while the server is running. Destructive update activation MUST NOT ship until start/maintenance coordination closes that race.

## 3. Non-goals for the first updater

The first updater will not:

- discover a "latest" release on the network;
- infer ownership from plausible filenames or directories;
- repair a malformed or partially owned installation;
- change `ModelsRoot`;
- remove user configuration or models;
- update global CUDA, drivers, Visual Studio, Git, Python, or other machine-wide prerequisites;
- provide an implicit downgrade/upgrade policy based on semantic-version ordering;
- support concurrent runtime start or another lifecycle mutation during activation.

A caller selects an exact target release manifest. A transition to an older or newer recorded release is therefore explicit; the updater does not guess ordering from release names.

## 4. Proposed command surface

The implementation should follow the installer input model:

- `-ReleaseManifestPath` selects the exact target release manifest;
- `-WheelPath` supplies the exact target wheel named and hashed by that manifest;
- `-InstallationRoot` selects the existing installation;
- optional pinned archive/offline inputs may mirror `install.ps1` where required;
- `ModelsRoot` comes from validated current install state and is not changeable by update;
- `-Json` returns a machine-readable result;
- destructive activation MUST use `SupportsShouldProcess` with `ConfirmImpact = 'High'` (or equivalent explicit high-impact semantics).

There is no target named `latest` and no unpinned target download.

`-WhatIf` still acquires the lifecycle locks and performs the same serialized read-only validation/planning snapshot, consistent with uninstall. It MUST NOT create or rewrite the update journal, create staging/workspace content, perform recovery mutation, activate, retire, or clean anything. If an existing pending transaction requires recovery, `-WhatIf` reports/refuses with the evidence intact rather than mutating it.

## 5. Required lock ordering and runtime exclusion

Top-level update follows the existing lifecycle order:

1. acquire `state\install-orchestrator.lock`;
2. acquire `.vllm-operation.lock`;
3. keep both locks through source validation, recovery, planning, activation, install-state commit, required synchronous validation, and synchronous cleanup;
4. release locks only after rollback is complete, or after a committed target has either completed cleanup or durably retained its transaction record for later cleanup recovery.

Before destructive update activation is implemented, `start.ps1` MUST participate in lifecycle serialization. The preferred v1 behavior is for a normal foreground start to hold `.vllm-operation.lock` for the lifetime of the managed server process. `-ValidateOnly` may acquire and release it only for validation.

This turns a running managed server into an OS-level maintenance conflict instead of relying only on a CIM process scan. Process inspection remains defense in depth for visible managed executables and diagnostics, not the sole race-prevention mechanism.

Start must never acquire the orchestrator lock, so the order cannot invert: start holds only the operation lock; install/update/uninstall acquire orchestrator then operation.

Managed-install mode and development mode are distinct, but classification MUST follow the effective execution target rather than merely the directory containing `start.ps1`. SM-18A must resolve candidate lifecycle roots from the installed/script root, the effective containment root, and the resolved runtime executable. If a candidate contains `state\install-state.json`, that state must validate and the resolved executable must be consistent with its recorded managed runtime. Multiple managed candidates must resolve to the same installation or start fails closed. A repo-checkout invocation is development mode only when no effective target resolves to a committed managed installation; development mode MUST NOT create an untracked `.vllm-operation.lock` in the source checkout.

This means a repo-checkout `start.ps1 -VllmExe <managed-root>\runtime\venv\Scripts\vllm.exe` is still a managed start and must serialize on `<managed-root>\.vllm-operation.lock`. Process-scan defense in depth likewise keys managed-runtime ownership on the executable path under verified managed roots, regardless of which copy of `start.ps1` launched it.

Managed starts are non-blocking with respect to the operation lock: if another start or maintenance operation already holds the lock, a second start fails immediately rather than queues. This is intentional for the current single-GPU support matrix.

A pending update is lifecycle-wide maintenance state, not private updater scratch space. Any non-update lifecycle entry that observes `state\update-transaction.json` at all — valid, malformed, or undecodable — MUST refuse without needing to understand its schema and direct the operator to `update.ps1`. Presence of the fixed reserved subtree `work\update-transaction` also causes unconditional refusal. `start.ps1 -ValidateOnly` in managed mode follows the same rule: it may report the maintenance condition, but it does not perform ordinary launch validation through it. `update.ps1` is the only normal lifecycle entry allowed to interpret, recover, or clean this state.

The pending-record/reserved-subtree check MUST occur, or be repeated, after the operation lock is held so that classification and refusal are serialized against transaction creation. SM-18A may add these forward-compatible presence checks before SM-18D can create the journal; until then they are normally absent but already define the safe behavior for future releases.

## 6. Source-generation proof

Under the lifecycle locks, update MUST validate the current installation at least as strictly as uninstall currently does:

- exact install-state schema and valid source `generation_id`;
- exact source release-manifest digest and release identity;
- exact distribution-file identities;
- exact managed-path set and physical-location constraints;
- exact receipt/provenance relationships;
- safe `InstallationRoot` and `ModelsRoot`;
- no contradictory reserved transaction paths;
- no detectable managed runtime process outside the start-lock guarantee.

Unknown, missing, drifted, malformed, redirected, or contradictory source ownership fails closed. Update must direct the operator to repair/reinstall rather than reconstruct ownership.

## 7. Target-generation proof

Before touching live payload, update MUST validate the target release from repository/source inputs:

- exact runtime-release schema/platform;
- exact self path;
- every distribution source file exists and matches size/SHA-256;
- the wheel filename, size, and SHA-256 match the target manifest;
- all referenced bootstrap/runtime manifests and locks are part of the target release payload and match their recorded identities;
- target managed paths are safe, non-overlapping with protected paths, and compatible with the current installation root;
- the target release differs from the source only through an explicit recorded transition;
- the transition is compatible with the existing protected `config.psd1`. Updater v1 supports only releases that do not require destructive or implicit config migration; a target that requires new incompatible config semantics must be rejected or await an explicit versioned config-migration contract.

If the target manifest digest and recorded release identity exactly equal the current source release, update is an idempotent no-op only after the current installation passes full validation. Same-name or same-version content with a different manifest digest is not idempotent and must fail unless it is represented as an explicit different recorded release.

## 8. Transition plan

Before materialization, update builds an in-memory transition plan from the validated source and target releases. Each owned path is classified as one of:

- `reuse`: exact source-owned content remains valid for the target;
- `replace`: the same live path requires different target-owned content;
- `add`: target-owned content has no live source counterpart;
- `retire`: source-owned content is not owned by the target.

The plan covers both distribution files and managed assets. It must record enough exact identity information to distinguish source, target, staging, and backup content without inferring ownership from path presence.

Protected paths (`ModelsRoot`, `config.psd1`, unrelated files, machine-wide prerequisites) never enter the destructive plan.

Lifecycle-control metadata is also excluded from ordinary `reuse` / `replace` / `add` / `retire` classification even when a release manifest lists it as managed. The held lock files (`state\install-orchestrator.lock` and `.vllm-operation.lock`), `state\install-state.json`, and `state\update-transaction.json` are validated and managed by dedicated lifecycle logic only. The updater MUST NOT move, replace, retire, or back up a lock file it is holding; install state changes only at the authoritative commit point; the transaction record changes only through atomic transaction-state writes.

`update.ps1` and `scripts/common.ps1` themselves may be ordinary replace-class distribution files. Self-replacement is safe only because the current PowerShell invocation has already parsed the running script and loaded its dot-sourced functions before activation; the updater MUST NOT re-load target lifecycle code mid-transaction. Any supported source-to-target transition must preserve transaction-journal compatibility sufficient for the target updater, if invoked after a crash, to interpret and recover a journal written by the source updater.

`retire` operations should be deferred until after target commit whenever possible. Leaving an obsolete source-owned object temporarily present is safer than deleting it before the target generation is committed.

## 9. Persisted update transaction

The updater reserves a top-level transaction record at:

`state\update-transaction.json`

and a fixed transaction workspace root at:

`work\update-transaction`

Future release manifests that ship the updater MUST reserve both as lifecycle-owned metadata.

Reserved update metadata and the fixed transaction workspace are lifecycle-owned independently of the frozen source release's `managed_paths`. This is required for the first transition from v0.27.1, whose manifest predates the updater and cannot retroactively list them. The journal is the ownership proof for exact descendants beneath `work\update-transaction`; any non-update entry refuses on presence of the journal or workspace root without parsing either, while `update.ps1` validates their exact relationship before recovery or cleanup.

The transaction record MUST be durably created at transaction open, before the first staging file or directory is created. Phase `materializing` therefore always exists before transaction-owned residue can exist. Staging and backup remain on the installation volume under `work\update-transaction\<transaction_id>\...` so activation can use same-volume renames. The record stores their exact physical/relative locations and the unique `transaction_id`.

The transaction schema must include, at minimum:

- schema/component/platform;
- `transaction_id`;
- transaction phase;
- installation and models roots;
- source release, source manifest digest, and source `generation_id`;
- target release, target manifest digest, and preallocated target `generation_id`;
- staging and backup roots;
- the exact persisted activation plan with source/target identities;
- creation/update timestamps.

The initial record and every later phase rewrite MUST use the same cross-edition atomic file-publication helper required for install-state commit below, then be semantically re-read. `Move-Item -Force` is not an acceptable overwrite primitive for transaction metadata on Windows PowerShell 5.1.

If staging or backup residue exists without a valid matching transaction record, update fails closed and preserves the evidence.

## 10. Transaction phases

The v1 state machine is:

`materializing -> prepared -> activating -> committed -> cleanup`

Semantics:

- `materializing`: target assets may be created only in staging/reusable versioned paths; no committed live payload is replaced;
- `prepared`: all target assets and the complete activation plan are verified, and rollback information is durable;
- `activating`: live `replace`/`add` operations may occur using exact staging/backup paths; the source install state is still the commit marker;
- `committed`: target `state\install-state.json` has been atomically installed and exactly validates the target generation;
- `cleanup`: source backups, obsolete `retire` paths, staging residue, and finally the transaction record may be removed after exact revalidation.

Transaction phase is diagnostic and constraining metadata. Commit status is never inferred from phase or directory presence alone.

## 11. Commit point and install-state semantics

The single authoritative commit point is atomic replacement of `state\install-state.json` with the fully validated target state. This replacement MUST use one native same-volume Windows replace operation whose behavior is independent of PowerShell edition; v1 uses a shared P/Invoke helper that fully writes and `FlushFileBuffers`-flushes the temporary state, then calls `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`, followed by an exact semantic re-read. `Move-Item -Force` MUST NOT implement this commit point: Windows PowerShell 5.1 can delete the destination before renaming the source, creating an observable no-state window.

The same helper/semantics apply to rewrites of `state\update-transaction.json`. The implementation must test atomic replacement behavior on both PowerShell 7 and Windows PowerShell 5.1, including fault injection around the publication boundary.

Before that replacement, the source generation is committed even if some target files have temporarily been activated under the operation lock. A crash must therefore roll back to the source generation.

After target state is committed and validates exactly, the target generation is committed. Recovery then performs cleanup only and MUST NOT roll back merely because old backups remain.

For a successful update:

- `generation_id` changes to the preallocated target generation ID;
- `installed_at` is preserved from the original installation;
- `updated_at` is replaced with the update commit time;
- `models_root` remains exactly the validated source value;
- release/provenance/distribution/managed-path fields describe only the target release.

The state file itself is never moved into the ordinary activation backup plan. It stays source-valid until the final atomic commit.

## 12. Activation rules

All live activation operations must be same-volume and use persisted staging/backup locations.

For `replace`:

1. revalidate the live source identity and physical path;
2. revalidate the staged target identity and physical path;
3. move live source to its reserved backup path;
4. move staged target into the live path;
5. validate the activated target at the live path.

For `add`, the live target must still be absent immediately before activation. For rollback, an exact activated target may be removed only when the transaction proves it was added by this transaction.

`retire` content remains until commit unless keeping it would make target validation impossible.

Every destructive operation is revalidated immediately before execution. A mismatch stops the transaction and preserves evidence if safe rollback cannot be proven.

## 13. Crash recovery

Every update entry first performs transaction recovery under both lifecycle locks.

Recovery decisions are generation-backed:

| Observed state | Required action |
| --- | --- |
| no transaction record and no reserved residue | normal planning may begin |
| residue without a valid transaction record | fail closed; preserve evidence |
| malformed/contradictory transaction record | fail closed; preserve evidence |
| valid transaction, install state still records source generation | restore every activated `replace`, remove only transaction-proven `add` targets, validate source generation, then clean staging/transaction metadata |
| valid transaction, install state exactly records target generation | target is committed; validate target, then clean backups/retired source content/staging/transaction metadata |
| valid transaction, `install-state.json` is absent | fail closed; preserve all transaction/workspace evidence; absence is not a normal crash state once atomic publication is implemented |
| install state matches neither recorded generation | fail closed; preserve all evidence |
| required source backup and live source are both missing before commit | automatic rollback is impossible; fail closed and preserve transaction evidence |
| an object has an identity matching neither recorded source nor target | fail closed; never guess which copy is owned |

Recovery must use recorded identities/generations and exact receipts, not path existence alone.

## 14. Target staging and relocation

Target materialization must happen without overwriting active live content. The exact staging mechanism is an implementation slice, but it must satisfy all of these properties:

- staging is inside the installation volume and physically validated;
- the staged target can be validated before activation;
- path-bearing runtime files/receipts are either created for their final live paths or are proven relocation-safe and regenerated/revalidated after activation;
- no existing bootstrap `-Force` behavior is treated as a substitute for the top-level transaction journal;
- final live validation runs again after activation and before state commit.

A full temporary installation under `work\` is acceptable only if relocation semantics are proven for the venv, scripts, receipts, and embedded paths. Otherwise updater-specific staging paths/parameters are required.

## 15. Failure policy

Before install-state commit, any activation or validation failure triggers rollback when rollback can be proven safe. If rollback itself cannot be proven or completed, update fails with transaction evidence preserved.

After install-state commit, cleanup failure is not a reason to revert a valid target generation. Synchronous cleanup is attempted while both lifecycle locks are still held. If cleanup cannot complete safely, the transaction record remains as committed-cleanup evidence before locks are released; subsequent non-update lifecycle entries refuse mutation/start and `update.ps1` recovery retries exact cleanup under both locks.

No failure path may silently adopt unknown content, delete protected data, or claim success with contradictory state.

## 16. Acceptance strategy

Because only one canonical real release currently exists, update logic is first validated with synthetic source/target releases that exercise different identities and path sets without external downloads.

Required adversarial coverage includes:

- same-release idempotent no-op;
- source drift/malformed state refusal;
- target manifest/file/wheel drift refusal;
- ModelsRoot/config/unknown-file preservation;
- managed start detection when a repo-checkout launcher targets a committed installation via `-VllmExe` or containment overrides;
- presence-only refusal for malformed/valid update journals and the fixed reserved workspace;
- operation/orchestrator lock contention;
- start/update serialization and a server starting/running during maintenance;
- target staging validation failure before live mutation;
- crash/fault injection before the first staging write, before first rename, after source backup, after target activation, immediately before state commit, immediately after state commit, and during cleanup;
- atomic journal/install-state publication on both PowerShell 7 and Windows PowerShell 5.1, including verification that overwrite does not expose a destination-absent window;
- rollback of replace/add operations;
- committed-cleanup recovery;
- missing/malformed transaction records and unexplained staging/backup residue;
- reparse/junction redirection and per-target TOCTOU revalidation;
- PowerShell 7 and Windows PowerShell 5.1 parsing/behavior where supported.

Mutation regressions remain trusted-only. Public PR CI stays source-level in accordance with `AGENTS.md`.

## 17. Implementation slices after this design gate

Implementation should remain split into reviewable slices:

1. **SM-18A — start/maintenance serialization and forward-compatible maintenance guard.** Make managed `start.ps1` hold the operation lock for the server lifetime, resolve managed mode from the effective target, and make start/install/uninstall refuse on presence of the future update journal/reserved workspace while holding the relevant lifecycle lock. Add contention/dev-mode/override-target tests. No updater mutation yet.
2. **SM-18B — update validation and transition planner.** Replace the updater stub with read-only source/target validation, same-release no-op, exact plan generation, and synthetic fixtures. No live mutation.
3. **SM-18C — target staging.** Materialize and validate a target generation away from live paths; prove relocation/final-path semantics.
4. **SM-18D — transaction journal and synthetic activation/recovery.** Implement persisted transaction state, replace/add rollback, target state commit, and fault-injection recovery using synthetic payloads.
5. **SM-18E — full release integration.** Connect the transaction engine to real release/bootstrap payloads, target install-state generation, distribution replacement, and post-commit retirement cleanup.
6. **SM-18F — trusted update regression.** Add Windows Server 2025 trusted workflow covering PS7/PS5.1 supported paths and crash-recovery acceptance; keep public PR CI source-only.

Each significant slice stops at its own merge gate. No later slice may weaken the source-generation proof or transaction semantics established here merely to make an update proceed.
