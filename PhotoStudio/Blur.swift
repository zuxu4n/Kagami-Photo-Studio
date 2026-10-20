import Metal
import Vision
import CoreGraphics
import CoreVideo
import Accelerate

/// Where the people are in one photo, from Apple's on-device person cutout, normalised so it applies at any resolution.
/// Made once per photo (and again after Enhance or Heal change it), then reused for every Blur frame and the Save.
struct PersonMatte {
    let width: Int, height: Int
    let base: [UInt8]           // 255 on a person as the cutout found them, refined along the edges with the photo as a guide (hair)
    let alpha: [UInt8]          // `base` with the hand-painted fixes in `edits`
    let holeWidth: Int, holeHeight: Int
    let hole: [UInt8]           // the people grown a little and feathered: where the background is filled before blurring
    let fill: [UInt8]           // RGBA at hole size: the background around the people carried in over them
    let fgWidth: Int, fgHeight: Int
    let fg: [UInt8]             // RGBA: the people's own colours carried out past their edges, for half-covered pixels
    let hasPerson: Bool
    var edits = MatteEdits.none
}

/// What Remove background puts behind the people.
enum CutMode {
    case color(SIMD3<Float>)   // a solid colour (sRGB, 0...1)
    case checker               // the usual grey squares for "see-through", for the preview
    case foreground            // the people's colours, carried out past their edges (for a see-through Save)
    case mask                  // the people's coverage as grey (for a see-through Save's alpha)

    var code: UInt32 {
        switch self { case .color: return 1; case .checker: return 2; case .foreground: return 4; case .mask: return 3 }
    }
}

/// Hand-painted fixes to the people found, at any size (normalised): 255 keeps a pixel sharp as part of a person,
/// 0 blurs it as background, 128 leaves the cutout's own answer.
struct MatteEdits: Equatable {
    var width: Int, height: Int
    var values: [UInt8]
    static let none = MatteEdits(width: 1, height: 1, values: [128])
    var isEmpty: Bool { !values.contains { $0 != 128 } }

    /// The same fixes at w x h (nearest pixel), so a photo that changed size keeps them in place.
    func resized(_ w: Int, _ h: Int) -> MatteEdits {
        if w == width && h == height { return self }
        var out = [UInt8](repeating: 128, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = values[min(height - 1, y * height / h) * width + min(width - 1, x * width / w)] } }
        return MatteEdits(width: w, height: h, values: out)
    }
}

/// Background blur like a camera lens: the people stay sharp and everything behind them is blurred with a round
/// aperture, so bright spots become soft discs. The background is blurred with the people taken out and filled in
/// from around them, so their colours don't bleed into it and leave a glow.
final class BackgroundBlur {
    static let shared = BackgroundBlur()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let prepPSO: MTLComputePipelineState
    private let lensPSO: MTLComputePipelineState
    private let compositePSO: MTLComputePipelineState

