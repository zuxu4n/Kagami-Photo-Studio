import SwiftUI

/// How a drag on the photo works in the Blur tab.
enum BlurMode: String, CaseIterable, Identifiable {
    case view = "View", brush = "Brush", erase = "Erase"
    var id: String { rawValue }
    var paints: Bool { self != .view }
}

/// The Blur tab's two parts: blur the background, or take it away.
enum BlurPanel: String, CaseIterable, Identifiable {
    case blur = "Blur", remove = "Remove background"
    var id: String { rawValue }
}

/// What Remove background puts behind the people. Off leaves the background (and Blur) as they are.
enum BackgroundChoice: String, CaseIterable, Identifiable {
    case off = "Off", clear = "Clear", white = "White", black = "Black"
    var id: String { rawValue }

    /// How the preview shows it (see-through is drawn as grey squares).
    var previewMode: CutMode? {
        switch self {
        case .off: return nil
        case .clear: return .checker
        case .white: return .color(SIMD3(1, 1, 1))
        case .black: return .color(SIMD3(0, 0, 0))
        }
    }
}

/// Blur › Brush and Erase: fix the people the cutout found by hand. Brush paints parts that should stay sharp (a
/// missed arm, a hat, a bag), Erase paints parts that should be blurred (background the cutout took for a person).
/// The fixes are kept at preview size and normalised, so they stay in place at full size, after Enhance or Heal
/// (when the cutout is made again) and on Save.
extension EditorModel {
    var blurTint: Bool { tool == .blur && blurMode.paints }

    /// Shows a part of the Blur tab. Remove background starts see-through the first time it's opened on a photo.
    func showBlurPanel(_ p: BlurPanel) {
        blurPanel = p
        if p == .remove, !removeOpened {
            removeOpened = true
            if background == .off { setBackground(.clear) }
        }
        findPeople()
    }

    /// Changes what's behind the people (one undo step).
    func setBackground(_ b: BackgroundChoice) {
        guard b != background else { return }
        pushUndo(undoStep(.unchanged))
        background = b
        renderPreview()
    }

    /// Paints a round dab from the last point of the stroke to `point` (preview pixels). The first dab of a stroke
    /// starts its undo step.
    func paintBlur(to point: CGPoint, finished: Bool = false) {
        guard let prev = preview else { return }
        let w = prev.width, h = prev.height
        if blurStroke == nil { blurStroke = (undoStep(.unchanged), nil) }
        var e = blurEdits.width == w && blurEdits.height == h ? blurEdits : (blurEdits.isEmpty ? MatteEdits(width: w, height: h, values: [UInt8](repeating: 128, count: w * h)) : blurEdits.resized(w, h))
        let r = max(2, Double(blurBrush) * Double(w))
        let from = blurStroke?.last ?? point
        let steps = max(1, Int(hypot(point.x - from.x, point.y - from.y) / (r * 0.4)))
        let v: UInt8 = blurMode == .erase ? 0 : 255
        e.values.withUnsafeMutableBufferPointer { px in
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let cx = from.x + (point.x - from.x) * t, cy = from.y + (point.y - from.y) * t
                let ri = Int(r.rounded(.up))
                let y0 = max(0, Int(cy) - ri), y1 = min(h - 1, Int(cy) + ri), x0 = max(0, Int(cx) - ri), x1 = min(w - 1, Int(cx) + ri)
                guard y0 <= y1, x0 <= x1 else { continue }   // a dab wholly off the photo
                for y in y0...y1 {
                    for x in x0...x1 {
                        let dx = Double(x) - Double(cx), dy = Double(y) - Double(cy)
                        if dx * dx + dy * dy <= r * r { px[y * w + x] = v }
                    }
                }
            }
        }
        blurEdits = e
        blurStroke?.last = point
        // The outline and the blur are redrawn at most about 20 times a second while painting, and always at the end.
        let now = CFAbsoluteTimeGetCurrent()
        if finished || now - lastOverlay > 0.05 {
            lastOverlay = now
            updateBlurOverlay()
            renderPreview()
        }
        if finished { endBlurStroke() }
    }

    /// Ends the stroke as one undo step and makes the background fill again around the fixed edges.
    func endBlurStroke() {
        guard let stroke = blurStroke else { return }
        blurStroke = nil
        if stroke.start.blurEdits != blurEdits { pushUndo(stroke.start) }
        updateBlurOverlay()
        rebuildEditedMatte()
        if blur < 0.001 { info = "Move Strength to see the blur" }
    }

    /// Takes every fix out (one undo step).
    func resetBlurEdits() {
        guard !blurEdits.isEmpty else { return }
        pushUndo(undoStep(.unchanged))
        blurEdits = .none
        updateBlurOverlay()
        rebuildEditedMatte()
    }

    /// Applies the current fixes to the people found, in the background, then redraws. The preview already shows
    /// the fixes on the edge meanwhile; this also refills the background behind them.
    func rebuildEditedMatte() {
        guard let m = personMatte, m.edits != blurEdits, let img = working else { renderPreview(); return }
        let edits = blurEdits, version = workingVersion
        Task {
            let (out, ms) = await Task.detached(priority: .userInitiated) { () -> (PersonMatte, Double) in
                let t0 = CFAbsoluteTimeGetCurrent()
                return (BackgroundBlur.withEdits(m, edits, image: img), (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }.value
            guard version == workingVersion, edits == blurEdits else { return }   // the photo or the fixes changed meanwhile
            record("Blur fixes applied", ms)
            personMatte = out
            updateBlurOverlay()
            renderPreview()
        }
    }

    /// The selection tint for Brush and Erase: the people as they'll stay sharp (the cutout with the fixes), in the
    /// same style as Heal's selection.
    func updateBlurOverlay() {
        guard blurTint, let m = personMatte, let prev = preview else { blurOverlay = nil; return }
        let s = min(1.0, 800.0 / Double(max(prev.width, prev.height)))
        let w = max(1, Int(Double(prev.width) * s)), h = max(1, Int(Double(prev.height) * s))
        let e = blurEdits
        var sel = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let my = min(m.height - 1, y * m.height / h), ey = min(e.height - 1, y * e.height / h)
            for x in 0..<w {
                let v = e.values[ey * e.width + min(e.width - 1, x * e.width / w)]
                let on = v > 128 ? true : v < 128 ? false : m.base[my * m.width + min(m.width - 1, x * m.width / w)] > 127
                if on { sel[y * w + x] = 255 }
            }
        }
        blurOverlay = ObjectRemoval.overlay(sel, width: w, height: h).uiImageWithAlpha()
    }
}
