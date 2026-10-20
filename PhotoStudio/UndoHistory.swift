import Foundation
import CoreGraphics

/// How to put the working photo's pixels back for one undo step.
enum PixelUndo {
    case unchanged
    /// The whole photo as it was (Enhance on or off, which change its size).
    case whole(RGBAImage)
    /// Only the rectangle a Heal changed, as it was before.
    case patch(x: Int, y: Int, RGBAImage)

    var bytes: Int {
        switch self {
        case .unchanged: return 0
        case .whole(let img): return img.pixels.count
        case .patch(_, _, let img): return img.pixels.count
        }
    }
}

/// Everything one undo puts back: the photo's pixels, the Enhance switch and the slider values.
struct UndoStep {
    var pixels: PixelUndo
    var enhanceOn: Bool
    var unenhanced: RGBAImage?
    var enhancedFull: RGBAImage?   // Enhance's own output and the photo before it at that size, for Strength
    var enhanceBase: RGBAImage?
    var enhanceStrength: Float
    var healsSinceEnhance: [HealRecord]
    var faces: [FaceGeometry]
    var shapes: [FaceShape]
    var selectedFace: Int?
    var smooth: Float
    var blur: Float
    var personMatte: PersonMatte?   // the people found on this step's photo, so undoing a Heal needn't look again
}

/// Undo and redo steps, newest last. Old undo steps are dropped once the saved pixels pass `maxBytes`, so a long
/// session can't hold many full-size photos in memory (one 12 MP photo is about 48 MB). A new edit clears redo.
struct UndoHistory {
    private(set) var steps: [UndoStep] = []
    private(set) var redoSteps: [UndoStep] = []
    let maxSteps = 40
    let maxBytes = 200 * 1024 * 1024

    var canUndo: Bool { !steps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    /// A new edit: it can be undone, and anything undone before it can no longer be redone.
    mutating func push(_ step: UndoStep) {
        redoSteps = []
        pushUndo(step)
    }

    /// Adds an undo step without clearing redo (used when redoing).
    mutating func pushUndo(_ step: UndoStep) {
        steps.append(step)
        trim()
    }

    mutating func pushRedo(_ step: UndoStep) {
        redoSteps.append(step)
        trim()
    }

    mutating func pop() -> UndoStep? { steps.popLast() }
    mutating func popRedo() -> UndoStep? { redoSteps.popLast() }
    mutating func clear() { steps = []; redoSteps = [] }

    /// Drops the oldest undo steps first, then the furthest redo steps, until both fit the limits.
    private mutating func trim() {
        func bytes() -> Int { (steps + redoSteps).reduce(0) { $0 + $1.pixels.bytes } }
        while steps.count + redoSteps.count > maxSteps || (steps.count + redoSteps.count > 1 && bytes() > maxBytes) {
            if !steps.isEmpty { steps.removeFirst() } else { redoSteps.removeFirst() }
        }
    }
}

extension RGBAImage {
    /// The smallest rectangle where this photo and `other` (same size) differ, or nil if they're the same.
    func changedRect(from other: RGBAImage) -> CGRect? {
        guard width == other.width, height == other.height else { return CGRect(x: 0, y: 0, width: width, height: height) }
        let w = width, h = height
        var minX = w, minY = h, maxX = -1, maxY = -1
        pixels.withUnsafeBytes { a in
            other.pixels.withUnsafeBytes { b in
                let pa = a.bindMemory(to: UInt32.self), pb = b.bindMemory(to: UInt32.self)
                for y in 0..<h {
                    let row = y * w
                    if memcmp(a.baseAddress! + row * 4, b.baseAddress! + row * 4, w * 4) == 0 { continue }
                    minY = min(minY, y); maxY = y
                    var x = 0
                    while x < w, pa[row + x] == pb[row + x] { x += 1 }
                    minX = min(minX, x)
                    var x2 = w - 1
                    while x2 > x, pa[row + x2] == pb[row + x2] { x2 -= 1 }
                    maxX = max(maxX, x2)
                }
            }
        }
        guard maxY >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// An exact copy of a pixel rectangle (no resampling).
    func crop(_ r: CGRect) -> RGBAImage {
        let x0 = Int(r.minX), y0 = Int(r.minY), cw = Int(r.width), ch = Int(r.height)
        var out = RGBAImage(width: cw, height: ch)
        pixels.withUnsafeBytes { s in
            out.pixels.withUnsafeMutableBytes { d in
                for y in 0..<ch {
                    memcpy(d.baseAddress! + y * cw * 4, s.baseAddress! + ((y0 + y) * width + x0) * 4, cw * 4)
                }
            }
        }
        return out
    }

    /// Writes `patch` back with its top-left corner at (x, y).
    mutating func paste(_ patch: RGBAImage, x x0: Int, y y0: Int) {
        let w = width
        pixels.withUnsafeMutableBytes { d in
            patch.pixels.withUnsafeBytes { s in
                for y in 0..<patch.height {
                    memcpy(d.baseAddress! + ((y0 + y) * w + x0) * 4, s.baseAddress! + y * patch.width * 4, patch.width * 4)
                }
            }
        }
    }
}
