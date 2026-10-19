import Foundation
import CoreGraphics
import CoreML

/// On-device timing of the Enhance options for a 12 MP photo, for test builds. It runs when the app is launched with
/// the argument -EnhanceBench and writes Documents/enhance_bench.json (rewritten after every run, `done` at the end).
/// The photo is generated, so no personal photo is needed or bundled.
enum EnhanceBench {
    /// Launch argument EnhanceBench (with or without a leading dash), or the environment variable ENHANCE_BENCH=1.
    static var requested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-EnhanceBench") || args.contains("EnhanceBench") || ProcessInfo.processInfo.environment["ENHANCE_BENCH"] == "1"
    }

    static var outputURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("enhance_bench.json")
    }

    /// Runs every option twice and saves the results. Returns false if something threw.
    @discardableResult
    static func runAndSave() -> Bool {
        var report: [String: Any] = ["device": deviceModel(), "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                     "started": ISO8601DateFormatter().string(from: Date()), "done": false]
        var runs: [[String: Any]] = []
        func save() {
            report["runs"] = runs
            if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: outputURL)
            }
        }
        do {
            let engine = EnhanceEngine.shared
            let photo = testPhoto(width: 4032, height: 3024)
            let faces = [testFace()]
            let single = try engine.loadIfNeeded()
            let t0 = CFAbsoluteTimeGetCurrent()
            let split = try engine.splitModels()
            let blank = try MLTensors.rgbTensor(from: RGBAImage(width: engine.tile, height: engine.tile), x0: 0, y0: 0, size: engine.tile)
            for m in split { _ = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": blank])) }
            report["split_models_load_ms"] = ms(t0)
            save()

            let options: [(name: String, divisor: Int, split: Bool)] = [
                ("half size, one model", 2, false), ("half size, Neural Engine + GPU", 2, true),
                ("full size, one model", 1, false), ("full size, Neural Engine + GPU", 1, true),
                ("third size, one model", 3, false)]
            for o in options {
                for run in 1...2 {
                    let thermal = ProcessInfo.processInfo.thermalState.rawValue
                    let meter = MemoryMeter()
                    let stats = EnhanceEngine.TileStats()
                    let a = CFAbsoluteTimeGetCurrent()
                    let src = o.divisor == 1 ? photo : RGBAImage(cgImage: photo.cgImage(), exactWidth: (photo.width + o.divisor - 1) / o.divisor,
                                                                 exactHeight: (photo.height + o.divisor - 1) / o.divisor)
                    let b = CFAbsoluteTimeGetCurrent()
                    var out = try engine.runTiles(src, perPixel: o.divisor, models: o.split ? split : [single], stats: stats)
                    let c = CFAbsoluteTimeGetCurrent()
                    EnhanceEngine.treatFaces(&out, original: photo, faces: faces, treatment: .smallChanges(limit: 0))
                    let d = CFAbsoluteTimeGetCurrent()
                    EnhanceEngine.sharpen(&out, amount: 0.6)  // every 12 MP option runs below the model's 4x
                    let e = CFAbsoluteTimeGetCurrent()
                    var row: [String: Any] = ["option": o.name, "run": run, "total_ms": (e - a) * 1000,
                                              "shrink_photo_ms": (b - a) * 1000, "tiles_ms": (c - b) * 1000,
                                              "faces_ms": (d - c) * 1000, "sharpen_ms": (e - d) * 1000,
                                              "peak_mb": meter.stop(), "result": "\(out.width)x\(out.height)",
                                              "thermal_before": thermal, "thermal_after": ProcessInfo.processInfo.thermalState.rawValue]
                    if let free = MemoryMeter.availableMB() { row["avail_mb"] = free }
                    for (k, v) in stats.dictionary { row["tile_" + k] = v }
                    runs.append(row)
                    save()
                }
            }
            report["done"] = true
            save()
            return true
        } catch {
            report["error"] = error.localizedDescription
            save()
            return false
        }
    }

    private static func ms(_ t0: CFAbsoluteTime) -> Double { (CFAbsoluteTimeGetCurrent() - t0) * 1000 }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// A deterministic test photo: smooth gradients, fine stripes and noise, so every tile has real work to do.
    static func testPhoto(width w: Int, height h: Int) -> RGBAImage {
        var img = RGBAImage(width: w, height: h)
        var seed: UInt32 = 12345
        img.pixels.withUnsafeMutableBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    seed = seed &* 1664525 &+ 1013904223
                    let n = Int(seed >> 27) - 16  // noise in -16...15
                    let stripes = ((x / 3 + y / 7) % 2) * 24
                    let i = (y * w + x) * 4
                    p[i] = UInt8(max(0, min(255, x * 200 / w + 30 + stripes + n)))
                    p[i + 1] = UInt8(max(0, min(255, y * 180 / h + 40 + n)))
                    p[i + 2] = UInt8(max(0, min(255, 140 - stripes + n)))
                    p[i + 3] = 255
                }
            }
        }
        return img
    }

    /// One made-up face in the middle of the frame, so the face step does its normal work.
    static func testFace() -> FaceGeometry {
        let cx = 0.5, cy = 0.45, rx = 0.08, ry = 0.13
        let contour = (0...16).map { k -> CGPoint in
            let a = Double.pi * Double(k) / 16
            return CGPoint(x: cx - rx * cos(a), y: cy + ry * sin(a) * 0.9)
        }
        let brow = { (dx: Double) in [CGPoint(x: cx + dx - 0.03, y: cy - 0.05), CGPoint(x: cx + dx, y: cy - 0.06), CGPoint(x: cx + dx + 0.03, y: cy - 0.05)] }
        let eye = { (dx: Double) in [CGPoint(x: cx + dx - 0.02, y: cy - 0.02), CGPoint(x: cx + dx, y: cy - 0.03), CGPoint(x: cx + dx + 0.02, y: cy - 0.02), CGPoint(x: cx + dx, y: cy - 0.01)] }
        return FaceGeometry(box: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), contour: contour,
                            leftEye: eye(-0.035), rightEye: eye(0.035), leftBrow: brow(-0.035), rightBrow: brow(0.035),
                            outerLips: [CGPoint(x: cx - 0.03, y: cy + 0.06), CGPoint(x: cx, y: cy + 0.05), CGPoint(x: cx + 0.03, y: cy + 0.06), CGPoint(x: cx, y: cy + 0.075)],
                            nose: [CGPoint(x: cx, y: cy), CGPoint(x: cx - 0.015, y: cy + 0.03), CGPoint(x: cx + 0.015, y: cy + 0.03)])
    }
}
