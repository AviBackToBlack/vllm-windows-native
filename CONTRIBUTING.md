# Contributing

Thanks for contributing to `vllm-windows-native`.

## Scope

Keep changes explicit about upstream version, Windows patch ownership, toolchain/runtime pins, and the support matrix they affect.

## Before opening a pull request

- Run the repository's PowerShell source-validation checks.
- Keep upstream source and project-owned patches/manifests clearly separated.
- Preserve integrity verification for downloaded bootstrap inputs.
- Add or update validation evidence when changing accepted build/runtime behavior.
- Do not claim support that has not passed the corresponding native-Windows acceptance.
- Do not commit secrets, local configuration, toolchains, reconstructed source trees, models, wheels, caches, or build artifacts.
- Do not modify licensing/provenance text as part of unrelated work.
- Resolve review conversations and ensure required CI/security checks are green before merge.

GPU/native-build acceptance is intentionally separate from public PR CI and must run only in a trusted isolated environment.

## Security issues

Do not open public issues for suspected vulnerabilities. Follow `SECURITY.md` or use GitHub private vulnerability reporting when available.
