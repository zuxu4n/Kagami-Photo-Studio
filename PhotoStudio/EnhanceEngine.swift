import CoreML
import CoreGraphics

/// Enhance with Real-ESRGAN general-x4v3 (BSD-3), converted to Core ML at a fixed 512x512 tile (4x out).
/// It works from the photo's own pixels in tiles and never makes the photo smaller; see `plan`.
final class EnhanceEngine {
    static let shared = EnhanceEngine()

    let tile = 512
    let overlap = 32
    let scale = 4
    private var model: MLModel?
    private let lock = NSLock()  // the launch warm-up and a tap can both ask for the model

    func loadIfNeeded() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        return try load()
    }

    /// Loads the model and runs one blank tile, so the first real Enhance doesn't pay for setup.
    /// Returns (load ms, first-run ms), or nil if the model was already loaded.
    func warmUp() throws -> (load: Double, run: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard model == nil else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        let m = try load()
        let t1 = CFAbsoluteTimeGetCurrent()
        let blank = try MLTensors.rgbTensor(from: RGBAImage(width: tile, height: tile), x0: 0, y0: 0, size: tile)
        _ = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": blank]))
        return ((t1 - t0) * 1000, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
    }

    private func load() throws -> MLModel {
        if let model { return model }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all  // fastest for this model in the M1 test (Neural Engine + GPU)
        guard let url = Bundle.main.url(forResource: "RealESRGANGeneralX4", withExtension: "mlmodelc") else {
            throw EngineError.missingModel("RealESRGANGeneralX4")
        }
        let m = try MLModel(contentsOf: url, configuration: cfg)
        model = m
        return m
    }

    /// Tile start positions covering `n` pixels with `overlap` between neighbours.
    func tileStarts(_ n: Int) -> [Int] {
        guard n > tile else { return [0] }
        var starts = Array(stride(from: 0, through: n - tile, by: tile - overlap))
        if let last = starts.last, last + tile < n { starts.append(n - tile) }
        return starts
    }

    /// How a photo is enhanced. The model sees the photo divided by `inputDivisor` (1 = its own pixels) and the result
    /// is `outputScale` times the photo, so each model input pixel becomes `outputScale * inputDivisor` result pixels
    /// (at most the model's 4; below 4 each tile's 4x result is scaled down before stitching).
    struct Plan: Equatable, CustomStringConvertible {
        var inputDivisor: Int
        var outputScale: Int
        var description: String { "model input 1/\(inputDivisor), result x\(outputScale)" }
    }

    /// The result is never smaller than the photo, and is enlarged up to 4x while it stays within `maxOutputPixels`
    /// (4x for a typical 0.8 MP selfie, 1x for a 12 MP camera photo). The model runs on the photo's own pixels unless
    /// that takes more than `maxTiles` tiles; then it runs on a half-size copy (a 12 MP photo: 20 tiles instead of 63).
    func plan(width w: Int, height h: Int, maxOutputPixels: Int = 12_600_000, maxTiles: Int = 20) -> Plan {
        var s = 4
        while s > 1 && w * h * s * s > maxOutputPixels { s -= 1 }
        var d = 1
        while d < 4 && tileStarts((w + d - 1) / d).count * tileStarts((h + d - 1) / d).count > maxTiles { d += 1 }
        return Plan(inputDivisor: d, outputScale: max(1, min(s, 4 / d)))
    }

    /// Enhances `photo` as `plan` says, then blends each face area back toward the original by `faceProtection`
    /// (1 = faces exactly as they were, only resized). Enhance must not change faces; restoring faces is a separate tool.
    func enhance(_ photo: RGBAImage, plan: Plan, faces: [FaceGeometry] = [], faceProtection: Float = 1,
                 progress: ((Double) -> Void)? = nil) throws -> RGBAImage {
        let model = try loadIfNeeded()
        let d = plan.inputDivisor
        let src = d == 1 ? photo : RGBAImage(cgImage: photo.cgImage(), exactWidth: (photo.width + d - 1) / d,
                                             exactHeight: (photo.height + d - 1) / d)
        var out = try runTiles(src, perPixel: plan.outputScale * d, models: [model], progress: progress)
        EnhanceEngine.protectFaces(&out, original: photo, faces: faces, amount: faceProtection)
        return out
    }

    /// Runs the model over `src` in overlapping tiles and stitches the results at the overlap midpoints, with `g` result
    /// pixels per input pixel (1...4). Several models (for example one on the Neural Engine and one on the GPU) share
    /// the tiles between them; each writes only its own tiles' areas of the result.
    func runTiles(_ src: RGBAImage, perPixel g: Int, models: [MLModel], progress: ((Double) -> Void)? = nil) throws -> RGBAImage {
        precondition((1...scale).contains(g) && !models.isEmpty)
        let w = src.width, h = src.height
        let padded = src.paddedByReplication(minWidth: tile, minHeight: tile)
        let xs = tileStarts(padded.width), ys = tileStarts(padded.height)
        var jobs: [(x0: Int, y0: Int, vx0: Int, vy0: Int, vx1: Int, vy1: Int)] = []
        for (iy, y0) in ys.enumerated() {
            let vy0 = iy == 0 ? 0 : (ys[iy - 1] + tile + y0) / 2
            let vy1 = min(h, iy == ys.count - 1 ? y0 + tile : (y0 + tile + ys[iy + 1]) / 2)
            for (ix, x0) in xs.enumerated() {
                let vx0 = ix == 0 ? 0 : (xs[ix - 1] + tile + x0) / 2
                let vx1 = min(w, ix == xs.count - 1 ? x0 + tile : (x0 + tile + xs[ix + 1]) / 2)
                if vx1 > vx0 && vy1 > vy0 { jobs.append((x0, y0, vx0, vy0, vx1, vy1)) }
            }
        }
        let outW = w * g, outH = h * g
        var out = RGBAImage(width: outW, height: outH)
        let side = tile * g  // one tile's result after scaling
        let queueLock = NSLock()
        var next = 0, done = 0
        var failure: Error?
        out.pixels.withUnsafeMutableBufferPointer { dst in
            DispatchQueue.concurrentPerform(iterations: models.count) { worker in
                var full = RGBAImage(width: tile * scale, height: tile * scale)
                while true {
                    queueLock.lock()
                    let j = next
                    next += 1
                    let stop = failure != nil
                    queueLock.unlock()
                    if stop || j >= jobs.count { return }
                    let t = jobs[j]
                    do {
                        let inArr = try MLTensors.rgbTensor(from: padded, x0: t.x0, y0: t.y0, size: tile)
                        let res = try models[worker].prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": inArr]))
                        guard let outArr = res.featureValue(for: "output")?.multiArrayValue else { throw EngineError.badOutput }
                        MLTensors.copyRGB(from: outArr, tx0: 0, ty0: 0, width: tile * scale, height: tile * scale,
                                          into: &full, dx0: 0, dy0: 0)
                        let part = g == scale ? full : full.scaled(toWidth: side, height: side)
                        // Copy this tile's share of the result.
                        let cx0 = (t.vx0 - t.x0) * g, cy0 = (t.vy0 - t.y0) * g
                        let cw = (t.vx1 - t.vx0) * g, ch = (t.vy1 - t.vy0) * g
                        part.pixels.withUnsafeBufferPointer { sp in
                            for row in 0..<ch {
                                let si = ((cy0 + row) * side + cx0) * 4
                                let di = ((t.vy0 * g + row) * outW + t.vx0 * g) * 4
                                (dst.baseAddress! + di).update(from: sp.baseAddress! + si, count: cw * 4)
                            }
                        }
                    } catch {
                        queueLock.lock()
                        failure = failure ?? error
                        queueLock.unlock()
                        return
                    }
                    queueLock.lock()
                    done += 1
                    let fraction = Double(done) / Double(jobs.count)
                    queueLock.unlock()
                    progress?(fraction)
                }
            }
        }
        if let failure { throw failure }
        return out
    }
}

enum EngineError: LocalizedError {
    case missingModel(String)
    case badOutput
    case noFace

    var errorDescription: String? {
        switch self {
        case .missingModel(let n): return "Model \(n) is missing from the app bundle."
        case .badOutput: return "The model returned an unexpected output."
        case .noFace: return "No face found in this photo."
        }
    }
}
