import SwiftUI
import Photos

enum Tool: String, CaseIterable, Identifiable {
    case enhance = "Enhance", smooth = "Smooth", heal = "Heal", face = "Face"
    var id: String { rawValue }
}

/// Holds the photo and runs every tool on the device. Enhance and Heal change the working image.
/// Smooth and Face shape are live sliders, rendered on a preview and again at full size on Save.
@MainActor
final class EditorModel: ObservableObject {
    @Published var display: UIImage?
    @Published var original: UIImage?
    @Published var busy: String?
    @Published var error: String?
    @Published var tool: Tool = .enhance
    @Published var smooth: Float = 0
    @Published var slim: Float = 0
    @Published var eyes: Float = 0
    @Published var nose: Float = 0
    @Published var brush: Float = 0.025      // heal brush radius as a fraction of the image width
    @Published var faceCount = 0
    @Published var timings: [(String, Double)] = []
    @Published var info: String = ""

    private var working: RGBAImage?     // full resolution, after Enhance/Heal
    private var preview: RGBAImage?     // long side <= previewSide, for live sliders
    private var faces: [FaceGeometry] = []
    private var renderTask: Task<Void, Never>?
    private var warmedUp = false

    let maxWorkingSide = 4032
    let previewSide = 1600

    var hasImage: Bool { working != nil }
    var previewSize: CGSize { preview.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    // MARK: Warm-up at launch, so the first tap on each tool isn't slow

    /// Compiles the slider GPU code, then loads the Heal and Enhance models in the background, one at a time.
    /// A tap that needs a model while it's still loading waits for that load instead of starting another.
    func warmUp() async {
        guard !warmedUp else { return }
        warmedUp = true
        let (gpuMs, gpuPeak) = await Task.detached(priority: .userInitiated) { () -> (Double, Double) in
            let meter = MemoryMeter()
            let t0 = CFAbsoluteTimeGetCurrent()
            GPU.shared.warmUp()
            return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
        }.value
        record("Warm-up: slider GPU code", gpuMs, peakMB: gpuPeak)
        await warmModel("Heal") { try HealEngine.shared.warmUp() }  // biggest first-use cost (about 3.5 s), so first
        await warmModel("Enhance") { try EnhanceEngine.shared.warmUp() }
    }

    private func warmModel(_ name: String, _ body: @escaping @Sendable () throws -> (load: Double, run: Double)?) async {
        let (times, peak, failure) = await Task.detached(priority: .userInitiated) { () -> ((load: Double, run: Double)?, Double, String?) in
            let meter = MemoryMeter()
            do { return (try body(), meter.stop(), nil) } catch { return (nil, meter.stop(), error.localizedDescription) }
        }.value
        if let failure {
            record("Warm-up: \(name) failed (\(failure))", 0, peakMB: peak)
        } else if let times {  // nil when a tap loaded the model first
            record("Warm-up: \(name) model", times.load + times.run, peakMB: peak,
                   extra: ["load_ms": times.load, "first_run_ms": times.run])
        }
    }

    func noteMemoryWarning() {
        record("Memory warning", 0)
    }

    // MARK: Loading

    func load(data: Data) async {
        busy = "Opening…"
        defer { busy = nil }
        let meter = MemoryMeter()
        let td = CFAbsoluteTimeGetCurrent()
        guard let ui = UIImage(data: data), let cg = ui.normalizedCGImage(maxSide: maxWorkingSide) else {
            error = "Couldn't read that photo."
            return
        }
        let decodeMs = (CFAbsoluteTimeGetCurrent() - td) * 1000
        let (full, prev, found, ms) = await Task.detached(priority: .userInitiated) { () -> (RGBAImage, RGBAImage, [FaceGeometry], Double) in
            let t0 = CFAbsoluteTimeGetCurrent()
            let full = RGBAImage(cgImage: cg)
            let prev = RGBAImage(cgImage: cg, maxSide: 1600)
            let found = FaceAnalyzer.detect(prev.cgImage())
            return (full, prev, found, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }.value
        working = full
        preview = prev
        faces = found
        faceCount = found.count
        original = prev.uiImage()
        display = original
        smooth = 0; slim = 0; eyes = 0; nose = 0
        smoothOpened = false
        toolShown(tool)
        info = "\(full.width)×\(full.height) · \(found.count) face(s)"
        record("Open + face landmarks", ms, peakMB: meter.stop(), extra: ["decode_ms": decodeMs])
    }

    // MARK: Where Smooth starts

    /// The Smooth slider's starting value the first time the Smooth tool is shown on a photo ((picked in testing)).
    /// Photos that never go into Smooth aren't smoothed.
    let smoothStart: Float = 0.3
    private var smoothOpened = false

    func toolShown(_ t: Tool) {
        guard t == .smooth, !smoothOpened, hasImage else { return }
        smoothOpened = true
        if smooth < 0.001 { smooth = smoothStart }
    }

    // MARK: Enhance (Real-ESRGAN, destructive)

    func runEnhance() async {
        guard let src = working else { return }
        busy = "Enhancing…"
        defer { busy = nil }
        do {
            let (out, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let out = try EnhanceEngine.shared.enhance(src, maxInputSide: 1024)
                return (out, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Enhance x4 (\(out.width)×\(out.height))", ms, peakMB: peak)
            await setWorking(out)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Heal (LaMa, destructive)

    /// `point` is in preview pixel coordinates.
    func heal(at point: CGPoint) async {
        guard var img = working, let prev = preview else { return }
        busy = "Healing…"
        defer { busy = nil }
        let sx = Double(img.width) / Double(prev.width)
        let cx = Int(point.x * sx), cy = Int(point.y * sx)
        let radius = max(4, Int(Double(brush) * Double(img.width)))
        do {
            let (out, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                var mask = [UInt8](repeating: 0, count: img.width * img.height)
                let r2 = radius * radius
                for y in max(0, cy - radius)...min(img.height - 1, cy + radius) {
                    for x in max(0, cx - radius)...min(img.width - 1, cx + radius) {
                        let dx = x - cx, dy = y - cy
                        if dx * dx + dy * dy <= r2 { mask[y * img.width + x] = 255 }
                    }
                }
                try HealEngine.shared.heal(&img, mask: mask)
                return (img, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Heal spot r=\(radius)px", ms, peakMB: peak)
            await setWorking(out, redetectFaces: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setWorking(_ img: RGBAImage, redetectFaces: Bool = true) async {
        let prevSide = previewSide
        let detect = redetectFaces
        let (prev, found) = await Task.detached(priority: .userInitiated) { () -> (RGBAImage, [FaceGeometry]?) in
            let prev = RGBAImage(cgImage: img.cgImage(), maxSide: prevSide)
            return (prev, detect ? FaceAnalyzer.detect(prev.cgImage()) : nil)
        }.value
        working = img
        preview = prev
        if let found {
            faces = found
            faceCount = found.count
        }
        info = "\(img.width)×\(img.height) · \(faceCount) face(s)"
        renderPreview()
    }

    // MARK: Live sliders (Smooth, Face shape)

    func renderPreview() {
        guard let prev = preview else { return }
        renderTask?.cancel()
        let params = (smooth, slim, eyes, nose)
        let faces = self.faces
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000)  // coalesce slider ticks
            if Task.isCancelled { return }
            let (img, ms, peak) = await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let out = EditorModel.apply(prev, faces: faces, smooth: params.0, slim: params.1, eyes: params.2, nose: params.3)
                return (out, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            if Task.isCancelled { return }
            display = img.uiImage()
            record("Preview render \(prev.width)×\(prev.height)", ms, peakMB: peak)
        }
    }

    /// Smooth then warp. Runs at any resolution because the face geometry is normalised.
    nonisolated static func apply(_ img: RGBAImage, faces: [FaceGeometry], smooth: Float, slim: Float, eyes: Float, nose: Float) -> RGBAImage {
        var out = img
        if smooth > 0.001, !faces.isEmpty {
            let s = min(1.0, 1024.0 / Double(max(img.width, img.height)))
            let mw = max(1, Int(Double(img.width) * s)), mh = max(1, Int(Double(img.height) * s))
            let mask = FaceAnalyzer.skinMask(faces: faces, width: mw, height: mh)
            let faceW = Float((faces.map { $0.box.width }.max() ?? 0.2)) * Float(img.width)
            out = GPU.shared.smooth(out, mask: mask, maskWidth: mw, maskHeight: mh, strength: smooth, radius: max(3, faceW / 40))
        }
        if slim > 0.001 || eyes > 0.001 || nose > 0.001 {
            let ops = FaceAnalyzer.warpOps(faces: faces, width: img.width, height: img.height, slim: slim, eyes: eyes, nose: nose)
            out = GPU.shared.warp(out, ops: ops)
        }
        return out
    }

    // MARK: Save

    func save() async {
        guard let img = working else { return }
        busy = "Saving…"
        defer { busy = nil }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            error = "Allow PhotoStudio to add photos in Settings to save."
            return
        }
        let params = (smooth, slim, eyes, nose)
        let faces = self.faces
        let (data, ms, peak) = await Task.detached(priority: .userInitiated) { () -> (Data?, Double, Double) in
            let meter = MemoryMeter()
            let t0 = CFAbsoluteTimeGetCurrent()
            let out = EditorModel.apply(img, faces: faces, smooth: params.0, slim: params.1, eyes: params.2, nose: params.3)
            let data = out.uiImage().jpegData(compressionQuality: 0.95)
            return (data, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
        }.value
        record("Full-size render + JPEG (\(img.width)×\(img.height))", ms, peakMB: peak)
        guard let data else { error = "Couldn't encode the photo."; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            info = "Saved to Photos"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resetSliders() {
        smooth = 0; slim = 0; eyes = 0; nose = 0
        renderPreview()
    }

    // MARK: Timings (also written to Documents/timings.json for collection over USB)

    private static let logQueue = DispatchQueue(label: "timings-log", qos: .utility)  // one file writer at a time

    /// Logs a timing with this app's memory: mem_mb now, peak_mb during the tool, avail_mb left before iOS would
    /// close the app, and the working photo's size.
    private func record(_ label: String, _ ms: Double, peakMB: Double? = nil, extra: [String: Double] = [:]) {
        timings.removeAll { $0.0 == label }
        timings.insert((label, ms), at: 0)
        if timings.count > 8 { timings.removeLast() }
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        var entry: [String: Any] = ["label": label, "ms": r1(ms), "at": ISO8601DateFormatter().string(from: Date()),
                                    "mem_mb": r1(MemoryMeter.footprintMB())]
        if let peakMB { entry["peak_mb"] = r1(peakMB) }
        if let free = MemoryMeter.availableMB() { entry["avail_mb"] = r1(free) }
        if let w = working { entry["photo"] = "\(w.width)x\(w.height)" }
        for (k, v) in extra { entry[k] = r1(v) }
        EditorModel.logQueue.async {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("timings.json")
            var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            all.append(entry)
            if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]) { try? d.write(to: url) }
        }
    }
}
