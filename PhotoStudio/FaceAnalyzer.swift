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

    /// Two-channel smoothing mask at w x h, interleaved as R,G bytes:
    /// R = face skin (jaw contour plus forehead), smoothed with lenient colour gating;
    /// G = body skin candidates, smoothed only where the colour is clearly skin. By default that's a fade down the
    /// neck below each jaw; with `person` (Apple's person cutout, "All skin") it's the whole person, so walls, wood
    /// and sand outside the person are never touched.
    /// Eyes, brows and lips are cut out of both channels.
    static func smoothMasks(faces: [FaceGeometry], width w: Int, height h: Int, person: [UInt8]?) -> [UInt8] {
        let S = CGSize(width: w, height: h)
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * S.width, y: p.y * S.height) }

        var face = [UInt8](repeating: 0, count: w * h)
        draw(into: &face, width: w, height: h) { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            for f in faces where f.contour.count > 4 {
                let jaw = f.contour.map(px)
                let brows = (f.leftBrow + f.rightBrow).map(px)
                let chin = jaw.max(by: { $0.y < $1.y }) ?? .zero
                let browY = brows.isEmpty ? (jaw.map(\.y).min() ?? 0) : brows.map(\.y).reduce(0, +) / CGFloat(brows.count)
                let lift = (chin.y - browY) * 0.45  // forehead height above the brows
                fillHull(ctx, hull(jaw + brows.map { CGPoint(x: $0.x, y: $0.y - lift) }))
            }
        }

        var body = person ?? [UInt8](repeating: 0, count: w * h)
        if person == nil {
            draw(into: &body, width: w, height: h) { ctx in
                for f in faces where f.contour.count > 4 {
                    let jaw = f.contour.map(px)
                    let midY = jaw.map(\.y).reduce(0, +) / CGFloat(jaw.count)
                    let lower = jaw.filter { $0.y >= midY }.sorted { $0.x < $1.x }
                    guard let l = lower.first, let r = lower.last, r.x - l.x > 4 else { continue }
                    let chinY = jaw.map(\.y).max() ?? midY
                    let faceH = CGFloat(f.box.height) * S.height
                    let depth = faceH * 0.75, inset = (r.x - l.x) * 0.12
                    let poly = lower + [CGPoint(x: r.x - inset, y: chinY + depth), CGPoint(x: l.x + inset, y: chinY + depth)]
                    ctx.saveGState()
                    ctx.beginPath(); ctx.addLines(between: poly); ctx.closePath(); ctx.clip()
                    let g = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2)!
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: midY), end: CGPoint(x: 0, y: chinY + depth), options: [])
                    ctx.restoreGState()
                }
            }
        }

        var protect = [UInt8](repeating: 0, count: w * h)
        draw(into: &protect, width: w, height: h) { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            for f in faces {
                for region in [f.leftEye, f.rightEye] where !region.isEmpty { fillHull(ctx, scaled(region.map(px), 1.6)) }
                for region in [f.leftBrow, f.rightBrow] where !region.isEmpty { fillHull(ctx, scaled(region.map(px), 1.4)) }
                if !f.outerLips.isEmpty { fillHull(ctx, scaled(f.outerLips.map(px), 1.15)) }
            }
        }

        // Feather sized to the face (or the image when there's no face).
        let faceW = Int((faces.map { $0.box.width }.max() ?? 0.2) * CGFloat(w))
        let k = max(3, (faceW / 25) | 1)
        face = tent(face, width: w, height: h, k: k)
        body = tent(body, width: w, height: h, k: k)
        protect = tent(protect, width: w, height: h, k: max(3, (k / 3) | 1))

        var out = [UInt8](repeating: 0, count: w * h * 2)
        for i in 0..<(w * h) {
            let keep = 255 - Int(protect[i])
            out[2 * i] = UInt8(Int(face[i]) * keep / 255)
            out[2 * i + 1] = UInt8(Int(body[i]) * keep / 255)
        }
        return out
    }

    /// The person's own skin colour (luma, Cb, Cr) learned from the face channel of a smoothMasks mask.
    /// Returns (mean, sigma) packed as float4s for the shader; mean.w = 1 marks it valid. Body smoothing then
    /// only touches pixels close to this colour and brightness, which keeps hair out for any skin tone.
    static func skinReference(_ img: RGBAImage, mask: [UInt8], maskWidth mw: Int, maskHeight mh: Int) -> (SIMD4<Float>, SIMD4<Float>) {
        var n: Float = 0
        var sum = SIMD3<Float>(repeating: 0), sum2 = SIMD3<Float>(repeating: 0)
        for my in stride(from: 0, to: mh, by: 2) {
            for mx in stride(from: 0, to: mw, by: 2) where mask[2 * (my * mw + mx)] >= 220 {
                let x = mx * img.width / mw, y = my * img.height / mh
                let i = (y * img.width + x) * 4
                let r = Float(img.pixels[i]) / 255, g = Float(img.pixels[i + 1]) / 255, b = Float(img.pixels[i + 2]) / 255
                let yv = 0.299 * r + 0.587 * g + 0.114 * b
                let cb = 0.5 + (-0.168736 * r - 0.331264 * g + 0.5 * b)
                let cr = 0.5 + (0.5 * r - 0.418688 * g - 0.081312 * b)
                if cb < 0.29 || cb > 0.52 || cr < 0.52 || cr > 0.70 { continue }  // skip hair/eye pixels inside the face area
                let v = SIMD3<Float>(yv, cb, cr)
                sum += v; sum2 += v * v; n += 1
            }
        }
        guard n > 50 else { return (SIMD4(0, 0, 0, 0), SIMD4(1, 1, 1, 0)) }
        let mean = sum / n
        let sd = (sum2 / n - mean * mean).squareRoot()  // per-component sqrt
        let sigma = SIMD3<Float>(max(sd.x * 2.5, 0.12), max(sd.y * 2.5, 0.025), max(sd.z * 2.5, 0.025))
        return (SIMD4(mean.x, mean.y, mean.z, 1), SIMD4(sigma.x, sigma.y, sigma.z, 0))
    }

    /// Apple Vision person cutout (soft matte), resampled to w x h. Used by "All skin".
    static func personMask(_ image: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([req])
        guard let pb = req.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pb)), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        return scalePlanar(&src, width: w, height: h)
    }

    /// Resamples an 8-bit mask to w x h.
    static func resample(_ m: [UInt8], fromWidth sw: Int, height sh: Int, toWidth w: Int, height h: Int) -> [UInt8] {
        if sw == w && sh == h { return m }
        var copy = m
        return copy.withUnsafeMutableBytes { sb -> [UInt8] in
            var src = vImage_Buffer(data: sb.baseAddress, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: sw)
            return scalePlanar(&src, width: w, height: h)
        }
    }

    private static func scalePlanar(_ src: inout vImage_Buffer, width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { db in
            var dst = vImage_Buffer(data: db.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        return out
    }

    private static func draw(into bytes: inout [UInt8], width w: Int, height h: Int, _ body: (CGContext) -> Void) {
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))  // top-left pixel coordinates
            ctx.scaleBy(x: 1, y: -1)
            body(ctx)
        }
    }

    private static func tent(_ m: [UInt8], width w: Int, height h: Int, k: Int) -> [UInt8] {
        var srcBytes = m
        var out = [UInt8](repeating: 0, count: w * h)
        srcBytes.withUnsafeMutableBytes { sb in
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
        // Biggest faces first, so the 64-handle cap drops background faces rather than the subject.
        for f in faces.sorted(by: { $0.box.width > $1.box.width }) {
            let faceW = Float(f.box.width) * W
            let mid = f.nose.isEmpty ? v(CGPoint(x: f.box.midX, y: f.box.midY)) : centroid(f.nose)
            if slim > 0.001, f.contour.count > 6 {
                // Pull the jaw line (not the temples) towards the face's vertical centre line.
                for p in f.contour.dropFirst(2).dropLast(2) {
                    let c = v(p)
                    let dir: Float = c.x < mid.x ? 1 : -1
                    ops.append(WarpOp(c: c, r: 0.25 * faceW, kind: 0, m: SIMD2(dir * slim * 0.07 * faceW, 0), s: 0))
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
