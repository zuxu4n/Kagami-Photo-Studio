import CoreML
import CoreGraphics

/// Spot and object removal with LaMa big-lama (Apache-2.0) at a fixed 512x512 working size.
/// Loaded on CPU + GPU: on the Neural Engine its FFT-as-matmul graph took 5-6 minutes to compile in the M1 test.
final class HealEngine {
    static let shared = HealEngine()

    let size = 512
    /// The working size of the package's second function, used for people and other large areas. One copy of the
    /// weights serves both sizes (a Core ML multifunction package).
    let largeSize = 1024
    private var model: MLModel?
    private var largeModel: MLModel?
    private var largeMissing = false   // an older single-size package: large areas fall back to 512
    private let lock = NSLock()  // the launch warm-up and a tap can both ask for the model

    func loadIfNeeded() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        return try load()
    }

    /// Loads the model and runs one blank 512 pass, so the first real Heal doesn't pay for setup.
    /// Returns (load ms, first-run ms), or nil if the model was already loaded.
    func warmUp() throws -> (load: Double, run: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard model == nil else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        let m = try load()
        let t1 = CFAbsoluteTimeGetCurrent()
        let image = try MLTensors.rgbTensor(from: RGBAImage(width: size, height: size), x0: 0, y0: 0, size: size)
        let mask = try MLTensors.maskTensor(from: [UInt8](repeating: 0, count: size * size), size: size)
        _ = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": image, "mask": mask]))
        return ((t1 - t0) * 1000, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
    }

    /// The 1024 function, or nil if the bundled package only has 512. Loaded on first use (about as long as the 512 one).
    func largeIfAvailable() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if let largeModel { return largeModel }
        if largeMissing { return nil }
        guard let url = Bundle.main.url(forResource: "LamaInpaint", withExtension: "mlmodelc") else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU
        guard #available(iOS 18.0, macOS 15.0, *) else {
            largeMissing = true
            return nil
        }
        cfg.functionName = "lama\(largeSize)"
        do {
            largeModel = try MLModel(contentsOf: url, configuration: cfg)
        } catch {
            largeMissing = true
        }
        return largeModel
    }

    /// Loads the 1024 function and runs one blank pass (for the launch warm-up, after the other models).
    /// Returns nil if it was already loaded or the package doesn't have it.
    func warmUpLarge() throws -> (load: Double, run: Double)? {
        guard largeModel == nil else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let m = largeIfAvailable() else { return nil }
        let t1 = CFAbsoluteTimeGetCurrent()
        _ = try run(m, image: RGBAImage(width: largeSize, height: largeSize), mask: [UInt8](repeating: 0, count: largeSize * largeSize), n: largeSize)
        return ((t1 - t0) * 1000, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
    }

    /// Runs one `n` x `n` pass of `model` on `image` with `mask` (255 = fill) and returns the result.
    func run(_ model: MLModel, image: RGBAImage, mask: [UInt8], n: Int) throws -> RGBAImage {
        let imageArr = try MLTensors.rgbTensor(from: image, x0: 0, y0: 0, size: n)
        let maskArr = try MLTensors.maskTensor(from: mask, size: n)
        let res = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": imageArr, "mask": maskArr]))
        guard let outArr = res.featureValue(for: "output")?.multiArrayValue else { throw EngineError.badOutput }
        var out = RGBAImage(width: n, height: n)
        var planes = [UInt8]()
        MLTensors.copyRGBFast(from: outArr, into: &out, planes: &planes)
        return out
    }

    private func load() throws -> MLModel {
        if let model { return model }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU
        guard let url = Bundle.main.url(forResource: "LamaInpaint", withExtension: "mlmodelc") else {
            throw EngineError.missingModel("LamaInpaint")
        }
        let m = try MLModel(contentsOf: url, configuration: cfg)
        model = m
        return m
    }

    /// Removes everything under `mask` (one byte per pixel, 255 = remove) from `img`, in place.
    /// Works on a square context about 3x the masked area, resized to 512, then pastes back only the hole.
    func heal(_ img: inout RGBAImage, mask: [UInt8]) throws {
        let model = try loadIfNeeded()
        let w = img.width, h = img.height
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        let side = min(min(w, h), max(192, max(bw, bh) * 3))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let x0 = min(max(cx - side / 2, 0), w - side)
        let y0 = min(max(cy - side / 2, 0), h - side)
        let region = CGRect(x: x0, y: y0, width: side, height: side)

        // Image and mask at the model's working size.
        let ctx512 = img.resampled(region: region, width: size, height: size)
        let maskCrop = HealEngine.cropMask(mask, width: w, region: (x0, y0, side))
        let mask512 = HealEngine.resizeMask(maskCrop, from: side, to: size)
        let imageArr = try MLTensors.rgbTensor(from: ctx512, x0: 0, y0: 0, size: size)
        let maskArr = try MLTensors.maskTensor(from: mask512, size: size)
        let res = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": imageArr, "mask": maskArr]))
        guard let outArr = res.featureValue(for: "output")?.multiArrayValue else { throw EngineError.badOutput }
        var out512 = RGBAImage(width: size, height: size)
        MLTensors.copyRGB(from: outArr, tx0: 0, ty0: 0, width: size, height: size, into: &out512, dx0: 0, dy0: 0)
        let healed = RGBAImage(cgImage: out512.cgImage(), exactWidth: side, exactHeight: side)

        // Paste back with a softened hole edge so the patch blends in.
        let alpha = HealEngine.feather(maskCrop, side: side, radius: max(2, side / 128))
        img.pixels.withUnsafeMutableBufferPointer { dst in
            healed.pixels.withUnsafeBufferPointer { src in
                for y in 0..<side {
                    for x in 0..<side {
                        let a = Int(alpha[y * side + x])
                        if a == 0 { continue }
                        let si = (y * side + x) * 4
                        let di = ((y0 + y) * w + (x0 + x)) * 4
                        for c in 0..<3 {
                            dst[di + c] = UInt8((Int(src[si + c]) * a + Int(dst[di + c]) * (255 - a)) / 255)
                        }
                    }
                }
            }
        }
    }

    static func healSpot(_ img: inout RGBAImage, center: CGPoint, brush: Double) throws -> Int {
        let cx = min(img.width - 1, max(0, Int(center.x * CGFloat(img.width))))
        let cy = min(img.height - 1, max(0, Int(center.y * CGFloat(img.height))))
        let radius = max(4, Int(brush * Double(img.width)))
        var mask = [UInt8](repeating: 0, count: img.width * img.height)
        let r2 = radius * radius
        for y in max(0, cy - radius)...min(img.height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(img.width - 1, cx + radius) {
                let dx = x - cx, dy = y - cy
                if dx * dx + dy * dy <= r2 { mask[y * img.width + x] = 255 }
            }
        }
        try shared.heal(&img, mask: mask)
        return radius
    }

    static func cropMask(_ mask: [UInt8], width w: Int, region: (Int, Int, Int)) -> [UInt8] {
        let (x0, y0, side) = region
        var out = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            let s = (y0 + y) * w + x0
            for x in 0..<side { out[y * side + x] = mask[s + x] }
        }
        return out
    }

    /// Nearest-neighbour resize of a square mask, so it stays binary.
    static func resizeMask(_ m: [UInt8], from a: Int, to b: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: b * b)
        for y in 0..<b {
            let sy = min(a - 1, y * a / b)
            for x in 0..<b { out[y * b + x] = m[sy * a + min(a - 1, x * a / b)] }
        }
        return out
    }

    /// Dilates the mask by `radius`, then box-blurs it by `radius` to give a soft paste edge.
    static func feather(_ m: [UInt8], side: Int, radius r: Int) -> [UInt8] {
        // Dilation via a horizontal then vertical running max.
        var tmp = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var v: UInt8 = 0
                for k in max(0, x - r)...min(side - 1, x + r) where m[y * side + k] > v { v = m[y * side + k] }
                tmp[y * side + x] = v
            }
        }
        var dil = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var v: UInt8 = 0
                for k in max(0, y - r)...min(side - 1, y + r) where tmp[k * side + x] > v { v = tmp[k * side + x] }
                dil[y * side + x] = v
            }
        }
        // Separable box blur.
        var blurH = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var s = 0, n = 0
                for k in max(0, x - r)...min(side - 1, x + r) { s += Int(dil[y * side + k]); n += 1 }
                blurH[y * side + x] = UInt8(s / n)
            }
        }
        var out = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var s = 0, n = 0
                for k in max(0, y - r)...min(side - 1, y + r) { s += Int(blurH[k * side + x]); n += 1 }
                out[y * side + x] = UInt8(s / n)
            }
        }
        return out
    }
}
