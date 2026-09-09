# vLLM Windows Native

Native Windows distribution and patchset for running vLLM on Windows 11 x64 without WSL or Docker.

> Status: first native-Windows single-GPU wheel candidate accepted on RTX 5090 / SM120; no supported public release yet.

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

## First accepted native-Windows candidate

The `v0.27.1` Windows patchset has completed pristine wheel, offline-generation, and OpenAI-compatible HTTP acceptance on an RTX 5090 / Blackwell SM120 system.

- validation record: [`docs/validation/v0.27.1-rtx5090-sm120.md`](docs/validation/v0.27.1-rtx5090-sm120.md)
- machine-readable manifest: [`manifests/runtime/v0.27.1-rtx5090-sm120.json`](manifests/runtime/v0.27.1-rtx5090-sm120.json)
- reproducible patch: [`patches/windows/v0.27.1/0001-native-windows-cuda-sm120.patch`](patches/windows/v0.27.1/0001-native-windows-cuda-sm120.patch)

The accepted scope is single-GPU native Windows serving. Multi-GPU/NCCL work is explicitly not part of this milestone.
