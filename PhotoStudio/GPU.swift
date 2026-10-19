import Metal

/// Runs the Metal kernels in Shaders.metal on RGBAImage buffers.
final class GPU {
    static let shared = GPU()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let smoothPSO: MTLComputePipelineState
    private let warpPSO: MTLComputePipelineState

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: ShaderSource.code, options: nil)
        smoothPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "smoothSkin")!)
        warpPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "faceWarp")!)
    }

    /// Runs each kernel once on a tiny image. The kernels compile in init (on first use of `shared`), so calling
    /// this at launch keeps that cost off the first slider move.
    func warmUp() {
        let img = RGBAImage(width: 8, height: 8)
        _ = smooth(img, mask: [UInt8](repeating: 255, count: 64), maskWidth: 8, maskHeight: 8, strength: 1, radius: 3)
        _ = warp(img, ops: [WarpOp(c: SIMD2(4, 4), r: 3, kind: 0, m: SIMD2(1, 0), s: 0)])
    }

    private func texture(_ img: RGBAImage) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        img.pixels.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: img.width * 4)
        }
        return t
    }

    private func grayTexture(_ bytes: [UInt8], width w: Int, height h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        bytes.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w)
        }
        return t
    }

    private func outputTexture(width w: Int, height h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)!
    }

    private func readBack(_ t: MTLTexture) -> RGBAImage {
        var out = RGBAImage(width: t.width, height: t.height)
        out.pixels.withUnsafeMutableBytes {
            t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return out
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, width w: Int, height h: Int) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    /// Skin smoothing. `mask` can be lower resolution than `img`; the kernel samples it with normalised coordinates.
    func smooth(_ img: RGBAImage, mask: [UInt8], maskWidth: Int, maskHeight: Int, strength: Float, radius: Float) -> RGBAImage {
        let src = texture(img), msk = grayTexture(mask, width: maskWidth, height: maskHeight)
        let dst = outputTexture(width: img.width, height: img.height)
        var s = strength, r = radius
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(smoothPSO)
        enc.setTexture(src, index: 0)
        enc.setTexture(msk, index: 1)
        enc.setTexture(dst, index: 2)
        enc.setBytes(&s, length: 4, index: 0)
        enc.setBytes(&r, length: 4, index: 1)
        dispatch(enc, smoothPSO, width: img.width, height: img.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return readBack(dst)
    }

    /// Face-shape warp: up to 64 slider operations plus the Reshape pushes.
    func warp(_ img: RGBAImage, ops: [WarpOp]) -> RGBAImage {
        guard !ops.isEmpty else { return img }
        let src = texture(img)
        let dst = outputTexture(width: img.width, height: img.height)
        // A buffer rather than setBytes, which is limited to 4 KB (128 operations).
        let list = ops.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        var count = UInt32(ops.count)
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(warpPSO)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBuffer(list, offset: 0, index: 0)
        enc.setBytes(&count, length: 4, index: 1)
        dispatch(enc, warpPSO, width: img.width, height: img.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return readBack(dst)
    }
}
