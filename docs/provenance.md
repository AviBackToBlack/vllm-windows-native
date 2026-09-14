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

## Portable uv bootstrap pin

The accepted environment tool is uv `0.12.13` from `astral-sh/uv`, release source commit `0ebbd9274a55a8a53a13970be3b97e4209598e17`. The selected Windows x64 archive is `uv-x86_64-pc-windows-msvc.zip`, 17,612,025 bytes with SHA-256 `A86C9DC7BAD9B03F388583B7187C05FE9951C2E0D392217E8FD43D97787F6EC2`. GitHub artifact attestation was verified during acceptance and identifies the same source commit.

The archive contains exactly three regular top-level files: `uv.exe`, `uvw.exe`, and `uvx.exe`. Acceptance also observed a valid Authenticode signature on all three binaries with subject `CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC", L=San Francisco, S=California, C=US`. Runtime materialization is integrity-pinned by the archive size/SHA and validates `uv.exe --version` against version `0.12.13` and commit prefix `0ebbd9274`.

The machine-readable acquisition/layout contract is [`manifests/bootstrap/uv-0.12.13-windows-x86_64.json`](../manifests/bootstrap/uv-0.12.13-windows-x86_64.json).
## Runtime venv bootstrap contract

The accepted empty build/runtime environment is created by uv `0.12.13` from the managed CPython `3.13.15` base and is tied to milestone `v0.27.1-native-windows-single-gpu-sm120`. The machine-readable contract is [`manifests/bootstrap/venv-v0.27.1-windows-x86_64.json`](../manifests/bootstrap/venv-v0.27.1-windows-x86_64.json).

Creation is offline and unseeded: no `pip`, setuptools, wheel, Torch, Triton-Windows, or other package is installed by this layer. The pinned uv creates 17 files before the first interpreter validation; the validation run creates the expected `_virtualenv.cpython-313.pyc`, so the forensic receipt records 18 files on the accepted path. The venv must report CPython `3.13.15`, a 64-bit interpreter, uv `0.12.13`, the managed CPython root as `sys.base_prefix`, and `runtime/venv` as `sys.prefix`.