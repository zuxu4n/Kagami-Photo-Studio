import Foundation
import CoreGraphics
import Accelerate

/// One heal since Enhance went on, kept so it can be done again on another version of the photo (Enhance off,
/// Strength moved). Spots are a centre and radius; removed areas are the selection on the preview.
enum HealRecord {
    case spot(center: CGPoint, brush: Double)
    case area(mask: [UInt8], width: Int, height: Int)

    func redo(on img: inout RGBAImage) throws {
        switch self {
        case .spot(let c, let b):
            _ = try HealEngine.healSpot(&img, center: c, brush: b)
        case .area(let m, let w, let h):
            _ = try ObjectRemoval.remove(&img, mask: ObjectRemoval.fullSize(m, width: w, height: h, to: img.width, img.height))
        }
    }
}

/// Removes people and other large areas with LaMa, close to the photo's own resolution, then gives the fill the same
/// fine detail and grain as the background around it. Small spots still go through HealEngine.heal unchanged.
///
/// Each separate area is done on its own crop: the area plus about half its size again of background around it.
/// The crop goes through LaMa's 1024 function (512 for crops that small), so a person on a 12 MP photo is filled at
/// about a third of full resolution instead of a sixth. The fill is then scaled up, its finest detail replaced by
/// patches of the background's own detail (grain, texture), and pasted back over the hole only.
enum ObjectRemoval {
    struct Report { var areas = 0; var largest = 0; var scale = 1.0 }

