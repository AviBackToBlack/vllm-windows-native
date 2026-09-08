# vLLM Windows Native

Native Windows distribution and patchset for running vLLM on Windows 11 x64 without WSL or Docker.

> Status: early architecture and validation work. No supported release yet.

## Project intent

This repository treats [`vllm-project/vllm`](https://github.com/vllm-project/vllm) as the authoritative upstream. Existing community Windows ports are research and reference sources, not runtime or release dependencies.

The project aims to provide:

- native Windows 11 x64 execution;
- reproducible, versioned Windows patchsets against official vLLM releases;
- project-owned Windows wheels and release artifacts;
- strongly contained runtime state under a configurable install root;
- explicit provenance, hashes, and update state;
- safe install, start, doctor, update, and uninstall lifecycle scripts.

## Current target

Initial development target:

- Windows 11 x64
- NVIDIA RTX 5090 / Blackwell SM120
- single GPU first
- default install root: `D:\AI\vLLM`

See [`docs/decisions/0001-upstream-and-patch-ownership.md`](docs/decisions/0001-upstream-and-patch-ownership.md) once the bootstrap commit lands.
