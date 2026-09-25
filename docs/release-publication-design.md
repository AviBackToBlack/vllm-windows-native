# SM-19 release publication and signing design

Status: design gate for issue #25. No production release is created by this document.

## Goal

Design and implement the first publishable, verifiable release pipeline for the native-Windows vLLM distribution.

SM-18 completed safe install/update/uninstall lifecycle semantics. The remaining product gap is release engineering: the accepted project wheel is still caller-supplied and there is no project-owned release bundle, signing/attestation contract, or publication path.

## Critical invariants

- Public PR CI remains source-only. Never execute untrusted PR code on the trusted Windows/GPU build environment.
- Publication consumes an already accepted wheel; it must not silently rebuild or substitute a merely equivalent-looking artifact.
- The canonical publishable wheel identity is the one referenced by the accepted runtime/release contracts (`66201EF4566E7B312D3663786EB03FBA5F67E37981118322C581EDDAF98958B6` at the current v0.27.1 milestone). The older `manifests/runtime/v0.27.1-rtx5090-sm120.json` build artifact (`EA763A...`) remains historical build evidence, not publication authority.
- Release identity/tag, project commit, release manifest digest, wheel filename/size/SHA-256, distribution payload identities, and provenance must form one explicit chain.
- Publication must fail closed on dirty worktrees, tag/commit mismatch, manifest drift, artifact mismatch, unexpected bundle members, or pre-existing mutable/conflicting release state.
- No secrets or signing material are committed to the repository.
- GitHub Actions remain pinned to full commit SHAs.
- Published assets should be immutable after release publication.

## Design questions resolved by this gate

1. Exact release tag/identifier mapping and whether the first public release is prerelease vs stable.
2. Canonical bundle contents and deterministic archive format.
3. Machine-readable release index/checksum contract.
4. Human-controlled detached signing vs GitHub/Sigstore attestations vs both, and exact verification UX.
5. How accepted local GPU-built wheel bytes enter the publication flow without weakening provenance.
6. Draft/upload/verify/publish ordering and rollback behavior before publication.
7. Whether automatic installer/update acquisition ships in this milestone or follows as a separate slice.

## Planned slices

- **SM-19 design gate** — release authority, trust boundaries, bundle/signing/publication contract, acceptance plan.
- **SM-19A** — deterministic release bundle/index builder + offline verifier; no GitHub mutation.
- **SM-19B** — signing/attestation contract and verification tooling.
- **SM-19C** — guarded draft GitHub Release publication and immutable-release integration.
- **SM-19D** — trusted end-to-end publication acceptance using non-production/draft fixtures.
- **SM-19E** — optional installer/updater release acquisition only if the design gate keeps it in scope; otherwise split to the next milestone.

Each significant slice stops at a merge gate.

## Acceptance

A consumer must be able to start from a release/tag plus downloaded assets and independently prove that the wheel and project distribution bundle are exactly the accepted artifacts for that project commit and release manifest, without trusting filenames alone.
## Accepted v1 decisions

### Release tag and identity

Project releases use `release/<release-manifest release>` tags so they cannot collide with upstream vLLM tags that may be fetched into local clones during source reconstruction. For the current milestone that means `release/v0.27.1-native-windows-single-gpu-sm120`. Changed accepted bytes require a new release identity/tag; moving a published release tag is forbidden.

The first public binary release is published as a GitHub prerelease. GitHub immutable-release semantics lock the tag and asset bytes but explicitly still permit changing prerelease/latest metadata. After an independent consumer acceptance downloads the published immutable assets, verifies the release/tag/attestation chain, and completes a clean install, the same immutable release may therefore be promoted by clearing prerelease status and marking it latest. Promotion never changes the tag or asset bytes.

