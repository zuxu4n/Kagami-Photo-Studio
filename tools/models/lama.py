"""lama.py CHECKPOINT LAMA_SRC WORKDIR OUT.mlpackage [SAMPLE_IMAGE]

LaMa big-lama (Apache-2.0, advimman/lama) as one Core ML package with a function per working size, 512 ("main",
the default) and 1024 ("lama1024", picked with MLModelConfiguration.functionName for large removals), sharing one
copy of the weights. Needs iOS 18.

CHECKPOINT is big-lama/models/best.ckpt. LAMA_SRC holds LaMa's own ffc.py, base.py and squeeze_excitation.py
(fetch_weights.sh downloads them at a pinned commit); their training-only imports are replaced by small stubs
below and nothing else from LaMa runs. Two FP16 fixes: every BatchNorm is folded to a scale and shift (LaMa's
running variances reach ~4.8e5, past the FP16 maximum), and the FFTs are pre-scaled so the DFT matmuls Core ML
lowers them to stay in range. With SAMPLE_IMAGE, each size is checked against PyTorch FP32 on a crop of it with a
hole in the middle (PSNR).
"""
import collections
import importlib.util
import json
import math
import os
import re
import sys
import types
import typing

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from esrgan import center_crop, psnr  # noqa: E402

SIZES = (512, 1024)


def _stub(name, **attrs):
    m = types.ModuleType(name)
    m.__dict__.update(attrs)
    m.__path__ = []  # allow submodules
    sys.modules[name] = m
    return m


def _load(modname, path):
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[modname] = mod
    spec.loader.exec_module(mod)
    return mod


def _fourier_forward_fp16_safe(self, x):
    """FourierUnit.forward with identical math to norm='ortho', but the 1/sqrt(N) scaling is applied to the
    *inputs* of both transforms. Core ML lowers the FFTs to DFT matmuls and scales after summing, which
    overflows FP16. Pre-scaling keeps every intermediate sum in range."""
    batch = x.shape[0]
    if self.spatial_scale_factor is not None:
        orig_size = x.shape[-2:]
        x = F.interpolate(x, scale_factor=self.spatial_scale_factor, mode=self.spatial_scale_mode, align_corners=False)
    fft_dim = (-3, -2, -1) if self.ffc3d else (-2, -1)
    n = 1
    for d in fft_dim:
        n *= x.shape[d]
    k = 1.0 / math.sqrt(n)
    ffted = torch.fft.rfftn(x * k, dim=fft_dim, norm="backward")  # == rfftn(x, norm='ortho')
    ffted = torch.stack((ffted.real, ffted.imag), dim=-1)
    ffted = ffted.permute(0, 1, 4, 2, 3).contiguous()
    ffted = ffted.view((batch, -1,) + ffted.size()[3:])
    if self.spectral_pos_encoding:
        height, width = ffted.shape[-2:]
        coords_vert = torch.linspace(0, 1, height)[None, None, :, None].expand(batch, 1, height, width).to(ffted)
        coords_hor = torch.linspace(0, 1, width)[None, None, None, :].expand(batch, 1, height, width).to(ffted)
        ffted = torch.cat((coords_vert, coords_hor, ffted), dim=1)
    if self.use_se:
        ffted = self.se(ffted)
    ffted = self.conv_layer(ffted)
    ffted = self.relu(self.bn(ffted))
    ffted = ffted.view((batch, -1, 2,) + ffted.size()[2:]).permute(0, 1, 3, 4, 2).contiguous()
    ffted = torch.complex(ffted[..., 0] * k, ffted[..., 1] * k)
    ifft_shape_slice = x.shape[-3:] if self.ffc3d else x.shape[-2:]
    output = torch.fft.irfftn(ffted, s=ifft_shape_slice, dim=fft_dim, norm="forward")  # == irfftn(., norm='ortho')
    if self.spatial_scale_factor is not None:
        output = F.interpolate(output, size=orig_size, mode=self.spatial_scale_mode, align_corners=False)
    return output


def build_lama(src):
    for n in ("saicinpainting", "saicinpainting.training", "saicinpainting.training.modules"):
        _stub(n)
    _stub("saicinpainting.training.modules.depthwise_sep_conv", DepthWiseSeperableConv=nn.Conv2d)
    _stub("saicinpainting.training.modules.multidilated_conv", MultidilatedConv=nn.Conv2d)
    _stub("saicinpainting.training.modules.spatial_transform", LearnableSpatialTransformWrapper=None)
    _stub("saicinpainting.utils", get_shape=lambda t: tuple(t.shape) if torch.is_tensor(t) else None)
    _load("saicinpainting.training.modules.base", os.path.join(src, "base.py"))
    _load("saicinpainting.training.modules.squeeze_excitation", os.path.join(src, "squeeze_excitation.py"))
    ffc = _load("saicinpainting.training.modules.ffc", os.path.join(src, "ffc.py"))
    ffc.FourierUnit.forward = _fourier_forward_fp16_safe
    # big-lama generator config (from big-lama/config.yaml)
    return ffc.FFCResNetGenerator(
        input_nc=4, output_nc=3, ngf=64, n_downsampling=3, n_blocks=18, add_out_act="sigmoid",
        init_conv_kwargs=dict(ratio_gin=0, ratio_gout=0, enable_lfu=False),
        downsample_conv_kwargs=dict(ratio_gin=0, ratio_gout=0, enable_lfu=False),
        resnet_conv_kwargs=dict(ratio_gin=0.75, ratio_gout=0.75, enable_lfu=False),
    )


