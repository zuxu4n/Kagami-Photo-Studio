import CoreGraphics
import Accelerate

extension EnhanceEngine {
    /// Blends each face area of `out` back toward the original photo, resized to `out`'s size, by `amount`
    /// (1 = faces exactly as they were). The area is the jaw contour plus the forehead (the brows lifted, as in
    /// FaceAnalyzer.skinMask) with the eyes, brows and lips included, feathered at the edge.
    static func protectFaces(_ out: inout RGBAImage, original: RGBAImage, faces: [FaceGeometry], amount: Float) {
        guard amount > 0.001, !faces.isEmpty else { return }
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

            let outW = out.width
            out.pixels.withUnsafeMutableBufferPointer { o in
                orig.pixels.withUnsafeBufferPointer { s in
                    for y in 0..<bh {
                        for x in 0..<bw {
                            let m = Float(mask[y * bw + x]) / 255 * amount
                            if m < 0.004 { continue }
                            let di = ((minY + y) * outW + minX + x) * 4, si = (y * bw + x) * 4
                            for c in 0..<3 {
                                let a = Float(o[di + c]), b = Float(s[si + c])
                                o[di + c] = UInt8(a + (b - a) * m + 0.5)
                            }
                        }
                    }
                }
            }
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
