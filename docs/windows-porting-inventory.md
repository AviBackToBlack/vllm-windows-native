# Windows Porting Inventory — vLLM v0.27.1

Status: Research baseline for the first native Windows port

This document classifies the Windows delta needed to turn the official
`vllm-project/vllm` tag `v0.27.1` into the first project-owned native Windows
runtime.

It is an inventory, not a patch. No item is accepted merely because another
Windows port implements it.

## Source baseline and references

Authoritative upstream:

- repository: `vllm-project/vllm`
- baseline tag: `v0.27.1`

Primary Windows reference:

- repository: `aivrar/vllm-windows-build`
- patch: `vllm-windows-v10.patch`
- declared base: official vLLM `v0.27.1`
- patch SHA-256: `4b6c9cd543414ef3ed1eb7fcbd7f39ce6be10bdc97d901261977ee905346c988`
- patch statistics: 72 files changed, 1,900 insertions, 287 deletions

Independent cross-check:

- repository: `SystemPanic/vllm-windows`
- reference branch: `vllm-for-windows`

`aivrar` and `SystemPanic` are research/reference sources only. See ADR 0001.
Their source and binaries are not upstream dependencies of this project.

## Classification

| Status | Meaning |
|---|---|
| `REQUIRED` | The initial native-Windows runtime is expected to need this capability. It still receives a project-owned implementation and test. |
| `IMPLEMENT_DIFFERENTLY` | The underlying problem is real, but the reference solution is too brittle, too limiting, or not appropriate for this project. |
| `OPTIONAL` | Useful Windows functionality, but not needed for first single-GPU OpenAI-compatible serving. |
| `DEFER` | Deliberately excluded from the first porting increment; revisit after baseline runtime validation. |
| `NOT_NEEDED_FOR_OUR_SCOPE` | Reference-project functionality that is not part of Windows portability. |
| `OBSOLETE_UPSTREAM` | Historical Windows fix that the selected official upstream no longer needs. |
| `VERIFY_IN_BUILD` | Likely compiler/toolchain compatibility fix whose necessity must be confirmed by an unpatched build or isolated compile failure. |

## Initial product scope

The first supported runtime is intentionally narrow:

- Windows 11 x64;
- NVIDIA CUDA;
- RTX 5090 / Blackwell SM120 as the primary validation GPU;
- one GPU;
- tensor parallel size 1;
- pipeline parallel size 1;
- data parallel size 1;
- upstream Python frontend first;
- OpenAI-compatible `vllm serve`;
- no WSL or Docker.

A feature is not part of the baseline merely because it is present in a
reference Windows wheel.

---

## A. Build-system enablement

| Area / files | Reference change | Status | Project decision |
|---|---|---|---|
| `setup.py` platform detection | Permit `VLLM_TARGET_DEVICE=cuda` on `win32` instead of forcing the unsupported/empty target | `REQUIRED` | Implement a minimal explicit Windows-CUDA gate. Do not broaden support to unvalidated Windows targets. |
| `CMakeLists.txt`, `cmake/utils.cmake` | Quote Python/CUDA paths and tolerate spaces in Windows paths | `REQUIRED` | Keep path handling fully quoted. Test with the normal `Program Files` CUDA location. |
| `setup.py` CMake arguments | Normalize Windows path separators where CMake command construction needs it | `REQUIRED` | Implement only where necessary; avoid global path rewriting. |
| CUDA toolkit selection | Force CMake CUDA roots to the selected `CUDA_HOME` | `REQUIRED` | Build manifest owns the exact toolkit. Fail on disagreement instead of silently selecting another installed CUDA. |
| Ninja discovery | Search the Python environment for `ninja.exe` and mutate PATH | `IMPLEMENT_DIFFERENTLY` | Our build driver owns the exact Ninja binary/path. Do not mutate persistent host PATH and do not rely on ambient discovery. |
| local precompiled `.pyd` wheel assembly | Package locally built native extensions rather than downloading Linux precompiled payloads | `REQUIRED` | Create a project-owned wheel assembly/release contract and validate archive contents before release. |
| generated FlashAttention Python payloads | Make copy logic path-independent on Windows | `REQUIRED` if FA2 is retained | Preserve generated Python payloads using `pathlib`-style path operations and validate wheel contents. |

### Required build contract

The build must never silently combine arbitrary host components. The eventual
runtime manifest must pin at least:

- official vLLM source revision;
- Python ABI;
- PyTorch version and CUDA build;
- CUDA Toolkit used for native compilation;
- Triton Windows version;
- MSVC toolset;
- Ninja version;
- target CUDA architectures;
- each project patch revision/hash.

---

## B. MSVC / nvcc language and toolchain compatibility