The release operator creates an annotated, cryptographically signed tag for the exact reviewed `main` commit. The existing hardware-backed SSH/Windows-Hello Git signing path is the intended operator-authorization mechanism. SM-19B creates the exact versioned trust-root path `config/release-allowed-signers` with the sole v1 principal `vllm-windows-native-release`. The initial authorized public key is the GitHub SSH signing key whose SHA-256 fingerprint is `SHA256:ga7J6BbUAgsSVju3a6RZU4Vw4/7wvn2xL/MTLWy77ng` (ECDSA-SK); no other key is authorized by v1. Publication verification first checks that the trust-root file contains exactly that principal/key identity, then uses invocation-local Git configuration (`git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=<absolute trust-root path> verify-tag <tag>`) and requires the tag to resolve to the expected commit. It MUST NOT rely on ambient/global Git signing configuration or accept a different principal/key merely because the signature is cryptographically valid. Consumer tooling requires an explicitly supplied/pinned copy of this trust root or equivalent out-of-band pin and never bootstraps trust from the unverified target release bundle itself. Signer rotation is a separately reviewed trust-policy change: the new key must be committed to the default branch before any release uses it, and an already trusted signer must authorize that trust-root transition; silent key replacement during publication is forbidden.

### Canonical publication assets

The v1 public asset set is the accepted wheel, `vllm-windows-native-<release>.zip`, `release-index.json`, and `SHA256SUMS`. The ZIP contains the canonical release manifest at its self path plus every file in the release manifest `files` array and nothing else. The wheel is not duplicated inside the ZIP. Bundle bytes are sourced from Git objects at the exact project commit recorded by the release index, not from mutable worktree files. After the signed project tag exists, publication and offline verification resolve `<tag>^{commit}`, require it to equal `release-index.json.project_commit`, read the release manifest and its referenced runtime manifest from that commit (`git show <commit>:<path>` or equivalent plumbing), and require those canonical blob bytes/digests to match the release index and the corresponding bundle members. Any tagged-commit/blob mismatch is a hard refusal.

`release-index.json` is versioned machine-readable root metadata binding project commit, release id/tag, release/runtime manifest digests, upstream and Windows patchset identities, wheel identity, distribution-bundle identity, the checksum-file name/format (not its digest), and optional accepted-build evidence. It must not contain local absolute paths, machine/user names, tokens, or secrets.

`SHA256SUMS` is deterministic LF UTF-8 and covers exactly the wheel, distribution bundle, and `release-index.json`; it never contains a checksum for itself. The release index records only the expected checksum-file name/format, so generation is acyclic. The published immutable GitHub release attestation binds `SHA256SUMS` itself together with the other release assets. Offline preparation verifies the exact canonical bytes of all four assets and builds them in a private sibling staging directory. The supplied wheel is pinned read-only before validation/copy, and the wheel, bundle, index, and checksum destinations are each CREATE_NEW/no-follow files whose writer streams deny concurrent writers through the final pre-publication byte proof. The parent and staging directory objects remain pinned by DELETE-capable handles that do not share delete/rename access; this intentionally serializes preparations sharing one parent directory. After the final stream-based identity proof, the four child streams are closed, no further preparation write is permitted, and the directory is renamed to the requested final path through its still-open directory handle. Any mutation after child-stream close is caught by the complete post-publication verifier and triggers the same guarded quarantine/cleanup path. Publication is not considered successful at that rename boundary: the final paths must still match the pre-publish filesystem object identities and the complete offline verifier must pass again. A post-publish mismatch triggers best-effort handle-based quarantine plus guarded cleanup before the original error is returned. The final path must be absent when preparation starts and is never used as a build/cleanup workspace; its parent must already exist and pass regular-directory/canonical-path checks. A pre-existing final path is refused without deletion, and if the path appears before publication, preparation fails closed and leaves that foreign path untouched. The persistent preparation sidecar is likewise treated as owned coordination metadata only after its schema/operation/root marker is validated; unrecognized existing bytes are preserved and rejected.

### Deterministic bundle

Temporary Git snapshots used to source canonical blob bytes are bound to the created temp-root physical/object identity and cleaned with explicit no-follow recursion, so Windows PowerShell 5.1 never traverses a junction/symlink target during cleanup. Release-owned files are not archive-extracted into that tree: each requested path is resolved to its tagged-commit Git blob, every missing parent is created/validated one segment at a time under pinned directory handles, and the blob bytes are streamed directly from `git cat-file` into a CREATE_NEW no-follow file handle. The materialized Git blob remains attached to its CREATE_NEW stream and all manifest parsing, hashing, CRC calculation, and bundle copying consume that pinned stream directly; no archive extraction or path-based re-open is required for source bytes.

