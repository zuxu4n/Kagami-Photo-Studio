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
    var slim: Float = 0       // -1...1, Jawline: slimmer or fuller (Apple Vision's outline)
    var eyes: Float = 0       // -1...1, Eyes › Size: smaller or bigger (Apple Vision's eyes)
    var eyeWidth: Float = 0   // -1...1, shorter or longer from corner to corner
    var eyeHeight: Float = 0  // -1...1, less or more open
    var eyeTilt: Float = 0    // -1...1, outer corners down or up
    var eyeDistance: Float = 0   // -1...1, closer together or further apart
    var nose: Float = 0       // 0...1, Nose › Narrow: a slimmer bridge
    var noseSize: Float = 0   // -1...1, smaller or bigger nose
    var noseWidth: Float = 0  // -1...1, narrower or wider nostrils and wings
    var noseLift: Float = 0   // -1...1, tip down or up
    var noseTip: Float = 0    // -1...1, smaller or bigger tip
    var size: Float = 0       // -1...1, smaller or bigger head
    var width: Float = 0      // -1...1, narrower or wider head (face, temples and hair)
    var perspective: Float = 0   // -1...1, as if the photo were taken from further away or closer
    var positionX: Float = 0  // Position: where the oval is, across and down the face, in half-widths and half-heights of the face
    var positionY: Float = 0
    var jaw: Float = 0        // -1...1, narrower or wider jaw corners
    var chin: Float = 0       // -1...1, shorter or longer chin
    var jawSize: Float = 0    // -1...1, smaller or bigger jaw
    var define: Float = 0     // 0...1, tighter under the jaw, sharper corners
    var jawLength: Float = 0  // -1...1, shorter or longer lower face
    var lips: Float = 0       // -1...1, Lips › Height: thinner or fuller lips
    var lipSize: Float = 0    // -1...1, smaller or bigger mouth
    var lipWidth: Float = 0   // -1...1, narrower or wider mouth
    var browThick: Float = 0  // -1...1, thinner or thicker brows
    var browLift: Float = 0   // -1...1, outer ends down or up (inner ends stay)
    var browShape: Float = 0  // -1...1, flatter or more arched
    var browTilt: Float = 0   // -1...1, outer ends down or up, turning about the middle
    var browRaise: Float = 0  // -1...1, whole brows lower or higher
    var smile: Float = 0      // 0...1, lifts the mouth corners
    var smirk: Float = 0      // -1...1, lifts the mouth corner on the photo's left or right
    var forehead: Float = 0   // -1...1, lower or higher hairline
    var pushes: [FacePush] = []   // in the order they were made; applied after the sliders
    var retouch = FaceRetouch()   // the Retouch tab's colour changes; not part of the warp (`isOff`)
    var meshOff: Bool {
        abs(slim) <= 0.001 && abs(eyes) <= 0.001 && abs(size) <= 0.001 && abs(width) <= 0.001 && abs(perspective) <= 0.001 && abs(positionX) <= 0.001 && abs(positionY) <= 0.001
            && abs(eyeWidth) <= 0.001 && abs(eyeHeight) <= 0.001 && abs(eyeTilt) <= 0.001 && abs(eyeDistance) <= 0.001
            && nose <= 0.001 && abs(noseSize) <= 0.001 && abs(noseWidth) <= 0.001 && abs(noseLift) <= 0.001 && abs(noseTip) <= 0.001
            && abs(jaw) <= 0.001 && abs(chin) <= 0.001 && abs(jawSize) <= 0.001 && define <= 0.001 && abs(jawLength) <= 0.001
            && abs(browThick) <= 0.001 && abs(browLift) <= 0.001 && abs(browShape) <= 0.001 && abs(browTilt) <= 0.001
            && abs(browRaise) <= 0.001
            && abs(lips) <= 0.001 && abs(lipSize) <= 0.001 && abs(lipWidth) <= 0.001 && smile <= 0.001 && abs(smirk) <= 0.001 && abs(forehead) <= 0.001
    }
    var isOff: Bool { abs(slim) <= 0.001 && abs(eyes) <= 0.001 && meshOff && pushes.isEmpty }
}

/// Matches the Metal `WarpOp` struct (32 bytes).
struct WarpOp {
    var c: SIMD2<Float>      // centre (pixels)
    var r: Float             // radius (pixels)
    var kind: Float          // 0 = translate, 1 = bulge, 2 = Reshape push, 3 = squeeze, 4 = scale, 5 = Perspective translate,
                             // 6 = skip marker (the next `pad` handles all lie within r of c)
    var m: SIMD2<Float>      // translate: displacement (pixels); squeeze and scale: the unit axis r is measured along
    var s: Float             // bulge, squeeze or scale: strength; translate: its slider's group (see TranslateGroup)
    var pad: Float = 0       // squeeze and scale: reach along the other axis (pixels; r is the reach along m)
}

