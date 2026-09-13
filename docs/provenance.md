# Provenance

Every tested runtime bundle must record, at minimum:

- official vLLM upstream repository and exact tag/commit;
- project Windows patchset revision;
- Python ABI/version;
- PyTorch version and CUDA runtime variant;
- Triton Windows version;
- all downloaded artifact URLs, effective URLs, sizes, and SHA-256 digests;
- build environment and build inputs for project-built artifacts;
- validation hardware and test results.

Community Windows ports may be used as research/reference sources. Any copied code or patch material must retain applicable license/copyright notices and be documented explicitly.

## Lifecycle safety reference

The Win32 final-path interop used by the lifecycle safety helpers is adapted from the author's separate `AviBackToBlack/unsloth-studio-windows-native` implementation. Exact tree/blob/file hashes and the retained MIT license notice are recorded in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## Portable CPython bootstrap pin

The accepted portable base interpreter is CPython `3.13.15` from `astral-sh/python-build-standalone` release `20260901`, source commit `4bb01f09aaf362c71e891be4a41cb6d6ddf830b3`. The selected Windows x64 `install_only_stripped` tar.gz asset is 21,936,514 bytes with SHA-256 `63D263AB0162F34A241A56DC5B283C22D6E131F5516117E6A921350C69BA7D4F`; GitHub artifact attestation was verified during acceptance.

The machine-readable acquisition/layout contract is [`manifests/bootstrap/cpython-3.13.15-windows-x86_64.json`](../manifests/bootstrap/cpython-3.13.15-windows-x86_64.json). The pinned archive contains exactly 3,303 regular files below a single `python/` root and no link entries.
