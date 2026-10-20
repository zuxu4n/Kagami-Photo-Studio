import SwiftUI

/// How a tap or drag on the photo works in the Heal tab.
enum HealMode: String, CaseIterable, Identifiable {
    case spot = "Spot", people = "People", brush = "Brush", erase = "Erase"
    var id: String { rawValue }
    /// People, Brush and Erase build a selection that's removed in one go; Spot heals each tap at once.
    var selects: Bool { self != .spot }
}

/// Heal › People, Brush and Erase: pick a whole person (tap), paint anything else, fix it with the eraser, add the
/// shadow, then remove it all at once with LaMa near full resolution (ObjectRemoval).
extension EditorModel {
    var selectionTint: Bool { tool == .heal && healMode.selects }

    func clearSelection() {
        selection = []
        hasSelection = false
        selectionOverlay = nil
        brushStroke = nil
    }

    /// Starts finding the people on the current preview, so the first tap doesn't wait for it. The first time, also
    /// loads LaMa's 1024 function (about 4 s and 500 MB on an iPhone 14 Pro), only once removal is actually in use.
    func preparePeople() {
        if !largeWarmed {
            largeWarmed = true
            Task.detached(priority: .utility) { [weak self] in
                let meter = MemoryMeter()
                guard let t = try? HealEngine.shared.warmUpLarge() else { return }
                let peak = meter.stop()
                await self?.record("Warm-up: Remove (LaMa 1024) model", t.load + t.run, peakMB: peak, extra: ["load_ms": t.load, "first_run_ms": t.run])
            }
        }
        guard let prev = preview, people?.version != sourceVersion, peopleTask == nil else { return }
        let version = sourceVersion
        let task = Task.detached(priority: .userInitiated) { () -> [[UInt8]] in PersonCutout.people(in: prev) }
        peopleTask = task
        Task {
            let t0 = CFAbsoluteTimeGetCurrent()
            let masks = await task.value
            peopleTask = nil
            if version == sourceVersion {
                people = (version, masks)
                record("Person cutout (\(masks.count) found)", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        }
    }

    /// People mode: a tap on the selection removes it; a tap on a person adds them to it.
    func peopleTap(at point: CGPoint) async {
        guard let prev = preview else { return }
        let w = prev.width, h = prev.height
        let i = min(h - 1, max(0, Int(point.y))) * w + min(w - 1, max(0, Int(point.x)))
        if hasSelection, selection.count == w * h, selection[i] > 127 {
            await removeSelection()
            return
        }
        busy = "Finding the person…"
        defer { busy = nil }
        if people?.version != sourceVersion {
            preparePeople()
            if let t = peopleTask { _ = await t.value }
        }
        let known = people?.masks ?? []
        let faceBoxes = faces.map(\.box)
        let current = selection
        let (picked, ms) = await Task.detached(priority: .userInitiated) { () -> ([UInt8]?, Double) in
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let found = PersonCutout.person(at: point, in: prev, known: known) else { return (nil, 0) }
            let one = PersonCutout.split(found, at: point, faces: faceBoxes, width: w, height: h)
            var sel = current.count == w * h ? current : [UInt8](repeating: 0, count: w * h)
            let grown = ObjectRemoval.grow(person: one, others: known, width: w, height: h)
            for k in sel.indices where grown[k] > 127 { sel[k] = 255 }
            return (sel, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }.value
        guard let picked else {
            info = "No person found there. Use Brush to paint it instead."
            return
        }
        record("Select person", ms)
        setSelection(picked)
        info = "Tap the outlined area again (or Remove) to remove it. Brush and Erase fix the edges."
    }

    /// Brush and Erase: paints a round dab from the last point of the stroke to `point` (preview pixels).
    func paint(to point: CGPoint, erase: Bool, finished: Bool = false) {
        guard let prev = preview else { return }
        let w = prev.width, h = prev.height
        if selection.count != w * h { selection = [UInt8](repeating: 0, count: w * h) }
        let r = max(2, Double(brush) * Double(w))
        let from = brushStroke ?? point
        let steps = max(1, Int(hypot(point.x - from.x, point.y - from.y) / (r * 0.4)))
        let v: UInt8 = erase ? 0 : 255
        for s in 0...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let cx = from.x + (point.x - from.x) * t, cy = from.y + (point.y - from.y) * t
            let ri = Int(r.rounded(.up))
            let y0 = max(0, Int(cy) - ri), y1 = min(h - 1, Int(cy) + ri), x0 = max(0, Int(cx) - ri), x1 = min(w - 1, Int(cx) + ri)
            guard y0 <= y1, x0 <= x1 else { continue }   // a dab wholly off the photo
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - Double(cx), dy = Double(y) - Double(cy)
                    if dx * dx + dy * dy <= r * r { selection[y * w + x] = v }
                }
            }
        }
        brushStroke = finished ? nil : point
        // The outline is redrawn at most about 20 times a second while painting, and always at the end.
        let now = CFAbsoluteTimeGetCurrent()
        if finished || now - lastOverlay > 0.05 {
            lastOverlay = now
            setSelection(selection)
        }
    }

