"""esrgan.py WEIGHTS OUT.mlpackage [SAMPLE_IMAGE]

Real-ESRGAN "realesr-general-x4v3" (BSD-3, xinntao/Real-ESRGAN) as a Core ML ML Program at FP16 with a fixed
512 x 512 input (the app's Enhance tile). The network is SRVGGNetCompact, written to match the official
checkpoint's state-dict keys, loaded with weights_only=True and strict keys so any mismatch fails loudly.
With SAMPLE_IMAGE, the Core ML output is checked against PyTorch FP32 on a 512 x 512 crop of it (PSNR).
"""
import json
import math
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct
from PIL import Image

SIZE = 512


class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        base = F.interpolate(x, scale_factor=self.upscale, mode="nearest")
        return out + base


def center_crop(path, size):
    """A size x size RGB crop from the middle of the image, 0...1, shaped (1, 3, size, size)."""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    if min(w, h) < size:
        s = size / min(w, h)
        im = im.resize((math.ceil(w * s), math.ceil(h * s)), Image.LANCZOS)
        w, h = im.size
    l, t = (w - size) // 2, (h - size) // 2
    arr = np.asarray(im.crop((l, t, l + size, t + size)), dtype=np.float32) / 255.0
    return np.ascontiguousarray(arr.transpose(2, 0, 1)[None])


def psnr(ref, got):
    mse = float(np.mean((np.clip(ref, 0, 1) - np.clip(got, 0, 1)) ** 2))
    return round(10 * math.log10(1 / mse), 2) if mse > 0 else 99.0


def main():
    wpath, out = sys.argv[1], sys.argv[2]
    sample = sys.argv[3] if len(sys.argv) > 3 else None
    model = SRVGGNetCompact()
    sd = torch.load(wpath, map_location="cpu", weights_only=True)
    model.load_state_dict(sd.get("params", sd), strict=True)
    model.eval()
    with torch.no_grad():
        traced = torch.jit.trace(model, torch.rand(1, 3, SIZE, SIZE))
    ml = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=(1, 3, SIZE, SIZE))],
                    outputs=[ct.TensorType(name="output")], convert_to="mlprogram",
                    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS16)
    ml.save(out)
    rec = {"model": "realesr-general-x4v3", "saved": out}
    if sample:
        inp = center_crop(sample, SIZE)
        with torch.no_grad():
            ref = model(torch.from_numpy(inp)).numpy()
        rec["psnr_db"] = psnr(ref, ml.predict({"input": inp})["output"])
    print(json.dumps(rec))


if __name__ == "__main__":
    main()
