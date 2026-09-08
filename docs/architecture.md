# Architecture

Status: design in progress.

The project is a native Windows distribution and patchset layered on official `vllm-project/vllm`. It owns its Windows patchset, build outputs, lifecycle tooling, runtime manifests, and release provenance.

The runtime is intended to be strongly contained beneath a configurable install root, defaulting to `D:\AI\vLLM`, with no persistent host PATH/profile changes and no host CUDA toolkit requirement unless a future build mode explicitly requires one.

Detailed containment, state, update, and uninstall contracts will be defined before installation work begins.
