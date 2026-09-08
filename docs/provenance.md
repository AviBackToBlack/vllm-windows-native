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
