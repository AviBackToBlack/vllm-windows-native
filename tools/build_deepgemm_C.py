# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""Build DeepGEMM's `_C` pybind11 extension for <TARGET_PY>.

Driven from cmake/external_projects/deepgemm.cmake. The driver runs against
the build interpreter's torch; <TARGET_PY> is only consulted for INCLUDEPY
and SOABI, so target venvs don't need torch installed.

Usage: python build_deepgemm_C.py <DEEPGEMM_SRC_DIR> <OUTPUT_DIR> <TARGET_PY>
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import torch
from torch.utils import cpp_extension

if len(sys.argv) != 4:
    sys.exit(f"usage: {sys.argv[0]} <SRC> <OUT> <TARGET_PY>")

src = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
target_py = sys.argv[3]
out.mkdir(parents=True, exist_ok=True)

info = json.loads(
    subprocess.check_output(
        [
            target_py,
            "-c",
            "import sys, sysconfig, json; "
            "print(json.dumps({'EXT_SUFFIX': sysconfig.get_config_var('EXT_SUFFIX'), "
            "'INCLUDEPY': sysconfig.get_config_var('INCLUDEPY'), "
            "'VERSION_NODOT': f'{sys.version_info.major}{sys.version_info.minor}', "
            "'GIL_DISABLED': bool(sysconfig.get_config_var('Py_GIL_DISABLED'))}))",
        ]
    ).decode()
)

cuda_home = cpp_extension.CUDA_HOME
if cuda_home is None:
    sys.exit("CUDA_HOME not found; cannot build DeepGEMM _C")
# CCCL lives outside the standard CUDAToolkit search (mirrors DeepGEMM's setup.py).
includes = [
    info["INCLUDEPY"],
    f"{cuda_home}/include",
    f"{cuda_home}/include/cccl",
    str(src / "csrc"),
    str(src / "deep_gemm/include"),
    str(src / "third-party/cutlass/include"),
    str(src / "third-party/cutlass/tools/util/include"),
    str(src / "third-party/fmt/include"),
    *cpp_extension.include_paths(device_type="cuda"),
]

cusolver_root = os.environ.get("VLLM_CUSOLVER_ROOT")
if cusolver_root:
    cusolver_include = Path(cusolver_root) / "include"
    if not (cusolver_include / "cusolverDn.h").is_file():
        sys.exit(
            f"VLLM_CUSOLVER_ROOT={cusolver_root} does not contain include/cusolverDn.h"
        )
    includes.append(str(cusolver_include))

if os.name == "nt":
    # DeepGEMM's binding uses pybind11/torch_python and is CPython-version
    # specific. Build it with the active MSVC toolchain on native Windows.
    python_lib_dir = Path(info["INCLUDEPY"]).parent / "libs"
    python_lib = (
        f"python{info['VERSION_NODOT']}"
        f"{'t' if info['GIL_DISABLED'] else ''}.lib"
    )
    library_dirs = [
        *cpp_extension.library_paths(device_type="cuda"),
        str(python_lib_dir),
        f"{cuda_home}/lib/x64",
    ]
    library_dirs = list(dict.fromkeys(library_dirs))
    cmd = [
        os.environ.get("CXX", "cl.exe"),
        "/nologo", "/LD", "/std:c++20", "/O2", "/EHsc", "/MD", "/bigobj",
        "/Zc:__cplusplus", "/permissive-", "/utf-8",
        "/DNOMINMAX", "/DWIN32_LEAN_AND_MEAN",
        "/DTORCH_API_INCLUDE_EXTENSION_H", "/DTORCH_EXTENSION_NAME=_C",
        *(f"/I{p}" for p in includes),
        str(src / "csrc/python_api.cpp"),
        "/link",
        *(f"/LIBPATH:{p}" for p in library_dirs),
        "torch.lib", "torch_python.lib", "torch_cpu.lib", "torch_cuda.lib",
        "c10.lib", "c10_cuda.lib", "cudart.lib", "nvrtc.lib",
        "cublas.lib", "cublasLt.lib", python_lib,
        f"/OUT:{out / f'_C{info['EXT_SUFFIX']}' }",
    ]
else:
    cmd = [
        os.environ.get("CXX", "g++"),
        "-shared", "-fPIC", "-std=c++20", "-O3", "-g0",
        "-Wno-psabi", "-Wno-deprecated-declarations",
        "-DTORCH_API_INCLUDE_EXTENSION_H", "-DTORCH_EXTENSION_NAME=_C",
        f"-D_GLIBCXX_USE_CXX11_ABI={int(torch.compiled_with_cxx11_abi())}",
        *(f"-I{p}" for p in includes),
        str(src / "csrc/python_api.cpp"),
        *(f"-L{p}" for p in cpp_extension.library_paths(device_type="cuda")),
        f"-L{cuda_home}/lib64",
        "-ltorch", "-ltorch_python", "-ltorch_cpu", "-ltorch_cuda",
        "-lc10", "-lc10_cuda", "-lcudart", "-lnvrtc",
        "-o", str(out / f"_C{info['EXT_SUFFIX']}"),
    ]
print("[build_deepgemm_C] " + " ".join(map(str, cmd)), flush=True)
subprocess.check_call(cmd)