Bundle creation uses an explicit canonical ZIP profile rather than ambient `Compress-Archive` behavior. Entries are sorted with ordinal comparison, use canonical UTF-8 forward-slash relative names, are regular files only, and reject absolute paths, `..`, empty segments, ADS syntax, links/reparse points, and case-insensitive collisions. V1 uses ZIP STORE (method 0, no compression), fixed ZIP/DOS wall-clock fields for `1980-01-01 00:00:00` (DOS time `0`, DOS date `33`; ZIP carries no timezone), no file comments or extra fields beyond what the canonical writer requires, and fixed external attributes. Those choices avoid runtime-dependent Deflate output. The produced ZIP is reopened and every member is revalidated against the tagged-commit blob bytes. Fixture acceptance requires byte-identical archive SHA-256 for repeated builds and across the supported PS7/Windows PowerShell 5.1 builder paths before both are advertised as builders.

### Publication transaction and immutability

Publication is draft-first and retry-safe. A new draft body contains an ownership marker binding schema v1, release id, signed tag, and project commit. On retry, an existing draft is resumable only when that marker and tag/commit identity match exactly. Remote release assets are queried through the GitHub API and their `name`, `size`, and `digest` fields must be a subset of the expected four-asset plan with exact matching identities; matching assets are left untouched and only missing assets may be uploaded. Any extra asset, wrong digest/size, missing ownership marker, conflicting tag/release, or published-but-nonmatching release causes refusal; default retry never deletes or clobbers an asset. Resetting an owned failed draft is a separate explicit `ShouldProcess`-guarded recovery action that first reproves the ownership marker and confirms the release is still a draft. Once the complete remote asset set is exact, the draft may be published. Repository release immutability is a prerequisite. A published exact-match release is treated as idempotently complete; a published mismatch is never repaired by replacing bytes and requires a new release identity.

### Attestation truthfulness

GitHub release attestation is part of the published-release integrity chain. Verification is exact: `gh release verify <tag> --format json` must succeed for the expected annotated tag object, while signed-tag verification separately requires that tag to peel to the expected project commit, and `gh release verify-asset <tag> <local-path>` must succeed separately for the wheel, distribution ZIP, `release-index.json`, and `SHA256SUMS`. The attested asset-name/digest set must contain exactly those four published assets. Local SHA-256 digests for the wheel, ZIP, and release index must also equal their `SHA256SUMS` entries and the identities recorded by the release index; the local `SHA256SUMS` digest must equal its attested asset digest. A valid release attestation for a different asset set is therefore insufficient. GitHub artifact/build attestations are used only when the attested workflow actually produced the subject artifact. A GitHub workflow that merely uploads a prebuilt local GPU wheel must not be described as its build provenance.

### SM-19B verification surface

SM-19B is verification-only. It versions `config/release-allowed-signers` as the publication-side v1 policy, but consumer verification requires an explicitly supplied/pinned `-AllowedSignersPath`; the verifier does not silently trust the copy from the target checkout or release bundle. `VerifySignedTag` requires an annotated tag, exact `<tag>^{commit}` equality, the expected principal/key fingerprint, and an SSH signature accepted by invocation-local Git signing configuration. The verification path disables system/global Git configuration for that invocation and explicitly selects `ssh-keygen`, the allowed-signers file, an empty revocation source, and `fully` minimum trust.

`VerifyPublished` composes the existing exact-four offline verifier with `VerifySignedTag`, `gh release verify <tag> --format json`, and one `gh release verify-asset` call per local asset. The verified release statement must be the GitHub release predicate `https://in-toto.io/attestation/release/v0.2`, bind repository `AviBackToBlack/vllm-windows-native`, the exact annotated release tag object, and contain exactly one package subject plus exactly the four expected case-sensitive asset names with their local verified SHA-256 digests. The signed-tag verifier separately peels that authenticated tag object to the exact reviewed project commit. This slice performs no production signing and no GitHub Release mutation. The package subject URI uses the canonical percent-encoded PURL version component for the tag, and the verified predicate purl must equal that package subject URI exactly.

