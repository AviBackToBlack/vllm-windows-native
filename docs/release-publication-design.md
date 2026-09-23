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

## Design questions to close before implementation

1. Exact release tag/identifier mapping and whether the first public release is prerelease vs stable.
2. Canonical bundle contents and deterministic archive format.
3. Machine-readable release index/checksum contract.
4. Human-controlled detached signing vs GitHub/Sigstore attestations vs both, and exact verification UX.
5. How accepted local GPU-built wheel bytes enter the publication flow without weakening provenance.
6. Draft/upload/verify/publish ordering and rollback behavior before publication.
7. Whether automatic installer/update acquisition ships in this milestone or follows as a separate slice.

## Proposed slices

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

Project releases use `release/<release-manifest release>` tags so they cannot collide with upstream vLLM tags already present in this repository. For the current milestone that means `release/v0.27.1-native-windows-single-gpu-sm120`. Changed accepted bytes require a new release identity/tag; moving a published release tag is forbidden.

The first public binary release is published as a GitHub prerelease. After an independent consumer acceptance downloads the published immutable assets, verifies the release/tag/attestation chain, and completes a clean install, the same immutable release may be promoted by clearing prerelease status and marking it latest. Promotion never changes the tag or asset bytes.

The release operator creates an annotated, cryptographically signed tag for the exact reviewed `main` commit. The existing hardware-backed SSH/Windows-Hello Git signing path is the intended operator-authorization mechanism. Publication tooling verifies the tag object and expected commit rather than trusting local Git configuration.

### Canonical publication assets

The v1 public asset set is the accepted wheel, `vllm-windows-native-<release>.zip`, `release-index.json`, and `SHA256SUMS`. The ZIP contains the canonical release manifest at its self path plus every file in the release manifest `files` array and nothing else. The wheel is not duplicated inside the ZIP.

`release-index.json` is versioned machine-readable root metadata binding project commit, release id/tag, release/runtime manifest digests, upstream and Windows patchset identities, wheel identity, distribution-bundle identity, checksum-file identity, and optional accepted-build evidence. It must not contain local absolute paths, machine/user names, tokens, or secrets.

`SHA256SUMS` is deterministic LF UTF-8. SM-19A fixes the exact non-circular representation in tests; the expected v1 shape covers the wheel, bundle, and release index.

### Deterministic bundle

Bundle creation uses explicit ZIP APIs rather than ambient `Compress-Archive` behavior. Entries are sorted, use canonical forward-slash relative names, are regular files only, and reject absolute paths, `..`, empty segments, ADS syntax, links/reparse points, and case-insensitive collisions. Archive metadata is normalized so identical inputs yield byte-stable output. The produced ZIP is reopened and every member is revalidated against the canonical source bytes.

### Publication transaction and immutability

Publication is draft-first: create an owned draft for the already-existing signed tag, upload the complete verified asset set, query and reverify the exact remote asset set, then publish. Repository release immutability is a prerequisite. A published release is never repaired by replacing bytes; corrections use a new release identity.

### Attestation truthfulness

GitHub release attestation is part of the published-release integrity chain. GitHub artifact/build attestations are used only when the attested workflow actually produced the subject artifact. A GitHub workflow that merely uploads a prebuilt local GPU wheel must not be described as its build provenance.

### Trust boundary

Public PR CI remains source-only. Trusted release preparation/publishing runs only from reviewed `main` in a trusted isolated environment or protected workflow and never uses `pull_request_target` to execute attacker-controlled PR code. Actions remain full-SHA pinned and final publication remains an explicit operator decision.

### Acquisition scope

Automatic installer/updater download from Releases is not required for SM-19A through SM-19D. SM-19E is an explicit decision gate: either add release-index-driven acquisition with its own cache/provenance contract or defer it to SM-20.

## External platform assumptions

As of this design gate, GitHub immutable releases lock the tag and release assets after publication and create a release attestation. GitHub artifact attestations use Sigstore/OIDC and are appropriate for artifacts actually produced by the attested workflow. These platform contracts must be rechecked immediately before SM-19C implementation.
## References

- GitHub Docs: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases
- GitHub Docs: https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations
