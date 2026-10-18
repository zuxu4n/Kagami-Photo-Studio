import CoreML

/// Moves pixels between RGBAImage and Core ML tensors shaped [1, C, H, W] with values in 0...1.
enum MLTensors {
    /// New [1, 3, size, size] Float32 tensor from the `size` x `size` region of `img` at (x0, y0).
    static func rgbTensor(from img: RGBAImage, x0: Int, y0: Int, size: Int) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let plane = size * size
        let dst = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        let inv: Float = 1.0 / 255.0
        img.pixels.withUnsafeBufferPointer { src in
            for y in 0..<size {
                let srow = ((y0 + y) * img.width + x0) * 4
                let drow = y * size
                for x in 0..<size {
                    let si = srow + x * 4
                    dst[drow + x] = Float(src[si]) * inv
                    dst[plane + drow + x] = Float(src[si + 1]) * inv
                    dst[2 * plane + drow + x] = Float(src[si + 2]) * inv
                }
            }
        }
        return arr
    }

    /// New [1, 1, size, size] Float32 tensor from 8-bit mask bytes (> 127 means 1).
    static func maskTensor(from mask: [UInt8], size: Int) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, 1, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let dst = arr.dataPointer.bindMemory(to: Float.self, capacity: size * size)
        for i in 0..<(size * size) { dst[i] = mask[i] > 127 ? 1 : 0 }
        return arr
    }

    /// Copies a region of a [1, 3, H, W] output tensor into `dst`.
    /// Tensor pixels (tx0..<tx0+w, ty0..<ty0+h) go to dst pixels starting at (dx0, dy0).
    static func copyRGB(from arr: MLMultiArray, tx0: Int, ty0: Int, width w: Int, height h: Int,
                        into dst: inout RGBAImage, dx0: Int, dy0: Int) {
        let st = arr.strides.map { $0.intValue }
        let cs = st[1], ys = st[2], xs = st[3]
        let dw = dst.width
        @inline(__always) func u8(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v * 255 + 0.5))) }
        dst.pixels.withUnsafeMutableBufferPointer { out in
            switch arr.dataType {
            case .float16:
                arr.withUnsafeBufferPointer(ofType: Float16.self) { p in
                    for y in 0..<h {
                        let base = (ty0 + y) * ys
                        let orow = ((dy0 + y) * dw + dx0) * 4
                        for x in 0..<w {
                            let o = base + (tx0 + x) * xs
                            let di = orow + x * 4
                            out[di] = u8(Float(p[o]))
                            out[di + 1] = u8(Float(p[o + cs]))
                            out[di + 2] = u8(Float(p[o + 2 * cs]))
                            out[di + 3] = 255
                        }
                    }
                }
            default:
                arr.withUnsafeBufferPointer(ofType: Float.self) { p in
                    for y in 0..<h {
                        let base = (ty0 + y) * ys
                        let orow = ((dy0 + y) * dw + dx0) * 4
                        for x in 0..<w {
                            let o = base + (tx0 + x) * xs
                            let di = orow + x * 4
                            out[di] = u8(p[o])
                            out[di + 1] = u8(p[o + cs])
                            out[di + 2] = u8(p[o + 2 * cs])
                            out[di + 3] = 255
                        }
                    }
                }
            }
        }
    }
}