### SM-19C guarded publication surface

Implementation rechecked GitHub's immutable-release contract on 2026-09-24. The publication client sends REST requests with API version `2026-03-10`. `StageDraft` and `PublishDraft` refuse all release mutation unless repository immutable releases are enabled, authenticated GitHub reports `main` at the exact reviewed project commit, and the remote release ref is the exact annotated tag object already authenticated by `VerifySignedTag`. The tooling never creates or signs the production tag and never changes the repository immutability setting.

Draft discovery uses the authenticated releases list rather than the by-tag release endpoint so owned drafts are visible before publication. A new draft is created with `gh release create --draft --prerelease --latest=false --verify-tag` and a schema-v1 ownership marker as the first body line. Retry adoption requires exact repository/release/tag/project-commit marker identity. Remote assets are an exact-subset transaction: each present asset must match one canonical case-sensitive name, byte size, uploaded state, and `sha256:` digest; matching assets are preserved and only missing assets are uploaded. The default path never uses `--clobber`, deletes an asset, or repairs a published mismatch.

`PublishDraft` is a separate `ShouldProcess`-guarded operator action. It repeats local offline verification, signed-tag verification, GitHub immutable/main/tag-object preflights, exact remote four-asset verification, and local asset size/digest checks immediately before publishing the draft as a prerelease. After the draft flag is cleared, success additionally requires GitHub to report the release immutable and the existing `VerifyPublished` release-attestation plus per-asset attestation chain to pass. An exact already-published immutable release is idempotently complete; later prerelease/latest metadata promotion does not alter asset/tag ownership.

The immediate post-publish attestation proof uses a short bounded retry window for GitHub propagation. Ordinary verification stays single-pass so eventual consistency is not hidden outside the publication transition.

`ResetDraft` is a separate `ShouldProcess`-guarded recovery action. It rediscovers the release, reproves the exact ownership marker, and deletes only an exact marker-owned draft. Published releases are never reset, deleted, or repaired by this tooling.

Reset authority is exact schema-v1 ownership plus draft state, not mutable prerelease metadata, so an externally edited owned draft remains recoverable while any published release remains untouchable.

SM-19C tests use an injected fake `gh` state machine and perform no GitHub mutation. Production signing, repository-setting mutation, and real publication remain outside the implementation PR and are exercised only after review in the trusted SM-19D/operator flow.

### SM-19D trusted end-to-end acceptance surface

SM-19D performs the first real GitHub publication transaction, but only with a clearly non-production one-shot fixture. The implementation PR itself remains source-only: its PowerShell regression uses a temporary local Git repository, a generated software SSH key, fake GitHub reads, and no remote release mutation. The real acceptance runs only after review and merge from clean main.

The repository immutable-release setting is a deliberate operator prerequisite rather than a capability of the release tooling. It was enabled before the trusted acceptance run and remains enabled for production readiness. Platform semantics were rechecked on 2026-09-25: drafts may still be modified or deleted; publication locks the release tag and asset bytes and creates a release attestation; deleting an immutable release does not make its tag name reusable. SM-19D therefore uses a unique acceptance/sm19d/<one-shot-id> annotated tag and never recycles acceptance identities.

Prepare creates exactly four synthetic non-production assets in an isolated workspace outside the repository, validates the one-shot id as lowercase and git-ref-safe, generates an ephemeral Ed25519 software key, signs an annotated tag at the exact reviewed main commit, verifies that tag through the same signed-tag verifier with an acceptance-only principal/fingerprint, deletes the private key, and atomically persists only public trust material plus asset identities and the tag object in acceptance-state.json. A subsequent operator-mode harness invocation sanitizes any residual safe regular private-key file left by an abnormal process termination before reading or mutating acceptance state. Read-only Verify never deletes local material; it instead refuses a workspace that still contains residual private signing material. The production hardware-backed key and config/release-allowed-signers are not used.