    private init() {
        device = GPU.shared.device
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: BackgroundBlur.shader, options: nil)
        prepPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "blurPrep")!)
        lensPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "lensBlur")!)
        compositePSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "blurComposite")!)
    }

    /// The blur's radius at Strength 1, as a fraction of the photo's long side.
    static let maxRadius = 0.03
    /// The background is blurred on a smaller copy, sized so the blur is at most this many of its pixels across.
    static let smallRadius = 12.0
    /// The hole and its fill are made at most this size on the long side.
    static let holeSide = 384.0
    /// The people's colours for half-covered pixels are made at most this size on the long side.
    static let fgSide = 640.0

    // MARK: Finding the people

    /// Runs the person cutout on `img` (accurate quality) and prepares the matte, hole and fill.
    static func personMatte(_ img: RGBAImage) throws -> PersonMatte {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: img.cgImage(), options: [:]).perform([req])
        var mw = 1, mh = 1
        var raw = [UInt8](repeating: 0, count: 1)
        if let pb = req.results?.first?.pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            mw = CVPixelBufferGetWidth(pb); mh = CVPixelBufferGetHeight(pb)
            let row = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            raw = [UInt8](repeating: 0, count: mw * mh)
            for y in 0..<mh { for x in 0..<mw { raw[y * mw + x] = base[y * row + x] } }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        let on = raw.reduce(0) { $0 + ($1 > 128 ? 1 : 0) }
        let hasPerson = Double(on) > 0.002 * Double(raw.count)
        let base = hasPerson ? refine(raw, mw, mh, guide: img.scaled(toWidth: mw, height: mh)) : [UInt8](repeating: 0, count: mw * mh)
        return finish(base: base, alpha: base, mw, mh, img, edits: .none)
    }

    /// `m` with `edits` painted over the cutout's own answer, and its fill made again so the background behind a
    /// pixel painted sharp doesn't hold its colours (and a part painted blurred is filled like background).
    static func withEdits(_ m: PersonMatte, _ edits: MatteEdits, image img: RGBAImage) -> PersonMatte {
        let e = edits.resized(m.width, m.height)
        var alpha = m.base
        for k in alpha.indices {
            let v = e.values[k]
            if v > 128 { alpha[k] = UInt8(Int(alpha[k]) + (255 - Int(alpha[k])) * (Int(v) - 128) / 127) }
            else if v < 128 { alpha[k] = UInt8(Int(alpha[k]) * Int(v) / 128) }
        }
        return finish(base: m.base, alpha: alpha, m.width, m.height, img, edits: edits)
    }

    private static func finish(base: [UInt8], alpha: [UInt8], _ mw: Int, _ mh: Int, _ img: RGBAImage, edits: MatteEdits) -> PersonMatte {
        let on = alpha.reduce(0) { $0 + ($1 > 128 ? 1 : 0) }
        let hasPerson = Double(on) > 0.002 * Double(alpha.count)
        let hs = min(1.0, holeSide / Double(max(img.width, img.height)))
        let hw = max(1, Int(Double(img.width) * hs)), hh = max(1, Int(Double(img.height) * hs))
        let hole = hasPerson ? holeMask(alpha, mw, mh, hw, hh) : [UInt8](repeating: 0, count: hw * hh)
        let small = img.scaled(toWidth: hw, height: hh)
        let fill = hasPerson ? pullPush(withBusyness(small, hole: hole), weights: hole.map { 1 - Float($0) / 255 }) : small.pixels
        // Where a person only half covers a pixel (hair, the soft edge), part of it is the sharp background. Their own
        // colour from just inside the edge takes that part's place, so no sharp rim or glow is left around them.
        let fs = min(1.0, fgSide / Double(max(img.width, img.height)))
        let fw = max(1, Int(Double(img.width) * fs)), fh = max(1, Int(Double(img.height) * fs))
        let fg = hasPerson ? pullPush(img.scaled(toWidth: fw, height: fh), weights: solid(alpha, mw, mh, fw, fh)) : [UInt8](repeating: 0, count: fw * fh * 4)
        return PersonMatte(width: mw, height: mh, base: base, alpha: alpha, holeWidth: hw, holeHeight: hh, hole: hole, fill: fill,
                           fgWidth: fw, fgHeight: fh, fg: fg, hasPerson: hasPerson, edits: edits)
    }

    /// The cutout's edges lined up with the photo's own (a guided filter on brightness), so strands of hair the cutout
    /// left soft follow the photo. Only the edge band changes; the inside and outside stay as the cutout found them.
    private static func refine(_ mask: [UInt8], _ w: Int, _ h: Int, guide: RGBAImage) -> [UInt8] {
        let n = w * h
        var I = [Float](repeating: 0, count: n), p = I
        for k in 0..<n {
            let o = k * 4
            I[k] = (0.299 * Float(guide.pixels[o]) + 0.587 * Float(guide.pixels[o + 1]) + 0.114 * Float(guide.pixels[o + 2])) / 255
            // The cutout is unsure of people further back (half values over a whole person): anything it half
            // believes is a person counts fully, so nobody turns see-through. The edge stays a ramp for the filter.
            let m = Float(mask[k]) / 255
            let t = max(0, min(1, (m - 0.15) / 0.35))
            p[k] = t * t * (3 - 2 * t)
        }
        let r = max(2, max(w, h) / 450), eps: Float = 0.0006
        let mI = box(I, w, h, r), mP = box(p, w, h, r)
        let mII = box(zip(I, I).map(*), w, h, r), mIP = box(zip(I, p).map(*), w, h, r)
        var a = [Float](repeating: 0, count: n), b = a
        for k in 0..<n {
            let v = mII[k] - mI[k] * mI[k]
            a[k] = (mIP[k] - mI[k] * mP[k]) / (v + eps)
            b[k] = mP[k] - a[k] * mI[k]
        }
        let mA = box(a, w, h, r), mB = box(b, w, h, r)
        var out = p.map { UInt8($0 * 255 + 0.5) }
        for k in 0..<n where mP[k] > 0.01 && mP[k] < 0.99 {
            let q = mA[k] * I[k] + mB[k]
            out[k] = UInt8(max(0, min(1, q)) * 255 + 0.5)
        }
        return out
    }

    /// A box blur of radius r, clamped at the edges (running sums, rows then columns).
    private static func box(_ v: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
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

    /// The people at hw x hh, grown by about 1.5% of the long side and feathered: the band around them holds a mix of
    /// their colours and the background's, so it's filled too rather than blurred into the background.
    private static func holeMask(_ alpha: [UInt8], _ mw: Int, _ mh: Int, _ hw: Int, _ hh: Int) -> [UInt8] {
        var bin = [UInt8](repeating: 0, count: hw * hh)
        for y in 0..<hh {
            for x in 0..<hw {
                // Any of the cutout's pixels under this one counts, so thin strands of hair are inside the hole.
                let x0 = x * mw / hw, x1 = max(x0 + 1, (x + 1) * mw / hw), y0 = y * mh / hh, y1 = max(y0 + 1, (y + 1) * mh / hh)
                var m: UInt8 = 0
                for yy in y0..<min(y1, mh) { for xx in x0..<min(x1, mw) { m = max(m, alpha[yy * mw + xx]) } }
                bin[y * hw + x] = m > 12 ? 255 : 0
            }
        }
        let grow = UInt32(max(2, max(hw, hh) / 66) * 2 + 1), soft = UInt32(max(1, max(hw, hh) / 160) * 2 + 1)
        var grown = [UInt8](repeating: 0, count: hw * hh), out = grown
        bin.withUnsafeMutableBytes { sb in
            grown.withUnsafeMutableBytes { gb in
                out.withUnsafeMutableBytes { ob in
                    var s = vImage_Buffer(data: sb.baseAddress, height: vImagePixelCount(hh), width: vImagePixelCount(hw), rowBytes: hw)
                    var g = vImage_Buffer(data: gb.baseAddress, height: vImagePixelCount(hh), width: vImagePixelCount(hw), rowBytes: hw)
                    var o = vImage_Buffer(data: ob.baseAddress, height: vImagePixelCount(hh), width: vImagePixelCount(hw), rowBytes: hw)
                    vImageMax_Planar8(&s, &g, nil, 0, 0, vImagePixelCount(grow), vImagePixelCount(grow), vImage_Flags(kvImageEdgeExtend))
                    vImageTentConvolve_Planar8(&g, &o, nil, 0, 0, soft, soft, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        // The feather goes outwards only, so the grown area stays fully filled.
        for k in out.indices { out[k] = max(out[k], grown[k]) }
        return out
    }

    /// 1 where every cutout pixel under a fw x fh pixel is fully on a person, else 0.
    private static func solid(_ alpha: [UInt8], _ mw: Int, _ mh: Int, _ fw: Int, _ fh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: fw * fh)
        for y in 0..<fh {
            for x in 0..<fw {
                let x0 = max(0, x * mw / fw - 1), x1 = min(mw, (x + 1) * mw / fw + 1), y0 = max(0, y * mh / fh - 1), y1 = min(mh, (y + 1) * mh / fh + 1)
                var m: UInt8 = 255
                for yy in y0..<y1 { for xx in x0..<x1 { m = min(m, alpha[yy * mw + xx]) } }
                out[y * fw + x] = m > 245 ? 1 : 0
            }
        }
        return out
    }

    /// The known pixels (weight 1) carried in over the unknown ones (pull-push): averages of the known ones, at
    /// coarser and coarser sizes, fill the gaps from their edges inward, so nearby colours fill nearby gaps.
    /// All four channels are carried.
    private static func pullPush(_ img: RGBAImage, weights: [Float]) -> [UInt8] {
        let w = img.width, h = img.height
        // Five floats a pixel: the four channels times the weight, then the weight.
        var levels: [(w: Int, h: Int, v: [Float])] = []
        var v = [Float](repeating: 0, count: w * h * 5)
        for k in 0..<(w * h) {
            let wt = weights[k]
            for c in 0..<4 { v[k * 5 + c] = Float(img.pixels[k * 4 + c]) * wt }
            v[k * 5 + 4] = wt
        }
        levels.append((w, h, v))
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let f = levels.last!
            let cw = (f.w + 1) / 2, ch = (f.h + 1) / 2
            var c = [Float](repeating: 0, count: cw * ch * 5)
            for y in 0..<ch {
                for x in 0..<cw {
                    var s = [Float](repeating: 0, count: 5)
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let o = (min(2 * y + dy, f.h - 1) * f.w + min(2 * x + dx, f.w - 1)) * 5
                        for i in 0..<5 { s[i] += f.v[o + i] }
                    }
                    let k: Float = s[4] > 1 ? 1 / s[4] : 1   // at most fully known
                    for i in 0..<5 { c[(y * cw + x) * 5 + i] = s[i] * k }
                }
            }
            levels.append((cw, ch, c))
        }
        if levels.last!.v[4] < 1e-6 { return img.pixels }   // nothing known: leave the photo as it is
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let c = levels[l + 1]
            var f = levels[l]
            for y in 0..<f.h {
                for x in 0..<f.w {
                    let o = (y * f.w + x) * 5
                    let missing = 1 - f.v[o + 4]
                    if missing <= 0 { continue }
                    // Bilinear from the coarser level, which is fully known by now.
                    let cx = max(0, min(Float(c.w - 1), (Float(x) + 0.5) / 2 - 0.5)), cy = max(0, min(Float(c.h - 1), (Float(y) + 0.5) / 2 - 0.5))
                    let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, c.w - 1), y1 = min(y0 + 1, c.h - 1)
                    let tx = cx - Float(x0), ty = cy - Float(y0)
                    for (xx, yy, wt) in [(x0, y0, (1 - tx) * (1 - ty)), (x1, y0, tx * (1 - ty)), (x0, y1, (1 - tx) * ty), (x1, y1, tx * ty)] {
                        let i = (yy * c.w + xx) * 5
                        guard c.v[i + 4] > 1e-6 else { continue }
                        let k = missing * wt / c.v[i + 4]
                        for j in 0..<5 { f.v[o + j] += c.v[i + j] * k }
                    }
                }
            }
            levels[l] = f
        }
        let top = levels[0].v
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for k in 0..<(w * h) {
            let wt = max(top[k * 5 + 4], 1e-6)
            for c in 0..<4 { out[k * 4 + c] = UInt8(max(0, min(255, top[k * 5 + c] / wt)) + 0.5) }
        }
        return out
    }

    /// How busy the background is around each pixel (the local spread of brightness, x4, in the alpha channel), so
    /// flyaway hair is only looked for in front of plain backgrounds, where it can't be mistaken for the scene.
    private static func withBusyness(_ img: RGBAImage, hole: [UInt8]) -> RGBAImage {
        let w = img.width, h = img.height, n = w * h
        let r = max(2, max(w, h) / 120)
        var l = [Float](repeating: 0, count: n), wt = l
        for k in 0..<n {
            let o = k * 4
            l[k] = (0.299 * Float(img.pixels[o]) + 0.587 * Float(img.pixels[o + 1]) + 0.114 * Float(img.pixels[o + 2])) / 255
            wt[k] = hole[k] == 0 ? 1 : 0
        }
        let bw = box(wt, w, h, r), bl = box(zip(l, wt).map(*), w, h, r), bll = box(l.enumerated().map { $1 * $1 * wt[$0] }, w, h, r)
        var out = img
        for k in 0..<n {
            let m = bw[k] > 1e-3 ? bl[k] / bw[k] : 0
            let v = bw[k] > 1e-3 ? max(0, bll[k] / bw[k] - m * m) : 0
            out.pixels[k * 4 + 3] = UInt8(min(255, sqrt(v) * 4 * 255))
        }
        return out
    }

    // MARK: Blurring

    /// `img` with the background blurred by `strength` (0...1). The matte is normalised, so this runs at any size.
    /// `edits`: fixes being painted that `matte` doesn't hold yet (a stroke under way), shown on the edge only.
    static func apply(_ img: RGBAImage, matte: PersonMatte, strength: Float, edits: MatteEdits? = nil) -> RGBAImage {
        let rFull = Double(strength) * maxRadius * Double(max(img.width, img.height))
        guard rFull > 0.3 else { return img }
        let s = min(0.5, smallRadius / rFull)
        let sw = max(8, Int((Double(img.width) * s).rounded())), sh = max(8, Int((Double(img.height) * s).rounded()))
        let small = img.scaled(toWidth: sw, height: sh)
        return shared.run(img, small: small, matte: matte, edits: edits ?? matte.edits, mode: 0, color: .zero, radius: Float(rFull * Double(sw) / Double(img.width)),
                          fade: Float(min(1, max(0, (rFull - 0.3) / 2.7))))
    }

    /// Remove background: `img` with everything but the people replaced as `mode` says. Same edges as the blur
    /// (the person's own colour on half-covered pixels, flyaway hair, painted fixes).
    static func cutOut(_ img: RGBAImage, matte: PersonMatte, mode: CutMode, edits: MatteEdits? = nil) -> RGBAImage {
        let s = min(0.5, smallRadius / (maxRadius * Double(max(img.width, img.height))))
        let sw = max(8, Int((Double(img.width) * s).rounded())), sh = max(8, Int((Double(img.height) * s).rounded()))
        var color = SIMD3<Float>.zero
        if case .color(let c) = mode { color = c }
        return shared.run(img, small: img.scaled(toWidth: sw, height: sh), matte: matte, edits: edits ?? matte.edits,
                          mode: mode.code, color: color, radius: 0, fade: 1)
    }

    private func run(_ img: RGBAImage, small: RGBAImage, matte: PersonMatte, edits: MatteEdits, mode: UInt32, color: SIMD3<Float>,
                     radius: Float, fade: Float) -> RGBAImage {
        func tex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, private p: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = p ? .private : .shared
            return device.makeTexture(descriptor: d)!
        }
        func upload(_ t: MTLTexture, _ bytes: [UInt8], _ bpp: Int) {
            bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: t.width * bpp) }
        }
        let src = tex(.rgba8Unorm, img.width, img.height); upload(src, img.pixels, 4)
        let sm = tex(.rgba8Unorm, small.width, small.height); upload(sm, small.pixels, 4)
        let hole = tex(.r8Unorm, matte.holeWidth, matte.holeHeight); upload(hole, matte.hole, 1)
        let fill = tex(.rgba8Unorm, matte.holeWidth, matte.holeHeight); upload(fill, matte.fill, 4)
        let alpha = tex(.r8Unorm, matte.width, matte.height); upload(alpha, matte.alpha, 1)
        let fg = tex(.rgba8Unorm, matte.fgWidth, matte.fgHeight); upload(fg, matte.fg, 4)
        let ed = tex(.r8Unorm, edits.width, edits.height); upload(ed, edits.values, 1)
        let prepped = tex(.rgba16Float, small.width, small.height, private: true)
        let blurred = tex(.rgba16Float, small.width, small.height, private: true)
        let dst = tex(.rgba8Unorm, img.width, img.height)
        var r = radius, f = fade
        var taps = UInt32(min(400, max(12, Int(3 * radius * radius))))
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        func dispatch(_ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
            enc.setComputePipelineState(pso)
            let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }
        enc.setTexture(sm, index: 0); enc.setTexture(hole, index: 1); enc.setTexture(fill, index: 2); enc.setTexture(prepped, index: 3)
        dispatch(prepPSO, small.width, small.height)
        if mode == 0 {
            enc.setTexture(prepped, index: 0); enc.setTexture(blurred, index: 1)
            enc.setBytes(&r, length: 4, index: 0); enc.setBytes(&taps, length: 4, index: 1)
            dispatch(lensPSO, small.width, small.height)
        }
        var md = mode, col = SIMD4<Float>(color, 1)
        enc.setBytes(&md, length: 4, index: 1); enc.setBytes(&col, length: 16, index: 2)
        enc.setTexture(src, index: 0); enc.setTexture(mode == 0 ? blurred : prepped, index: 1); enc.setTexture(alpha, index: 2); enc.setTexture(dst, index: 3); enc.setTexture(fg, index: 4)
        enc.setTexture(prepped, index: 5); enc.setTexture(hole, index: 6); enc.setTexture(fill, index: 7); enc.setTexture(ed, index: 8)
        enc.setBytes(&f, length: 4, index: 0)
        dispatch(compositePSO, img.width, img.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = RGBAImage(width: img.width, height: img.height)
        out.pixels.withUnsafeMutableBytes { dst.getBytes($0.baseAddress!, bytesPerRow: img.width * 4, from: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0) }
        return out
    }

    /// Runs the kernels and the person cutout once on a tiny image, so their first-use costs (the cutout's model load
    /// is several seconds) aren't on the first Blur.
    func warmUp() {
        let img = RGBAImage(width: 64, height: 64)
        let matte = (try? BackgroundBlur.personMatte(img))
            ?? PersonMatte(width: 1, height: 1, base: [0], alpha: [0], holeWidth: 1, holeHeight: 1, hole: [0], fill: [0, 0, 0, 255],
                           fgWidth: 1, fgHeight: 1, fg: [0, 0, 0, 255], hasPerson: false)
        _ = BackgroundBlur.apply(img, matte: matte, strength: 1)
    }

    // Compiled on the device at first use, like ShaderSource.
    private static let shader = """
#include <metal_stdlib>
using namespace metal;

// sRGB and linear light, close enough for blurring: lenses blur light, so highlights spread like real ones.
static float3 toLinear(float3 c) { return pow(c, 2.2); }
static float3 toSRGB(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }

// The small copy of the photo with the people (and a band around them) replaced by the background filled in from
// around them, in linear light.
kernel void blurPrep(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::sample> hole [[texture(1)]],
                     texture2d<float, access::sample> fill [[texture(2)]],
                     texture2d<float, access::write> dst [[texture(3)]],
                     uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler sn(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float3 c = src.read(gid).rgb;
    float m = hole.sample(sn, uv).r;
    dst.write(float4(toLinear(mix(c, fill.sample(sn, uv).rgb, m)), 1.0), gid);
}

// A round aperture: an even disc of samples (a golden-angle spiral). Bright samples count for more, as a bright spot
// out of focus is a bright disc that outshines the dimmer light around it.
kernel void lensBlur(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float &radius [[buffer(0)]],
                     constant uint &taps [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler sp(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 p = float2(gid) + 0.5;
    float3 acc = 0.0;
    float wsum = 0.0;
    for (uint i = 0; i < taps; i++) {
        float r = radius * sqrt((float(i) + 0.5) / float(taps));
        float a = float(i) * 2.39996323;
        float3 c = src.sample(sp, p + r * float2(cos(a), sin(a))).rgb;
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        float b = smoothstep(0.45, 1.0, l);
        float wt = 1.0 + 14.0 * b * b;
        acc += c * wt;
        wsum += wt;
    }
    dst.write(float4(acc / wsum, 1.0), gid);
}

// The sharp photo over the blurred background, through the people's matte.
kernel void blurComposite(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::sample> blurred [[texture(1)]],
                          texture2d<float, access::sample> alpha [[texture(2)]],
                          texture2d<float, access::write> dst [[texture(3)]],
                          texture2d<float, access::sample> fg [[texture(4)]],
                          texture2d<float, access::sample> behind [[texture(5)]],
                          texture2d<float, access::sample> hole [[texture(6)]],
                          texture2d<float, access::sample> fill [[texture(7)]],
                          texture2d<float, access::sample> edits [[texture(8)]],
                          constant float &fade [[buffer(0)]],
                          constant uint &mode [[buffer(1)]],
                          constant float4 &color [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler sn(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float3 c = src.read(gid).rgb;
    // The matte's soft edge is narrowed, so the sharp background doesn't show through it as a ring and hair edges
    // stay crisp; strands the cutout only half caught still count as hair.
    float a = smoothstep(0.3, 0.95, alpha.sample(sn, uv).r);
    float3 bg = toSRGB(blurred.sample(sn, uv).rgb);
    float3 fc = fg.sample(sn, uv).rgb;
    // Flyaway hair the cutout missed: near a person, a pixel that lies between the background behind it and the
    // person's own colour (and close to that line) is taken as a strand covering that much of it.
    float near = hole.sample(sn, uv).r;
    if (near > 0.01 && a < 0.95) {
        float3 b = toSRGB(behind.sample(sn, uv).rgb);
        float3 d = fc - b;
        float dd = dot(d, d);
        if (dd > 0.012) {
            float t = clamp(dot(c - b, d) / dd, 0.0, 1.0);
            float off = length(c - (b + t * d));
            float busy = fill.sample(sn, uv).a;   // the background's local spread of brightness, x4
            float s = smoothstep(0.2, 0.8, t) * (1.0 - smoothstep(0.03, 0.09, off)) * smoothstep(0.3, 0.9, near)
                    * (1.0 - smoothstep(0.12, 0.3, busy));
            a = max(a, s);
        }
    }
    // Painted fixes come last: they win over the cutout and the flyaway search.
    float e = edits.sample(sn, uv).r;
    if (e > 0.51) a = mix(a, 1.0, (e - 0.5) * 2.0);
    else if (e < 0.49) a = mix(a, 0.0, (0.5 - e) * 2.0);
    // A half-covered pixel's own colour is part background; the person's colour from inside the edge stands in for
    // more of it the less the person covers it.
    float3 f = mix(fc, c, a * a);
    if (mode != 0) {   // Remove background
        float3 o;
        if (mode == 1) o = mix(color.rgb, f, a);
        else if (mode == 2) {
            uint cell = max(8u, max(w, h) / 64u);
            float k = ((gid.x / cell + gid.y / cell) & 1u) ? 0.78 : 0.94;
            o = mix(float3(k), f, a);
        }
        else if (mode == 3) o = float3(a);
        else o = a > 0.004 ? f : fc;
        dst.write(float4(o, 1.0), gid);
        return;
    }
    float3 sharp = mix(c, f, fade);
    dst.write(float4(mix(bg, sharp, a) * fade + c * (1.0 - fade), 1.0), gid);
}
"""
}
