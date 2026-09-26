# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vllm-windows-native project
"""Trusted native-Windows RTX 5090 / SM120 NVFP4 GEMM regression."""
from __future__ import annotations
import importlib, os
os.environ.setdefault("CUDA_LAUNCH_BLOCKING","1")
import torch
from vllm import _custom_ops as ops

F8=torch.finfo(torch.float8_e4m3fn).max
F4=6.0
BS=16
SHAPES=((128,128,64),(128,128,128),(256,128,64),(128,256,128),(150,128,64),(128,128,96))
DTYPES=(torch.float16,torch.bfloat16)

def unpack(x,dtype):
    m,n=x.shape
    f=x.flatten()
    z=torch.stack((f&15,(f&240)>>4),dim=1).flatten()
    sign=(z&8).bool()
    mag=(z&7).long()
    lut=torch.tensor((0,.5,1,1.5,2,3,4,6),device=x.device)
    return (lut[mag]*torch.where(sign,-1.0,1.0)).reshape(m,n*2).to(dtype)

def unswizzle(sf,m,k):
    mt=(m+127)//128
    kt=(k+63)//64
    x=sf.reshape(1,mt,kt,32,4,4).permute(0,1,4,3,2,5)
    return x.reshape(mt*128,kt*4)[:m,:k//BS]

def dequant(x,sf,g,dtype):
    m,pk=x.shape
    k=pk*2
    v=unpack(x,dtype).reshape(m,k//BS,BS)
    s=unswizzle(sf.view(torch.float8_e4m3fn),m,k).float()/g
    return (v*s.unsqueeze(-1)).reshape(m,k).to(dtype)

def run(dtype,shape,device):
    torch.manual_seed(42)
    torch.cuda.manual_seed_all(42)
    m,n,pk=shape
    k=pk*2
    a=torch.randn((m,k),dtype=dtype,device=device)
    b=torch.randn((n,k),dtype=dtype,device=device)
    ag=((F8*F4)/a.flatten().amax()).float()
    bg=((F8*F4)/b.flatten().amax()).float()
    alpha=1.0/(ag*bg)
    af,asf=ops.scaled_fp4_quant(a,ag)
    bf,bsf=ops.scaled_fp4_quant(b,bg)
    expected=dequant(af,asf,ag,dtype)@dequant(bf,bsf,bg,dtype).t()
    actual=ops.cutlass_scaled_fp4_mm(af,bf,asf,bsf,alpha,dtype)
    torch.cuda.synchronize(device)
    torch.testing.assert_close(actual,expected.to(dtype),atol=.1,rtol=.1)
    d=(actual.float()-expected.float()).abs()
    return d.max().item(),d.mean().item()

def main():
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA required")
    device=torch.device("cuda:0")
    cap=torch.cuda.get_device_capability(device)
    if cap!=(12,0):
        raise RuntimeError(f"exact SM120 required, got {cap}")
    if not ops.cutlass_scaled_mm_supports_fp4(120):
        raise RuntimeError("native CUTLASS FP4 support predicate rejected SM120")
    native=importlib.import_module("vllm._C_stable_libtorch")
    print(f"device={torch.cuda.get_device_name(device)}")
    print(f"capability={cap}")
    print(f"native_extension={native.__file__}")
    print(f"CUDA_LAUNCH_BLOCKING={os.environ.get('CUDA_LAUNCH_BLOCKING')}")
    count=0
    with torch.inference_mode():
        for dtype in DTYPES:
            for shape in SHAPES:
                mx,mean=run(dtype,shape,device)
                count+=1
                print(f"PASS {count}/12 dtype={dtype} shape={shape} max_abs={mx:.6f} mean_abs={mean:.6f}")
    print("SM120_NVFP4_GEMM_ACCEPTANCE=PASS")
    print(f"cases={count}")

if __name__=="__main__":
    main()