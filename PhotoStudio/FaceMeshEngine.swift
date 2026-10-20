import CoreML
import CoreGraphics

/// MediaPipe Face Mesh V2 (Apache-2.0): 478 face landmarks from a 256x256 crop of one face, upright and with a 25%
/// margin on each side. Apple Vision finds the faces; this places the dense mesh on each one for the Face sliders.
final class FaceMeshEngine {
    static let shared = FaceMeshEngine()

    let size = 256
    private var model: MLModel?
    private let lock = NSLock()  // the launch warm-up and opening a photo can both ask for the model

    /// Loads the model and runs one blank crop. Returns (load ms, first-run ms), or nil if it was already loaded.
    func warmUp() throws -> (load: Double, run: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard model == nil else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        let m = try load()
        let t1 = CFAbsoluteTimeGetCurrent()
        let image = try MLTensors.rgbTensor(from: RGBAImage(width: size, height: size), x0: 0, y0: 0, size: size)
        _ = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": image]))
        return ((t1 - t0) * 1000, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
    }

    private func load() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: "FaceMesh", withExtension: "mlmodelc") else {
            throw EngineError.missingModel("FaceMesh")
        }
        let m = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
        model = m
        return m
    }

    /// The mesh for one face found by Vision, in pixels of `img`. Two passes, as MediaPipe's own tracking does:
    /// the first crop comes from Vision's box and eye line, the second from the first pass's landmarks, which
    /// centres and levels the face better. Nil when the model doesn't see a face there.
    /// `depth` is each point's distance towards the camera from the middle of the head, in image pixels.
    func mesh(in img: RGBAImage, box: CGRect, leftEye: CGPoint, rightEye: CGPoint) throws -> (points: [CGPoint], depth: [CGFloat])? {
        let (a, b) = leftEye.x < rightEye.x ? (leftEye, rightEye) : (rightEye, leftEye)
        let angle = atan2(b.y - a.y, b.x - a.x)
        guard let first = try landmarks(in: img, center: CGPoint(x: box.midX, y: box.midY), side: max(box.width, box.height) * 1.5, angle: angle)
        else { return nil }
        let xs = first.points.map(\.x), ys = first.points.map(\.y)
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let level = atan2(first.points[263].y - first.points[33].y, first.points[263].x - first.points[33].x)   // outer eye corners
        return try landmarks(in: img, center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                             side: max(maxX - minX, maxY - minY) * 1.5, angle: level) ?? first
    }

    /// The mesh for a face tracked from the last video frame: one pass on the crop that frame's mesh places (as
    /// MediaPipe's own tracking does between detections), in pixels of `img`. Nil when the face has gone.
    func track(in img: RGBAImage, previous m: [CGPoint]) throws -> (points: [CGPoint], depth: [CGFloat])? {
        guard m.count >= 478 else { return nil }
        let xs = m.map(\.x), ys = m.map(\.y)
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let level = atan2(m[263].y - m[33].y, m[263].x - m[33].x)
        return try landmarks(in: img, center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                             side: max(maxX - minX, maxY - minY) * 1.5, angle: level)
    }

    /// Runs the model on the square of `side` pixels centred on `center` and turned by `angle` (radians, y down),
    /// and maps its landmarks back to image pixels. The model's z is negative towards the camera, in crop pixels.
    private func landmarks(in img: RGBAImage, center: CGPoint, side: CGFloat, angle: CGFloat) throws -> (points: [CGPoint], depth: [CGFloat])? {
        lock.lock()
        defer { lock.unlock() }
        let model = try load()
        let n = size
        let k = side / CGFloat(n), c = cos(angle), s = sin(angle)
        // Crop pixel (u, v) comes from x0 + (a u + b v, d u + e v).
        let a = c * k, b = -s * k, d = s * k, e = c * k
        let x0 = center.x - (a + b) * CGFloat(n) / 2, y0 = center.y - (d + e) * CGFloat(n) / 2
        var crop = RGBAImage(width: n, height: n)
        let W = img.width, H = img.height
        img.pixels.withUnsafeBufferPointer { src in
            crop.pixels.withUnsafeMutableBufferPointer { dst in
                for v in 0..<n {
                    for u in 0..<n {
                        // Bilinear sample at the pixel centre, clamped to the edge.
                        let fu = CGFloat(u) + 0.5, fv = CGFloat(v) + 0.5
                        let sx = min(max(x0 + a * fu + b * fv - 0.5, 0), CGFloat(W - 1))
                        let sy = min(max(y0 + d * fu + e * fv - 0.5, 0), CGFloat(H - 1))
                        let ix = min(Int(sx), max(W - 2, 0)), iy = min(Int(sy), max(H - 2, 0))
                        let fx = Float(sx - CGFloat(ix)), fy = Float(sy - CGFloat(iy))
                        let i00 = (iy * W + ix) * 4, i10 = i00 + 4, i01 = i00 + W * 4, i11 = i01 + 4
                        let o = (v * n + u) * 4
                        for ch in 0..<3 {
                            let top = Float(src[i00 + ch]) * (1 - fx) + Float(src[i10 + ch]) * fx
                            let bot = Float(src[i01 + ch]) * (1 - fx) + Float(src[i11 + ch]) * fx
                            dst[o + ch] = UInt8(min(255, max(0, top * (1 - fy) + bot * fy + 0.5)))
                        }
                        dst[o + 3] = 255
                    }
                }
            }
        }
        let input = try MLTensors.rgbTensor(from: crop, x0: 0, y0: 0, size: n)
        let res = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let lm = res.featureValue(for: "landmarks")?.multiArrayValue, lm.count >= 478 * 3,
              let presence = res.featureValue(for: "presence")?.multiArrayValue else { throw EngineError.badOutput }
        guard presence[0].floatValue > 0 else { return nil }   // a logit: below 0 means under 50% sure it's a face
        let points = (0..<478).map { i in
            let u = CGFloat(lm[i * 3].floatValue), v = CGFloat(lm[i * 3 + 1].floatValue)
            return CGPoint(x: x0 + a * u + b * v, y: y0 + d * u + e * v)
        }
        return (points, (0..<478).map { -CGFloat(lm[$0 * 3 + 2].floatValue) * k })
    }
}
