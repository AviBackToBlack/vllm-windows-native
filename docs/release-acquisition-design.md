# SM-20 trusted release acquisition design

Status: design gate for issue #34. This document defines the v1 network-to-verified-local-artifact boundary. It does not publish a production release.

## Goal

SM-20 bridges two already-proven boundaries without weakening either one:

1. SM-19 publishes an immutable GitHub Release whose exact tag, project commit, four assets, checksums, and GitHub release attestations can be independently verified.
2. SM-18 `install.ps1` / `update.ps1` accept exact local inputs and fail closed when the release manifest, distribution payload, wheel, or lifecycle identity does not match.

The acquisition layer starts from an explicitly selected repository, exact release tag, independently pinned allowed-signers trust root, and empty or explicitly untrusted acquisition cache. It must end with one cryptographically verified immutable local release artifact set plus a provenance receipt.

Acquisition completes before the installer/updater receives lifecycle mutation authority. Network access is not added to `install.ps1` or `update.ps1`.

## Existing primitives are authoritative

SM-20 composes existing implementation rather than introducing parallel cryptography or release formats:

- `Assert-VllmReleaseAllowedSigners` and `Assert-VllmReleaseSignedTag` remain authoritative for the pinned trust root, annotated SSH-signed tag, signer principal/fingerprint, and exact tag-to-project-commit binding.
- `Get-VllmReleaseContext` / `Assert-VllmOfflineRelease` remain authoritative for tagged-commit manifest reconstruction, exact four-asset identity, the canonical bundle, `release-index.json`, and `SHA256SUMS`.
- `Invoke-VllmGitHubReleaseVerification` remains authoritative for GitHub release attestation and the independent `gh release verify-asset` proof of every local asset.
- existing release-publication read paths are reused for immutable remote release metadata where applicable.
- existing atomic-state helpers are reused for receipt publication.
- existing exact-input `install.ps1 -ReleaseManifestPath ... -WheelPath ...` and `update.ps1 -ReleaseManifestPath ... -WheelPath ...` validation remains authoritative.

SM-20 MUST NOT add a second tag-signature format, checksum format, release-index parser, asset-attestation verifier, or lifecycle transaction engine.

## V1 exact-tag command surface

The production consumer surface is a new top-level `acquire.ps1`. Exact-tag mode takes these caller-selected trust inputs:

```text
-Repository           AviBackToBlack/vllm-windows-native
-Tag                  release/<exact-release-id>
-AllowedSignersPath   <independently pinned local file>
-CacheRoot            <caller-selected local acquisition root>
```

`-GhExecutable` and `-Json` are test/automation plumbing. V1 has no `latest`, channel, semver range, or implicit update discovery. A future policy layer may choose an exact tag and invoke this primitive, but selection stays outside acquisition internals and outside the installer/updater.

The v1 production repository identity is pinned:

```text
slug:      AviBackToBlack/vllm-windows-native
repo id:   1361670545
node id:   R_kgDOUSlxkQ
HTTPS URL: https://github.com/AviBackToBlack/vllm-windows-native.git
```

A different slug or GitHub API repository identity is rejected. Repository rename/fork migration is therefore an explicit reviewed trust-policy change.

## Trust ordering

The independently supplied `allowed_signers` file is the only human release-signing trust root accepted by v1 acquisition. It is never downloaded from the target release, bundle, checkout, cache, or GitHub asset set.

```text
explicit repository + exact tag + out-of-band allowed_signers
        -> authenticated GitHub repository identity
        -> isolated exact-tag Git transport
        -> authorized annotated SSH-signed tag
        -> exact project commit
        -> canonical release manifest from that commit
        -> exact expected four asset names
        -> isolated downloads
        -> existing offline release verification
        -> immutable GitHub release + release attestation
        -> independent per-asset attestation verification
        -> atomic verified cache commit + provenance receipt
        -> exact local install/update handoff
```

No lower layer may bootstrap an authority required by an earlier layer.

## Exact repository and tag acquisition

Acquisition uses a fresh isolated Git repository inside the private staging generation. It does not use the caller's checkout, ambient remotes, or cached Git objects as authority.

Before transport it:

1. authenticates the requested repository with `gh api` and requires the pinned slug/id/node-id;
2. constructs the canonical HTTPS URL from policy rather than remote release metadata;
3. disables Git system/global configuration and relevant repository/config override environment variables for the isolated fetch;
4. disables terminal credential prompting;
5. starts from an empty repository with no local `url.*.insteadOf`, alternate object database, hooks, or remotes.

