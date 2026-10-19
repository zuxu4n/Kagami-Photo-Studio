import Foundation
import CoreGraphics
import Accelerate
#if canImport(UIKit)
import UIKit
#endif

/// Opaque 8-bit RGBA pixels, top row first. The working format for every tool.
struct RGBAImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 255, count: width * height * 4)
    }

    /// Draws `cgImage` into a new buffer, optionally scaled so the long side is at most `maxSide`.
    init(cgImage: CGImage, maxSide: Int? = nil) {
        var w = cgImage.width, h = cgImage.height
        if let m = maxSide, max(w, h) > m {
            let s = Double(m) / Double(max(w, h))
            w = max(1, Int((Double(w) * s).rounded()))
            h = max(1, Int((Double(h) * s).rounded()))
        }
        self.init(cgImage: cgImage, exactWidth: w, exactHeight: h)
    }

    /// Draws `cgImage` scaled to exactly `w` x `h`.
    init(cgImage: CGImage, exactWidth w: Int, exactHeight h: Int) {
        width = w
        height = h
        pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: RGBAImage.colorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    func cgImage() -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: RGBAImage.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    #if canImport(UIKit)
    func uiImage() -> UIImage { UIImage(cgImage: cgImage()) }
    #endif

    /// A region (top-left origin, pixels) resampled to `w` x `h`.
    func resampled(region: CGRect, width w: Int, height h: Int) -> RGBAImage {
        let src = cgImage().cropping(to: region.integral) ?? cgImage()
        return RGBAImage(cgImage: src, exactWidth: w, exactHeight: h)
    }

    /// Resized to exactly `w` x `h` with vImage's high-quality (Lanczos) filter.
    func scaled(toWidth w: Int, height h: Int) -> RGBAImage {
        var out = RGBAImage(width: w, height: h)
        pixels.withUnsafeBytes { sp in
            out.pixels.withUnsafeMutableBytes { dp in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sp.baseAddress), height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width * 4)
                var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                vImageScale_ARGB8888(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return out
    }

    /// Copy with edges replicated so the result is at least `minW` x `minH`.
    func paddedByReplication(minWidth minW: Int, minHeight minH: Int) -> RGBAImage {
        guard width < minW || height < minH else { return self }
        let nw = max(width, minW), nh = max(height, minH)
        var out = RGBAImage(width: nw, height: nh)
        for y in 0..<nh {
            let sy = min(y, height - 1)
            for x in 0..<nw {
                let sx = min(x, width - 1)
                let si = (sy * width + sx) * 4, di = (y * nw + x) * 4
                out.pixels[di] = pixels[si]
                out.pixels[di + 1] = pixels[si + 1]
                out.pixels[di + 2] = pixels[si + 2]
                out.pixels[di + 3] = 255
            }
        }
        return out
    }
}

#if canImport(UIKit)
extension UIImage {
    /// Upright, 8-bit sRGB CGImage with the long side capped at `maxSide`.
    func normalizedCGImage(maxSide: Int) -> CGImage? {
        let pxW = size.width * scale, pxH = size.height * scale
        let s = min(1.0, CGFloat(maxSide) / max(pxW, pxH))
        let target = CGSize(width: (pxW * s).rounded(), height: (pxH * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let img = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return img.cgImage
    }
}
#endif