The aivrar patch carries a large set of C++/CUDA source changes that compensate
for GCC/Clang assumptions or MSVC/nvcc limitations. These are strong porting
candidates, but they should become small independently removable patches rather
than a copied mega-diff.

| Problem | Representative files | Status | Notes |
|---|---|---|---|
| MSVC standard preprocessor / `__cplusplus` reporting | `CMakeLists.txt` | `VERIFY_IN_BUILD` | `/Zc:preprocessor` and `/Zc:__cplusplus` are plausible requirements for current CUDA/CUTLASS headers. Confirm with the selected toolchain. |
| Windows SDK `small` macro collision | `CMakeLists.txt` / PyTorch headers | `VERIFY_IN_BUILD` | Reference uses `WIN32_LEAN_AND_MEAN` plus `/Usmall`. Keep only if reproduced. |
| CUDA 13 CCCL include path with spaces | `CMakeLists.txt` | `REQUIRED` | Use generator-safe include-directory handling instead of embedding a fragile quoted `-I` string. |
| MSVC optimizer ICE in CUDA host compilation | multiple CUDA TUs / Marlin | `VERIFY_IN_BUILD` | Reference disables host optimization with `/Od`. Treat as a toolchain workaround with a regression test and exact MSVC/CUDA applicability window. |
| missing POSIX/GNU identifiers/types | `cumem_allocator.cpp`, attention/fused kernels | `VERIFY_IN_BUILD` | Examples include `ssize_t`, `uint`, `__builtin_clz`, GNU attributes. Prefer portable standard/CUDA forms. |
| math macros / device math namespace differences | activation/attention kernels | `VERIFY_IN_BUILD` | Replace non-portable `M_*` or host-only forms only where current MSVC/nvcc actually rejects them. |
| C99 designated initializers | quantization CUDA | `VERIFY_IN_BUILD` | Prefer standard C++ initialization if required. |
| `__int128_t` / compiler-private integer names | quantization CUDA | `VERIFY_IN_BUILD` | Use explicit standard/CUDA types with equivalent layout; add compile/runtime tests where semantics matter. |
| alternative operator tokens (`and`, `or`) under nvcc/MSVC | quantization CUDA | `VERIFY_IN_BUILD` | Replacing with `&&`/`||` is low-risk if still required. |
| device variable template attributes | quantization utilities | `VERIFY_IN_BUILD` | Reference converts `quant_type_max_v<T>` variable template to function template. This is intrusive and must be tied to a reproduced compiler failure. |
| nested constexpr lambda dispatch | Mamba selective scan | `VERIFY_IN_BUILD` | Reference expands dispatch to explicit template branches. Keep isolated if needed. |
| MSVC C1061 from generated deep `else if` chains | Marlin generators | `VERIFY_IN_BUILD` | Prefer generator change producing equivalent flat mutually-exclusive `if` statements. |
| preprocessor directive inside macro argument | MoE TopK | `VERIFY_IN_BUILD` | Hoist platform preprocessor condition outside the macro if still present upstream. |
| GNU `always_inline` attribute | persistent TopK | `VERIFY_IN_BUILD` | Add a compiler-neutral macro rather than scattered platform conditionals. |

### Policy for compiler patches

Every compiler workaround must record:

1. exact upstream file/hunk it fixes;
2. exact compiler/CUDA failure or diagnostic;
3. smallest supported alternative implementation;
4. a test or build assertion proving it is still needed;
5. an easy removal path when upstream/toolchain changes.

---

## C. Optional CUDA extensions and external projects

Native Windows should not fail merely because an optional Linux-centric backend
cannot build or has no Windows package.

| Component | Baseline decision | Status |
|---|---|---|
| FlashAttention 2 | retain and build if the first toolchain validation succeeds | `REQUIRED` for intended optimized baseline |
| FlashAttention 3 | exclude from first Windows build | `DEFER` |
| FlashAttention 4 / CuTe DSL | exclude | `DEFER` |
| QuTLASS / QuACK / CUTLASS DSL helpers | exclude | `DEFER` |
| DeepGEMM | exclude from baseline | `DEFER` |
| FlashKDA | exclude | `DEFER` |
| FlashInfer | do not require for startup; Windows default must use a supported sampler/backend | `REQUIRED` behavior, dependency itself `DEFER` |
| fastsafetensors | exclude; Linux/io_uring-centric dependency | `DEFER` |
| TileLang / Linux-only helper packages | exclude from baseline dependency graph | `DEFER` |
| NCCL | not needed for the single-GPU baseline | `NOT_NEEDED_FOR_OUR_SCOPE` |

Missing optional extensions must be represented by explicit capability checks
and tested fallbacks, not by import-time crashes.