/// Each slider's translate handles are blended among themselves (a weighted average, so its handles and holds can't pile
/// up), and the sliders' results are added. So one slider never weakens another where their handles overlap.
enum TranslateGroup {
    static let jawline: Float = 1, nose: Float = 2, jaw: Float = 3, chin: Float = 4, lips: Float = 5, mouth: Float = 6,
               forehead: Float = 7, jawSize: Float = 8, define: Float = 9, jawLength: Float = 10, noseSize: Float = 11,
               noseWidth: Float = 12, noseLift: Float = 13, eyeWidth: Float = 14, eyeHeight: Float = 15, eyeTilt: Float = 16,
               eyeDistance: Float = 17, eyeSize: Float = 24, lipSize: Float = 18, lipWidth: Float = 19, browRaise: Float = 20, browLift: Float = 21,
               browShape: Float = 22, browTilt: Float = 23
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

    /// Local warps (Gustafsson-style translate and bulge) for the Jawline and Eyes sliders, in pixels of a w x h image,
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
            let f = faces[i], (slim, eyes) = (shapes[i].slim, shapes[i].eyes)
            let faceW = Float(f.box.width) * W
            let mid = f.nose.isEmpty ? v(CGPoint(x: f.box.midX, y: f.box.midY)) : centroid(f.nose)
            if abs(slim) > 0.001, f.mesh.count != 478, f.contour.count > 6 {
                // Jawline without the mesh (meshOps does it otherwise): pull the jaw line (not the temples) towards the face's vertical centre line (slimmer is
                // negative), or push it out (fuller, at most 5% of the face's width, as more looks swollen).
                let amount = slim < 0 ? -slim * 0.07 : -slim * 0.05
                for p in f.contour.dropFirst(2).dropLast(2) {
                    let c = v(p)
                    let dir: Float = c.x < mid.x ? 1 : -1
                    ops.append(WarpOp(c: c, r: 0.25 * faceW, kind: 0, m: SIMD2(dir * amount * faceW, 0), s: TranslateGroup.jawline))
                }
            }
            if abs(eyes) > 0.001, f.mesh.count != 478 {   // Eyes › Size without the mesh: a bulge on each eye, or a pinch
                for eye in [f.leftEye, f.rightEye] where eye.count > 2 {
                    let xs = eye.map { Float($0.x) * W }
                    let eyeW = (xs.max() ?? 0) - (xs.min() ?? 0)
                    ops.append(WarpOp(c: centroid(eye), r: 1.5 * eyeW, kind: 1, m: .zero, s: eyes * 0.3))
                }
            }
            if !shapes[i].meshOff, f.mesh.count == 478 {
                ops += meshOps(f.mesh.map(v), f.meshDepth.map { Float($0) * W }, shapes[i])
            }
        }
        ops = withSkips(Array(ops.prefix(maxSliderOps)))
        // Pushes are applied one after another on top of the slider warp. The shader looks each one up at the
        // point it moved content to (c + m), so content under the finger follows the finger.
        for shape in shapes {
            for p in shape.pushes {
                let m = SIMD2(p.dx * W, p.dy * W)
                ops.append(WarpOp(c: SIMD2(p.x * W, p.y * H) + m, r: p.r * W, kind: 2, m: m, s: 0))
            }
        }
        return ops
    }

    /// Most slider handles kept across all faces (every slider on one face makes about 700). Biggest faces come
    /// first, so background faces are dropped first.
    static let maxSliderOps = 2000

    /// Puts a skip marker (kind 6) before each run of 4 or more translate or depth handles of one group: a circle
    /// holding every handle's reach and move, and how many handles follow. The shader skips the whole run for pixels
    /// outside it, so a frame costs about as much as the handles near each pixel rather than all of them.
    static func withSkips(_ ops: [WarpOp]) -> [WarpOp] {
        func key(_ op: WarpOp) -> Float? { op.kind < 0.5 ? op.s : (op.kind > 4.5 && op.kind < 5.5 ? -2 : nil) }
        var out: [WarpOp] = []
        out.reserveCapacity(ops.count + 64)
        var i = 0
        while i < ops.count {
            guard let k = key(ops[i]) else { out.append(ops[i]); i += 1; continue }
            var j = i
            while j < ops.count, key(ops[j]) == k { j += 1 }
            let run = ops[i..<j]
            if run.count >= 4 {
                let c = run.reduce(SIMD2<Float>(0, 0)) { $0 + $1.c } / Float(run.count)
                let reach = run.map { simd_length($0.c - c) + $0.r + simd_length($0.m) }.max()! + 2
                out.append(WarpOp(c: c, r: reach, kind: 6, m: .zero, s: 0, pad: Float(run.count)))
            }
            out.append(contentsOf: run)
            i = j
        }
        return out
    }

    /// One eye in MediaPipe's mesh: its corners, the upper and lower lid from the outer corner in, and the iris centre.
    struct MeshEye { let outer: Int, inner: Int, upper: [Int], lower: [Int], iris: Int }
    static let meshEyes = [
        MeshEye(outer: 33, inner: 133, upper: [246, 161, 160, 159, 158, 157, 173], lower: [7, 163, 144, 145, 153, 154, 155], iris: 468),
        MeshEye(outer: 263, inner: 362, upper: [466, 388, 387, 386, 385, 384, 398], lower: [249, 390, 373, 374, 380, 381, 382], iris: 473),
    ]

    /// One eyebrow in MediaPipe's mesh: its upper and lower edge, each from the outer end to the inner end, in
    /// matching columns. The outermost column sits just under the tail.
    struct MeshBrow { let upper: [Int], lower: [Int] }
    static let meshBrows = [MeshBrow(upper: [70, 63, 105, 66, 107], lower: [46, 53, 52, 65, 55]),
                            MeshBrow(upper: [300, 293, 334, 296, 336], lower: [276, 283, 282, 295, 285])]

    /// The lips' outer edge (from one corner round the upper lip and back round the lower lip) and inner edge.
    static let outerLips = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146]
    static let innerLips = [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95]

    /// The lower part of the outline, from beside one ear round the chin (index 10) to beside the other.
    static let lowerOutline = [234, 93, 132, 58, 172, 136, 150, 149, 176, 148, 152, 377, 400, 378, 379, 365, 397, 288, 361, 323, 454]

    /// MediaPipe's face outline, in order around the face from the top of the forehead.
    static let faceOval = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377,
                           152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]

    /// Points inside the outline that carry the Perspective and Position changes: nose, eyes, brows, cheeks, mouth, chin, forehead.
    static let depthPoints = [1, 6, 197, 98, 327, 33, 133, 362, 263, 105, 334, 50, 280, 117, 346, 205, 425, 123, 352,
                                    61, 291, 0, 17, 199, 151, 108, 337]

    /// The frame the Position oval moves in: the middle of the face (about the nose) and the face's own axes, with the
    /// outline's half-width `ra` along `across` and half-height `rb` along `down`, in pixels of a w x h image.
    static func positionFrame(for f: FaceGeometry, width w: Int, height h: Int) -> (centre: SIMD2<Float>, across: SIMD2<Float>, down: SIMD2<Float>, ra: Float, rb: Float)? {
        guard f.mesh.count == 478 else { return nil }
        let m = f.mesh.map { SIMD2(Float($0.x) * Float(w), Float($0.y) * Float(h)) }
        let across = simd_normalize(m[263] - m[33]), down = SIMD2(-across.y, across.x)
        let oval = faceOval.map { m[$0] }
        let mid = oval.reduce(SIMD2<Float>(0, 0), +) / Float(oval.count)
        let ra = oval.map { abs(simd_dot($0 - mid, across)) }.max() ?? 1
        let rb = oval.map { abs(simd_dot($0 - mid, down)) }.max() ?? 1
        return (mid, across, down, ra, rb)
    }

    /// Size, Width, Perspective, Position, Jaw, Chin, Lips, Smile, Smirk and Forehead handles from the MediaPipe mesh (`m`, in
    /// pixels, and `z`, each point's distance towards the camera in pixels). Directions follow the face's own axes
    /// (across = eye corner to eye corner, down = at right angles to it), so a tilted head changes the same way as an
    /// upright one.
    static func meshOps(_ m: [SIMD2<Float>], _ z: [Float], _ s: FaceShape) -> [WarpOp] {
        var ops: [WarpOp] = []
        let across = simd_normalize(m[263] - m[33])          // outer eye corners, image left to right
        let down = SIMD2(-across.y, across.x)
        let faceW = simd_length(m[454] - m[234])            // cheek to cheek
        let centre = (m[234] + m[454]) / 2
        var group: Float = 0   // the slider whose handles are being added (see TranslateGroup)
        func move(_ idx: [Int], r: Float, _ by: (SIMD2<Float>) -> SIMD2<Float>) {
            for k in idx { ops.append(WarpOp(c: m[k], r: r, kind: 0, m: by(m[k]), s: group)) }
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
        let turn = SIMD2(s.positionX, s.positionY)
        if abs(s.perspective) > 0.001 || simd_length(turn) > 0.001, z.count == m.count {
            // Perspective: a camera closer to the face enlarges what's nearer to it more than what's further away.
            // So each point moves away from the middle of the face (closer) or towards it (further) in proportion
            // to how far it sits in front of the face's average depth: the nose grows a little and the sides of the
            // face, which sit furthest back, come in.
            // Position: the head turns towards the oval, about the back of the head, more the further out it is (the
            // nose moves 3% of the face's width with the oval on the outline). Each point moves that way by how far it
            // sits in front of the sides of the face: the nose most, the eyes and mouth about half as far, the sides
            // of the face not at all.
            // A ring a third of the way further out than the outline moves the hair and ears beside each outline
            // point with it (Position: a bit less), and the change fades out beyond that. Both share these handles,
            // blended among themselves, so they add to the other sliders.
            let zRef = z.prefix(468).reduce(0, +) / 468
            let k = s.perspective * 0.2 / faceW
            let zBack = (z[234] + z[454]) / 2, zFront = z[1]       // the sides of the face and the nose tip
            let turnBy = (across * turn.x + down * turn.y) * 0.03 * faceW
            func shift(_ p: SIMD2<Float>, _ depth: Float, ring: Bool = false) -> SIMD2<Float> {
                let front = min(1, max(0, (depth - zBack) / max(zFront - zBack, 1)))
                return (p - mid) * k * (depth - zRef) + turnBy * front * (ring ? 0.6 : 1)
            }
            for i in depthPoints { ops.append(WarpOp(c: m[i], r: 0.2 * faceW, kind: 5, m: shift(m[i], z[i]), s: 0)) }
            for i in faceOval {
                ops.append(WarpOp(c: m[i], r: 0.25 * faceW, kind: 5, m: shift(m[i], z[i]), s: 0))
                ops.append(WarpOp(c: mid + (m[i] - mid) * 1.35, r: 0.4 * faceW, kind: 5, m: shift(m[i], z[i], ring: true), s: 0))
            }
        }
        if s.jaw > 0.001 {
            // The lower jaw on both sides, from the jaw's corner to beside the chin, towards the middle and slightly
            // up (narrower is negative), or out and slightly down.
            group = TranslateGroup.jaw
            move([172, 136, 150, 397, 365, 379], r: 0.22 * faceW) { (inward($0) - 0.2 * down) * -s.jaw * 0.045 * faceW }
        }
        if abs(s.chin) > 0.001 {
            // The bottom of the chin, along the face's down direction (longer is positive). The lower lip stays.
            group = TranslateGroup.chin
            move([152, 148, 377], r: 0.3 * faceW) { _ in down * s.chin * 0.05 * faceW }
            hold([17, 84, 314], r: 0.12 * faceW)
        }
        // Eyes tab, each eye on its own: its centre, its corner-to-corner width and the direction of its outer corner.
        // Each slider adds both eyes' handles together, so they blend as one group.
        let eyes = meshEyes.map { e -> (e: MeshEye, contour: [Int], c: SIMD2<Float>, w: Float, out: SIMD2<Float>) in
            let contour = [e.outer] + e.upper + [e.inner] + e.lower
            let c = contour.map { m[$0] }.reduce(SIMD2<Float>(0, 0), +) / Float(contour.count)
            return (e, contour, c, simd_length(m[e.outer] - m[e.inner]), simd_normalize(m[e.outer] - m[e.inner]))
        }
        // Lid points count less towards the corners (the first and last of each lid are next to a corner).
        func taper(_ i: Int, _ n: Int) -> Float { 1 - 0.5 * abs(Float(i) - Float(n - 1) / 2) / (Float(n - 1) / 2) }
        if abs(s.eyes) > 0.001 {
            // Eyes › Size: the eye's outline and iris away from its centre (bigger, positive) or towards it, so the
            // eye and iris scale together. The brows and the bridge of the nose stay.
            group = TranslateGroup.eyeSize
            for (e, contour, c, eyeW, _) in eyes {
                move(contour + (1...4).map { e.iris + $0 }, r: 0.45 * eyeW) { p in (p - c) * s.eyes * 0.4 }
            }
            hold([46, 53, 52, 65, 55, 276, 283, 282, 295, 285, 168, 6], r: 0.12 * faceW)
        }
        if abs(s.eyeWidth) > 0.001 {
            // Longer (positive) or shorter from corner to corner: the outer corner moves along the eye's own line,
            // the inner corner half as far (so the eyes don't crowd the nose). The iris keeps its shape.
            group = TranslateGroup.eyeWidth
            for (e, _, _, eyeW, out) in eyes {
                let d = out * s.eyeWidth * 0.12 * eyeW
                move([e.outer], r: 0.45 * eyeW) { _ in d }
                move([e.upper[0], e.lower[0]], r: 0.35 * eyeW) { _ in d * 0.6 }
                move([e.inner], r: 0.35 * eyeW) { _ in -d * 0.5 }
                move([e.upper[e.upper.count - 1], e.lower[e.lower.count - 1]], r: 0.3 * eyeW) { _ in -d * 0.3 }
                hold([e.iris], r: 0.2 * eyeW)
            }
        }
        if abs(s.eyeHeight) > 0.001 {
            // More open (positive) or less: the upper lid moves up and the lower lid down half as far, most in the
            // middle. The corners stay.
            group = TranslateGroup.eyeHeight
            for (e, _, _, eyeW, _) in eyes {
                for (i, k) in e.upper.enumerated() {
                    move([k], r: 0.3 * eyeW) { _ in -down * s.eyeHeight * 0.08 * eyeW * taper(i, e.upper.count) }
                }
                for (i, k) in e.lower.enumerated() {
                    move([k], r: 0.3 * eyeW) { _ in down * s.eyeHeight * 0.04 * eyeW * taper(i, e.lower.count) }
                }
                hold([e.outer, e.inner], r: 0.2 * eyeW)
            }
        }
        if abs(s.eyeTilt) > 0.001 {
            // Each eye turns about its centre so its outer corner goes up (positive) or down, up to 7 degrees.
            group = TranslateGroup.eyeTilt
            for (e, contour, c, eyeW, out) in eyes {
                let angle = s.eyeTilt * 0.12 * (simd_dot(out, across) < 0 ? 1 : -1)
                let (co, si) = (cos(angle), sin(angle))
                move(contour + [e.iris], r: 0.4 * eyeW) { p in
                    let d = p - c
                    return SIMD2(d.x * co - d.y * si, d.x * si + d.y * co) - d
                }
            }
        }
        if abs(s.eyeDistance) > 0.001 {
            // Each whole eye towards the middle of the face (closer, negative) or away from it. The bridge of the
            // nose stays.
            group = TranslateGroup.eyeDistance
            for (e, contour, c, eyeW, _) in eyes {
                let away = simd_dot(c - mid, across) < 0 ? -across : across
                move(contour + [e.iris], r: 0.45 * eyeW) { _ in away * s.eyeDistance * 0.15 * eyeW }
            }
            hold([168, 6, 197], r: 0.08 * faceW)
        }

        // Eyebrows tab. Each brow's columns run from the outer end (u = 0) to the inner end (u = 1); the middle of
        // each column is on the brow's centre line. The eyes stay where the brows move.
        let brows = meshBrows.map { b -> (b: MeshBrow, mids: [SIMD2<Float>], c: SIMD2<Float>, thick: Float) in
            let mids = zip(b.upper, b.lower).map { (m[$0] + m[$1]) / 2 }
            let thick = (1...3).map { simd_length(m[b.upper[$0]] - m[b.lower[$0]]) }.reduce(0, +) / 3
            return (b, mids, mids.reduce(SIMD2<Float>(0, 0), +) / Float(mids.count), thick)
        }
        let eyeHolds = [159, 158, 160, 157, 161, 33, 133, 386, 385, 387, 384, 388, 263, 362]
        // Moves every column of both brows by `by(column, u)`, upper and lower edge alike, holding the eyes.
        func moveBrows(_ by: (Int, Float) -> SIMD2<Float>) {
            for (b, _, _, _) in brows {
                for i in 0..<b.upper.count {
                    let d = by(i, Float(i) / Float(b.upper.count - 1))
                    move([b.upper[i], b.lower[i]], r: 0.09 * faceW) { _ in d }
                }
            }
            hold(eyeHolds, r: 0.05 * faceW)
        }
        if abs(s.browRaise) > 0.001 {
            // The whole brows up (positive) or down.
            group = TranslateGroup.browRaise
            moveBrows { _, _ in -down * s.browRaise * 0.035 * faceW }
        }
        if abs(s.browLift) > 0.001 {
            // The outer end up (positive) or down, less towards the middle, the inner end not at all.
            group = TranslateGroup.browLift
            moveBrows { _, u in -down * s.browLift * 0.035 * faceW * (1 - u) }
        }
        if abs(s.browShape) > 0.001 {
            // More arched (positive) or flatter: the arch, a third of the way in from the outer end, up or down;
            // both ends stay.
            group = TranslateGroup.browShape
            moveBrows { _, u in
                let t = u < 0.35 ? 0.5 * u / 0.35 : 0.5 + 0.5 * (u - 0.35) / 0.65
                return -down * s.browShape * 0.025 * faceW * sin(.pi * t)
            }
        }
        if abs(s.browTilt) > 0.001 {
            // Each brow turns about its middle so its outer end goes up (positive) or down, up to 7 degrees.
            group = TranslateGroup.browTilt
            for (b, mids, c, _) in brows {
                let angle = s.browTilt * 0.12 * (simd_dot(mids[0] - c, across) < 0 ? 1 : -1)
                let (co, si) = (cos(angle), sin(angle))
                move(b.upper + b.lower, r: 0.09 * faceW) { p in
                    let d = p - c
                    return SIMD2(d.x * co - d.y * si, d.x * si + d.y * co) - d
                }
            }
            hold(eyeHolds, r: 0.05 * faceW)
        }
        if abs(s.browThick) > 0.001 {
            // Thicker (positive) or thinner: each stretch of the brow's centre line gets a stretch (or squeeze) across
            // the brow, reaching 2.5 brow-thicknesses out and fading to nothing, so the brow widens about its own line.
            for (_, mids, _, thick) in brows {
                for i in 0..<(mids.count - 1) {
                    let along = mids[i + 1] - mids[i]
                    let normal = simd_normalize(SIMD2(-along.y, along.x))
                    ops.append(WarpOp(c: (mids[i] + mids[i + 1]) / 2, r: 2.5 * thick, kind: 3, m: normal,
                                      s: -s.browThick * 0.4, pad: simd_length(along)))
                }
            }
        }

        // Nose tab. The nose's own axis runs from between the eyes (168) to the tip (1); its width is wing to wing.
        let noseAxis = simd_normalize(m[1] - m[168])
        let noseW = simd_length(m[327] - m[98])
        func towardsNoseLine(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let rel = p - m[168]
            let off = rel - noseAxis * simd_dot(rel, noseAxis)
            return simd_length(off) > 0.001 ? -simd_normalize(off) : .zero
        }
        if abs(s.noseSize) > 0.001 {
            // The whole nose bigger (positive) or smaller about the middle of its lower half: tip, wings and sides
            // move away from or towards it. The top of the bridge, the inner eye corners, the cheeks beside the nose
            // and the upper lip stay.
            group = TranslateGroup.noseSize
            let c = (m[4] + m[5]) / 2
            move([1, 4, 2, 19, 94, 44, 274, 45, 275, 98, 327, 48, 278, 64, 294, 219, 439, 240, 460, 131, 360, 115, 344, 220, 440],
                 r: 0.35 * noseW) { p in (p - c) * s.noseSize * 0.12 }
            hold([168, 6, 133, 362, 0, 37, 267, 205, 425, 36, 266], r: 0.25 * noseW)
        }
        if abs(s.noseWidth) > 0.001 {
            // The wings and nostrils towards the nose's centre line (narrower is negative) or away from it. The tip,
            // the cheeks beside the nose and the upper lip stay.
            group = TranslateGroup.noseWidth
            move([98, 327, 48, 278, 64, 294, 219, 439, 240, 460, 102, 331], r: 0.35 * noseW) { p in towardsNoseLine(p) * -s.noseWidth * 0.12 * noseW }
            hold([1, 4, 205, 425, 36, 266, 0, 164], r: 0.25 * noseW)
        }
        if s.nose > 0.001 {
            // Narrow: the sides of the bridge, from between the eyes down to above the wings, towards the nose's
            // centre line. The line itself, the wings and the inner eye corners stay.
            group = TranslateGroup.nose
            move([198, 420, 209, 429, 236, 456, 217, 437, 131, 360, 134, 363, 51, 281, 3, 248, 174, 399], r: 0.35 * noseW) { p in
                towardsNoseLine(p) * s.nose * 0.1 * noseW
            }
            hold([6, 197, 195, 5, 4, 98, 327, 48, 278, 133, 362], r: 0.15 * noseW)
        }
        if abs(s.noseLift) > 0.001 {
            // The tip and the bottom of the nose up (positive) or down along the face's down direction, the wings
            // about half as far. The bridge above and the upper lip below stay, so the nose looks shorter and turned up.
            group = TranslateGroup.noseLift
            move([1, 4, 2, 19, 94, 44, 274, 45, 275], r: 0.35 * noseW) { _ in -down * s.noseLift * 0.1 * noseW }
            move([98, 327, 48, 278, 64, 294, 240, 460], r: 0.3 * noseW) { _ in -down * s.noseLift * 0.05 * noseW }
            hold([5, 195, 197, 6, 0, 37, 267, 164], r: 0.2 * noseW)
        }
        if abs(s.noseTip) > 0.001 {
            // The tip bigger (positive) or smaller: a bulge (or pinch) just above the tip point, about the tip's own size.
            ops.append(WarpOp(c: m[1] * 0.6 + m[4] * 0.4, r: 0.55 * noseW, kind: 1, m: .zero, s: s.noseTip * 0.25))
        }
        // How far along the lower outline a point is: 0 beside the ears, 1 at the chin.
        func level(_ i: Int) -> Float { 1 - Float(abs(i - 10)) / 10 }
        func ease(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        if abs(s.slim) > 0.001 {
            // Jawline: the outline from the cheeks round the chin towards the face's centre line (slimmer is
            // negative) or away from it (fuller, at most 6% of the face's width, as more looks swollen), along the
            // face's own across direction so a tilted head slims the same way. Points near the chin move less, as
            // they're already near the line.
            group = TranslateGroup.jawline
            let amount = s.slim < 0 ? -s.slim * 0.09 : -s.slim * 0.06
            for k in lowerOutline.dropFirst(2).dropLast(2) {
                let off = simd_dot(m[k] - centre, across)
                let side = min(1, max(-1, off / (0.3 * faceW)))
                move([k], r: 0.25 * faceW) { _ in -across * side * amount * faceW }
            }
        }
        if abs(s.jawSize) > 0.001 {
            // The jaw's outline away from the middle of the mouth (bigger is positive) or towards it: the chin and
            // jaw corners fully, fading out up the cheeks towards the ears. The mouth stays.
            group = TranslateGroup.jawSize
            let anchor = (m[61] + m[291]) / 2
            for (i, k) in lowerOutline.enumerated() {
                let w = ease(0, 0.45, level(i))
                if w > 0.01 { move([k], r: 0.22 * faceW) { p in (p - anchor) * s.jawSize * 0.1 * w } }
            }
            hold([61, 291, 0, 17], r: 0.12 * faceW)
        }
        if abs(s.jawLength) > 0.001 {
            // The lower face longer (positive) or shorter: the chin moves furthest along the face's down direction,
            // the jaw corners about a fifth as far, nothing beside the ears. The mouth stays, so the area between the
            // lower lip and the chin stretches.
            group = TranslateGroup.jawLength
            for (i, k) in lowerOutline.enumerated() {
                let w = ease(0.15, 1, level(i))
                if w > 0.01 { move([k], r: 0.25 * faceW) { _ in down * s.jawLength * 0.06 * faceW * w } }
            }
            hold([61, 291, 0, 17, 13, 14, 84, 314], r: 0.1 * faceW)
        }
        if s.define > 0.001 {
            // A sharper jawline: the soft area just under the jaw (from the corners round the chin) is drawn up
            // towards the jaw's edge, which stays put, so the edge gets crisper. The jaw corners move out a little.
            group = TranslateGroup.define
            for (i, k) in lowerOutline.enumerated() where level(i) >= 0.3 {
                let a = m[lowerOutline[max(i - 1, 0)]], b = m[lowerOutline[min(i + 1, lowerOutline.count - 1)]]
                var n = simd_normalize(SIMD2(-(b - a).y, (b - a).x))
                if simd_dot(n, m[k] - centre) < 0 { n = -n }   // away from the face
                ops.append(WarpOp(c: m[k] + n * 0.1 * faceW, r: 0.12 * faceW, kind: 0, m: -n * s.define * 0.045 * faceW, s: group))
                if k != 172, k != 397 { hold([k], r: 0.06 * faceW) }
            }
            move([172, 397], r: 0.12 * faceW) { p in simd_normalize(p - centre) * s.define * 0.02 * faceW }
        }
        let mouthW = simd_length(m[291] - m[61])
        let lipH = simd_length(m[17] - m[0])
        if abs(s.lips) > 0.001 {
            // Upper lip's top edge up and lower lip's bottom edge down (fuller is positive), with the line between
            // the lips held still, so each lip grows outwards from it and the mouth doesn't open.
            group = TranslateGroup.lips
            let amt = s.lips * 0.15 * lipH, r = 0.5 * lipH
            move([40, 39, 37, 0, 267, 269, 270], r: r) { _ in -down * amt }
            move([91, 181, 84, 17, 314, 405, 321], r: r) { _ in down * amt }
            hold([78, 81, 13, 311, 308, 178, 14, 402], r: r)
        }
        if abs(s.lipSize) > 0.001 {
            // The whole mouth bigger (positive) or smaller about its middle: every point on both lip edges moves away
            // from or towards it. The base of the nose and the chin stay.
            group = TranslateGroup.lipSize
            let c = outerLips.map { m[$0] }.reduce(SIMD2<Float>(0, 0), +) / Float(outerLips.count)
            move(outerLips + innerLips, r: 0.3 * mouthW) { p in (p - c) * s.lipSize * 0.15 }
            hold([2, 164, 167, 393, 152, 199, 175], r: 0.25 * mouthW)
        }
        if abs(s.lipWidth) > 0.001 {
            // The corners along the mouth's own line, out (wider, positive) or in, the lip next to them a bit less.
            // The middle of the lips stays.
            group = TranslateGroup.lipWidth
            let along = simd_normalize(m[291] - m[61])
            func side(_ p: SIMD2<Float>) -> SIMD2<Float> { simd_dot(p - (m[61] + m[291]) / 2, along) < 0 ? -along : along }
            move([61, 291, 78, 308], r: 0.35 * mouthW) { p in side(p) * s.lipWidth * 0.1 * mouthW }
            move([185, 146, 409, 375, 191, 95, 415, 324], r: 0.3 * mouthW) { p in side(p) * s.lipWidth * 0.06 * mouthW }
            hold([0, 17, 13, 14], r: 0.2 * mouthW)
        }
        if s.smile > 0.001 || abs(s.smirk) > 0.001 {
            // Mouth corners up and a little outward; the middle of the lips stays. Smirk lifts one corner on top of
            // Smile: the one on the photo's left (negative) or right (positive). The other corner stays where Smile puts it.
            group = TranslateGroup.mouth
            for i in [61, 291] {
                let onLeft = simd_dot(m[i] - centre, across) < 0
                let lift = s.smile * 0.1 + (onLeft ? max(0, -s.smirk) : max(0, s.smirk)) * 0.13
                move([i], r: 0.45 * mouthW) { p in (-down - 0.3 * inward(p)) * lift * mouthW }
            }
            hold([0, 17], r: 0.3 * mouthW)
        }
        if abs(s.forehead) > 0.001 {
            // The top of the forehead, up for a higher hairline (positive) or down for a lower one. The brows stay.
            group = TranslateGroup.forehead
            move([10, 109, 338, 67, 297], r: 0.28 * faceW) { _ in -down * s.forehead * 0.06 * faceW }
            hold([70, 63, 105, 66, 107, 336, 296, 334, 293, 300], r: 0.15 * faceW)
        }
        return ops
    }

    /// Where the slider warp (`ops`, without pushes) takes the content shown at `p`, the same steps as the shader: the
    /// point on the photo (as already pushed) that the sliders put at p. Used to place a new push under the sliders.
    static func sliderSource(_ p: SIMD2<Float>, _ ops: [WarpOp]) -> SIMD2<Float> {
        var p = p
        for op in ops where op.kind > 3.5 && op.kind < 4.5 {
            let d = p - op.c
            let a = simd_dot(d, op.m), b = simd_dot(d, SIMD2(-op.m.y, op.m.x))
            let x2 = a * a / (op.r * op.r) + b * b / (op.pad * op.pad)
            guard x2 < 1 else { continue }
            let t = min(1, max(0, (sqrt(x2) - 0.6) / 0.4))
            p = op.c + d * (1 - op.s * (1 - t * t * (3 - 2 * t)))
        }
        var q = p, run = SIMD2<Float>(0, 0), runW: Float = 0, runGroup: Float = -1
        func flush() { if runW > 0 { q -= run / max(1, runW) }; run = .zero; runW = 0 }
        for op in ops where op.kind < 0.5 || op.kind > 4.5 {
            if op.kind > 5.5 { flush(); runGroup = -1; continue }
            let group: Float = op.kind > 4.5 ? -2 : op.s
            if group != runGroup { flush(); runGroup = group }
            let d = p - op.c, x2 = simd_dot(d, d) / (op.r * op.r)
            guard x2 < 1 else { continue }
            let wgt = (1 - x2) * (1 - x2)
            run += wgt * op.m; runW += wgt
        }
        flush()
        for op in ops where op.kind > 2.5 && op.kind < 3.5 {
            let d = q - op.c
            let a = simd_dot(d, op.m), b = simd_dot(d, SIMD2(-op.m.y, op.m.x))
            let x2 = a * a / (op.r * op.r) + b * b / (op.pad * op.pad)
            if x2 < 1 { q += op.m * a * op.s * (1 - x2) * (1 - x2) }
        }
        for op in ops where op.kind > 0.5 && op.kind < 1.5 {
            let d = q - op.c, x2 = simd_dot(d, d) / (op.r * op.r)
            if x2 < 1 { q = op.c + d * (1 - op.s * (1 - x2) * (1 - x2)) }
        }
        return q
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
    /// top-left coordinates. They sit just outside the jaw line and follow the Slim, Size, Width, Perspective, Position,
    /// Jaw and Chin warps and the Reshape pushes, so they track the face as it changes.
    static func guideCurves(for f: FaceGeometry, width w: Int, height h: Int, shape: FaceShape, minGap: CGFloat = 0) -> [[CGPoint]] {
        let n = f.contour.count
        guard n > 6 else { return [] }
        let W = CGFloat(w), H = CGFloat(h)
        var pts = f.contour.map { CGPoint(x: $0.x * W, y: $0.y * H) }
        // Move each point the way the slim warp moves the pixels under it (forward version of the shader's blend).
        let outline = FaceShape(slim: shape.slim, size: shape.size, width: shape.width, perspective: shape.perspective,
                                positionX: shape.positionX, positionY: shape.positionY, jaw: shape.jaw, chin: shape.chin,
                                jawSize: shape.jawSize, define: shape.define, jawLength: shape.jawLength)
        let ops = warpOps(faces: [f], shapes: [outline], width: w, height: h)
        // Pushes move the photo first, then the sliders move the result.
        pts = pts.map { p0 in
            let p = pushed(p0, by: shape.pushes, width: w, height: h)
            // Translates (each slider's group on its own) and Perspective handles, blended and added as the shader does.
            func blended(_ kind: Float) -> CGVector {
                var groups: [Int: (d: CGVector, ws: CGFloat)] = [:]
                for op in ops where abs(op.kind - kind) < 0.5 {
                    let dx = p.x - CGFloat(op.c.x), dy = p.y - CGFloat(op.c.y)
                    let x2 = (dx * dx + dy * dy) / CGFloat(op.r * op.r)
                    guard x2 < 1 else { continue }
                    let wgt = (1 - x2) * (1 - x2)
                    let g = kind < 0.5 ? Int(op.s.rounded()) : 0
                    var e = groups[g] ?? (.zero, 0)
                    e.d.dx += wgt * CGFloat(op.m.x); e.d.dy += wgt * CGFloat(op.m.y); e.ws += wgt
                    groups[g] = e
                }
                return groups.values.reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.d.dx / max(1, $1.ws), dy: $0.dy + $1.d.dy / max(1, $1.ws)) }
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
            return q
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