    /// Fills everything under `mask` (one byte per pixel of `img`, > 127 = remove), in place.
    static func remove(_ img: inout RGBAImage, mask: [UInt8]) throws -> Report {
        var report = Report()
        for box in areas(mask, width: img.width, height: img.height) {
            var part = [UInt8](repeating: 0, count: mask.count)
            let w = img.width
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) where mask[y * w + x] > 127 { part[y * w + x] = 255 }
            }
            let m = Int(max(box.width, box.height))
            report.areas += 1
            report.largest = max(report.largest, m)
            if m <= 170 {
                // Spot size: the tap-to-heal path, which already passes.
                try HealEngine.shared.heal(&img, mask: part)
            } else {
                report.scale = min(report.scale, try fillLarge(&img, mask: part, box: box))
            }
        }
        return report
    }

    // MARK: Separate areas

    /// Bounding boxes of the mask's separate areas (found on a small copy), with boxes that would share background
    /// context merged, largest first.
    static func areas(_ mask: [UInt8], width w: Int, height h: Int) -> [CGRect] {
        let f = max(1, max(w, h) / 400)
        let sw = (w + f - 1) / f, sh = (h + f - 1) / f
        var small = [UInt8](repeating: 0, count: sw * sh)
        mask.withUnsafeBufferPointer { m in
            for y in 0..<h {
                let row = (y / f) * sw
                for x in 0..<w where m[y * w + x] > 127 { small[row + x / f] = 1 }
            }
        }
        var label = [Int32](repeating: -1, count: sw * sh)
        var boxes: [CGRect] = []
        for start in 0..<(sw * sh) where small[start] == 1 && label[start] < 0 {
            var stack = [start]
            label[start] = Int32(boxes.count)
            var x0 = sw, y0 = sh, x1 = 0, y1 = 0
            while let i = stack.popLast() {
                let x = i % sw, y = i / sw
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < sw && ny < sh {
                    let j = ny * sw + nx
                    if small[j] == 1 && label[j] < 0 { label[j] = label[start]; stack.append(j) }
                }
            }
            boxes.append(CGRect(x: x0 * f, y: y0 * f, width: min(w, (x1 + 1) * f) - x0 * f, height: min(h, (y1 + 1) * f) - y0 * f))
        }
        // Merge areas whose context would overlap, so one fill sees both holes.
        var merged = true
        while merged {
            merged = false
            outer: for i in boxes.indices {
                for j in boxes.indices where j > i {
                    let a = boxes[i], b = boxes[j]
                    let pa = max(a.width, a.height) * 0.25, pb = max(b.width, b.height) * 0.25
                    if a.insetBy(dx: -pa, dy: -pa).intersects(b.insetBy(dx: -pb, dy: -pb)) {
                        boxes[i] = a.union(b)
                        boxes.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return boxes.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    // MARK: One large area

    /// Returns the working scale used (1 = native resolution).
    private static func fillLarge(_ img: inout RGBAImage, mask: [UInt8], box: CGRect) throws -> Double {
        let w = img.width, h = img.height
        let large = HealEngine.shared.largeIfAvailable()
        let m = Int(max(box.width, box.height))
        let margin = max(48, Int(Double(m) * marginFraction))
        // The crop: the area plus margin, then widened towards a square where the photo allows.
        var x0 = max(0, Int(box.minX) - margin), x1 = min(w, Int(box.maxX) + margin)
        var y0 = max(0, Int(box.minY) - margin), y1 = min(h, Int(box.maxY) + margin)
        let side = max(x1 - x0, y1 - y0)
        if x1 - x0 < side { (x0, x1) = widen(x0, x1, to: min(side, w), limit: w) }
        if y1 - y0 < side { (y0, y1) = widen(y0, y1, to: min(side, h), limit: h) }
        let cw = x1 - x0, ch = y1 - y0
        let (model, n) = large != nil && max(cw, ch) > HealEngine.shared.size
            ? (large!, HealEngine.shared.largeSize) : (try HealEngine.shared.loadIfNeeded(), HealEngine.shared.size)
        let k = min(1.0, Double(n) / Double(max(cw, ch)))

        let rect = CGRect(x: x0, y: y0, width: cw, height: ch)
        let crop = img.crop(rect)
        var hole = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw { hole[y * cw + x] = mask[(y0 + y) * w + x0 + x] > 127 ? 255 : 0 }
        }
        // The model's view: any pixel the hole touches counts as hole, grown so the person's colours blended into
        // the edge pixels by the resize aren't kept as "background" (they'd come back as a dark ghost).
        let small = crop.scaled(toWidth: n, height: n)
        var smallHole = MaskOps.resize(hole, w: cw, h: ch, to: n, n)
        for i in smallHole.indices { smallHole[i] = smallHole[i] > 8 ? 255 : 0 }
        smallHole = MaskOps.dilate(smallHole, w: n, h: n, r: 3)
        let out = try HealEngine.shared.run(model, image: small, mask: smallHole, n: n)
        let fill = out.scaled(toWidth: cw, height: ch)
        // Paste area: the hole grown a little and feathered, never wider than the area the model filled.
        let soft = max(2, Int((1.0 / k).rounded()))
        let alpha = MaskOps.blur(MaskOps.dilate(hole, w: cw, h: ch, r: soft + 1), w: cw, h: ch, r: soft)
        let detailed = DetailTransfer.apply(fill: fill, source: crop, hole: alpha, sigma: max(1.0, 0.7 / k))

        img.pixels.withUnsafeMutableBufferPointer { dst in
            detailed.pixels.withUnsafeBufferPointer { src in
                for y in 0..<ch {
                    for x in 0..<cw {
                        let a = Int(alpha[y * cw + x])
                        if a == 0 { continue }
                        let si = (y * cw + x) * 4, di = ((y0 + y) * w + x0 + x) * 4
                        for c in 0..<3 { dst[di + c] = UInt8((Int(src[si + c]) * a + Int(dst[di + c]) * (255 - a)) / 255) }
                    }
                }
            }
        }
        return k
    }

    /// Background context on each side of an area, as a fraction of its size (the harness tries others).
    nonisolated(unsafe) static var marginFraction = 0.5

    private static func widen(_ a: Int, _ b: Int, to len: Int, limit: Int) -> (Int, Int) {
        var lo = (a + b) / 2 - len / 2
        lo = min(max(0, lo), limit - len)
        return (lo, lo + len)
    }

    // MARK: Selection helpers (preview resolution)

    /// A selection made on the preview, at the working photo's size: scaled up smoothly, cut at half, then grown by
    /// a pixel per step of scale so the resize never leaves a sliver of the edge behind.
    static func fullSize(_ sel: [UInt8], width pw: Int, height ph: Int, to w: Int, _ h: Int) -> [UInt8] {
        var m = MaskOps.resize(sel, w: pw, h: ph, to: w, h)
        for i in m.indices { m[i] = m[i] > 127 ? 255 : 0 }
        return MaskOps.dilate(m, w: w, h: h, r: max(1, Int((Double(w) / Double(pw)).rounded())))
    }

    /// A person's cutout as a selection: firm inside, grown a little past the soft edge so hair ends and the outline
    /// go too, but not grown into other people, who stay.
    static func grow(person: [UInt8], others: [[UInt8]], width w: Int, height h: Int) -> [UInt8] {
        var bin = person.map { $0 > 60 ? UInt8(255) : 0 }
        guard let b = MaskOps.bbox(bin, w: w, h: h) else { return bin }
        let r = max(2, Int(Double(max(b.width, b.height)) * 0.015))
        bin = MaskOps.dilate(bin, w: w, h: h, r: r)
        for o in others where o != person {
            for i in bin.indices where o[i] > 127 && person[i] <= 60 { bin[i] = 0 }
        }
        return bin
    }

    /// Shadows (and dark reflections) joined to `selection`: pixels near it that are clearly darker than the background
    /// around them, connected to it. People (`people`, any cutouts) outside the selection are never added. If the dark
    /// area found is bigger than the selection itself it's mostly not shadow (dark clothes, hair, a dark wall), so the
    /// threshold tightens; if it's still too big, nothing is added. Returns only the added pixels, at `img`'s size.
    static func shadows(of selection: [UInt8], in img: RGBAImage, people: [[UInt8]]) -> [UInt8] {
        let w = img.width, h = img.height, n = w * h
        let none = [UInt8](repeating: 0, count: n)
        guard let b = MaskOps.bbox(selection, w: w, h: h) else { return none }
        let selArea = selection.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
        let luma = MaskOps.luma(img)
        var blocked = MaskOps.dilate(selection, w: w, h: h, r: 2)
        for p in people { for i in 0..<n where p[i] > 100 && selection[i] < 128 { blocked[i] = 255 } }
        // Background brightness: a wide average of the pixels that aren't the selection or people.
        let rb = max(6, Int(max(b.width, b.height)) / 5)
        var lv = [Float](repeating: 0, count: n), valid = [Float](repeating: 0, count: n)
        for i in 0..<n where blocked[i] < 128 { lv[i] = Float(luma[i]); valid[i] = 1 }
        let sl = MaskOps.boxF(lv, w: w, h: h, r: rb), sv = MaskOps.boxF(valid, w: w, h: h, r: rb)
        // Shadows and reflections fall from the lower half of a person or object (feet, legs, the base), so only
        // pixels from there down are looked at; a dark door frame beside someone's head isn't their shadow.
        var reach = MaskOps.dilate(selection, w: w, h: h, r: max(4, Int(Double(max(b.width, b.height)) * 0.45)))
        let top = Int(b.midY)
        for i in 0..<(min(h, top) * w) { reach[i] = 0 }
        let edge = MaskOps.dilate(selection, w: w, h: h, r: 3)
        for ratio: Float in [0.8, 0.68, 0.56] {
            var dark = [UInt8](repeating: 0, count: n)
            for i in 0..<n where reach[i] > 127 && blocked[i] < 128 && sv[i] > 0.05 {
                let bg = sl[i] / sv[i]
                let l = Float(luma[i])
                if l < bg * ratio && l < bg - 8 { dark[i] = 1 }
            }
            // Keep only the dark pixels joined to the selection.
            var added = [UInt8](repeating: 0, count: n)
            var stack: [Int] = []
            for i in 0..<n where edge[i] > 127 && dark[i] == 1 { added[i] = 255; stack.append(i) }
            var count = stack.count
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let j = ny * w + nx
                    if dark[j] == 1 && added[j] == 0 { added[j] = 255; stack.append(j); count += 1 }
                }
            }
            if count > selArea { continue }
            // Close pinholes and soften the shadow's ragged edge a little.
            let closed = MaskOps.blur(MaskOps.dilate(added, w: w, h: h, r: 2), w: w, h: h, r: 2)
            return (0..<n).map { closed[$0] > 100 && blocked[$0] < 128 ? 255 : 0 }
        }
        return none
    }

    /// The selection drawn over the photo: a translucent fill with a bright outline (RGBA, premultiplied-free).
    static func overlay(_ sel: [UInt8], width w: Int, height h: Int) -> RGBAImage {
        var out = RGBAImage(width: w, height: h)
        let outer = MaskOps.dilate(sel, w: w, h: h, r: max(1, max(w, h) / 600))
        out.pixels.withUnsafeMutableBufferPointer { p in
            for i in 0..<(w * h) {
                let o = i * 4
                if sel[i] > 127 {
                    p[o] = 255; p[o + 1] = 60; p[o + 2] = 90; p[o + 3] = 95
                } else if outer[i] > 127 {
                    p[o] = 255; p[o + 1] = 255; p[o + 2] = 255; p[o + 3] = 255
                } else {
                    p[o] = 0; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0
                }
            }
        }
        return out
    }
}

/// Gives a filled area the background's own fine detail: the fill keeps its broad shapes and colours (blurred at
/// `sigma`), and its finest detail is replaced by overlapping patches of detail copied from nearby background of
/// similar brightness. So the patch has the photo's grain and texture instead of being smoother than the rest.
enum DetailTransfer {
    static func apply(fill: RGBAImage, source: RGBAImage, hole: [UInt8], sigma: Double) -> RGBAImage {
        let w = fill.width, h = fill.height
        guard let hb = MaskOps.bbox(hole, w: w, h: h) else { return fill }
        let r = max(1, Int((sigma * 2.2).rounded()))
        let fillBlur = MaskOps.tent(fill, r: r)
        let srcBlur = MaskOps.tent(source, r: r)
        let B = max(8, Int((sigma * 6).rounded()) & ~1)   // half the patch size: patches are 2B across, placed every B

        // Where patches may come from: blocks wholly outside the (grown) hole.
        let far = MaskOps.dilate(hole.map { $0 > 0 ? 255 : 0 }, w: w, h: h, r: B + 2)
        let lumaSrc = MaskOps.luma(srcBlur), lumaFill = MaskOps.luma(fillBlur)
        let bigSrc = MaskOps.blur(lumaSrc, w: w, h: h, r: B), bigFill = MaskOps.blur(lumaFill, w: w, h: h, r: B)
        var energy = [UInt8](repeating: 0, count: w * h)
        source.pixels.withUnsafeBufferPointer { s in
            srcBlur.pixels.withUnsafeBufferPointer { sb in
                for i in 0..<(w * h) {
                    let o = i * 4
                    let d = abs(Int(s[o]) - Int(sb[o])) + abs(Int(s[o + 1]) - Int(sb[o + 1])) + abs(Int(s[o + 2]) - Int(sb[o + 2]))
                    energy[i] = UInt8(min(255, d * 2))
                }
            }
        }
        let bigEnergy = MaskOps.blur(energy, w: w, h: h, r: B)
        var cands: [(x: Int, y: Int, l: Float, e: Float)] = []
        let step = max(2, B / 2)
        var y = B
        while y + B < h {
            var x = B
            while x + B < w {
                if far[y * w + x] < 128 && far[(y - B) * w + x - B] < 128 && far[(y + B - 1) * w + x + B - 1] < 128
                    && far[(y - B) * w + x + B - 1] < 128 && far[(y + B - 1) * w + x - B] < 128 {
                    cands.append((x, y, Float(bigSrc[y * w + x]), Float(bigEnergy[y * w + x])))
                }
                x += step
            }
            y += step
        }
        var out = fillBlur
        guard !cands.isEmpty else { return fill }
        let medE = cands.map(\.e).sorted()[cands.count / 2]
        // Patches with much more detail than usual are edges of other things (a door frame, someone's hair): avoid.
        let calm = cands.filter { $0.e <= max(medE * 1.6, 6) }
        let pool = calm.isEmpty ? cands : calm

        var acc = [Float](repeating: 0, count: w * h * 3)
        var win = [Float](repeating: 0, count: 2 * B)
        for i in 0..<(2 * B) { let s = sin(Float.pi * (Float(i) + 0.5) / Float(2 * B)); win[i] = s * s }
        var rng = SplitMix(seed: 0x5eed)
        // Patch centres on a grid every B; a patch spans [c - B, c + B). With sin² windows they add up to exactly 1.
        let gx0 = Int(hb.minX) - B, gy0 = Int(hb.minY) - B
        var cy = gy0
        while cy <= Int(hb.maxY) + B {
            var cx = gx0
            while cx <= Int(hb.maxX) + B {
                let tx = min(max(cx, 0), w - 1), ty = min(max(cy, 0), h - 1)
                let tl = Float(bigFill[ty * w + tx])
                var best = pool[0], bestScore = Float.infinity
                for _ in 0..<40 {
                    let c = pool[Int(rng.next() % UInt64(pool.count))]
                    let dist = hypot(Float(c.x - cx), Float(c.y - cy)) / Float(max(w, h))
                    let score = abs(c.l - tl) + 0.5 * abs(c.e - medE) + 12 * dist
                    if score < bestScore { bestScore = score; best = c }
                }
                let gain = max(0.6, min(1.6, (tl + 12) / (best.l + 12)))
                source.pixels.withUnsafeBufferPointer { s in
                    srcBlur.pixels.withUnsafeBufferPointer { sb in
                        for j in 0..<(2 * B) {
                            let py = cy - B + j, sy = best.y - B + j
                            if py < 0 || py >= h { continue }
                            for i in 0..<(2 * B) {
                                let px = cx - B + i, sx = best.x - B + i
                                if px < 0 || px >= w { continue }
                                let wt = win[i] * win[j] * gain
                                let so = (sy * w + sx) * 4, a = (py * w + px) * 3
                                acc[a] += wt * Float(Int(s[so]) - Int(sb[so]))
                                acc[a + 1] += wt * Float(Int(s[so + 1]) - Int(sb[so + 1]))
                                acc[a + 2] += wt * Float(Int(s[so + 2]) - Int(sb[so + 2]))
                            }
                        }
                    }
                }
                cx += B
            }
            cy += B
        }
        out.pixels.withUnsafeMutableBufferPointer { o in
            fill.pixels.withUnsafeBufferPointer { f in
                for i in 0..<(w * h) where hole[i] > 0 {
                    let p = i * 4, a = i * 3
                    for c in 0..<3 {
                        // Keep half of the fill's own fine detail (real structure at native scale), add the background's.
                        let v = Float(o[p + c]) + acc[a + c] + 0.5 * Float(Int(f[p + c]) - Int(o[p + c]))
                        o[p + c] = UInt8(max(0, min(255, v.rounded())))
                    }
                }
                for i in 0..<(w * h) where hole[i] == 0 {
                    let p = i * 4
                    o[p] = f[p]; o[p + 1] = f[p + 1]; o[p + 2] = f[p + 2]
                }
            }
        }
        return out
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// One-byte masks and small image filters on vImage.
enum MaskOps {
    static func bbox(_ m: [UInt8], w: Int, h: Int) -> CGRect? {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        m.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where p[row + x] > 127 {
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                    if y < y0 { y0 = y }
                    y1 = y
                }
            }
        }
        return x1 < 0 ? nil : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// Grows the mask by `r` pixels: a square max filter, then a rounded corner pass (a second, diagonal-ish
    /// pass of 0.7r on a cross), close to a round brush.
    static func dilate(_ m: [UInt8], w: Int, h: Int, r: Int) -> [UInt8] {
        guard r > 0 else { return m }
        let k = max(1, Int(Double(r) * 0.71))
        var a = maxFilter(m, w: w, h: h, kw: 2 * k + 1, kh: 2 * k + 1)
        let rest = r - k
        if rest > 0 {
            let hz = maxFilter(a, w: w, h: h, kw: 2 * rest + 1, kh: 1)
            let vt = maxFilter(a, w: w, h: h, kw: 1, kh: 2 * rest + 1)
            for i in a.indices { a[i] = max(hz[i], vt[i]) }
        }
        return a
    }

    private static func maxFilter(_ m: [UInt8], w: Int, h: Int, kw: Int, kh: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        m.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress), height: vImagePixelCount(h),
                                        width: vImagePixelCount(w), rowBytes: w)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageMax_Planar8(&src, &dst, nil, 0, 0, vImagePixelCount(kh), vImagePixelCount(kw), vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    /// Tent (triangle) blur of a one-byte plane with radius `r`.
    static func blur(_ m: [UInt8], w: Int, h: Int, r: Int) -> [UInt8] {
        guard r > 0 else { return m }
        var out = [UInt8](repeating: 0, count: w * h)
        m.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress), height: vImagePixelCount(h),
                                        width: vImagePixelCount(w), rowBytes: w)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageTentConvolve_Planar8(&src, &dst, nil, 0, 0, UInt32(2 * r + 1), UInt32(2 * r + 1), 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    /// Tent blur of an RGBA image with radius `r`.
    static func tent(_ img: RGBAImage, r: Int) -> RGBAImage {
        var out = img
        img.pixels.withUnsafeBytes { s in
            out.pixels.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress), height: vImagePixelCount(img.height),
                                        width: vImagePixelCount(img.width), rowBytes: img.width * 4)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(img.height), width: vImagePixelCount(img.width),
                                        rowBytes: img.width * 4)
                vImageTentConvolve_ARGB8888(&src, &dst, nil, 0, 0, UInt32(2 * r + 1), UInt32(2 * r + 1), nil, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    static func luma(_ img: RGBAImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: img.width * img.height)
        img.pixels.withUnsafeBufferPointer { p in
            for i in out.indices { out[i] = UInt8((Int(p[i * 4]) * 77 + Int(p[i * 4 + 1]) * 150 + Int(p[i * 4 + 2]) * 29) >> 8) }
        }
        return out
    }

    /// Smooth resize of a one-byte plane.
    static func resize(_ m: [UInt8], w: Int, h: Int, to nw: Int, _ nh: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: nw * nh)
        m.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress), height: vImagePixelCount(h),
                                        width: vImagePixelCount(w), rowBytes: w)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(nh), width: vImagePixelCount(nw), rowBytes: nw)
                vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    /// Box mean of a float plane, radius `r` (running sums, rows then columns, clamped at the edges).
    static func boxF(_ v: [Float], w: Int, h: Int, r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: v.count), out = tmp
        let norm = 1 / Float(2 * r + 1)
        v.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    var sum: Float = 0
                    for i in -r...r { sum += src[row + min(max(i, 0), w - 1)] }
                    for x in 0..<w {
                        dst[row + x] = sum * norm
                        sum += src[row + min(x + r + 1, w - 1)] - src[row + max(x - r, 0)]
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for x in 0..<w {
                    var sum: Float = 0
                    for i in -r...r { sum += src[min(max(i, 0), h - 1) * w + x] }
                    for y in 0..<h {
                        dst[y * w + x] = sum * norm
                        sum += src[min(y + r + 1, h - 1) * w + x] - src[max(y - r, 0) * w + x]
                    }
                }
            }
        }
        return out
    }
}
