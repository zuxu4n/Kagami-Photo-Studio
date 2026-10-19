import CoreGraphics
import CoreImage
import Accelerate

/// What Enhance does inside face areas. None of these let the model redraw a face.
enum FaceTreatment: Equatable, CustomStringConvertible {
    /// The original face, only resized to the result's size.
    case original
    /// The model's changes, each softly capped at about `limit` levels (0-255), so noise removal and fine sharpening
    /// stay but large changes such as drawn eye outlines don't. A limit of 0 picks it per face: 2.5x the face's own
    /// pixel noise, between 6 and 16, so grainy faces get more cleaning than clean ones.
    case smallChanges(limit: Float)
    /// The original face, resized, with Core Image noise reduction and sharpening (no AI).
    case classic(noise: Float, sharpness: Float)

    var description: String {
        switch self {
        case .original: return "original"
        case .smallChanges(let l): return l > 0 ? "model changes capped at \(Int(l))" : "model changes capped by face noise"
        case .classic(let n, let s): return "classic denoise \(n) sharpen \(s)"
        }
    }
}

extension EnhanceEngine {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Replaces each face area of the enhanced `out` with `treatment` of the original face. The area is the jaw
    /// contour plus the forehead (the brows lifted, as in FaceAnalyzer.skinMask) with the eyes, brows and lips
    /// included, feathered at the edge.
    static func treatFaces(_ out: inout RGBAImage, original: RGBAImage, faces: [FaceGeometry], treatment: FaceTreatment) {
        guard !faces.isEmpty else { return }
        let W = CGFloat(out.width), H = CGFloat(out.height)
        let originalCG = original.cgImage()
        for f in faces where f.contour.count > 4 {
            let jaw = f.contour.map { CGPoint(x: $0.x * W, y: $0.y * H) }
            let brows = (f.leftBrow + f.rightBrow).map { CGPoint(x: $0.x * W, y: $0.y * H) }
            let chinY = jaw.map(\.y).max() ?? 0
            let browY = brows.isEmpty ? (jaw.map(\.y).min() ?? 0) : brows.map(\.y).reduce(0, +) / CGFloat(brows.count)
            let lift = (chinY - browY) * 0.45
            let hull = FaceAnalyzer.hull(jaw + brows.map { CGPoint(x: $0.x, y: $0.y - lift) })
            guard hull.count > 2 else { continue }
            let feather = max(2, Int(CGFloat(f.box.width) * W * 0.05))
            let minX = max(0, Int(hull.map(\.x).min()!) - 2 * feather), minY = max(0, Int(hull.map(\.y).min()!) - 2 * feather)
            let maxX = min(out.width, Int(hull.map(\.x).max()!) + 2 * feather), maxY = min(out.height, Int(hull.map(\.y).max()!) + 2 * feather)
            let bw = maxX - minX, bh = maxY - minY
            guard bw > 4, bh > 4 else { continue }

            var mask = [UInt8](repeating: 0, count: bw * bh)
            mask.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return }
                ctx.translateBy(x: 0, y: CGFloat(bh))  // top-left pixel coordinates
                ctx.scaleBy(x: 1, y: -1)
                ctx.setFillColor(gray: 1, alpha: 1)
                FaceAnalyzer.fillHull(ctx, hull.map { CGPoint(x: $0.x - CGFloat(minX), y: $0.y - CGFloat(minY)) })
            }
            mask = feathered(mask, width: bw, height: bh, radius: feather)

