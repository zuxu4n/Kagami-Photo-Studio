import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import SwiftUI

/// The shape a photo or video is cropped to, centred.
enum CropRatio: String, CaseIterable, Identifiable {
    case original = "Original", square = "1:1", fourFive = "4:5", threeFour = "3:4", story = "9:16", wide = "16:9"
    var id: String { rawValue }

    /// Width over height, nil for the photo's own shape.
    var value: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .fourFive: return 4.0 / 5
        case .threeFour: return 3.0 / 4
        case .story: return 9.0 / 16
        case .wide: return 16.0 / 9
        }
    }
}

/// The Adjust settings, the same for photos and videos: crop, turn and flip, then light and colour.
struct Adjustments: Equatable {
    var brightness: Float = 0   // -1...1
    var contrast: Float = 0     // -1...1
    var saturation: Float = 0   // -1...1
    var warmth: Float = 0       // -1...1, cooler or warmer
    var crop: CropRatio = .original
    var turns = 0               // quarter turns clockwise, 0...3
    var flipped = false         // mirrored left to right

    var colorOff: Bool { abs(brightness) <= 0.001 && abs(contrast) <= 0.001 && abs(saturation) <= 0.001 && abs(warmth) <= 0.001 }
    var shapeOff: Bool { crop == .original && turns % 4 == 0 && !flipped }
    var isOff: Bool { colorOff && shapeOff }

    /// The size an image of `size` comes out at after the turn and crop.
    func outputSize(for size: CGSize) -> CGSize {
        var s = turns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        if let r = crop.value {
            s = s.width / s.height > r ? CGSize(width: (s.height * r).rounded(), height: s.height) : CGSize(width: s.width, height: (s.width / r).rounded())
        }
        return s
    }

    /// `img` with the settings applied (`shape: false` leaves out the crop, turn and flip), its extent at the origin.
    func apply(_ img: CIImage, shape: Bool = true) -> CIImage {
        var out = img
        if !colorOff {
            let cc = CIFilter.colorControls()
            cc.inputImage = out
            cc.brightness = brightness * 0.2
            cc.contrast = 1 + contrast * 0.35
            cc.saturation = 1 + saturation
            out = cc.outputImage ?? out
            if abs(warmth) > 0.001 {
                let t = CIFilter.temperatureAndTint()
                t.inputImage = out
                t.neutral = CIVector(x: 6500, y: 0)
                t.targetNeutral = CIVector(x: 6500 - CGFloat(warmth) * 2500, y: 0)
                out = t.outputImage ?? out
            }
            out = out.cropped(to: img.extent)
        }
        if shape && !shapeOff {
            if flipped { out = out.oriented(.upMirrored) }
            let turn: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
            out = out.oriented(turn[((turns % 4) + 4) % 4])
            out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
            let size = outputSize(for: CGSize(width: img.extent.width, height: img.extent.height))
            let x = ((out.extent.width - size.width) / 2).rounded(), y = ((out.extent.height - size.height) / 2).rounded()
            out = out.cropped(to: CGRect(x: x, y: y, width: size.width, height: size.height))
                .transformed(by: CGAffineTransform(translationX: -x, y: -y))
        }
        return out
    }

    private static let context = CIContext(mtlDevice: GPU.shared.device)

    /// A CGImage with the settings applied, keeping any see-through parts.
    func apply(_ cg: CGImage, shape: Bool = true) -> CGImage {
        guard !(colorOff && (!shape || shapeOff)) else { return cg }
        let out = apply(CIImage(cgImage: cg), shape: shape)
        return Adjustments.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) ?? cg
    }
}

/// The Adjust controls: crop shape, turn and flip, and one slider at a time for light and colour.
struct AdjustPanel: View {
    @Binding var adjust: Adjustments
    @State private var slider = "Brightness"
    private static let sliders: [(String, WritableKeyPath<Adjustments, Float>)] = [
        ("Brightness", \.brightness), ("Contrast", \.contrast), ("Saturation", \.saturation), ("Warmth", \.warmth)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CropRatio.allCases) { r in
                        chip(r.rawValue, on: adjust.crop == r) { adjust.crop = r }
                    }
                    Divider().frame(height: 22)
                    Button { adjust.turns = (adjust.turns + 1) % 4 } label: { Image(systemName: "rotate.right") }
                        .accessibilityLabel("Turn")
                    Button { adjust.flipped.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .accessibilityLabel("Flip")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.sliders, id: \.0) { s in chip(s.0, on: slider == s.0) { slider = s.0 } }
                    Button("Reset all") { adjust = Adjustments() }.font(.subheadline)
                }
            }
            if let path = Self.sliders.first(where: { $0.0 == slider })?.1 {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(adjust[keyPath: path]) }, set: { adjust[keyPath: path] = Float($0) }), in: -1...1)
                    Text("\(Int((adjust[keyPath: path] * 100).rounded()))").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    Button { adjust[keyPath: path] = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.accentColor : Color.gray.opacity(0.25), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
    }
}
