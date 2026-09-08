# ADR 0001: Upstream and Windows patch ownership

Status: Accepted

## Decision

`vllm-project/vllm` is the authoritative source upstream for this project.

This repository is not a downstream binary wrapper around `aivrar/vllm-windows-build`, `SystemPanic/vllm-windows`, `devnen/vllm-windows`, or another community distribution.

Community Windows implementations are research and reference sources. Their fixes may be studied, independently reimplemented, or incorporated when licensing permits and provenance is retained.

Project releases must be produced from:

1. an exact official vLLM upstream revision;
2. a project-owned, reviewable Windows patchset;
3. a project-owned reproducible build process;
4. project-published artifacts with recorded hashes and provenance.

## Consequences

- Deleting or abandoning a reference project must not break an already supported project release.
- Updating vLLM means rebasing/revalidating our Windows patchset against official upstream, not waiting for a reference project to publish a wheel.
- Reference-project binaries may be used temporarily for research or hardware validation, but they are not acceptable as the runtime artifact of a project release.
- Copied implementation material must preserve its applicable license and attribution.
