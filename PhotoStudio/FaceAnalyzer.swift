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
    var mesh: [CGPoint] = []   // MediaPipe Face Mesh V2, 478 points; empty if the mesh couldn't be placed
    var meshDepth: [CGFloat] = []   // each mesh point's distance towards the camera, as a fraction of the image width
}

/// One step of a Reshape drag: the pixels around (x, y) pushed by (dx, dy). x and y are normalised (0...1);
/// r, dx and dy are fractions of the image width, so a push keeps its shape at any resolution.
struct FacePush: Equatable {
    var x: Float, y: Float
    var r: Float
    var dx: Float, dy: Float
}

/// The Face tab's slider values and Reshape pushes for one face. Each face keeps its own.
struct FaceShape: Equatable {
    var slim: Float = 0
    var eyes: Float = 0
    var nose: Float = 0
    var size: Float = 0       // -1...1, smaller or bigger head
    var width: Float = 0      // -1...1, narrower or wider head (face, temples and hair)
    var perspective: Float = 0   // -1...1, as if the photo were taken from further away or closer
    var jaw: Float = 0        // 0...1, narrower jaw
    var chin: Float = 0       // -1...1, shorter or longer chin
    var lips: Float = 0       // -1...1, thinner or fuller lips
    var smile: Float = 0      // 0...1, lifts the mouth corners
    var smirk: Float = 0      // -1...1, lifts the mouth corner on the photo's left or right
    var forehead: Float = 0   // -1...1, lower or higher hairline
    var pushes: [FacePush] = []   // in the order they were made; applied after the sliders
    var meshOff: Bool {
        abs(size) <= 0.001 && abs(width) <= 0.001 && abs(perspective) <= 0.001 && jaw <= 0.001 && abs(chin) <= 0.001
            && abs(lips) <= 0.001 && smile <= 0.001 && abs(smirk) <= 0.001 && abs(forehead) <= 0.001
    }
    var isOff: Bool { slim <= 0.001 && eyes <= 0.001 && nose <= 0.001 && meshOff && pushes.isEmpty }
}

/// Matches the Metal `WarpOp` struct (32 bytes).
struct WarpOp {
    var c: SIMD2<Float>      // centre (pixels)
    var r: Float             // radius (pixels)
    var kind: Float          // 0 = translate, 1 = bulge, 2 = Reshape push, 3 = squeeze, 4 = scale, 5 = Perspective translate
    var m: SIMD2<Float>      // translate: displacement (pixels); squeeze and scale: the unit axis r is measured along
    var s: Float             // bulge, squeeze or scale: strength
    var pad: Float = 0       // squeeze and scale: reach along the other axis (pixels; r is the reach along m)
}

