import Vision
import CoreGraphics
import Accelerate

/// One face's landmarks, normalised to 0...1 of the image (top-left origin) so they apply at any resolution.
struct FaceGeometry {
    var box: CGRect
    var contour: [CGPoint]
    var leftEye: [CGPoint]
    var rightEye: [CGPoint]
    var leftBrow: [CGPoint]
    var rightBrow: [CGPoint]
    var outerLips: [CGPoint]
    var nose: [CGPoint]
}

/// Matches the Metal `WarpOp` struct (32 bytes).
struct WarpOp {
    var c: SIMD2<Float>      // centre (pixels)
    var r: Float             // radius (pixels)
    var kind: Float          // 0 = translate, 1 = bulge
    var m: SIMD2<Float>      // translate: displacement (pixels)
    var s: Float             // bulge: strength
    var pad: Float = 0
}

enum FaceAnalyzer {
    /// Apple Vision 76-point landmarks for every face (Face shape uses these until a denser mesh is added).
    static func detect(_ image: CGImage) -> [FaceGeometry] {
        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([req])
        let size = CGSize(width: image.width, height: image.height)
        func pts(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            // Vision is bottom-left origin: flip to top-left and normalise.
            return region.pointsInImage(imageSize: size).map { CGPoint(x: $0.x / size.width, y: 1 - $0.y / size.height) }
        }
        return (req.results ?? []).compactMap { obs in
            guard let lm = obs.landmarks else { return nil }
            let b = obs.boundingBox
            return FaceGeometry(box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                                contour: pts(lm.faceContour), leftEye: pts(lm.leftEye), rightEye: pts(lm.rightEye),
                                leftBrow: pts(lm.leftEyebrow), rightBrow: pts(lm.rightEyebrow),
                                outerLips: pts(lm.outerLips), nose: pts(lm.nose))
        }
    }

    // MARK: Skin mask for Smooth

    /// 8-bit mask at w x h: 255 on face skin (jaw contour plus forehead), 0 on eyes, brows and lips, feathered.
    static func skinMask(faces: [FaceGeometry], width w: Int, height h: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            // Draw in top-left pixel coordinates.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            let S = CGSize(width: w, height: h)
            func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * S.width, y: p.y * S.height) }
            for f in faces where f.contour.count > 4 {
                let jaw = f.contour.map(px)
                let brows = (f.leftBrow + f.rightBrow).map(px)
                let chin = jaw.max(by: { $0.y < $1.y }) ?? .zero
                let browY = brows.isEmpty ? (jaw.map(\.y).min() ?? 0) : brows.map(\.y).reduce(0, +) / CGFloat(brows.count)
                let lift = (chin.y - browY) * 0.45  // forehead height above the brows
                let forehead = brows.map { CGPoint(x: $0.x, y: $0.y - lift) }
                ctx.setFillColor(gray: 1, alpha: 1)
                fillHull(ctx, hull(jaw + forehead))
                ctx.setFillColor(gray: 0, alpha: 1)
                for region in [f.leftEye, f.rightEye] where !region.isEmpty { fillHull(ctx, scaled(region.map(px), 1.6)) }
                for region in [f.leftBrow, f.rightBrow] where !region.isEmpty { fillHull(ctx, scaled(region.map(px), 1.4)) }
                if !f.outerLips.isEmpty { fillHull(ctx, scaled(f.outerLips.map(px), 1.15)) }
            }
        }
        // Feather with a tent blur sized to the face.
        let faceW = Int((faces.map { $0.box.width }.max() ?? 0.2) * CGFloat(w))
        let k = max(3, (faceW / 25) | 1)
        var out = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { sb in
            out.withUnsafeMutableBytes { db in
                var src = vImage_Buffer(data: sb.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var dst = vImage_Buffer(data: db.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageTentConvolve_Planar8(&src, &dst, nil, 0, 0, UInt32(k), UInt32(k), 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    // MARK: Warp handles for Face shape

    /// Local warps (Gustafsson-style translate and bulge) for the slim, eyes and nose sliders, in pixels of a w x h image.
    static func warpOps(faces: [FaceGeometry], width w: Int, height h: Int, slim: Float, eyes: Float, nose: Float) -> [WarpOp] {
        var ops: [WarpOp] = []
        let W = Float(w), H = Float(h)
        func v(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x) * W, Float(p.y) * H) }
        func centroid(_ ps: [CGPoint]) -> SIMD2<Float> {
            ps.reduce(SIMD2<Float>(0, 0)) { $0 + v($1) } / Float(max(ps.count, 1))
        }
        for f in faces {
            let faceW = Float(f.box.width) * W
            let mid = f.nose.isEmpty ? v(CGPoint(x: f.box.midX, y: f.box.midY)) : centroid(f.nose)
            if slim > 0.001, f.contour.count > 6 {
                // Pull the jaw line (not the temples) towards the face's vertical centre line.
                for p in f.contour.dropFirst(2).dropLast(2) {
                    let c = v(p)
                    let dir: Float = c.x < mid.x ? 1 : -1
                    ops.append(WarpOp(c: c, r: 0.22 * faceW, kind: 0, m: SIMD2(dir * slim * 0.06 * faceW, 0), s: 0))
                }
            }
            if eyes > 0.001 {
                for eye in [f.leftEye, f.rightEye] where eye.count > 2 {
                    let xs = eye.map { Float($0.x) * W }
                    let eyeW = (xs.max() ?? 0) - (xs.min() ?? 0)
                    ops.append(WarpOp(c: centroid(eye), r: 1.5 * eyeW, kind: 1, m: .zero, s: eyes * 0.3))
                }
            }
            if nose > 0.001, f.nose.count > 2 {
                let xs = f.nose.map { Float($0.x) * W }
                let nmin = xs.min() ?? 0, nmax = xs.max() ?? 0
                let nw = nmax - nmin
                let c = centroid(f.nose)
                let amt = nose * 0.12 * nw
                ops.append(WarpOp(c: SIMD2(nmin, c.y), r: 0.8 * nw, kind: 0, m: SIMD2(amt, 0), s: 0))
                ops.append(WarpOp(c: SIMD2(nmax, c.y), r: 0.8 * nw, kind: 0, m: SIMD2(-amt, 0), s: 0))
            }
        }
        return Array(ops.prefix(64))
    }

    // MARK: Geometry helpers

    static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static func scaled(_ pts: [CGPoint], _ k: CGFloat) -> [CGPoint] {
        let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count), cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        return hull(pts).map { CGPoint(x: cx + ($0.x - cx) * k, y: cy + ($0.y - cy) * k) }
    }

    static func fillHull(_ ctx: CGContext, _ pts: [CGPoint]) {
        guard pts.count > 2 else { return }
        ctx.beginPath()
        ctx.addLines(between: pts)
        ctx.closePath()
        ctx.fillPath()
    }
}
