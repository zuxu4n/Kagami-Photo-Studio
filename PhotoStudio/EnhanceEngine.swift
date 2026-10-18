import CoreML

/// 4x enhance/upscale with Real-ESRGAN general-x4v3 (BSD-3), converted to Core ML at a fixed 512x512 tile.
final class EnhanceEngine {
    static let shared = EnhanceEngine()

    let tile = 512
    let overlap = 32
    let scale = 4
    private var model: MLModel?

    func loadIfNeeded() throws -> MLModel {
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

    /// Enhances `input` 4x. The input is first capped to `maxInputSide` on its long side, so a 1024 px cap
    /// gives an output of up to 4096 px (about 12 MP for 4:3).
    func enhance(_ input: RGBAImage, maxInputSide: Int = 1024, progress: ((Double) -> Void)? = nil) throws -> RGBAImage {
        let model = try loadIfNeeded()
        var src = input
        if max(src.width, src.height) > maxInputSide {
            src = RGBAImage(cgImage: input.cgImage(), maxSide: maxInputSide)
        }
        let w = src.width, h = src.height
        let padded = src.paddedByReplication(minWidth: tile, minHeight: tile)
        let xs = tileStarts(padded.width), ys = tileStarts(padded.height)
        var out = RGBAImage(width: w * scale, height: h * scale)
        let total = xs.count * ys.count
        var done = 0
        for (iy, y0) in ys.enumerated() {
            // Each tile keeps the part up to the middle of its overlap with each neighbour.
            let vy0 = iy == 0 ? 0 : (ys[iy - 1] + tile + y0) / 2
            let vy1 = min(h, iy == ys.count - 1 ? y0 + tile : (y0 + tile + ys[iy + 1]) / 2)
            for (ix, x0) in xs.enumerated() {
                let vx0 = ix == 0 ? 0 : (xs[ix - 1] + tile + x0) / 2
                let vx1 = min(w, ix == xs.count - 1 ? x0 + tile : (x0 + tile + xs[ix + 1]) / 2)
                let inArr = try MLTensors.rgbTensor(from: padded, x0: x0, y0: y0, size: tile)
                let res = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": inArr]))
                guard let outArr = res.featureValue(for: "output")?.multiArrayValue else { throw EngineError.badOutput }
                if vx1 > vx0 && vy1 > vy0 {
                    MLTensors.copyRGB(from: outArr,
                                      tx0: (vx0 - x0) * scale, ty0: (vy0 - y0) * scale,
                                      width: (vx1 - vx0) * scale, height: (vy1 - vy0) * scale,
                                      into: &out, dx0: vx0 * scale, dy0: vy0 * scale)
                }
                done += 1
                progress?(Double(done) / Double(total))
            }
        }
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