enum FaceAnalyzer {
    /// Apple Vision finds every face and its 76 landmarks; MediaPipe's Face Mesh then places 478 points on each
    /// face for the Jaw, Chin, Lips, Smile and Forehead sliders.
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
        var faces: [FaceGeometry] = (req.results ?? []).compactMap { obs in
            guard let lm = obs.landmarks else { return nil }
            let b = obs.boundingBox
            return FaceGeometry(box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                                contour: pts(lm.faceContour), leftEye: pts(lm.leftEye), rightEye: pts(lm.rightEye),
                                leftBrow: pts(lm.leftEyebrow), rightBrow: pts(lm.rightEyebrow),
                                outerLips: pts(lm.outerLips), nose: pts(lm.nose))
        }
        guard !faces.isEmpty else { return faces }
        let rgba = RGBAImage(cgImage: image)
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        func mean(_ ps: [CGPoint]) -> CGPoint? {
            ps.isEmpty ? nil : CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
        }
        for i in faces.indices {
            let f = faces[i]
            guard let le = mean(f.leftEye.map(px)), let re = mean(f.rightEye.map(px)) else { continue }
            let box = CGRect(x: f.box.minX * size.width, y: f.box.minY * size.height, width: f.box.width * size.width, height: f.box.height * size.height)
            if let mesh = try? FaceMeshEngine.shared.mesh(in: rgba, box: box, leftEye: le, rightEye: re) {
                faces[i].mesh = mesh.points.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) }
                faces[i].meshDepth = mesh.depth.map { $0 / size.width }
            }
        }
        return faces
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

    /// Most Reshape pushes kept across all faces (each one is checked by every pixel, so this bounds render time).
    static let maxPushes = 256

    /// Local warps (Gustafsson-style translate and bulge) for the slim, eyes and nose sliders, in pixels of a w x h image,
    /// followed by every face's Reshape pushes. `shapes[i]` holds the values for `faces[i]`.
    static func warpOps(faces: [FaceGeometry], shapes: [FaceShape], width w: Int, height h: Int) -> [WarpOp] {
        var ops: [WarpOp] = []
        let W = Float(w), H = Float(h)
        func v(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x) * W, Float(p.y) * H) }
        func centroid(_ ps: [CGPoint]) -> SIMD2<Float> {
            ps.reduce(SIMD2<Float>(0, 0)) { $0 + v($1) } / Float(max(ps.count, 1))
        }
        // Biggest faces first, so the handle cap drops background faces rather than the subject.
        for i in faces.indices.sorted(by: { faces[$0].box.width > faces[$1].box.width }) where i < shapes.count {
            let f = faces[i], (slim, eyes, nose) = (shapes[i].slim, shapes[i].eyes, shapes[i].nose)
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
            if !shapes[i].meshOff, f.mesh.count == 478 {
                ops += meshOps(f.mesh.map(v), f.meshDepth.map { Float($0) * W }, shapes[i])
            }
        }
        ops = Array(ops.prefix(maxSliderOps))
        // Pushes are applied one after another on top of the slider warp. The shader looks each one up at the
        // point it moved content to (c + m), so content under the finger follows the finger.
        for shape in shapes {
            for p in shape.pushes {
                let m = SIMD2(p.dx * W, p.dy * W)
                ops.append(WarpOp(c: SIMD2(p.x * W, p.y * H) + m, r: p.r * W, kind: 2, m: m, s: 0))
            }
        }
        return Array(ops.prefix(maxSliderOps + maxPushes))
    }

    /// Most slider handles kept across all faces. Biggest faces come first, so background faces are dropped first.
    static let maxSliderOps = 160

    /// MediaPipe's face outline, in order around the face from the top of the forehead.
    static let faceOval = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377,
                           152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]

    /// Points inside the outline that carry the Perspective change: nose, eyes, brows, cheeks, mouth, chin, forehead.
    static let perspectivePoints = [1, 6, 197, 98, 327, 33, 133, 362, 263, 105, 334, 50, 280, 117, 346, 205, 425, 123, 352,
                                    61, 291, 0, 17, 199, 151, 108, 337]

    /// Size, Width, Perspective, Jaw, Chin, Lips, Smile, Smirk and Forehead handles from the MediaPipe mesh (`m`, in
    /// pixels, and `z`, each point's distance towards the camera in pixels). Directions follow the face's own axes
    /// (across = eye corner to eye corner, down = at right angles to it), so a tilted head changes the same way as an
    /// upright one.
    static func meshOps(_ m: [SIMD2<Float>], _ z: [Float], _ s: FaceShape) -> [WarpOp] {
        var ops: [WarpOp] = []
        let across = simd_normalize(m[263] - m[33])          // outer eye corners, image left to right
        let down = SIMD2(-across.y, across.x)
        let faceW = simd_length(m[454] - m[234])            // cheek to cheek
        let centre = (m[234] + m[454]) / 2
        func move(_ idx: [Int], r: Float, _ by: (SIMD2<Float>) -> SIMD2<Float>) {
            for k in idx { ops.append(WarpOp(c: m[k], r: r, kind: 0, m: by(m[k]), s: 0)) }
        }
        func inward(_ p: SIMD2<Float>) -> SIMD2<Float> { simd_dot(p - centre, across) < 0 ? across : -across }
        // Handles that don't move: they hold features next to a moving area in place, so the move fades out
        // smoothly before it reaches them instead of dragging them along (or folding where two moves meet).
        func hold(_ idx: [Int], r: Float) { move(idx, r: r) { _ in .zero } }
        let oval = faceOval.map { m[$0] }
        let mid = oval.reduce(SIMD2<Float>(0, 0), +) / Float(oval.count)   // the middle of the face, about the nose
        if abs(s.size) > 0.001 {
            // The whole head bigger or smaller about the middle of the face: evenly across the face (the inner 60%
            // of an oval reaching a bit past the outline), fading out over the hair, ears and neck.
            let ra = oval.map { abs(simd_dot($0 - mid, across)) }.max() ?? faceW / 2
            let rb = oval.map { abs(simd_dot($0 - mid, down)) }.max() ?? faceW / 2
            ops.append(WarpOp(c: mid, r: ra * 1.05 / 0.6, kind: 4, m: across, s: s.size * 0.1, pad: rb * 1.05 / 0.6))
        }
        if abs(s.width) > 0.001 {
            // The whole head narrower or wider, hair included: one squeeze (or stretch) across the face, centred between
            // the cheeks, reaching a face width out to each side and a bit more up and down. It fades to nothing at its edge.
            ops.append(WarpOp(c: centre - down * 0.1 * faceW, r: 1.0 * faceW, kind: 3, m: across, s: -s.width * 0.12, pad: 1.15 * faceW))
        }
        if abs(s.perspective) > 0.001, z.count == m.count {
            // A camera closer to the face enlarges what's nearer to it more than what's further away. So each point
            // moves away from the middle of the face (closer) or towards it (further) in proportion to how far it sits
            // in front of the face's average depth: the nose grows a little and the sides of the face, which sit
            // furthest back, come in. A ring a third of the way further out moves the hair and ears beside each
            // outline point with it, and the change fades out beyond that. These handles are blended among
            // themselves, so they add to the other sliders.
            let zRef = z.prefix(468).reduce(0, +) / 468
            let k = s.perspective * 0.2 / faceW
            func shift(_ p: SIMD2<Float>, _ depth: Float) -> SIMD2<Float> { (p - mid) * k * (depth - zRef) }
            for i in perspectivePoints { ops.append(WarpOp(c: m[i], r: 0.2 * faceW, kind: 5, m: shift(m[i], z[i]), s: 0)) }
            for i in faceOval {
                ops.append(WarpOp(c: m[i], r: 0.25 * faceW, kind: 5, m: shift(m[i], z[i]), s: 0))
                ops.append(WarpOp(c: mid + (m[i] - mid) * 1.35, r: 0.4 * faceW, kind: 5, m: shift(m[i], z[i]), s: 0))
            }
        }
        if s.jaw > 0.001 {
            // The lower jaw on both sides, from the jaw's corner to beside the chin, towards the middle and slightly up.
            move([172, 136, 150, 397, 365, 379], r: 0.22 * faceW) { (inward($0) - 0.2 * down) * s.jaw * 0.045 * faceW }
        }
        if abs(s.chin) > 0.001 {
            // The bottom of the chin, along the face's down direction (longer is positive). The lower lip stays.
            move([152, 148, 377], r: 0.3 * faceW) { _ in down * s.chin * 0.05 * faceW }
            hold([17, 84, 314], r: 0.12 * faceW)
        }
        let mouthW = simd_length(m[291] - m[61])
        let lipH = simd_length(m[17] - m[0])
        if abs(s.lips) > 0.001 {
            // Upper lip's top edge up and lower lip's bottom edge down (fuller is positive), with the line between
            // the lips held still, so each lip grows outwards from it and the mouth doesn't open.
            let amt = s.lips * 0.15 * lipH, r = 0.5 * lipH
            move([40, 39, 37, 0, 267, 269, 270], r: r) { _ in -down * amt }
            move([91, 181, 84, 17, 314, 405, 321], r: r) { _ in down * amt }
            hold([78, 81, 13, 311, 308, 178, 14, 402], r: r)
        }
        if s.smile > 0.001 || abs(s.smirk) > 0.001 {
            // Mouth corners up and a little outward; the middle of the lips stays. Smirk lifts one corner on top of
            // Smile: the one on the photo's left (negative) or right (positive). The other corner stays where Smile puts it.
            for i in [61, 291] {
                let onLeft = simd_dot(m[i] - centre, across) < 0
                let lift = s.smile * 0.1 + (onLeft ? max(0, -s.smirk) : max(0, s.smirk)) * 0.13
                move([i], r: 0.45 * mouthW) { p in (-down - 0.3 * inward(p)) * lift * mouthW }
            }
            hold([0, 17], r: 0.3 * mouthW)
        }
        if abs(s.forehead) > 0.001 {
            // The top of the forehead, up for a higher hairline (positive) or down for a lower one. The brows stay.
            move([10, 109, 338, 67, 297], r: 0.28 * faceW) { _ in -down * s.forehead * 0.06 * faceW }
            hold([70, 63, 105, 66, 107, 336, 296, 334, 293, 300], r: 0.15 * faceW)
        }
        return ops
    }

    /// Moves a point (pixels of a w x h image) the way the Reshape pushes move the pixels under it.
    static func pushed(_ p: CGPoint, by pushes: [FacePush], width w: Int, height h: Int) -> CGPoint {
        let W = CGFloat(w), H = CGFloat(h)
        var q = p
        for u in pushes {
            let dx = q.x - CGFloat(u.x) * W, dy = q.y - CGFloat(u.y) * H, r = CGFloat(u.r) * W
            let x2 = (dx * dx + dy * dy) / (r * r)
            guard x2 < 1 else { continue }
            let wgt = (1 - x2) * (1 - x2)
            q.x += wgt * CGFloat(u.dx) * W; q.y += wgt * CGFloat(u.dy) * W
        }
        return q
    }

    // MARK: Outline guides for the Face tab

    /// Two curves bracketing the face's left and right sides, temple to jaw (chin left open), in normalised
    /// top-left coordinates. They sit just outside the jaw line and follow the Slim, Size, Width, Perspective, Jaw
    /// and Chin warps and the Reshape pushes, so they track the face as it changes.
    static func guideCurves(for f: FaceGeometry, width w: Int, height h: Int, shape: FaceShape, minGap: CGFloat = 0) -> [[CGPoint]] {
        let n = f.contour.count
        guard n > 6 else { return [] }
        let W = CGFloat(w), H = CGFloat(h)
        var pts = f.contour.map { CGPoint(x: $0.x * W, y: $0.y * H) }
        // Move each point the way the slim warp moves the pixels under it (forward version of the shader's blend).
        let outline = FaceShape(slim: shape.slim, size: shape.size, width: shape.width, perspective: shape.perspective, jaw: shape.jaw, chin: shape.chin)
        let ops = warpOps(faces: [f], shapes: [outline], width: w, height: h)
        pts = pts.map { p in
            // Translates and Perspective handles, each group blended among themselves as the shader does.
            func blended(_ kind: Float) -> CGVector {
                var d = CGVector.zero, ws: CGFloat = 0
                for op in ops where abs(op.kind - kind) < 0.5 {
                    let dx = p.x - CGFloat(op.c.x), dy = p.y - CGFloat(op.c.y)
                    let x2 = (dx * dx + dy * dy) / CGFloat(op.r * op.r)
                    guard x2 < 1 else { continue }
                    let wgt = (1 - x2) * (1 - x2)
                    d.dx += wgt * CGFloat(op.m.x); d.dy += wgt * CGFloat(op.m.y); ws += wgt
                }
                return CGVector(dx: d.dx / max(1, ws), dy: d.dy / max(1, ws))
            }
            let t = blended(0), pv = blended(5)
            var q = CGPoint(x: p.x + t.dx + pv.dx, y: p.y + t.dy + pv.dy)
            for op in ops where abs(op.kind - 3) < 0.5 {
                // The shader samples q + axis * a * s * fall, so content at q shows about a * s * fall nearer the middle.
                let ax = CGFloat(op.m.x), ay = CGFloat(op.m.y)
                let dx = q.x - CGFloat(op.c.x), dy = q.y - CGFloat(op.c.y)
                let a = dx * ax + dy * ay, b = -dx * ay + dy * ax
                let x2 = a * a / CGFloat(op.r * op.r) + b * b / CGFloat(op.pad * op.pad)
                guard x2 < 1 else { continue }
                let shift = a * CGFloat(op.s) * (1 - x2) * (1 - x2) / (1 + CGFloat(op.s))
                q.x -= ax * shift; q.y -= ay * shift
            }
            for op in ops where abs(op.kind - 4) < 0.5 {
                // The shader samples c + d * (1 - s * w), so content at q shows at about c + d / (1 - s * w).
                let ax = CGFloat(op.m.x), ay = CGFloat(op.m.y)
                let dx = q.x - CGFloat(op.c.x), dy = q.y - CGFloat(op.c.y)
                let a = dx * ax + dy * ay, b = -dx * ay + dy * ax
                let rho = sqrt(a * a / CGFloat(op.r * op.r) + b * b / CGFloat(op.pad * op.pad))
                guard rho < 1 else { continue }
                let t = min(1, max(0, (rho - 0.6) / 0.4)), wgt = 1 - t * t * (3 - 2 * t)
                let k = 1 / (1 - CGFloat(op.s) * wgt)
                q = CGPoint(x: CGFloat(op.c.x) + dx * k, y: CGFloat(op.c.y) + dy * k)
            }
            return pushed(q, by: shape.pushes, width: w, height: h)
        }
        // Both the shape and the ends come from the detected outline: each side is the outline itself, moved
        // outward by a fixed gap along its own normal, from its top point down to where the jaw turns towards
        // the chin (the outline gets flatter than 45 degrees). The chin stays open.
        // Where they end is set by the size of the head: both sides stop at the same level, 88% of the way from
        // the eyes down to the chin. That distance shrinks when the photo is taken from above, so those guides
        // come out shorter too. On a turned face the side facing the camera runs further down (up to 103%).
        let cx = pts.map(\.x).reduce(0, +) / CGFloat(n), cy = pts.map(\.y).reduce(0, +) / CGFloat(n)
        // The gap is 10% of the face's width, raised towards minGap (pixels, about 14 pt on screen) so mid-size faces
        // stay readable, but never above 15% of the face, so small faces in group shots keep their lines close.
        // minGap * 0.3 (about 4 pt) is the floor, so the line never touches the face.
        let faceW = f.box.width * W
        let gap = max(faceW * 0.1, min(minGap, faceW * 0.15), minGap * 0.3)
        let eyePts = (f.leftEye + f.rightEye).map { CGPoint(x: $0.x * W, y: $0.y * H) }
        let chin = pts[n / 2]
        let eyes = eyePts.isEmpty ? CGPoint(x: cx, y: cy)
            : CGPoint(x: eyePts.map(\.x).reduce(0, +) / CGFloat(eyePts.count), y: eyePts.map(\.y).reduce(0, +) / CGFloat(eyePts.count))
        let down = CGVector(dx: chin.x - eyes.x, dy: chin.y - eyes.y)          // eyes -> chin, follows head tilt
        let dd = max(down.dx * down.dx + down.dy * down.dy, 1)
        func level(_ p: CGPoint) -> CGFloat { ((p.x - eyes.x) * down.dx + (p.y - eyes.y) * down.dy) / dd }   // 0 at the eyes, 1 at the chin
        // How far the face is turned: the nose sits closer to the far side's end of the outline. Small
        // differences on front-on faces are ignored.
        let nose = f.nose.isEmpty ? eyes : CGPoint(x: f.nose.map(\.x).reduce(0, +) / CGFloat(f.nose.count) * W,
                                                   y: f.nose.map(\.y).reduce(0, +) / CGFloat(f.nose.count) * H)
        let dFirst = hypot(nose.x - pts[0].x, nose.y - pts[0].y), dLast = hypot(nose.x - pts[n - 1].x, nose.y - pts[n - 1].y)
        let turn = (dLast - dFirst) / max(dLast + dFirst, 1) * 2        // > 0: turned so the `last` side faces the camera
        let turnAmount = min(1, max(0, abs(turn) - 0.3) / 0.7)
        let nearCut = 0.88 + 0.15 * turnAmount
        func side(_ s: [CGPoint], cut: CGFloat) -> [CGPoint] {
            func tangent(_ i: Int) -> CGVector {
                let a = s[max(i - 1, 0)], b = s[min(i + 1, s.count - 1)]
                let len = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
                return CGVector(dx: (b.x - a.x) / len, dy: (b.y - a.y) / len)
            }
            var last = s.count - 1
            for i in 1..<s.count where abs(tangent(i).dy) < abs(tangent(i).dx) { last = i; break }
            let curve = (0...last).map { i in
                let t = tangent(i)
                var nx = -t.dy, ny = t.dx
                if nx * (s[i].x - cx) + ny * (s[i].y - cy) < 0 { nx = -nx; ny = -ny }   // point away from the face
                return CGPoint(x: s[i].x + nx * gap, y: s[i].y + ny * gap)
            }
            return trim(curve, atLevel: cut, level).map { CGPoint(x: $0.x / W, y: $0.y / H) }
        }
        let m = n / 2 + 1   // top point on each side through to the one beside the chin
        return [side(Array(pts.prefix(m)), cut: turn < 0 ? nearCut : 0.88),
                side(Array(pts.suffix(m).reversed()), cut: turn > 0 ? nearCut : 0.88)].map(smoothed)
    }

    // MARK: Geometry helpers

    /// Irons out the kinks between landmarks (two neighbour-averaging passes), then rounds the corners
    /// (Chaikin, twice). Both ends stay where they were.
    static func smoothed(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var p = pts
        for _ in 0..<2 {
            p = p.indices.map { i in
                guard i > 0, i < p.count - 1 else { return p[i] }
                return CGPoint(x: (p[i - 1].x + 2 * p[i].x + p[i + 1].x) / 4, y: (p[i - 1].y + 2 * p[i].y + p[i + 1].y) / 4)
            }
        }
        for _ in 0..<2 {
            var q = [p[0]]
            for (a, b) in zip(p, p.dropFirst()) {
                q.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                q.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            q.append(p[p.count - 1])
            p = q
        }
        return p
    }

    /// The polyline up to where `level` first reaches `cut` (interpolated), or all of it if it never does.
    static func trim(_ pts: [CGPoint], atLevel cut: CGFloat, _ level: (CGPoint) -> CGFloat) -> [CGPoint] {
        guard let first = pts.first else { return pts }
        var out = [first]
        for (a, b) in zip(pts, pts.dropFirst()) {
            let la = level(a), lb = level(b)
            if lb >= cut {
                let u = lb > la ? max(0, (cut - la) / (lb - la)) : 0
                out.append(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u))
                return out
            }
            out.append(b)
        }
        return out
    }

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
