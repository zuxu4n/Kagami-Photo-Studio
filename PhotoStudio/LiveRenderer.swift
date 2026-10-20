import Metal
import CoreVideo
import Accelerate
import simd

/// The camera's beauty settings, applied the same to every face.
struct LiveLook: Equatable {
    var smooth: Float = 0.3
    var shape = FaceShape()   // Face sliders and the Retouch values (`shape.retouch`); Reshape pushes aren't used
    var isOff: Bool { smooth <= 0.001 && shape.retouch.isOff && shape.meshOff && abs(shape.slim) <= 0.001 && abs(shape.eyes) <= 0.001 }
}

/// Smooth, Retouch and the Face warp on camera frames, with the same Metal kernels as the editor. Frames stay on the
/// GPU: the camera's buffer is read in place and the result is written straight into a buffer for the screen and the
/// recording. Only the small masks are made on the CPU, from the tracked faces.
final class LiveRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let smoothPSO, retouchPSO, warpPSO: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var scratch: [MTLTexture] = []
    private var maskTex: MTLTexture?, retouchTex: MTLTexture?, lowTex: MTLTexture?
    private var opsBuffer: MTLBuffer?

    /// The masks are made this size on the long side, the skin colour averages this.
    static let maskSide = 480.0, lowSide = 192.0

    init() {
        device = GPU.shared.device
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: ShaderSource.code, options: nil)
        smoothPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "smoothSkin")!)
        warpPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "faceWarp")!)
        let rlib = try! device.makeLibrary(source: Retouch.shader, options: nil)
        retouchPSO = try! device.makeComputePipelineState(function: rlib.makeFunction(name: "retouch")!)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// What the CPU prepares for one frame from the tracked faces: masks, averages and warp handles.
    struct Plan {
        var smoothMask: [UInt8]?, maskW = 0, maskH = 0, strength: Float = 0, radius: Float = 3
        var retouchMasks: [UInt8]?, low: [Float] = [], lowW = 1, lowH = 1
        var ops: [WarpOp] = []
    }

    /// Masks and handles for `faces` in a w x h frame. `small` is the frame at lowSide, for Even skin tone.
    static func plan(faces: [FaceGeometry], look: LiveLook, width w: Int, height h: Int, frame: RGBAImage) -> Plan {
        var p = Plan()
        guard !faces.isEmpty, !look.isOff else { return p }
        let s = min(1.0, maskSide / Double(max(w, h)))
        p.maskW = max(1, Int(Double(w) * s)); p.maskH = max(1, Int(Double(h) * s))
        if look.smooth > 0.001 {
            p.smoothMask = FaceAnalyzer.skinMask(faces: faces, width: p.maskW, height: p.maskH)
            p.strength = look.smooth
            p.radius = max(3, Float(faces.map(\.box.width).max() ?? 0.2) * Float(w) / 40)
        }
        let retouch = [FaceRetouch](repeating: look.shape.retouch, count: faces.count)
        if !look.shape.retouch.isOff {
            p.retouchMasks = Retouch.strengthMasks(faces: faces, retouch: retouch, width: p.maskW, height: p.maskH)
            if look.shape.retouch.tone > 0.001 {
                let ls = min(1.0, lowSide / Double(max(w, h)))
                p.lowW = max(1, Int(Double(w) * ls)); p.lowH = max(1, Int(Double(h) * ls))
                p.low = Retouch.skinAverages(frame, faces: faces, retouch: retouch, width: p.lowW, height: p.lowH)
            } else {
                p.low = [0, 0, 0, 0]
            }
        }
        var shape = look.shape
        shape.pushes = []
        shape.positionX = 0; shape.positionY = 0
        if !shape.isOff {
            p.ops = FaceAnalyzer.warpOps(faces: faces, shapes: [FaceShape](repeating: shape, count: faces.count), width: w, height: h)
        }
        return p
    }

    /// `src` (32BGRA) with the plan applied, in a new buffer of the same size; `src` itself when there's nothing to do.
    func render(_ src: CVPixelBuffer, plan: Plan) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let steps = (plan.smoothMask != nil ? 1 : 0) + (plan.retouchMasks != nil ? 1 : 0) + (plan.ops.isEmpty ? 0 : 1)
        guard steps > 0, let input = texture(src), let out = newBuffer(w, h), let output = texture(out) else { return src }
        if scratch.first?.width != w || scratch.first?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            scratch = [device.makeTexture(descriptor: d)!, device.makeTexture(descriptor: d)!]
        }
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return src }
        var current = input, done = 0
        func target() -> MTLTexture { done += 1; return done == steps ? output : scratch[done % 2] }
        if let mask = plan.smoothMask {
            let m = upload(&maskTex, .r8Unorm, plan.maskW, plan.maskH, mask, bytesPerPixel: 1)
            let dst = target()
            var strength = plan.strength, radius = plan.radius
            enc.setComputePipelineState(smoothPSO)
            enc.setTexture(current, index: 0); enc.setTexture(m, index: 1); enc.setTexture(dst, index: 2)
            enc.setBytes(&strength, length: 4, index: 0); enc.setBytes(&radius, length: 4, index: 1)
            dispatch(enc, smoothPSO, w, h)
            current = dst
        }
        if let masks = plan.retouchMasks {
            let m = upload(&retouchTex, .rgba8Unorm, plan.maskW, plan.maskH, masks, bytesPerPixel: 4)
            let lo = plan.low.withUnsafeBytes { b -> MTLTexture in
                upload(&lowTex, .rgba32Float, plan.lowW, plan.lowH, Array(b), bytesPerPixel: 16)
            }
            let dst = target()
            enc.setComputePipelineState(retouchPSO)
            enc.setTexture(current, index: 0); enc.setTexture(m, index: 1); enc.setTexture(lo, index: 2); enc.setTexture(dst, index: 3)
            dispatch(enc, retouchPSO, w, h)
            current = dst
        }
        if !plan.ops.isEmpty {
            let bytes = plan.ops.count * MemoryLayout<WarpOp>.stride
            if (opsBuffer?.length ?? 0) < bytes { opsBuffer = device.makeBuffer(length: max(bytes, 64 * 1024), options: .storageModeShared) }
            plan.ops.withUnsafeBytes { opsBuffer!.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
            var count = UInt32(plan.ops.count)
            let dst = target()
            enc.setComputePipelineState(warpPSO)
            enc.setTexture(current, index: 0); enc.setTexture(dst, index: 1)
            enc.setBuffer(opsBuffer, offset: 0, index: 0); enc.setBytes(&count, length: 4, index: 1)
            dispatch(enc, warpPSO, w, h)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()   // the masks and handles are reused next frame, and the frame goes out right after
        return out
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    private func upload(_ t: inout MTLTexture?, _ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ bytes: [UInt8], bytesPerPixel: Int) -> MTLTexture {
        if t == nil || t!.width != w || t!.height != h || t!.pixelFormat != fmt {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            t = device.makeTexture(descriptor: d)
        }
        bytes.withUnsafeBytes { t!.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * bytesPerPixel) }
        return t!
    }

    private func texture(_ pb: CVPixelBuffer) -> MTLTexture? {
        guard let cache else { return nil }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
        return t.flatMap { CVMetalTextureGetTexture($0) }
    }

    private func newBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (w, h) {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                                        kCVPixelBufferMetalCompatibilityKey as String: true,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, attrs as CFDictionary, &pool)
            poolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        guard let pool else { return nil }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    /// The frame as RGBA on the CPU, for the face mesh and the skin colour averages.
    static func rgba(_ pb: CVPixelBuffer) -> RGBAImage {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var img = RGBAImage(width: w, height: h)
        var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(h), width: vImagePixelCount(w),
                                rowBytes: CVPixelBufferGetBytesPerRow(pb))
        img.pixels.withUnsafeMutableBytes { buf in
            var dst = vImage_Buffer(data: buf.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            let order: [UInt8] = [2, 1, 0, 3]   // BGRA to RGBA
            vImagePermuteChannels_ARGB8888(&src, &dst, order, vImage_Flags(kvImageNoFlags))
        }
        return img
    }
}
