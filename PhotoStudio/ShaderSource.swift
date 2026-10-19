import Foundation

/// Metal source for the Smooth and Face-shape kernels, compiled on the device at first use with
/// MTLDevice.makeLibrary(source:). That avoids needing Xcode's separately downloaded Metal Toolchain to build.
enum ShaderSource {
    static let code = """
#include <metal_stdlib>
using namespace metal;

// Edge-preserving skin smoothing: a sparse bilateral filter on luminance differences, applied only where the
// landmark skin mask is set and the colour looks like skin. Edges (eyes, brows, lips, moles) are kept sharp.
kernel void smoothSkin(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::sample> mask [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]],
                       constant float &strength [[buffer(0)]],
                       constant float &radius [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler sp(coord::pixel, address::clamp_to_edge, filter::linear);
    constexpr sampler sn(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 p = float2(gid) + 0.5;
    float4 c = src.sample(sp, p);
    float m = mask.sample(sn, p / float2(w, h)).r;
    if (m < 0.01 || strength < 0.001) { dst.write(float4(c.rgb, 1.0), gid); return; }

    const float3 lw = float3(0.299, 0.587, 0.114);
    float lum = dot(c.rgb, lw);
    const int K = 5;                      // 11 x 11 sparse taps
    float step = max(1.0, radius / float(K));
    float3 acc = 0.0;
    float wsum = 0.0;
    for (int j = -K; j <= K; j++) {
        for (int i = -K; i <= K; i++) {
            float4 n = src.sample(sp, p + float2(i, j) * step);
            float dl = dot(n.rgb, lw) - lum;
            float ws = exp(-float(i * i + j * j) / (2.0 * 9.0));
            float wr = exp(-(dl * dl) / (2.0 * 0.06 * 0.06));
            acc += n.rgb * ws * wr;
            wsum += ws * wr;
        }
    }
    float3 sm = acc / max(wsum, 1e-4);

    // Skin likelihood from YCbCr (soft version of the classic Cb 77-127, Cr 133-173 box).
    float cb = 0.5 + (-0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b);
    float cr = 0.5 + (0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b);
    float skin = smoothstep(0.27, 0.31, cb) * (1.0 - smoothstep(0.50, 0.54, cb))
               * smoothstep(0.49, 0.53, cr) * (1.0 - smoothstep(0.68, 0.72, cr));
    float a = clamp(strength * m * mix(0.35, 1.0, skin), 0.0, 1.0) * 0.9;  // keep 10% texture at most strength
    dst.write(float4(mix(c.rgb, sm, a), 1.0), gid);
}

struct WarpOp {
    float2 c;      // centre, pixels
    float r;       // radius, pixels
    float kind;    // 0 = translate, 1 = bulge, 2 = Reshape push, 3 = squeeze (Width), 4 = scale (Size), 5 = Perspective translate
    float2 m;      // translate displacement, pixels; squeeze and scale: the unit axis r is measured along
    float s;       // bulge, squeeze or scale strength; translate: its slider's group (0-15)
    float pad;     // squeeze and scale: reach along the other axis, pixels (r is the reach along m)
};

// Inverse-mapped local warps: each output pixel looks up where its content comes from.
// Translate handles are blended (weighted average, not summed) within each slider's group, so overlapping handles
// can't pile up and tear the image, and the groups' results are added, so one slider never weakens another.
// Perspective handles are blended the same way as one more group.
// Bulges (eyes) are applied afterwards. Reshape pushes were made on top of the slider warp, one after another,
// so they are undone first, newest first. Each push is under 0.65 of its radius, so none folds. Size comes next:
// it scales the whole head, so the handles after it line up with the photo's own landmarks.
kernel void faceWarp(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant WarpOp *ops [[buffer(0)]],
                     constant uint &count [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler sp(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 p = float2(gid) + 0.5;
    for (int k = int(count) - 1; k >= 0; k--) {
        WarpOp op = ops[k];
        if (op.kind < 1.5 || op.kind > 2.5) continue;   // Reshape pushes only
        float2 d = p - op.c;
        float dd = dot(d, d);
        float rr = op.r * op.r;
        if (dd >= rr) continue;
        float x2 = dd / rr;
        p -= op.m * (1.0 - x2) * (1.0 - x2);
    }
    // Scales are even over the inner 60% of an oval and fade to nothing at its edge (smoothstep), so the face keeps
    // its shape and the hair and background around it bend smoothly. At up to 10% they can't fold.
    for (uint k = 0; k < count; k++) {
        WarpOp op = ops[k];
        if (op.kind < 3.5 || op.kind > 4.5) continue;
        float2 d = p - op.c;
        float a = dot(d, op.m);
        float b = dot(d, float2(-op.m.y, op.m.x));
        float x2 = (a * a) / (op.r * op.r) + (b * b) / (op.pad * op.pad);
        if (x2 >= 1.0) continue;
        p = op.c + d * (1.0 - op.s * (1.0 - smoothstep(0.6, 1.0, sqrt(x2))));   // look nearer the middle to enlarge
    }
    float2 gsum[17];
    float gw[17];
    for (int g = 0; g < 17; g++) { gsum[g] = 0.0; gw[g] = 0.0; }
    for (uint k = 0; k < count; k++) {
        WarpOp op = ops[k];
        bool persp = op.kind > 4.5;
        if (op.kind > 0.5 && !persp) continue;  // translate and Perspective only
        float2 d = p - op.c;
        float dd = dot(d, d);
        float rr = op.r * op.r;
        if (dd >= rr) continue;
        float x2 = dd / rr;
        float wgt = (1.0 - x2) * (1.0 - x2);   // smooth bump: 1 at the centre, 0 with zero slope at the edge
        int g = persp ? 16 : clamp(int(op.s + 0.5), 0, 15);
        gsum[g] += wgt * op.m;
        gw[g] += wgt;
    }
    float2 q = p;
    for (int g = 0; g < 17; g++) { if (gw[g] > 0.0) q -= gsum[g] / max(1.0, gw[g]); }
    // Squeezes narrow (or widen) an oval area along one axis, most in the middle and fading to nothing at its edge.
    // They come after the translates, so Width adds to Slim jawline instead of being averaged with it.
    for (uint k = 0; k < count; k++) {
        WarpOp op = ops[k];
        if (op.kind < 2.5 || op.kind > 3.5) continue;
        float2 d = q - op.c;
        float a = dot(d, op.m);
        float b = dot(d, float2(-op.m.y, op.m.x));
        float x2 = (a * a) / (op.r * op.r) + (b * b) / (op.pad * op.pad);
        if (x2 >= 1.0) continue;
        q += op.m * a * op.s * (1.0 - x2) * (1.0 - x2);   // look further out, so the content draws inward
    }
    for (uint k = 0; k < count; k++) {
        WarpOp op = ops[k];
        if (op.kind < 0.5 || op.kind > 1.5) continue;  // bulge only
        float2 d = q - op.c;
        float dd = dot(d, d);
        float rr = op.r * op.r;
        if (dd >= rr) continue;
        float x2 = dd / rr;
        q = op.c + d * (1.0 - op.s * (1.0 - x2) * (1.0 - x2));
    }
    dst.write(float4(src.sample(sp, q).rgb, 1.0), gid);
}
"""
}