---

## D. Windows runtime: event loop, process model, signals and IPC

Independent Windows ports solve the same family of problems differently, which
confirms the problems while warning us not to cargo-cult one implementation.

| Area | Reference behavior | Status | Project direction |
|---|---|---|---|
| `uvloop` imports | aivrar falls back to asyncio/selector policy; SystemPanic uses `winloop` on Windows | `IMPLEMENT_DIFFERENTLY` | Establish one Windows event-loop abstraction and test pyzmq `add_reader` behavior. Avoid repeated import/fallback snippets across entrypoints. |
| multiprocessing method | force `spawn` on Windows | `REQUIRED` | Set deliberately and early; never depend on Unix `fork`. |
| asyncio signal handlers | fallback when `loop.add_signal_handler` / Unix signal semantics are unavailable | `REQUIRED` | Centralize Windows shutdown handling and test Ctrl+C / graceful server stop. |
| process-tree termination | avoid Unix-only signal assumptions; reference uses psutil/taskkill variants | `REQUIRED` | Prefer one owned process-tree termination helper with PID ownership checks. |
| ZMQ `ipc://` endpoints | aivrar uses loopback TCP on Windows | `REQUIRED` unless a tested Windows IPC transport replaces it | Use loopback TCP and reserve/bind ports safely; no externally exposed listener. |
| `zmq.Poller` and process sentinels | Windows HANDLEs are not ZMQ sockets | `REQUIRED` | Do not register process HANDLE sentinels in a ZMQ socket poller; use process state separately. |
| Unix-domain server option | reject clearly if `AF_UNIX` is unavailable/unsupported in the selected path | `REQUIRED` behavior | Fail clearly rather than crashing later. |
| `SO_REUSEPORT` assumptions | guard platform availability | `REQUIRED` | Capability-test the socket option. |
| `InprocClient` fallback | aivrar forces in-process core for a Windows path | `IMPLEMENT_DIFFERENTLY` | Do not permanently sacrifice architecture/performance before proving it is required. First make spawn/TCP/process monitoring work correctly. |

---

## E. Single-rank distributed initialization

This is a real Windows blocker area, but the aivrar solution should not be
copied as the final design.

### Reference finding

The aivrar port replaces the CPU Gloo path on Windows with a
`FakeProcessGroup` imported from PyTorch's internal testing package and a
`FileStore`, because its tested PyTorch Windows build could not create a usable
Gloo transport.

That is sufficient for single-rank bookkeeping but depends on a private testing
API.

SystemPanic takes a broader distributed approach and does not use the same fake
backend implementation.

### Decision

Classification: `IMPLEMENT_DIFFERENTLY`.

For world size 1, investigate whether vLLM can cleanly bypass creation of a
real CPU distributed process group where no collective communication is
required. Preferred order:

1. no unnecessary process group for world size 1;
2. a small project-owned single-rank backend/adapter if vLLM APIs require one;
3. only as a temporary experiment, PyTorch's private `FakeProcessGroup`.

The released runtime must not depend on `torch.testing._internal` unless there
is no viable public-API alternative and the dependency is explicitly pinned
and tested.

Multi-GPU Windows distributed support is outside the first release scope.

---

## F. Model loading / safetensors

The aivrar port includes a custom Windows safetensors iterator that uses
`numpy.memmap` and streams large tensors directly to the GPU in chunks to avoid
Windows commit-charge/pagefile failures such as `ERROR_COMMITMENT_LIMIT` /
Win32 error 1455.

Classification: `DEFER`.

Reason:

- this is a valuable robustness feature;
- it is not yet proven necessary on our target machine/runtime configuration;
- replacing the upstream model-loading path is large and correctness-sensitive.

Before porting it, create a reproducer covering:

- normal pagefile;
- constrained/small pagefile where practical;
- a large safetensors shard;
- peak committed memory and GPU destination correctness.

If upstream loading succeeds reliably, do not carry this patch merely because a
reference project does.

---

## G. Local CPU/filesystem KV offload

The aivrar patch makes substantial upstream KV-offload/tiering functionality
Windows-safe: shared mmap placement, binary file I/O, path sanitization, CUDA
DMA, cleanup semantics and a non-Triton block-table fallback.

Classification: `DEFER` for the first native serving milestone.

Reason: none of this is required to prove a correct single-GPU OpenAI-compatible
vLLM server on a 32 GB RTX 5090.

When revisited, split it into independent capabilities:

1. shared CPU mmap tier;
2. filesystem tier;
3. Windows CUDA DMA path;
4. path/namespace portability;
5. non-Triton block-table fallback.

Each should have Windows-specific tests and independent enable/disable behavior.

---

## H. Multi-TurboQuant

