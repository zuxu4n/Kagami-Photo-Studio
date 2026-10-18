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

    let maxWorkingSide = 4032
    let previewSide = 1600

    var hasImage: Bool { working != nil }
    var previewSize: CGSize { preview.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    // MARK: Loading

    func load(data: Data) async {
        busy = "Opening…"
        defer { busy = nil }
        guard let ui = UIImage(data: data), let cg = ui.normalizedCGImage(maxSide: maxWorkingSide) else {
            error = "Couldn't read that photo."
            return
        }
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
        info = "\(full.width)×\(full.height) · \(found.count) face(s)"
        record("Open + face landmarks", ms)
    }

    // MARK: Enhance (Real-ESRGAN, destructive)

    func runEnhance() async {
        guard let src = working else { return }
        busy = "Enhancing…"
        defer { busy = nil }
        do {
            let (out, ms) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double) in
                let t0 = CFAbsoluteTimeGetCurrent()
                let out = try EnhanceEngine.shared.enhance(src, maxInputSide: 1024)
                return (out, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }.value
            record("Enhance x4 (\(out.width)×\(out.height))", ms)
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
            let (out, ms) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double) in
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
                return (img, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }.value
            record("Heal spot r=\(radius)px", ms)
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
            let (img, ms) = await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double) in
                let t0 = CFAbsoluteTimeGetCurrent()
                let out = EditorModel.apply(prev, faces: faces, smooth: params.0, slim: params.1, eyes: params.2, nose: params.3)
                return (out, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }.value
            if Task.isCancelled { return }
            display = img.uiImage()
            record("Preview render \(prev.width)×\(prev.height)", ms)
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
        let (data, ms) = await Task.detached(priority: .userInitiated) { () -> (Data?, Double) in
            let t0 = CFAbsoluteTimeGetCurrent()
            let out = EditorModel.apply(img, faces: faces, smooth: params.0, slim: params.1, eyes: params.2, nose: params.3)
            let data = out.uiImage().jpegData(compressionQuality: 0.95)
            return (data, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }.value
        record("Full-size render + JPEG (\(img.width)×\(img.height))", ms)
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

    private func record(_ label: String, _ ms: Double) {
        timings.removeAll { $0.0 == label }
        timings.insert((label, ms), at: 0)
        if timings.count > 8 { timings.removeLast() }
        let entry: [String: Any] = ["label": label, "ms": (ms * 10).rounded() / 10, "at": ISO8601DateFormatter().string(from: Date())]
        Task.detached(priority: .utility) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("timings.json")
            var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            all.append(entry)
            if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]) { try? d.write(to: url) }
        }
    }
}
