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
    @Published var slim: Float = 0          // slim, eyes and nose show the selected face's values
    @Published var eyes: Float = 0
    @Published var nose: Float = 0
    @Published var brush: Float = 0.025      // heal brush radius as a fraction of the image width
    @Published var faceCount = 0
    @Published var timings: [(String, Double)] = []
    @Published var info: String = ""

    private var working: RGBAImage?     // full resolution, after Enhance/Heal
    private var preview: RGBAImage?     // long side <= previewSide, for live sliders
    @Published private(set) var faces: [FaceGeometry] = []
    @Published private(set) var selectedFace: Int?   // the face the Face tab guides and sliders are on
    private var shapes: [FaceShape] = []             // Face tab values for each face, same order as `faces`
    private var renderTask: Task<Void, Never>?
    @Published var enhanceOn = false
    private var unenhanced: RGBAImage?  // the photo as it was before Enhance, kept while Enhance is on
    private var healsSinceEnhance: [(center: CGPoint, brush: Double)] = []  // replayed on `unenhanced` when Enhance goes off
    private var warmedUp = false

    let maxWorkingSide = 4032
    let previewSide = 1600

    var hasImage: Bool { working != nil }
    var previewSize: CGSize { preview.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    /// Outline guides for the Face tab, on every face, each following its own Slim value. `selected` marks the
    /// face the sliders change. `minGap` is the smallest gap between a face and its guide, in preview pixels.
    func faceGuides(minGap: CGFloat) -> [(curves: [[CGPoint]], selected: Bool)] {
        guard let prev = preview else { return [] }
        return faces.indices.map { i in
            let s = i == selectedFace ? slim : (i < shapes.count ? shapes[i].slim : 0)
            return (FaceAnalyzer.guideCurves(for: faces[i], width: prev.width, height: prev.height, slim: s, minGap: minGap), i == selectedFace)
        }
    }

    // MARK: Which face the Face tab edits

    /// Selects the face whose area holds `point` (preview pixels) and shows its own slider values.
    /// Where face areas overlap, the face whose centre is nearest wins. A tap outside every face changes nothing.
    func selectFace(at point: CGPoint) {
        guard let prev = preview else { return }
        let p = CGPoint(x: point.x / CGFloat(prev.width), y: point.y / CGFloat(prev.height))
        let hits = faces.indices.filter { faces[$0].box.insetBy(dx: -faces[$0].box.width * 0.15, dy: -faces[$0].box.height * 0.15).contains(p) }
        guard let i = hits.min(by: { centreDistance(faces[$0], p) < centreDistance(faces[$1], p) }), i != selectedFace else { return }
        storeShape()
        selectedFace = i
        let v = shapes[i]
        slim = v.slim; eyes = v.eyes; nose = v.nose
        renderPreview()
    }

    private func centreDistance(_ f: FaceGeometry, _ p: CGPoint) -> CGFloat { hypot(f.box.midX - p.x, f.box.midY - p.y) }

    /// Keeps the sliders' values as the selected face's own.
    private func storeShape() {
        guard let i = selectedFace, i < shapes.count else { return }
        shapes[i] = FaceShape(slim: slim, eyes: eyes, nose: nose)
    }

    /// Starts the Face tab on the biggest face, with every face's sliders at zero.
    private func resetFaces() {
        shapes = Array(repeating: FaceShape(), count: faces.count)
        selectedFace = faces.indices.max(by: { faces[$0].box.width < faces[$1].box.width })
        slim = 0; eyes = 0; nose = 0
    }

    /// After faces are found again (Enhance on or off), gives each new face the values of the old face nearest it,
    /// so settings and the selection stay with the same person.
    private func carryShapes(to found: [FaceGeometry]) {
        storeShape()
        let old = faces, oldShapes = shapes, oldSel = selectedFace
        func nearest(_ f: FaceGeometry) -> Int? {
            let c = CGPoint(x: f.box.midX, y: f.box.midY)
            return old.indices.filter { centreDistance(old[$0], c) < max(old[$0].box.width, f.box.width) * 0.5 }
                .min(by: { centreDistance(old[$0], c) < centreDistance(old[$1], c) })
        }
        let match = found.map(nearest)
        faces = found
        shapes = match.map { $0.map { oldShapes[$0] } ?? FaceShape() }
        selectedFace = match.firstIndex(where: { $0 != nil && $0 == oldSel })
            ?? found.indices.max(by: { found[$0].box.width < found[$1].box.width })
        let v = selectedFace.map { shapes[$0] } ?? FaceShape()
        slim = v.slim; eyes = v.eyes; nose = v.nose
    }

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
        await warmModel("Enhance Neural Engine + GPU") { try EnhanceEngine.shared.warmUpSplit() }  // for 12 MP photos
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

    /// Test builds: times the Enhance options on this phone (see EnhanceBench), keeping the screen awake meanwhile.
    func runEnhanceBench() async {
        busy = "Timing Enhance options… keep the app open"
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            busy = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let ok = await Task.detached(priority: .userInitiated) { EnhanceBench.runAndSave() }.value
        info = ok ? "Enhance timing done" : "Enhance timing failed"
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
        resetFaces()
        original = prev.uiImage()
        display = original
        smooth = 0
        smoothOpened = false
        enhanceOn = false
        unenhanced = nil
        healsSinceEnhance = []
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

    // MARK: Enhance (Real-ESRGAN from the photo's own pixels, faces kept as they are; destructive)

    /// Enhance is a switch. The first tap enhances the photo; the next tap puts back the photo as it was before Enhance,
    /// with any spots healed since then healed again on it. So Enhance never runs on its own result.
    func runEnhance() async {
        if enhanceOn {
            await enhanceOff()
            return
        }
        guard let src = working else { return }
        busy = "Enhancing…"
        defer { busy = nil }
        let faces = self.faces
        do {
            let (out, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let engine = EnhanceEngine.shared
                let out = try engine.enhance(src, plan: engine.plan(width: src.width, height: src.height), faces: faces)
                return (out, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Enhance (\(out.width)×\(out.height))", ms, peakMB: peak)
            unenhanced = src
            healsSinceEnhance = []
            enhanceOn = true
            await setWorking(out)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func enhanceOff() async {
        guard var base = unenhanced else {
            enhanceOn = false
            return
        }
        busy = "Turning Enhance off…"
        defer { busy = nil }
        let heals = healsSinceEnhance
        do {
            let (out, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                for h in heals { _ = try EditorModel.healSpot(&base, center: h.center, brush: h.brush) }
                return (base, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Enhance off (\(heals.count) heal(s) redone)", ms, peakMB: peak)
            unenhanced = nil
            healsSinceEnhance = []
            enhanceOn = false
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
        let center = CGPoint(x: point.x / CGFloat(prev.width), y: point.y / CGFloat(prev.height))
        let brushFraction = Double(brush)
        do {
            let (out, radius, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Int, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let radius = try EditorModel.healSpot(&img, center: center, brush: brushFraction)
                return (img, radius, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Heal spot r=\(radius)px", ms, peakMB: peak)
            if enhanceOn { healsSinceEnhance.append((center, brushFraction)) }
            await setWorking(out, redetectFaces: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Heals one round spot. `center` is normalised (0...1) and `brush` is the radius as a fraction of the image width,
    /// so the same tap can be redone on another version of the photo. Returns the radius in pixels.
    nonisolated static func healSpot(_ img: inout RGBAImage, center: CGPoint, brush: Double) throws -> Int {
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
        try HealEngine.shared.heal(&img, mask: mask)
        return radius
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
            carryShapes(to: found)
            faceCount = found.count
        }
        info = "\(img.width)×\(img.height) · \(faceCount) face(s)"
        renderPreview()
    }

    // MARK: Live sliders (Smooth, Face shape)

    func renderPreview() {
        guard let prev = preview else { return }
        renderTask?.cancel()
        storeShape()
        let smooth = self.smooth, shapes = self.shapes
        let faces = self.faces
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000)  // coalesce slider ticks
            if Task.isCancelled { return }
            let (img, ms, peak) = await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let out = EditorModel.apply(prev, faces: faces, smooth: smooth, shapes: shapes)
                return (out, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            if Task.isCancelled { return }
            display = img.uiImage()
            record("Preview render \(prev.width)×\(prev.height)", ms, peakMB: peak)
        }
    }

    /// Smooth then warp. Runs at any resolution because the face geometry is normalised.
    nonisolated static func apply(_ img: RGBAImage, faces: [FaceGeometry], smooth: Float, shapes: [FaceShape]) -> RGBAImage {
        var out = img
        if smooth > 0.001, !faces.isEmpty {
            let s = min(1.0, 1024.0 / Double(max(img.width, img.height)))
            let mw = max(1, Int(Double(img.width) * s)), mh = max(1, Int(Double(img.height) * s))
            let mask = FaceAnalyzer.skinMask(faces: faces, width: mw, height: mh)
            let faceW = Float((faces.map { $0.box.width }.max() ?? 0.2)) * Float(img.width)
            out = GPU.shared.smooth(out, mask: mask, maskWidth: mw, maskHeight: mh, strength: smooth, radius: max(3, faceW / 40))
        }
        if shapes.contains(where: { !$0.isOff }) {
            let ops = FaceAnalyzer.warpOps(faces: faces, shapes: shapes, width: img.width, height: img.height)
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
        storeShape()
        let smooth = self.smooth, shapes = self.shapes
        let faces = self.faces
        let (data, ms, peak) = await Task.detached(priority: .userInitiated) { () -> (Data?, Double, Double) in
            let meter = MemoryMeter()
            let t0 = CFAbsoluteTimeGetCurrent()
            let out = EditorModel.apply(img, faces: faces, smooth: smooth, shapes: shapes)
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
        shapes = Array(repeating: FaceShape(), count: faces.count)
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