            // The original for this box, from the whole photo resized to the output size, so it lines up exactly.
            var orig = RGBAImage(width: bw, height: bh)
            orig.pixels.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
                                          space: RGBAImage.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return }
                ctx.interpolationQuality = .high
                ctx.draw(originalCG, in: CGRect(x: -CGFloat(minX), y: -CGFloat(out.height - maxY), width: W, height: H))
            }
            if case .classic(let noise, let sharpness) = treatment { orig = classicDenoise(orig, noise: noise, sharpness: sharpness) }
            var limit: Float = 0
            if case .smallChanges(let l) = treatment {
                limit = l > 0 ? l : min(16, max(6, 2.5 * noiseLevel(original, face: f.box)))
            }

            let outW = out.width
            out.pixels.withUnsafeMutableBufferPointer { o in
                orig.pixels.withUnsafeBufferPointer { s in
                    for y in 0..<bh {
                        for x in 0..<bw {
                            let m = Float(mask[y * bw + x]) / 255
                            if m < 0.004 { continue }
                            let di = ((minY + y) * outW + minX + x) * 4, si = (y * bw + x) * 4
                            for c in 0..<3 {
                                let model = Float(o[di + c]), base = Float(s[si + c])
                                // Target: the treated original, plus the model's change capped softly at `limit`.
                                let target = limit > 0 ? base + limit * tanhf((model - base) / limit) : base
                                o[di + c] = UInt8(max(0, min(255, model + (target - model) * m)) + 0.5)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Pixel noise (standard deviation, 0-255 levels) in the middle of a face, from the original photo: the median
    /// absolute 4-neighbour Laplacian of luma, which edges barely affect.
    static func noiseLevel(_ img: RGBAImage, face box: CGRect) -> Float {
        let W = img.width, H = img.height
        let x0 = max(1, Int((box.minX + 0.2 * box.width) * CGFloat(W))), x1 = min(W - 1, Int((box.minX + 0.8 * box.width) * CGFloat(W)))
        let y0 = max(1, Int((box.minY + 0.2 * box.height) * CGFloat(H))), y1 = min(H - 1, Int((box.minY + 0.8 * box.height) * CGFloat(H)))
        guard x1 - x0 > 4, y1 - y0 > 4 else { return 0 }
        var values: [Float] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))
        img.pixels.withUnsafeBufferPointer { p in
            func luma(_ x: Int, _ y: Int) -> Float {
                let i = (y * W + x) * 4
                return 0.299 * Float(p[i]) + 0.587 * Float(p[i + 1]) + 0.114 * Float(p[i + 2])
            }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let lap = luma(x, y) - (luma(x - 1, y) + luma(x + 1, y) + luma(x, y - 1) + luma(x, y + 1)) / 4
                    values.append(abs(lap))
                }
            }
        }
        values.sort()
        return 1.4826 * values[values.count / 2] * 1.118
    }

    /// Core Image noise reduction with built-in sharpening, on an RGBA8 image (no AI).
    private static func classicDenoise(_ img: RGBAImage, noise: Float, sharpness: Float) -> RGBAImage {
        let size = CGSize(width: img.width, height: img.height)
        let input = CIImage(bitmapData: Data(img.pixels), bytesPerRow: img.width * 4, size: size, format: .RGBA8,
                            colorSpace: RGBAImage.colorSpace)
        guard let filter = CIFilter(name: "CINoiseReduction") else { return img }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(noise, forKey: "inputNoiseLevel")
        filter.setValue(sharpness, forKey: "inputSharpness")
        guard let result = filter.outputImage?.cropped(to: input.extent) else { return img }
        var out = img
        out.pixels.withUnsafeMutableBytes { buf in
            ciContext.render(result, toBitmap: buf.baseAddress!, rowBytes: img.width * 4, bounds: input.extent, format: .RGBA8,
                             colorSpace: RGBAImage.colorSpace)
        }
        for i in stride(from: 3, to: out.pixels.count, by: 4) { out.pixels[i] = 255 }
        return out
    }

    /// Light unsharp mask over the whole result (Core Image, GPU). Results the model made below its native 4x come out
    /// a little soft after scaling down, and this brings back crispness without redrawing anything.
    static func sharpen(_ img: inout RGBAImage, amount: Float, radius: Float = 1.5) {
        guard amount > 0.001 else { return }
        let size = CGSize(width: img.width, height: img.height)
        let input = CIImage(bitmapData: Data(img.pixels), bytesPerRow: img.width * 4, size: size, format: .RGBA8,
                            colorSpace: RGBAImage.colorSpace)
        guard let filter = CIFilter(name: "CIUnsharpMask") else { return }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(amount, forKey: kCIInputIntensityKey)
        guard let result = filter.outputImage?.cropped(to: input.extent) else { return }
        let w = img.width
        img.pixels.withUnsafeMutableBytes { buf in
            ciContext.render(result, toBitmap: buf.baseAddress!, rowBytes: w * 4, bounds: input.extent, format: .RGBA8,
                             colorSpace: RGBAImage.colorSpace)
        }
    }

    /// Two passes of a box blur of `radius`, so the mask edge fades over about two radii.
    private static func feathered(_ m: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        var a = m, b = [UInt8](repeating: 0, count: m.count)
        let k = UInt32(2 * r + 1)
        for _ in 0..<2 {
            a.withUnsafeMutableBytes { sp in
                b.withUnsafeMutableBytes { dp in
                    var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    vImageBoxConvolve_Planar8(&s, &d, nil, 0, 0, k, k, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
            swap(&a, &b)
        }
        return a
    }
}
