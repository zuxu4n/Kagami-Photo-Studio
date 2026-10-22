"""Minimal TFLite flatbuffer reader (no tensorflow needed): tensors, weights and the operator list."""
import struct
import numpy as np

class T:
    def __init__(self, buf, pos):
        self.b, self.pos = buf, pos
        self.vt = pos - struct.unpack_from('<i', buf, pos)[0]
        self.vtlen = struct.unpack_from('<H', buf, self.vt)[0]
    def _off(self, i):
        o = 4 + 2 * i
        return struct.unpack_from('<H', self.b, self.vt + o)[0] if o < self.vtlen else 0
    def scalar(self, i, fmt, default=0):
        o = self._off(i)
        return struct.unpack_from('<' + fmt, self.b, self.pos + o)[0] if o else default
    def _ind(self, i):
        o = self._off(i)
        if not o: return None
        p = self.pos + o
        return p + struct.unpack_from('<I', self.b, p)[0]
    def table(self, i):
        p = self._ind(i)
        return T(self.b, p) if p is not None else None
    def vec(self, i):
        p = self._ind(i)
        if p is None: return None, 0
        return p + 4, struct.unpack_from('<I', self.b, p)[0]
    def tables(self, i):
        p, n = self.vec(i)
        return [T(self.b, p + 4 * k + struct.unpack_from('<I', self.b, p + 4 * k)[0]) for k in range(n)]
    def nums(self, i, dtype):
        p, n = self.vec(i)
        return np.frombuffer(self.b, dtype=dtype, count=n, offset=p).copy() if p else np.zeros(0, dtype)
    def string(self, i):
        p, n = self.vec(i)
        return self.b[p:p + n].decode() if p else ''

TYPES = {0: np.float32, 1: np.float16, 2: np.int32, 3: np.uint8, 4: np.int64, 9: np.int8}

def load(path):
    buf = open(path, 'rb').read()
    m = T(buf, struct.unpack_from('<I', buf, 0)[0])
    codes = []
    for oc in m.tables(1):
        c = max(oc.scalar(0, 'b'), oc.scalar(3, 'i'))
        codes.append(c if c or not oc.string(1) else oc.string(1))
    buffers = [bf.nums(0, np.uint8) for bf in m.tables(4)]
    sg = m.tables(2)[0]
    tensors = []
    for t in sg.tables(0):
        shape = t.nums(0, np.int32).tolist()
        dt = TYPES[t.scalar(1, 'b')]
        raw = buffers[t.scalar(2, 'I')]
        data = np.frombuffer(raw.tobytes(), dtype=dt).reshape(shape) if raw.size else None
        tensors.append(dict(name=t.string(3), shape=shape, dtype=dt, data=data))
    ops = []
    for op in sg.tables(3):
        ops.append(dict(code=codes[op.scalar(0, 'I')], inputs=op.nums(1, np.int32).tolist(),
                        outputs=op.nums(2, np.int32).tolist(), opt_type=op.scalar(3, 'B'), opt=op.table(4)))
    return dict(tensors=tensors, ops=ops, inputs=sg.nums(1, np.int32).tolist(), outputs=sg.nums(2, np.int32).tolist())