The aivrar patch adds six local KV-cache compression modes and their Triton
attention integration.

Classification: `NOT_NEEDED_FOR_OUR_SCOPE`.

These changes are feature development, not Windows portability. They must not be
present in the baseline Windows patch series.

If such functionality is ever desired, it belongs in a separately designed
feature with its own provenance, dependency and performance contract.

---

## I. Rust frontend and Rust tool parser

The aivrar patch ports Unix process/listener behavior to Windows and packages
`vllm-rs.exe` / Rust extension artifacts.

Official vLLM v0.27.1 does not enable the Rust frontend by default.

Classification: `DEFER`.

The first successful Windows runtime should use the normal Python frontend.
This removes Rust, `protoc`, Windows Rust process management and Rust packaging
from the critical path. Reintroduce the Rust frontend only after the baseline
wheel and server are stable.

---

## J. Blackwell SM120 — do not inherit the aivrar limitation

This is a dedicated investigation item because the primary target GPU is an RTX
5090.

### aivrar behavior

The v0.27.1 reference patch disables selected native SM120 CUTLASS paths on
Windows, including SM120 scaled-mm and NVFP4/MoE specializations, citing
MSVC x64 incompatibility with generated CUDA host stubs containing over-aligned
by-value parameters.

### independent evidence

The SystemPanic Windows branch contains CMake paths that build Blackwell SM120
scaled-mm and SM120 NVFP4 kernels rather than categorically disabling them.

This does **not** prove that SystemPanic's exact implementation compiles against
vLLM v0.27.1 with our selected MSVC/CUDA versions, but it proves that
"Windows => disable SM120" is not an acceptable architectural assumption.

### Decision

Classification: `IMPLEMENT_DIFFERENTLY` / mandatory build experiment.

Do not copy aivrar's `NOT WIN32` SM120 guards into the project baseline until an
isolated compile experiment proves that no supportable alternative exists.

The first build campaign must explicitly test:

1. official v0.27.1 SM120 scaled-mm sources under the selected Windows toolchain;
2. exact compiler diagnostic if they fail;
3. SystemPanic's relevant build/source approach and why it succeeds or differs;
4. whether the failure is caused by source, CUTLASS revision, generated host
   wrapper ABI, CMake flags, CUDA architecture spelling, or toolchain version;
5. FP8/NVFP4 correctness on RTX 5090 if compilation succeeds.

A project-owned Windows port targeted at RTX 5090 should prefer preserving
Blackwell-specialized kernels over silently falling back whenever practical.

---

## K. Historical fixes already obsolete upstream

The aivrar patch history itself documents Windows hunks removed after upstream
rewrites, including examples around old TopK initialization, an old `fcntl`
locking path and a previous KV-cache dtype assertion.

Classification: `OBSOLETE_UPSTREAM`.

This is evidence for maintaining a small patch series. Every rebase must ask
whether each individual patch still applies and is still necessary; successful
upstream removal is a feature, not a maintenance problem.

---

## Proposed first project patch series

Names are provisional; boundaries are the important part.

```text
patches/windows/v0.27.1/
  0001-build-enable-win32-cuda.patch
  0002-build-windows-paths-and-toolchain.patch
  0003-msvc-cuda-language-compat.patch
  0004-msvc-cutlass-compat.patch
  0005-win32-optional-extension-gating.patch
  0006-win32-event-loop-and-signals.patch
  0007-win32-process-and-zmq-ipc.patch
  0008-win32-single-rank-distributed.patch
  0009-win32-wheel-packaging.patch
```

Not part of the initial series:

```text
custom safetensors loader
CPU/filesystem KV offload
Multi-TurboQuant
Rust frontend
multi-GPU distributed support
blanket SM120 disable guards
```

The exact series will be refined after the first unpatched/partially patched
Windows build campaign.

## First build campaign acceptance questions

The build phase must answer these questions rather than merely "make it
compile":

1. What is the first failure of clean upstream v0.27.1 on Windows CUDA?
2. Which minimal patch removes that failure?
3. Which MSVC workarounds are still necessary with our exact compiler and CUDA
   versions?
4. Can all required SM120 scaled-mm / FP8 / NVFP4 sources compile?
5. Can the Python frontend start without Rust?
6. Can a world-size-1 runtime avoid a private FakeProcessGroup dependency?
7. Can engine IPC/process supervision work with spawn + loopback TCP without
   forcing the in-process engine as a permanent architecture?
8. Does a minimal supported model load and serve through `/health`, `/v1/models`
   and `/v1/chat/completions`?
9. What filesystem/registry/environment changes escape the managed project root?

Only observed failures should graduate `VERIFY_IN_BUILD` items into required
project patches.
