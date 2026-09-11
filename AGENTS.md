# AGENTS.md

Repository-wide instructions for coding agents and automation.

## Project intent

`vllm-windows-native` owns a native-Windows distribution/patchset against authoritative upstream `vllm-project/vllm`. Preserve the distinction between upstream source, project-owned Windows patches, manifests, and locally reconstructed build trees.

## Critical invariants

- Treat official `vllm-project/vllm` Git objects as the authoritative upstream source.
- Existing community Windows ports are research/reference sources, not implicit runtime or release dependencies.
- Preserve versioned patchsets and machine-readable manifests as the source of truth for accepted build/runtime pins.
- Do not silently broaden the accepted support matrix. The current accepted milestone is native Windows 11 x64, RTX 5090 / SM120, single GPU.
- Do not claim unsupported installer, multi-GPU, NCCL, TP/PP, or public-release capabilities.
- Keep bootstrap downloads pinned and integrity-verified; never replace hash/size verification with best-effort download behavior.
- Do not mutate a user's global Git/toolchain configuration when an invocation-local setting works.
- Keep secrets, downloaded toolchains, reconstructed source trees, build artifacts, wheels, models, caches, and local config out of Git.

## Validation

Public PR CI is source-level only: PowerShell parsing/static analysis and GitHub Actions security analysis. Do not execute untrusted public PR code on a home/self-hosted GPU/build machine.

Native CUDA/build/runtime acceptance belongs in an isolated trusted Windows environment and must use the repository's pinned manifests and validation records.

## Licensing

Do not modify or replace `LICENSE`, upstream notices, or licensing/provenance statements as part of unrelated work. Licensing changes require an explicit task and review.

## Governance

Keep GitHub Actions pinned to full commit SHAs with readable version comments. Do not weaken CI/security/governance policy without an explicit task and documented reason.