The fetch requests only the exact tag ref. It does not fetch `latest`, all tags, or a branch tip.

The authenticated GitHub tag-ref API must report an annotated tag object, and that object id must exactly match the annotated tag object fetched by Git. `Assert-VllmReleaseSignedTag` then verifies the fetched tag using the independently supplied trust root and returns the exact peeled project commit.

Lightweight, unsigned, wrong-signature-format, wrong-principal, wrong-fingerprint, wrong-commit, or otherwise unauthorized tags are rejected.

## Release-manifest resolution

The caller does not select a release-manifest path in production exact-tag mode.

After tag authentication, acquisition enumerates regular Git blobs below `manifests/release/` in the authenticated project commit. Exactly one runtime-release candidate must satisfy:

- supported schema/component/platform;
- `release/<manifest.release>` equals the exact requested tag;
- `self_path` equals the candidate path;
- existing `Get-VllmReleaseContext` validation succeeds against the authenticated commit.

Zero or multiple matches fail closed. This prevents a downloaded `release-index.json` from telling the consumer which project manifest should authenticate that same index.

## Remote release preflight

Before downloading bytes, acquisition reads the exact GitHub Release and requires:

- exact repository and tag identity;
- `draft=false`;
- `immutable=true`;
- exactly four assets;
- exact case-sensitive names derived from the authenticated release context: the declared wheel, `vllm-windows-native-<release>.zip`, `release-index.json`, and `SHA256SUMS`;
- no duplicate or case-colliding names;
- safe leaf filenames only.

Remote filename, reported size/digest, UI state, or successful download alone never marks an asset trusted.

## Isolated staging

Each attempt receives a fresh generation:

```text
<CacheRoot>\.staging\<generation-id>\
```

The generation contains only tool-owned acquisition state, an isolated Git repository, and the four downloaded assets. The final cache entry is never a download destination.

Downloads are requested one expected asset at a time from the exact repository/tag. The download directory must remain exactly the four expected regular non-reparse-point files and nothing else.

Interrupted/failed staging is non-authoritative. It may be preserved for evidence or guarded cleanup, but it is never a cache hit and is never handed to lifecycle tooling.

## Verification chain before cache commit

A generation becomes commit-eligible only after all of these succeed:

1. repository identity proof;
2. remote/fetched annotated tag-object equality;
3. signed-tag authorization and exact project commit binding;
4. release-manifest resolution from the authenticated commit;
5. exact immutable remote asset-set preflight;
6. complete isolated download;
7. `Assert-VllmOfflineRelease` against the authenticated commit and resolved manifest;
8. remote asset metadata comparison against locally verified asset identities;
9. `Invoke-VllmGitHubReleaseVerification` for exact repository/tag/tag-object and the four locally verified digests;
10. its independent `gh release verify-asset` call for each local asset.

Any failure leaves the final cache unchanged.

## Cache identity and layout

The verified cache is addressed by authenticated release identity, not by a mutable friendly filename:

```text
<CacheRoot>\
  verified\
    <repository-id>\
      <tag-object-sha>\
        artifacts\
          <wheel>
          vllm-windows-native-<release>.zip
          release-index.json
          SHA256SUMS
        acquisition-receipt.json
```

The canonical key is `(pinned repository id, authenticated annotated tag object sha)`. The receipt additionally binds the exact tag string, project commit, release id, release/runtime manifest digests, signer identity, and all four asset identities.

The tag string alone is not a cache key. An entry named only after `latest`, release id, wheel filename, or tag is not trusted.

Reacquisition of the exact same release may reuse a cache entry only after the complete receipt schema and all local artifact identities are revalidated. A cache hit does not skip local byte verification.

If the requested tag resolves to a different tag object, or any receipt/artifact identity conflicts, acquisition fails closed. It does not repair, replace, or silently adopt the conflicting entry.

## Provenance receipt

`acquisition-receipt.json` is schema v1 and is committed atomically with the artifact set. Required identity includes:

```text
schema_version
component
verified_utc
repository: slug, id, node_id, canonical_https_url
release: release, tag, tag_object, project_commit,
         release_manifest_path, release_manifest_sha256, runtime_manifest_sha256
signing: principal, key_fingerprint
artifacts: wheel/bundle/index/checksums filename, size_bytes, sha256
verification: offline_release_schema, github_release_attestation_schema,
              per_asset_attestation_count
```

The receipt contains no secrets, token, private signing material, copy of `allowed_signers`, or mutable URL treated as authority. `verified_utc` is audit metadata only and never participates in identity/idempotence.

## Atomic cache commit and interruption

For a new entry:

1. all verification completes in private staging;
2. the receipt is written and validated there;
3. no verification-required file is modified after final byte proof;
4. artifact set plus receipt is published to the final key by one same-filesystem atomic directory rename;
5. the committed entry is reopened and fully revalidated before success is returned.

A process death before rename leaves only non-authoritative staging. A process death after rename leaves a complete candidate that must pass ordinary cache-hit validation on retry.

If a destination appears concurrently, acquisition never overwrites it. It validates the winner as an exact cache hit or rejects the conflict.

Unknown conflicting final cache state is never deleted merely because an acquisition lock is held.

## Exact handoff to install/update

Successful acquisition returns exact local paths and identities including repository, tag, tag object, project commit, release id, cache entry, verified release manifest, wheel, bundle, index, checksums, and receipt.

The release manifest handed to lifecycle tooling comes from a verified local materialization of the authenticated distribution bundle/tagged commit, never from a mutable network checkout.

Install/update continue to receive the same explicit inputs:

```text
install.ps1 -ReleaseManifestPath <verified-local-manifest> -WheelPath <verified-local-wheel> ...
update.ps1  -ReleaseManifestPath <verified-local-manifest> -WheelPath <verified-local-wheel> ...
```

The existing installer/updater validation remains unchanged. Acquisition success never authorizes bypassing release-manifest, distribution-file, wheel, planner, staging, transaction, or recovery checks.

Bundle materialization for handoff uses existing archive/path-safety rules and is revalidated against the authenticated release contract before use.

## Required source-only regressions

Public PR CI remains source-only, using temporary local Git repositories and an injected fake `gh` state machine. The regression must cover at least exact tag success; wrong repository; lightweight/unsigned/bad signer tag; tag-object mismatch; project-commit mismatch; zero/multiple manifest matches; missing/extra/case-colliding assets; bad SHA/index/checksum; release-attestation failure; per-asset verification failure; stale/partial/poisoned cache; same-tag/different-object conflict; interrupted download; interrupted cache publication; retry; idempotent exact reacquisition; and install/update handoff.

The regression runs in PowerShell 7 and Windows PowerShell 5.1.

## Trusted SM-20 acceptance

Trusted/network acceptance is separate from public PR CI and runs only after implementation is reviewed and merged.

SM-20E uses a clearly non-production immutable one-shot fixture in the canonical repository and the same exact-tag acquisition/signature/offline-release/GitHub-release/per-asset verification path as production. It MUST NOT publish the public v1.0/GA release.

A reviewed acceptance slice may add a dedicated non-production release manifest plus deterministic synthetic wheel so the fixture can use a `release/<acceptance-id>` tag while exercising the canonical release format. The immutable fixture is preserved as audit evidence.

The trusted proof starts with an empty cache, completes acquisition and exact local handoff, then repeats from deliberately partial/untrusted state to prove retry/recovery.

## Implementation slices

- **SM-20 design gate** - this document.
- **SM-20A/B** - exact-tag network acquisition plus composition of existing tag/offline/attestation verifiers. They may be one PR because download without verification must never become a temporarily trusted interface.
- **SM-20C** - verified distribution materialization and exact handoff into install/update.
- **SM-20D** - no v1 implementation unless a concrete release blocker appears. `latest`/channel/semver policy is post-v1 because exact-tag acquisition satisfies the completion contract.
- **SM-20E** - trusted immutable non-production exact-tag acceptance, including interruption/retry evidence.

Each significant implementation slice stops at a merge gate. SM-20 never merges or publishes the production GA release.

## Explicit non-goals

SM-20 does not add multi-GPU/NCCL/TP/PP, FA3/FA4, service mode, GUI, WinGet/Chocolatey, model management, broader GPU support, future-upstream support, automatic `latest`, a background updater, or another signing format.

## Completion statement

SM-20 is complete only when the following is factually true:

> Given the exact canonical repository, an exact release tag, an independently pinned allowed-signers trust root, and empty or untrusted local acquisition state, the project can authenticate the repository and signed annotated tag, bind it to the exact project commit, download and independently verify the immutable four-asset release, atomically commit a provenance-backed local artifact set, recover safely from interruption, and hand exact verified local inputs to the existing installer/updater without weakening their validation.
