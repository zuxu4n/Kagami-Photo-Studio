import Metal
import CoreGraphics
import Accelerate
import simd

/// The Retouch tab's values for one face, 0...1 each. They change colours only, never the face's shape.
struct FaceRetouch: Equatable {
    var teeth: Float = 0   // whiter, less yellow teeth
    var eyes: Float = 0    // brighter, clearer eye whites and irises
    var tone: Float = 0    // more even skin colour: blotches and redness fade, texture and shading stay
    var isOff: Bool { teeth <= 0.001 && eyes <= 0.001 && tone <= 0.001 }
}

/// Whiten teeth, Brighten eyes and Even skin tone, on the GPU. Runs after Smooth and before the Face warp, on the
/// photo's own (unwarped) layout, so the masks come straight from the landmarks.
final class Retouch {
    static let shared = Retouch()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pso: MTLComputePipelineState

    private init() {
        device = GPU.shared.device
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: Retouch.shader, options: nil)
        pso = try! device.makeComputePipelineState(function: lib.makeFunction(name: "retouch")!)
    }

    /// The masks are made at most this size on the long side (like Smooth's), the skin colour averages at most this.
    static let maskSide = 1024.0, lowSide = 384.0

    /// `img` with each face's Retouch values applied. Faces without any are left as they are.
    static func apply(_ img: RGBAImage, faces: [FaceGeometry], retouch: [FaceRetouch]) -> RGBAImage {
        guard retouch.contains(where: { !$0.isOff }), !faces.isEmpty else { return img }
        let s = min(1.0, maskSide / Double(max(img.width, img.height)))
        let mw = max(1, Int(Double(img.width) * s)), mh = max(1, Int(Double(img.height) * s))
        let masks = strengthMasks(faces: faces, retouch: retouch, width: mw, height: mh)
        var low: [Float] = [0, 0, 0, 0]
        var lw = 1, lh = 1
        if retouch.contains(where: { $0.tone > 0.001 }) {
            let ls = min(1.0, lowSide / Double(max(img.width, img.height)))
            lw = max(1, Int(Double(img.width) * ls)); lh = max(1, Int(Double(img.height) * ls))
            low = skinAverages(img, faces: faces, retouch: retouch, width: lw, height: lh)
        }
        return shared.run(img, masks: masks, maskWidth: mw, maskHeight: mh, low: low, lowWidth: lw, lowHeight: lh)
    }

    // MARK: Masks

    /// RGBA at w x h: R = teeth, G = eyes, B = skin, each already scaled by that face's slider, feathered.
    static func strengthMasks(faces: [FaceGeometry], retouch: [FaceRetouch], width w: Int, height h: Int) -> [UInt8] {
        var teeth = [UInt8](repeating: 0, count: w * h), eyes = teeth, skin = teeth
        for (i, f) in faces.enumerated() where i < retouch.count && !retouch[i].isOff {
            let r = retouch[i]
            let feather = max(1, Int(f.box.width * CGFloat(w) / 50))
            if r.teeth > 0.001 {
                let mouth = f.mesh.isEmpty ? [shrunk(f.outerLips, 0.7)] : [FaceAnalyzer.innerLips.map { f.mesh[$0] }]
                maxInto(&teeth, polygonMask(mouth, w, h, feather: feather), r.teeth)
            }
            if r.eyes > 0.001 {
                let openings = f.mesh.isEmpty ? [f.leftEye, f.rightEye]
                    : FaceAnalyzer.meshEyes.map { e in ([e.outer] + e.upper + [e.inner] + e.lower.reversed()).map { f.mesh[$0] } }
                maxInto(&eyes, polygonMask(openings, w, h, feather: feather), r.eyes)
            }
            if r.tone > 0.001 {
                maxInto(&skin, FaceAnalyzer.skinMask(faces: [f], width: w, height: h), r.tone)
            }
        }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for p in 0..<(w * h) {
            out[p * 4] = teeth[p]; out[p * 4 + 1] = eyes[p]; out[p * 4 + 2] = skin[p]
        }
        return out
    }

    private static func maxInto(_ dst: inout [UInt8], _ src: [UInt8], _ k: Float) {
        for p in dst.indices { dst[p] = max(dst[p], UInt8(Float(src[p]) * k + 0.5)) }
    }

    /// Points pulled `k` of the way towards their own middle.
    private static func shrunk(_ ps: [CGPoint], _ k: CGFloat) -> [CGPoint] {
        guard !ps.isEmpty else { return [] }
        let c = CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
        return ps.map { CGPoint(x: c.x + ($0.x - c.x) * k, y: c.y + ($0.y - c.y) * k) }
    }

    /// 8-bit mask at w x h, 255 inside the polygons (normalised, top-left origin), softened by a tent blur.
    private static func polygonMask(_ polys: [[CGPoint]], _ w: Int, _ h: Int, feather: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 1, alpha: 1)
            for poly in polys where poly.count > 2 {
                ctx.beginPath()
                ctx.addLines(between: poly.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) })
                ctx.closePath()
                ctx.fillPath()
            }
        }
        let k = UInt32(feather | 1)
        var out = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { sb in
            out.withUnsafeMutableBytes { db in
                var src = vImage_Buffer(data: sb.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var dst = vImage_Buffer(data: db.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageTentConvolve_Planar8(&src, &dst, nil, 0, 0, k, k, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    // MARK: Skin averages for Even skin tone

    /// Float RGBA at w x h, averaged over each face's skin only (so hair and background don't leak in):
    /// R, G = the skin's colour (Cb, Cr) over a wide area, B = brightness over a blotch-sized area, A = brightness
    /// over a wide area. The shader pulls each skin pixel's colour to the wide average and takes out B - A,
    /// which keeps the face's shading and the skin's fine texture.
    static func skinAverages(_ img: RGBAImage, faces: [FaceGeometry], retouch: [FaceRetouch], width w: Int, height h: Int) -> [Float] {
        let small = img.scaled(toWidth: w, height: h)
        let toned = faces.indices.filter { $0 < retouch.count && retouch[$0].tone > 0.001 }.map { faces[$0] }
        let mask = FaceAnalyzer.skinMask(faces: toned, width: w, height: h).map { Float($0) / 255 }
        let n = w * h
        var y = [Float](repeating: 0, count: n), cb = y, cr = y
        for p in 0..<n {
            let r = Float(small.pixels[p * 4]) / 255, g = Float(small.pixels[p * 4 + 1]) / 255, b = Float(small.pixels[p * 4 + 2]) / 255
            y[p] = 0.299 * r + 0.587 * g + 0.114 * b
            cb[p] = -0.168736 * r - 0.331264 * g + 0.5 * b
            cr[p] = 0.5 * r - 0.418688 * g - 0.081312 * b
        }
        let faceW = Float(toned.map { $0.box.width }.max() ?? 0.2) * Float(w)
        let wide = max(2, Int(faceW / 5)), blotch = max(1, Int(faceW / 24))
        func avg(_ v: [Float], _ r: Int) -> [Float] {
            let num = blur(zip(v, mask).map { $0 * $1 }, w, h, r), den = blur(mask, w, h, r)
            return zip(num, den).map { $1 > 1e-3 ? $0 / $1 : 0 }
        }
        let cbW = avg(cb, wide), crW = avg(cr, wide), yB = avg(y, blotch), yW = avg(y, wide)
        var out = [Float](repeating: 0, count: n * 4)
        for p in 0..<n {
            out[p * 4] = cbW[p]; out[p * 4 + 1] = crW[p]; out[p * 4 + 2] = yB[p]; out[p * 4 + 3] = yW[p]
        }
        return out
    }

    /// Two box blurs of radius r (about a tent), clamped at the edges.
    private static func blur(_ v: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var a = v, b = [Float](repeating: 0, count: v.count)
        func pass(_ src: [Float], _ dst: inout [Float], _ len: Int, _ lines: Int, _ at: (Int, Int) -> Int) {
            let norm = 1 / Float(2 * r + 1)
            for l in 0..<lines {
                var sum: Float = 0
                for i in -r...r { sum += src[at(l, min(max(i, 0), len - 1))] }
                for i in 0..<len {
                    dst[at(l, i)] = sum * norm
                    sum += src[at(l, min(i + r + 1, len - 1))] - src[at(l, max(i - r, 0))]
                }
            }
        }
        for _ in 0..<2 {
            pass(a, &b, w, h) { l, i in l * w + i }
            pass(b, &a, h, w) { l, i in i * w + l }
        }
        return a
    }

    // MARK: GPU

    private func run(_ img: RGBAImage, masks: [UInt8], maskWidth mw: Int, maskHeight mh: Int,
                     low: [Float], lowWidth lw: Int, lowHeight lh: Int) -> RGBAImage {
        func tex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, write: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = write ? [.shaderRead, .shaderWrite] : [.shaderRead]
            d.storageMode = .shared
            return device.makeTexture(descriptor: d)!
        }
        let src = tex(.rgba8Unorm, img.width, img.height)
        img.pixels.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.width * 4) }
        let msk = tex(.rgba8Unorm, mw, mh)
        masks.withUnsafeBytes { msk.replace(region: MTLRegionMake2D(0, 0, mw, mh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: mw * 4) }
        let lo = tex(.rgba32Float, lw, lh)
        low.withUnsafeBytes { lo.replace(region: MTLRegionMake2D(0, 0, lw, lh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: lw * 16) }
        let dst = tex(.rgba8Unorm, img.width, img.height, write: true)
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0)
        enc.setTexture(msk, index: 1)
        enc.setTexture(lo, index: 2)
        enc.setTexture(dst, index: 3)
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: img.width, height: img.height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = RGBAImage(width: img.width, height: img.height)
        out.pixels.withUnsafeMutableBytes { dst.getBytes($0.baseAddress!, bytesPerRow: img.width * 4, from: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0) }
        return out
    }

    /// Runs the kernel once on a tiny image, so its compile isn't on the first slider move.
    func warmUp() {
        let img = RGBAImage(width: 8, height: 8)
        _ = run(img, masks: [UInt8](repeating: 0, count: 256), maskWidth: 8, maskHeight: 8, low: [0, 0, 0, 0], lowWidth: 1, lowHeight: 1)
    }

    // Compiled on the device at first use, like ShaderSource.
    static let shader = """
#include <metal_stdlib>
using namespace metal;

// Works in YCbCr (Cb and Cr centred on 0): brightness and colour can be changed separately.
kernel void retouch(texture2d<float, access::sample> src [[texture(0)]],
                    texture2d<float, access::sample> masks [[texture(1)]],
                    texture2d<float, access::sample> low [[texture(2)]],
                    texture2d<float, access::write> dst [[texture(3)]],
                    uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler sn(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float4 c = src.read(gid);
    float4 m = masks.sample(sn, uv);
    if (m.r < 0.004 && m.g < 0.004 && m.b < 0.004) { dst.write(float4(c.rgb, 1.0), gid); return; }

    float y = dot(c.rgb, float3(0.299, 0.587, 0.114));
    float cb = dot(c.rgb, float3(-0.168736, -0.331264, 0.5));
    float cr = dot(c.rgb, float3(0.5, -0.418688, -0.081312));

    // Even skin tone: colour goes most of the way to the skin's wide average, and blotch-sized patches of light and
    // dark are partly evened out. Fine texture (pores) and the face's shading are left.
    if (m.b > 0.004) {
        float4 a = low.sample(sn, uv);
        // Only pixels close to the skin's own colour and brightness, so hair, brows and glasses over the skin stay.
        float t = m.b * (1.0 - smoothstep(0.035, 0.08, length(float2(cb, cr) - a.rg)))
                      * (1.0 - smoothstep(0.12, 0.25, abs(y - a.a)));
        cb = mix(cb, a.r, t * 0.7);
        cr = mix(cr, a.g, t * 0.7);
        y -= t * 0.6 * clamp(a.b - a.a, -0.08, 0.08);
    }

    // Whiten teeth: only bright, not-red pixels in the mouth (so lips, gums and tongue stay), losing their yellow
    // and getting a little brighter.
    if (m.r > 0.004) {
        float teeth = smoothstep(0.22, 0.42, y) * (1.0 - smoothstep(0.05, 0.11, cr));
        float t = m.r * teeth;
        cb = mix(cb, cb * (cb < 0.0 ? 0.2 : 0.5), t * 0.85);   // keeps a trace of warmth, so they don't turn blue-white
        cr = mix(cr, cr * 0.4, t * 0.7);
        y = mix(y, 1.0 - pow(1.0 - y, 1.45), t * 0.85);
    }

    // Brighten eyes: lifts the mid-tones (whites and iris) more than the dark pupil and lashes, and takes the
    // redness out of the whites.
    if (m.g > 0.004) {
        float t = m.g;
        float white = smoothstep(0.35, 0.6, y) * (1.0 - smoothstep(0.08, 0.18, length(float2(cb, cr))));
        cr = mix(cr, min(cr, 0.0) + max(cr, 0.0) * 0.3, t * white);
        cb = mix(cb, cb * 0.6, t * white);
        y = mix(y, 1.0 - pow(1.0 - y, 1.5), t * 0.7);
    }

    float3 rgb = float3(y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb);
    dst.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
}
"""
}