class LamaWrap(nn.Module):
    """image [0,1] (1,3,H,W) and mask (1,1,H,W) with 1 = hole. Same pre-processing as LaMa's predictor."""
    def __init__(self, gen):
        super().__init__()
        self.gen = gen

    def forward(self, image, mask):
        masked = image * (1 - mask)
        out = self.gen(torch.cat([masked, mask], dim=1))
        return mask * out + (1 - mask) * image


class AffineBN(nn.Module):
    """Inference BatchNorm as y = x*s + t, with s and t precomputed in FP32 so they stay in FP16 range."""
    def __init__(self, bn):
        super().__init__()
        s = bn.weight.detach() / torch.sqrt(bn.running_var.detach() + bn.eps)
        self.register_buffer("s", s.view(1, -1, 1, 1).clone())
        self.register_buffer("t", (bn.bias.detach() - bn.running_mean.detach() * s).view(1, -1, 1, 1).clone())

    def forward(self, x):
        return x * self.s + self.t


def replace_batchnorm(module):
    n = 0
    for name, child in list(module.named_children()):
        if isinstance(child, nn.BatchNorm2d):
            setattr(module, name, AffineBN(child))
            n += 1
        else:
            n += replace_batchnorm(child)
    return n


def load_lama_state(path):
    """Lightning checkpoint: load tensors only (weights_only=True). Each unknown training-metadata class it names
    gets an inert placeholder with the same name; plain containers and typing markers are allowed as themselves."""
    safe_builtins = {"dict": dict, "list": list, "set": set, "tuple": tuple, "int": int, "float": float,
                     "str": str, "bool": bool, "frozenset": frozenset, "bytes": bytes}
    safe_std = {("collections", "defaultdict"): collections.defaultdict,
                ("collections", "OrderedDict"): collections.OrderedDict}
    fake_mods = {}
    for _ in range(40):
        try:
            ck = torch.load(path, map_location="cpu", weights_only=True)
            break
        except Exception as e:
            b = re.search(r"Unsupported global: GLOBAL (\w+) was not", str(e))
            if b and b.group(1) in safe_builtins:
                torch.serialization.add_safe_globals([safe_builtins[b.group(1)]])
                continue
            m = re.search(r"Unsupported global: GLOBAL ([\w.]+)\.(\w+)", str(e))
            if not m:
                raise
            mod, cls = m.group(1), m.group(2)
            if mod == "typing":
                torch.serialization.add_safe_globals([getattr(typing, cls)])
                continue
            if (mod, cls) in safe_std:
                torch.serialization.add_safe_globals([safe_std[(mod, cls)]])
                continue
            if mod in fake_mods:
                module = fake_mods[mod]
            elif mod in sys.modules or mod.split(".")[0] in ("builtins", "collections", "torch", "numpy", "os", "sys"):
                raise RuntimeError(f"refusing to stub real module global {mod}.{cls}")
            else:
                module = types.ModuleType(mod)
                sys.modules[mod] = module
                fake_mods[mod] = module
            placeholder = type(cls, (), {"__module__": mod, "__setstate__": lambda self, st: None})
            setattr(module, cls, placeholder)
            torch.serialization.add_safe_globals([placeholder])
    else:
        raise RuntimeError("too many unknown globals")
    sd = ck.get("state_dict", ck)
    return {k[len("generator."):]: v for k, v in sd.items() if k.startswith("generator.")}


def main():
    ckpt, src, workdir, out = sys.argv[1:5]
    sample = sys.argv[5] if len(sys.argv) > 5 else None
    os.makedirs(workdir, exist_ok=True)
    gen = build_lama(src)
    gen.load_state_dict(load_lama_state(ckpt), strict=True)
    folded = replace_batchnorm(gen)
    model = LamaWrap(gen).eval()
    parts = []
    for size in SIZES:
        path = os.path.join(workdir, f"lama_{size}_single.mlpackage")
        ex = (torch.rand(1, 3, size, size), (torch.rand(1, 1, size, size) > 0.5).float())
        with torch.no_grad():
            traced = torch.jit.trace(model, ex, check_trace=False)
        inputs = [ct.TensorType(name="image", shape=(1, 3, size, size)), ct.TensorType(name="mask", shape=(1, 1, size, size))]
        ml = ct.convert(traced, inputs=inputs, outputs=[ct.TensorType(name="output")], convert_to="mlprogram",
                        compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS18,
                        compute_units=ct.ComputeUnit.CPU_AND_GPU)  # the Neural Engine compile takes many minutes
        ml.save(path)
        rec = {"size": size, "bn_folded": folded}
        if sample:
            img = center_crop(sample, size)
            m = np.zeros((1, 1, size, size), np.float32)
            m[..., size // 3: 2 * size // 3, size // 3: 2 * size // 3] = 1
            with torch.no_grad():
                ref = model(torch.from_numpy(img), torch.from_numpy(m)).numpy()
            rec["psnr_db"] = psnr(ref, ml.predict({"image": img, "mask": m})["output"])
        print(json.dumps(rec), flush=True)
        parts.append((size, path))
        del ml, traced

    desc = ct.utils.MultiFunctionDescriptor()
    for size, path in parts:
        desc.add_function(path, src_function_name="main", target_function_name="main" if size == SIZES[0] else f"lama{size}")
    desc.default_function_name = "main"
    ct.utils.save_multifunction(desc, out)
    print(json.dumps({"saved": out, "functions": list(SIZES)}))


if __name__ == "__main__":
    main()
