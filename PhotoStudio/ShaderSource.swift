import Foundation

/// Metal source for the Smooth and Face-shape kernels, compiled on the device at first use with
/// MTLDevice.makeLibrary(source:). That avoids needing Xcode's separately downloaded Metal Toolchain to build.
enum ShaderSource {
    static let code = """
#include <metal_stdlib>
using namespace metal;

// Edge-preserving skin smoothing: a sparse bilateral filter on luminance differences.
// The mask texture has two channels: R = face skin (lenient colour gating), G = body skin candidates such as the neck
// fade or the "All skin" person cutout (strict gating: only clearly skin-coloured pixels). Eyes, brows and lips are
// already cut out of both channels on the CPU. Edges (eyes, lips, moles, hair strands) stay sharp.
kernel void smoothSkin(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::sample> mask [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]],
                       constant float &strength [[buffer(0)]],
                       constant float &radius [[buffer(1)]],
                       constant float4 &refMean [[buffer(2)]],
                       constant float4 &refSigma [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler sp(coord::pixel, address::clamp_to_edge, filter::linear);
    constexpr sampler sn(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 p = float2(gid) + 0.5;
    float4 c = src.sample(sp, p);
    float2 mm = mask.sample(sn, p / float2(w, h)).rg;
    if (max(mm.r, mm.g) < 0.01 || strength < 0.001) { dst.write(float4(c.rgb, 1.0), gid); return; }

    // Skin likelihood from YCbCr chroma, which works across skin tones because it ignores brightness.
    // The Cr floor is set high enough that brown and black hair (near-neutral chroma) falls outside it.
    float cb = 0.5 + (-0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b);
    float cr = 0.5 + (0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b);
    float skin = smoothstep(0.27, 0.31, cb) * (1.0 - smoothstep(0.50, 0.54, cb))
               * smoothstep(0.515, 0.545, cr) * (1.0 - smoothstep(0.68, 0.72, cr));
    // Closeness to this person's own skin (colour and brightness learned from the face), if available.
    float like = 1.0;
    if (refMean.w > 0.5) {
        float3 d = (float3(dot(c.rgb, float3(0.299, 0.587, 0.114)), cb, cr) - refMean.xyz) / refSigma.xyz;
        like = exp(-0.5 * dot(d, d));
    }
    float a = max(mm.r * mix(0.15, 1.0, skin * mix(0.5, 1.0, like)), mm.g * skin * like);
    a = clamp(strength * a, 0.0, 1.0) * 0.9;  // keep at least 10% of the original texture
    if (a < 0.004) { dst.write(float4(c.rgb, 1.0), gid); return; }

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
    dst.write(float4(mix(c.rgb, sm, a), 1.0), gid);
}

struct WarpOp {
    float2 c;      // centre, pixels
    float r;       // radius, pixels
    float kind;    // 0 = translate, 1 = bulge
    float2 m;      // translate displacement, pixels
    float s;       // bulge strength
    float pad;
};

// Inverse-mapped local warps: each output pixel looks up where its content comes from.
// Translate handles are blended (weighted average, not summed), so overlapping jaw handles can't pile up and
// tear the image. Bulges (eyes) are applied afterwards.
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
    float2 dsum = 0.0;
    float wsum = 0.0;
    for (uint k = 0; k < count; k++) {
        WarpOp op = ops[k];
        if (op.kind > 0.5) continue;
        float2 d = p - op.c;
        float dd = dot(d, d);
        float rr = op.r * op.r;
        if (dd >= rr) continue;
        float x2 = dd / rr;
        float wgt = (1.0 - x2) * (1.0 - x2);   // smooth bump: 1 at the centre, 0 with zero slope at the edge
        dsum += wgt * op.m;
        wsum += wgt;
    }
    float2 q = p - dsum / max(1.0, wsum);
    for (uint k = 0; k < count; k++) {
        WarpOp op = ops[k];
        if (op.kind < 0.5) continue;
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