ExerciseDraft pushes the exact authenticated one-shot tag to the explicit canonical https://github.com/AviBackToBlack/vllm-windows-native.git destination, not to a checkout remote name. Before push it requires that the explicit URL is not rewritten by git insteadOf and refuses any configured pushInsteadOf rewrite. It then executes the real StageDraft transaction, repeats StageDraft to prove retry idempotence, executes the exact marker-owned ResetDraft recovery path, and proves the draft is absent. The remote tag remains for the later publication phase. Publish is a separate ShouldProcess boundary and refuses to run until that real draft round trip has completed. It recreates the exact owned draft, publishes prerelease/latest=false, requires immutable=true, and verifies the release attestation plus each of the four local assets. Verify repeats that attestation proof without requiring remote main to remain at the historical publication commit and is strictly read-only with respect to acceptance-state.json. If publication succeeded remotely but local state persistence failed, RecoverPublishedState repeats the complete immutable proof and only then atomically reconciles the local state to the verified remote release.

Published SM-19D fixtures are preserved as audit evidence and are never reset, repaired, clobbered, or deleted by the acceptance harness. acceptance-state.json is updated with the repository atomic JSON writer so a failure before the replacement boundary leaves the prior valid state intact and retries remain possible after remote mutations. The state file is still trusted-workspace coordination metadata, not a cryptographic proof against a malicious or compromised same-rights process; that stronger attacker is explicitly outside the project trust boundary below. Pre-publication failures may be recovered with the same exact marker-owned ResetDraft primitive. The fixture asset bytes are intentionally synthetic opaque publication inputs: SM-19A already owns canonical production-bundle correctness, while SM-19D isolates and proves the GitHub transaction, immutable-release boundary, signed-tag authorization, and release-attestation transport end to end.

The final StageDraft re-fetch now also requires draft=true and immutable=false before reporting draft success. This closes the last review nit where a concurrent actor could publish the owned draft between the earlier state check and the final fetch and leave only a stale local state label.

### Trust boundary

Public PR CI remains source-only. Trusted release preparation/publishing runs only from reviewed `main` in a trusted isolated environment or protected workflow and never uses `pull_request_target` to execute attacker-controlled PR code. Actions remain full-SHA pinned and final publication remains an explicit operator decision.

SM-19 release tooling is not a sandbox against a malicious or compromised process running with the same (or stronger) filesystem rights as the trusted release operator. The release workspace and its parent directory are prerequisites of the trust boundary: they must be isolated from untrusted local writers by the runner boundary and operating-system permissions. The handle/path/identity guards in SM-19A are fail-closed defenses against stale state, accidental interference, reparse/path surprises, and concurrency among cooperating release invocations; they do not claim perpetual immutability against an adversary that can create/delete/rename arbitrary entries in the workspace. Offline verification proves the observed four-asset set at its acceptance boundary; subsequent external mutation invalidates that verification and must be prevented by the trusted workspace or detected by a later verification/attestation step.

### Acquisition scope

Automatic installer/updater download from Releases is not required for SM-19A through SM-19D. SM-19E is an explicit decision gate: either add release-index-driven acquisition with its own cache/provenance contract or defer it to SM-20.

## External platform assumptions

As of this design gate, GitHub immutable releases lock the tag and release assets after publication and create a release attestation. GitHub artifact attestations use Sigstore/OIDC and are appropriate for artifacts actually produced by the attested workflow. These platform contracts must be rechecked immediately before SM-19C implementation.
## References

- GitHub Docs: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases
- GitHub Docs: https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations
- Git Docs: https://git-scm.com/docs/git-config (gpg.ssh.allowedSignersFile)
- GitHub REST Docs: https://docs.github.com/en/rest/releases/assets (release asset digest)
- GitHub CLI: https://cli.github.com/manual/gh_release_verify and https://cli.github.com/manual/gh_release_verify-asset
