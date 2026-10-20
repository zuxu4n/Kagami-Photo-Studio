import Vision
import CoreGraphics
import CoreVideo

/// Each person in a photo as their own mask, from Apple's on-device person instance cutout (iOS 17). Vision returns
/// at most four people per request, so people it missed can be found again on a crop around a tap (crowds).
enum PersonCutout {
    /// One mask per person found in `img`, at `img`'s size (0...255, soft at the edges), largest first.
    static func people(in img: RGBAImage) -> [[UInt8]] {
        people(in: img.cgImage(), width: img.width, height: img.height)
    }

    /// The person under `point` (pixels of `img`). Vision sometimes joins people who touch into one cutout, and only
    /// finds four, so it also looks on crops around the point and keeps the smallest cutout that holds the point and
    /// isn't cut off by the crop's edge: one person, not the group they stand in. `known` comes from `people(in:)`.
    /// Returns a mask at `img`'s size, or nil if no person covers the point.
    static func person(at point: CGPoint, in img: RGBAImage, known: [[UInt8]]) -> [UInt8]? {
        let w = img.width, h = img.height
        let px = min(w - 1, max(0, Int(point.x))), py = min(h - 1, max(0, Int(point.y)))
        var best = known.first(where: { $0[py * w + px] > 100 })
        var bestArea = best.map(area) ?? Int.max
        let cg = img.cgImage()
        for frac in [0.55, 0.35] {
            let side = Int(Double(max(w, h)) * frac)
            let cw = min(w, side), ch = min(h, side)
            let x0 = min(max(px - cw / 2, 0), w - cw), y0 = min(max(py - ch / 2, 0), h - ch)
            guard let crop = cg.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)) else { continue }
            for m in people(in: crop, width: cw, height: ch) where m[(py - y0) * cw + (px - x0)] > 100 {
                // A person running off a crop edge that isn't the photo's edge is only partly in the crop.
                let cut = (x0 > 0 && (0..<ch).contains { m[$0 * cw] > 127 })
                    || (x0 + cw < w && (0..<ch).contains { m[$0 * cw + cw - 1] > 127 })
                    || (y0 > 0 && (0..<cw).contains { m[$0] > 127 })
                    || (y0 + ch < h && (0..<cw).contains { m[(ch - 1) * cw + $0] > 127 })
                let a = area(m)
                if cut || a >= bestArea { continue }
                var out = [UInt8](repeating: 0, count: w * h)
                for y in 0..<ch {
                    for x in 0..<cw { out[(y0 + y) * w + x0 + x] = m[y * cw + x] }
                }
                best = out
                bestArea = a
            }
        }
        return best
    }

    /// When one cutout holds several faces (people standing close are often joined), the part that belongs to the
    /// person at `point`: each pixel goes to the face it lines up with best (mostly by column, as bodies hang below
    /// faces), and the piece joined to the tap is kept. `faces` are normalised boxes, top-left origin.
    static func split(_ mask: [UInt8], at point: CGPoint, faces: [CGRect], width w: Int, height h: Int) -> [UInt8] {
        // Faces the cutout touches anywhere on the face (a face half behind someone else still counts).
        let inside = faces.filter { f in
            for fy in stride(from: 0.2, through: 0.8, by: 0.3) {
                for fx in stride(from: 0.2, through: 0.8, by: 0.3) {
                    let x = Int((f.minX + f.width * fx) * CGFloat(w)), y = Int((f.minY + f.height * fy) * CGFloat(h))
                    if x >= 0 && y >= 0 && x < w && y < h && mask[y * w + x] > 60 { return true }
                }
            }
            return false
        }
        guard inside.count > 1 else { return mask }
        let boxes = inside.map { CGRect(x: $0.minX * CGFloat(w), y: $0.minY * CGFloat(h), width: $0.width * CGFloat(w), height: $0.height * CGFloat(h)) }
        func owner(_ x: Int, _ y: Int) -> Int {
            var best = 0, bestD = CGFloat.infinity
            for (k, b) in boxes.enumerated() {
                let dx = (CGFloat(x) - b.midX) / b.width
                // Above a face's middle only that face's own head counts; below it, distance down matters little.
                let dy = (CGFloat(y) - b.midY) / b.height
                let d = dx * dx + (dy < 0 ? dy * dy * 1.5 : dy * dy * 0.04)
                if d < bestD { bestD = d; best = k }
            }
            return best
        }
        let px = min(w - 1, max(0, Int(point.x))), py = min(h - 1, max(0, Int(point.y)))
        let mine = owner(px, py)
        var keep = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] > 60 && owner(x, y) == mine { keep[y * w + x] = mask[y * w + x] }
        }
        // Only the piece joined to the tap (an arm of the next person reaching across stays theirs).
        var out = [UInt8](repeating: 0, count: w * h)
        var stack = [py * w + px]
        if keep[py * w + px] == 0, let b = boxes.indices.first(where: { $0 == mine }) {
            stack = [Int(boxes[b].midY) * w + Int(boxes[b].midX)]
        }
        while let i = stack.popLast() {
            guard keep[i] > 0, out[i] == 0 else { continue }
            out[i] = keep[i]
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y < h - 1 { stack.append(i + w) }
        }
        return out
    }

    private static func area(_ m: [UInt8]) -> Int { m.reduce(0) { $0 + ($1 > 127 ? 1 : 0) } }

    private static func people(in cg: CGImage, width w: Int, height h: Int) -> [[UInt8]] {
        let req = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return [] }
        var out: [[UInt8]] = []
        for i in obs.allInstances {
            guard let pb = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: handler) else { continue }
            let m = bytes(pb, width: w, height: h)
            if m.contains(where: { $0 > 127 }) { out.append(m) }
        }
        return out.sorted { area($0) > area($1) }
    }

    /// A one-channel mask buffer (8-bit or 32-bit float) as bytes at `w` x `h` (nearest neighbour if its size differs).
    private static func bytes(_ pb: CVPixelBuffer, width w: Int, height h: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        let isFloat = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent32Float
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let sy = min(bh - 1, y * bh / h)
            for x in 0..<w {
                let sx = min(bw - 1, x * bw / w)
                if isFloat {
                    let v = base.load(fromByteOffset: sy * row + sx * 4, as: Float.self)
                    out[y * w + x] = UInt8(max(0, min(1, v)) * 255 + 0.5)
                } else {
                    out[y * w + x] = base.load(fromByteOffset: sy * row + sx, as: UInt8.self)
                }
            }
        }
        return out
    }
}
