"""Converts MediaPipe Face Mesh V2 (face_landmarks_detector.tflite from face_landmarker.task, Apache-2.0) to Core ML.
Runs the TFLite graph op by op in PyTorch (NCHW), traces it and converts with coremltools. No TensorFlow needed.
Input: `image` (1, 3, 256, 256) float RGB face crop, 0...1 (the app's MLTensors.rgbTensor layout). Outputs: `landmarks` (1, 1434) = 478 x (x, y, z) in crop pixels, `presence` (1, 1) logit."""
import sys, os
import numpy as np
import torch
import torch.nn.functional as F
sys.path.insert(0, os.path.dirname(__file__))
import tflite_read as R  # noqa: E402

ADD, CONV, DW, DEQ, POOL, PAD, PRELU, LOGISTIC, RESHAPE = 0, 3, 4, 6, 17, 34, 54, 14, 22

def act(x, a):
    return F.relu(x) if a == 1 else (torch.clamp(x, 0, 6) if a == 3 else x)

def same_pad(x, k, s):
    h, w = x.shape[2], x.shape[3]
    ph = max((-(-h // s) - 1) * s + k[0] - h, 0)
    pw = max((-(-w // s) - 1) * s + k[1] - w, 0)
    return F.pad(x, (pw // 2, pw - pw // 2, ph // 2, ph - ph // 2))

class Mesh(torch.nn.Module):
    def __init__(self, g):
        super().__init__()
        self.g = g
        T = g['tensors']
        const = {}
        for i, t in enumerate(T):
            if t['data'] is not None: const[i] = t['data'].astype(np.float32)
        for op in g['ops']:   # fold DEQUANTIZE of constants
            if op['code'] == DEQ and op['inputs'][0] in const:
                const[op['outputs'][0]] = const[op['inputs'][0]]
        self.params = torch.nn.ParameterDict()
        self.prep = {}
        for op in g['ops']:
            c = op['code']
            if c == CONV:
                w = const[op['inputs'][1]].transpose(0, 3, 1, 2)          # OHWI -> OIHW
                self._p(op, w, const.get(op['inputs'][2]))
            elif c == DW:
                w = const[op['inputs'][1]].transpose(3, 0, 1, 2)          # 1HWC -> C1HW
                self._p(op, w, const.get(op['inputs'][2]))
            elif c == PRELU:
                a = const[op['inputs'][1]].reshape(-1)
                self.params[f"a{op['outputs'][0]}"] = torch.nn.Parameter(torch.tensor(a).view(1, -1, 1, 1), requires_grad=False)
            elif c == PAD:
                self.prep[op['outputs'][0]] = const[op['inputs'][1]].astype(int)

    def _p(self, op, w, b):
        k = op['outputs'][0]
        self.params[f"w{k}"] = torch.nn.Parameter(torch.tensor(w), requires_grad=False)
        self.params[f"b{k}"] = torch.nn.Parameter(torch.tensor(b if b is not None else np.zeros(w.shape[0], np.float32)), requires_grad=False)

    def forward(self, x):
        g = self.g
        v = {g['inputs'][0]: x}
        outs = []
        for op in g['ops']:
            c, i, o, opt = op['code'], op['inputs'], op['outputs'][0], op['opt']
            if c == DEQ:
                continue
            if c in (CONV, DW):
                w, b = self.params[f"w{o}"], self.params[f"b{o}"]
                if c == CONV:
                    pad, sw, sh, a = opt.scalar(0, 'b'), opt.scalar(1, 'i'), opt.scalar(2, 'i'), opt.scalar(3, 'b')
                else:
                    pad, sw, sh, a = opt.scalar(0, 'b'), opt.scalar(1, 'i'), opt.scalar(2, 'i'), opt.scalar(4, 'b')
                y = v[i[0]]
                k = (w.shape[2], w.shape[3])
                if pad == 0: y = same_pad(y, k, sh)
                y = F.conv2d(y, w, b, stride=(sh, sw), groups=1 if c == CONV else y.shape[1])
                v[o] = act(y, a)
            elif c == PRELU:
                y = v[i[0]]
                v[o] = torch.where(y >= 0, y, y * self.params[f"a{o}"])
            elif c == ADD:
                v[o] = act(v[i[0]] + v[i[1]], opt.scalar(0, 'b') if opt else 0)
            elif c == POOL:
                pad, sw, sh, fw, fh = (opt.scalar(k, 'b' if k == 0 else 'i') for k in range(5))
                y = v[i[0]]
                if pad == 0: y = same_pad(y, (fh, fw), sh)
                v[o] = F.max_pool2d(y, (fh, fw), (sh, sw))
            elif c == PAD:
                p = self.prep[o]   # NHWC [[n],[h],[w],[c]]
                v[o] = F.pad(v[i[0]], (int(p[2][0]), int(p[2][1]), int(p[1][0]), int(p[1][1]), int(p[3][0]), int(p[3][1])))
            elif c == LOGISTIC:
                v[o] = torch.sigmoid(v[i[0]])
            elif c == RESHAPE:
                v[o] = v[i[0]].reshape(1, -1)
            else:
                raise ValueError(f"op {c}")
        lm = v[g['outputs'][0]].reshape(1, -1)
        pres = v[g['outputs'][1]].reshape(1, 1)
        return lm, pres

def build(path):
    return Mesh(R.load(path)).eval()

if __name__ == '__main__':
    import coremltools as ct
    src, dst = sys.argv[1], sys.argv[2]
    m = build(src)
    ex = torch.rand(1, 3, 256, 256)
    with torch.no_grad():
        tr = torch.jit.trace(m, ex)
    ml = ct.convert(tr, inputs=[ct.TensorType(name='image', shape=(1, 3, 256, 256))],
                    outputs=[ct.TensorType(name='landmarks'), ct.TensorType(name='presence')],
                    minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
    ml.short_description = 'MediaPipe Face Mesh V2 (Apache-2.0), 478 landmarks from a 256x256 face crop'
    ml.save(dst)
    print('saved', dst)