    func endStroke() {
        brushStroke = nil
        setSelection(selection)
    }

    /// Adds the shadow (or a dark reflection) joined to the selection.
    func addShadow() async {
        guard hasSelection, let prev = preview else { return }
        busy = "Finding the shadow…"
        defer { busy = nil }
        let sel = selection, known = people?.masks ?? []
        let (out, added, ms) = await Task.detached(priority: .userInitiated) { () -> ([UInt8], Int, Double) in
            let t0 = CFAbsoluteTimeGetCurrent()
            let add = ObjectRemoval.shadows(of: sel, in: prev, people: known)
            var out = sel
            var n = 0
            for i in out.indices where add[i] > 127 && out[i] < 128 { out[i] = 255; n += 1 }
            return (out, n, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }.value
        record("Add shadow (\(added) px)", ms)
        setSelection(out)
        info = added == 0 ? "No shadow found next to the selection. Paint it with Brush." : "Shadow added. Erase any part that isn't shadow."
    }

    /// Removes the selected area from the full-size photo (one undo step).
    func removeSelection() async {
        guard hasSelection, var img = working, let prev = preview else { return }
        busy = "Removing…"
        defer { busy = nil }
        let sel = selection, pw = prev.width, ph = prev.height
        var before = undoStep(.unchanged)
        do {
            let (out, undo, report, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, PixelUndo, ObjectRemoval.Report, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let old = img
                let report = try ObjectRemoval.remove(&img, mask: ObjectRemoval.fullSize(sel, width: pw, height: ph, to: img.width, img.height))
                let undo = img.changedRect(from: old).map { PixelUndo.patch(x: Int($0.minX), y: Int($0.minY), old.crop($0)) } ?? .unchanged
                return (img, undo, report, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Remove area (\(report.areas) area(s), \(report.largest) px, scale \(String(format: "%.2f", report.scale)))", ms, peakMB: peak)
            before.pixels = undo
            pushUndo(before)
            if enhanceOn { healsSinceEnhance.append(.area(mask: sel, width: pw, height: ph)) }
            clearSelection()
            await setWorking(out, redetectFaces: false)
            info = "Removed. Undo puts it back."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setSelection(_ sel: [UInt8]) {
        guard let prev = preview else { return }
        selection = sel
        hasSelection = sel.contains { $0 > 127 }
        selectionOverlay = hasSelection ? ObjectRemoval.overlay(sel, width: prev.width, height: prev.height).uiImageWithAlpha() : nil
    }
}

extension RGBAImage {
    /// The pixels as a UIImage that keeps their alpha (overlays); `uiImage()` treats the photo as opaque.
    func uiImageWithAlpha() -> UIImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: RGBAImage.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }
}

/// On-device timing of removal for test builds: launched with the argument RemoveBench, the app opens
/// Documents/remove_bench.jpg (copied in over USB, never bundled), then runs the real Heal paths and logs each to
/// timings.json as usual: person cutout, a tap on the person at the normalised point in Documents/remove_bench.txt
/// ("x,y", default the middle), Remove, Undo, Remove again (warm), and one spot heal.
enum RemoveBench {
    static var requested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-RemoveBench") || args.contains("RemoveBench")
    }
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
}

extension EditorModel {
    func runRemoveBench() async {
        guard let data = try? Data(contentsOf: RemoveBench.docs.appendingPathComponent("remove_bench.jpg")) else {
            info = "RemoveBench: no Documents/remove_bench.jpg"
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let tap = (try? String(contentsOf: RemoveBench.docs.appendingPathComponent("remove_bench.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").compactMap { Double($0) } ?? []
        let nx = tap.count == 2 ? tap[0] : 0.5, ny = tap.count == 2 ? tap[1] : 0.5
        record("RemoveBench start", 0)
        await load(data: data)
        tool = .heal
        healMode = .people
        preparePeople()
        if let t = peopleTask { _ = await t.value }
        guard let prev = preview else { return }
        let p = CGPoint(x: nx * Double(prev.width), y: ny * Double(prev.height))
        await peopleTap(at: p)
        await removeSelection()
        await undo()
        await peopleTap(at: p)
        await removeSelection()
        healMode = .spot
        await heal(at: CGPoint(x: Double(prev.width) * 0.1, y: Double(prev.height) * 0.9))
        record("RemoveBench done", 0)
        info = "Remove timing done"
    }
}
