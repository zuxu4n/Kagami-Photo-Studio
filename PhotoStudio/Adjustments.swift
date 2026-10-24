import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import SwiftUI

/// The shape a photo or video is cropped to.
enum CropRatio: String, CaseIterable, Identifiable {
    case original = "Original", free = "Free", square = "1:1", fourFive = "4:5", threeFour = "3:4", twoThree = "2:3", story = "9:16", fourThree = "4:3", threeTwo = "3:2", wide = "16:9"
    var id: String { rawValue }

    /// Width over height, nil for the photo's own shape.
    var value: CGFloat? {
        switch self {
        case .original, .free: return nil
        case .square: return 1
        case .fourFive: return 4.0 / 5
        case .threeFour: return 3.0 / 4
        case .twoThree: return 2.0 / 3
        case .story: return 9.0 / 16
        case .fourThree: return 4.0 / 3
        case .threeTwo: return 3.0 / 2
        case .wide: return 16.0 / 9
        }
    }
}

/// The Adjust settings, the same for photos and videos: crop, turn, flip and straighten, then light and colour.
struct Adjustments: Equatable {
    var brightness: Float = 0   // -1...1
    var contrast: Float = 0     // -1...1
    var saturation: Float = 0   // -1...1
    var warmth: Float = 0       // -1...1, cooler or warmer
    var crop: CropRatio = .original
    var cropRect: CGRect?       // the crop as a fraction of the turned and straightened picture (top-left origin);
                                // nil = as large as the shape allows, centred (Free: the whole picture)
    var turns = 0               // quarter turns clockwise, 0...3
    var flipped = false         // mirrored left to right (before the turn)
    var flippedV = false        // upside down (before the turn)
    var straighten: Float = 0   // -1...1 = 15 degrees anticlockwise...clockwise, zoomed in so no corner shows

    static let maxStraighten: Double = 15   // degrees

    var colorOff: Bool { abs(brightness) <= 0.001 && abs(contrast) <= 0.001 && abs(saturation) <= 0.001 && abs(warmth) <= 0.001 }
    var geometryOff: Bool { turns % 4 == 0 && !flipped && !flippedV && abs(straighten) <= 0.001 }
    var shapeOff: Bool { crop == .original && geometryOff }
    var isOff: Bool { colorOff && shapeOff }

    /// The size an image of `size` comes out at after the turn and crop (straightening keeps the size).
    func outputSize(for size: CGSize) -> CGSize {
        let s = turns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        guard crop != .original else { return s }
        let f = cropFrame(for: s)
        return CGSize(width: max(1, (s.width * f.width).rounded()), height: max(1, (s.height * f.height).rounded()))
    }

    /// The largest box of the picked shape in a picture of `size`, centred, as a fraction of it.
    static func fullFrame(_ crop: CropRatio, for size: CGSize) -> CGRect {
        guard let r = crop.value, size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let w = min(1, r * size.height / size.width), h = min(1, size.width / r / size.height)
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// The crop as a fraction of the turned and straightened picture of `size`, top-left origin.
    func cropFrame(for size: CGSize) -> CGRect {
        cropRect ?? Adjustments.fullFrame(crop, for: size)
    }

    /// The crop frame `r0` after one of its handles moved by `d` (fractions of the picture). A shape's frame keeps its
    /// shape when a corner moves (`keepShape`); Free's corners and edges move on their own. It stays on the picture.
    static func dragged(_ r0: CGRect, _ handle: CropHandle, by d: CGVector, keepShape: Bool) -> CGRect {
        let minSide: CGFloat = 0.06
        switch handle {
        case .move:
            return CGRect(x: min(1 - r0.width, max(0, r0.minX + d.dx)), y: min(1 - r0.height, max(0, r0.minY + d.dy)),
                          width: r0.width, height: r0.height)
        case .side(let sx, let sy) where keepShape && sx != 0 && sy != 0:
            // The opposite corner stays put; the frame grows or shrinks by whichever way the finger went further.
            let ax = sx > 0 ? r0.minX : r0.maxX, ay = sy > 0 ? r0.minY : r0.maxY
            var k = max((r0.width + sx * d.dx) / r0.width, (r0.height + sy * d.dy) / r0.height)
            k = min(k, (sx > 0 ? 1 - ax : ax) / r0.width, (sy > 0 ? 1 - ay : ay) / r0.height)
            k = max(k, minSide / min(r0.width, r0.height))
            let w = r0.width * k, h = r0.height * k
            return CGRect(x: sx > 0 ? ax : ax - w, y: sy > 0 ? ay : ay - h, width: w, height: h)
        case .side(let sx, let sy):
            var l = r0.minX, r = r0.maxX, t = r0.minY, b = r0.maxY
            if sx < 0 { l = min(r - minSide, max(0, l + d.dx)) }
            if sx > 0 { r = max(l + minSide, min(1, r + d.dx)) }
            if sy < 0 { t = min(b - minSide, max(0, t + d.dy)) }
            if sy > 0 { b = max(t + minSide, min(1, b + d.dy)) }
            return CGRect(x: l, y: t, width: r - l, height: b - t)
        }
    }

    /// Which part of the crop frame `f` a finger at `p` takes hold of, with `reach` the grab distance (fractions of
    /// the picture across and down). Edges count only for Free. Nil when the finger is outside the frame.
    static func cropHandle(at p: CGPoint, frame f: CGRect, reach: CGSize, edges: Bool) -> CropHandle? {
        let dl = abs(p.x - f.minX), dr = abs(p.x - f.maxX), dt = abs(p.y - f.minY), db = abs(p.y - f.maxY)
        let nearX: CGFloat = min(dl, dr) < reach.width ? (dl < dr ? -1 : 1) : 0
        let nearY: CGFloat = min(dt, db) < reach.height ? (dt < db ? -1 : 1) : 0
        let withinX = p.x > f.minX - reach.width && p.x < f.maxX + reach.width
        let withinY = p.y > f.minY - reach.height && p.y < f.maxY + reach.height
        guard withinX && withinY else { return nil }
        if nearX != 0 && nearY != 0 { return .side(nearX, nearY) }
        if edges && (nearX != 0 || nearY != 0) { return .side(nearX, nearY) }
        return f.contains(p) ? .move : nil
    }

    /// `img` with the settings applied, its extent at the origin. `shape: false` leaves out the crop, turn, flip and
    /// straighten; `crop: false` leaves out only the crop (the Crop tool draws its frame over the whole picture).
    func apply(_ img: CIImage, shape: Bool = true, crop: Bool = true) -> CIImage {
        var out = img
        if !colorOff {
            if abs(brightness) > 0.001 {
                // Lifts or lowers the middle tones along a curve, so black stays black and white stays white
                // (adding the same amount everywhere made the photo look washed out).
                let b = CGFloat(brightness)
                let tc = CIFilter.toneCurve()
                tc.inputImage = out
                tc.point0 = CGPoint(x: 0, y: 0)
                tc.point1 = CGPoint(x: 0.25, y: 0.25 + 0.13 * b)
                tc.point2 = CGPoint(x: 0.5, y: 0.5 + 0.17 * b)
                tc.point3 = CGPoint(x: 0.75, y: 0.75 + 0.12 * b)
                tc.point4 = CGPoint(x: 1, y: 1)
                out = tc.outputImage ?? out
            }
            if abs(contrast) > 0.001 || abs(saturation) > 0.001 {
                let cc = CIFilter.colorControls()
                cc.inputImage = out
                cc.contrast = 1 + contrast * 0.35
                cc.saturation = 1 + saturation
                out = cc.outputImage ?? out
            }
            if abs(warmth) > 0.001 {
                let t = CIFilter.temperatureAndTint()
                t.inputImage = out
                t.neutral = CIVector(x: 6500, y: 0)
                t.targetNeutral = CIVector(x: 6500 - CGFloat(warmth) * 2000, y: 0)
                out = t.outputImage ?? out
            }
            out = out.cropped(to: img.extent)
        }
        guard shape else { return out }
        if !geometryOff {
            if flipped { out = out.oriented(.upMirrored) }
            if flippedV { out = out.oriented(.downMirrored) }
            let turn: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
            out = out.oriented(turn[((turns % 4) + 4) % 4])
            out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
            if abs(straighten) > 0.001 {
                // Turned about the middle, then zoomed in just enough that the largest same-shaped box fills the picture.
                let a = Double(straighten) * Adjustments.maxStraighten * .pi / 180
                let w = out.extent.width, h = out.extent.height, c = abs(cos(a)), s = abs(sin(a))
                let k = min(w / (w * c + h * s), h / (w * s + h * c))
                let t = CGAffineTransform(translationX: w / 2, y: h / 2).rotated(by: -a).scaledBy(x: 1 / k, y: 1 / k).translatedBy(x: -w / 2, y: -h / 2)
                let ext = out.extent
                out = out.clampedToExtent().transformed(by: t).cropped(to: ext)
            }
        }
        if crop, self.crop != .original {
            let ext = out.extent
            let f = cropFrame(for: ext.size)
            let w = (f.width * ext.width).rounded(), h = (f.height * ext.height).rounded()
            let x = (f.minX * ext.width).rounded(), y = (ext.height - f.minY * ext.height - h).rounded()   // Core Image counts up from the bottom
            out = out.cropped(to: CGRect(x: x, y: y, width: w, height: h)).transformed(by: CGAffineTransform(translationX: -x, y: -y))
        }
        return out
    }

    private static let context = CIContext(mtlDevice: GPU.shared.device)

    /// A CGImage with the settings applied, keeping any see-through parts.
    func apply(_ cg: CGImage, shape: Bool = true, crop: Bool = true) -> CGImage {
        guard !(colorOff && (!shape || shapeOff)) else { return cg }
        let out = apply(CIImage(cgImage: cg), shape: shape, crop: crop)
        return Adjustments.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) ?? cg
    }
}

/// What a finger holds of the crop frame: the whole frame, or a corner or edge (-1 left or top, 1 right or bottom, 0 neither).
enum CropHandle: Equatable {
    case move
    case side(CGFloat, CGFloat)
}

/// The tools inside Adjust, in the order of the tool row.
enum AdjustTool: String, CaseIterable, Identifiable {
    case crop = "Crop", rotate = "Rotate", brightness = "Brightness", contrast = "Contrast", saturation = "Saturation", warmth = "Warmth"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .crop: return "crop"
        case .rotate: return "crop.rotate"
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .saturation: return "drop.halffull"
        case .warmth: return "thermometer.medium"
        }
    }

    /// The light or colour value this tool's slider moves.
    var value: WritableKeyPath<Adjustments, Float>? {
        switch self {
        case .brightness: return \.brightness
        case .contrast: return \.contrast
        case .saturation: return \.saturation
        case .warmth: return \.warmth
        case .crop, .rotate: return nil
        }
    }

    func isChanged(_ a: Adjustments) -> Bool {
        switch self {
        case .crop: return a.crop != .original
        case .rotate: return !a.geometryOff
        default: return abs(a[keyPath: value!]) > 0.001
        }
    }

    /// The same settings with this tool's part put back.
    func reset(_ a: Adjustments) -> Adjustments {
        var a = a
        switch self {
        case .crop: a.crop = .original; a.cropRect = nil
        case .rotate: a.turns = 0; a.flipped = false; a.flippedV = false; a.straighten = 0
        default: a[keyPath: value!] = 0
        }
        return a
    }
}

/// The Adjust controls: a row of tools with icons, and above it the picked tool's controls.
/// `editing` brackets every change (true before, false after) so the photo editor can make each one an undo step.
struct AdjustPanel<Accessory: View>: View {
    @Binding var adjust: Adjustments
    @Binding var tool: AdjustTool
    var editing: (Bool) -> Void = { _ in }
    var freeCrop = true   // whether Free is offered (it needs the frame's handles, which only the photo editor has)
    var photoCropStyle = false   // approved Shape rail, local to the photo editor
    var photoRotateStyle = false // approved Action row, local to the photo editor
    @ViewBuilder var accessory: () -> Accessory
    @State private var cropEntry: (crop: CropRatio, rect: CGRect?)?   // the crop when Crop was opened, for Cancel
    @State private var lastTool: AdjustTool = .brightness              // where Done and Cancel go back to
    @State private var confirmed = 0                                    // bumps on Done, for its tap you can feel

    var body: some View {
        VStack(spacing: 6) {
            if photoRotateStyle && tool == .rotate {
                ViewThatFits(in: .horizontal) {
                    photoRotateRows(compact: false)
                    photoRotateRows(compact: true)
                }
            } else {
                if photoCropStyle && tool == .crop { photoCropHeader } else { header }
                Group {
                    switch tool {
                    case .crop:
                        if photoCropStyle { photoCropControls } else { cropControls }
                    case .rotate: rotateControls
                    default:
                        ValueSlider(value: valueBinding(tool.value!), editing: editing)
                            .accessibilityLabel(tool.rawValue)
                    }
                }
                .frame(height: 58)
            }
            toolRow
        }
        .onAppear { if tool == .crop { cropEntry = (adjust.crop, adjust.cropRect) } }
        .onChange(of: tool) { old, new in
            if new == .crop { cropEntry = (adjust.crop, adjust.cropRect) }
            if old != .crop { lastTool = old }
        }
        .sensoryFeedback(.success, trigger: confirmed)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Text(tool.rawValue).font(.headline)
            ResetButton(label: "Reset \(tool.rawValue)") { change { $0 = tool.reset($0) } }
                .disabled(!tool.isChanged(adjust))
            Spacer()
            if tool == .crop {
                // Cancel puts the crop back as it was when Crop opened; Done keeps it. Both show the cropped photo.
                Button("Cancel") { cancelCrop() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Cancel crop")
                Button("Done") { confirmCrop() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Done cropping")
            } else {
                PanelTextButton(title: "Reset all") { change { $0 = Adjustments() } }
                    .disabled(adjust.isOff)
                accessory()
            }
        }
        .frame(height: 36)
    }

    /// Photo-editor-only Crop actions. Reset availability and all action callbacks stay the same.
    private var photoCropHeader: some View {
        HStack(spacing: 8) {
            Text("Crop").font(.body.weight(.medium))
            Button {
                change { $0 = tool.reset($0) }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(PhotoCropActionStyle(icon: true))
            .disabled(!tool.isChanged(adjust))
            .accessibilityLabel("Reset Crop")
            .accessibilityHint("Returns crop to Original")
            Spacer(minLength: 0)
            Button("Cancel") { cancelCrop() }
                .buttonStyle(PhotoCropActionStyle())
                .accessibilityLabel("Cancel crop")
            Button("Done") { confirmCrop() }
                .buttonStyle(PhotoCropActionStyle(primary: true))
                .accessibilityLabel("Done cropping")
        }
        .frame(height: 44)
    }

    private struct PhotoCropActionStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        var primary = false
        var icon = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(icon ? .system(size: 20) : .subheadline.weight(primary ? .semibold : .regular))
                .foregroundStyle(!isEnabled ? Color(.tertiaryLabel) : primary ? Color.white : Color.accentColor)
                .padding(.horizontal, icon ? 0 : 10)
                .frame(minWidth: icon ? 44 : 60, minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(primary ? Color.accentColor.opacity(isEnabled ? 1 : 0.35) : Color(.secondarySystemBackground))
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }

    private func confirmCrop() {
        confirmed += 1
        withAnimation { tool = lastTool }
    }

    private func cancelCrop() {
        if let e = cropEntry { change { $0.crop = e.crop; $0.cropRect = e.rect } }
        withAnimation { tool = lastTool }
    }

    /// The tools inside Adjust; the picked one is in the accent colour, and a dot marks a changed one.
    private var toolRow: some View {
        HStack(spacing: 0) {
            ForEach(AdjustTool.allCases) { t in
                let on = t == tool
                Button {
                    withAnimation { tool = t }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon)
                            .frame(width: 40, height: 28)
                            .overlay(alignment: .topTrailing) {
                                if t.isChanged(adjust) && !on {
                                    Circle().fill(.secondary).frame(width: 6, height: 6)
                                }
                            }
                        Text(t.rawValue).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.rawValue + (t.isChanged(adjust) ? ", changed" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: tool)
    }

    private var cropControls: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(CropRatio.allCases.filter { freeCrop || $0 != .free }) { r in
                        let on = adjust.crop == r
                        Button {
                            change { $0.crop = r; $0.cropRect = nil }
                        } label: {
                            VStack(spacing: 5) {
                                Group {
                                    if r == .free { Image(systemName: "crop") } else { RatioIcon(ratio: r.value) }
                                }
                                .frame(width: 26, height: 26)
                                Text(r.rawValue).font(.caption2).lineLimit(1).fixedSize()
                            }
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                            .frame(minWidth: 50).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(r)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .onAppear { proxy.scrollTo(adjust.crop, anchor: .center) }
        }
        .sensoryFeedback(.selection, trigger: adjust.crop)
    }

    /// The approved Shape rail keeps the original order, ratios, and one-step crop changes.
    private var photoCropControls: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(CropRatio.allCases.filter { freeCrop || $0 != .free }) { r in
                        let on = adjust.crop == r
                        Button {
                            change { $0.crop = r; $0.cropRect = nil }
                        } label: {
                            VStack(spacing: 5) {
                                Group {
                                    if r == .free { Image(systemName: "crop") } else { RatioIcon(ratio: r.value) }
                                }
                                .frame(width: 26, height: 26)
                                Text(r.rawValue)
                                    .font(.caption2.weight(on ? .semibold : .regular))
                                    .lineLimit(1).fixedSize()
                            }
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                            .frame(minWidth: 58)
                            .frame(height: 58)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.accentColor.opacity(on ? 0.12 : 0))
                            }
                            .overlay(alignment: .bottom) {
                                if on {
                                    Capsule().fill(Color.accentColor)
                                        .frame(width: 14, height: 2).padding(.bottom, 3)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PhotoCropRatioStyle())
                        .id(r)
                        .accessibilityLabel(r == .original ? "Original, no crop" : r == .free ? "Free, unrestricted crop" : "\(r.rawValue) aspect ratio")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .onAppear { proxy.scrollTo(adjust.crop, anchor: .center) }
        }
        .sensoryFeedback(.selection, trigger: adjust.crop)
    }

    private struct PhotoCropRatioStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
        }
    }

    /// Photo-editor-only Action row. The compact layout keeps every target at least 44 points.
    private func photoRotateRows(compact: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                photoTransformButton("rotate.left", "Left", "Turn left 90 degrees") {
                    change { $0.turns = ($0.turns + 3) % 4; $0.cropRect = nil }
                }
                photoTransformButton("rotate.right", "Right", "Turn right 90 degrees") {
                    change { $0.turns = ($0.turns + 1) % 4; $0.cropRect = nil }
                }
                photoTransformButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Across", "Flip across",
                                     selected: adjust.turns % 2 == 1 ? adjust.flippedV : adjust.flipped) {
                    change { if $0.turns % 2 == 1 { $0.flippedV.toggle() } else { $0.flipped.toggle() } }
                }
                photoTransformButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Up/down", "Flip upside down",
                                     selected: adjust.turns % 2 == 1 ? adjust.flipped : adjust.flippedV) {
                    change { if $0.turns % 2 == 1 { $0.flipped.toggle() } else { $0.flippedV.toggle() } }
                }
                Spacer(minLength: 0)
                Button {
                    change { $0 = AdjustTool.rotate.reset($0) }
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 20))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PhotoRotateButtonStyle(accent: true))
                .disabled(!AdjustTool.rotate.isChanged(adjust))
                .accessibilityLabel("Reset Rotate and Straighten")
                .accessibilityHint("Clears turns, flips and the straighten angle")
                if !compact { photoResetAll(compact: false) }
            }
            .frame(height: 44)
            HStack(spacing: 8) {
                if compact {
                    VStack(spacing: -4) {
                        HStack(spacing: 4) {
                            Text("Straighten").font(.footnote.weight(.medium)).fixedSize()
                            Spacer(minLength: 0)
                            Text(Self.degrees(adjust.straighten))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(straightenAtZero ? Color.secondary : Color.accentColor)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 18)
                        photoStraightenSlider
                    }
                    photoResetAll(compact: true)
                } else {
                    Text("Straighten").font(.subheadline.weight(.medium)).fixedSize()
                    photoStraightenSlider
                    Text(Self.degrees(adjust.straighten))
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(straightenAtZero ? Color.secondary : Color.accentColor)
                        .frame(width: 60, height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(straightenAtZero ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.12))
                        }
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 58)
        }
    }

    private var straightenAtZero: Bool { abs(Double(adjust.straighten) * Adjustments.maxStraighten) < 0.05 }

    private var photoStraightenSlider: some View {
        ValueSlider(value: valueBinding(\.straighten), label: Self.degrees, editing: editing, showsValue: false)
            .accessibilityLabel("Straighten")
    }

    private func photoResetAll(compact: Bool) -> some View {
        Button {
            change { $0 = Adjustments() }
        } label: {
            Text("Reset\nall").font(.footnote).multilineTextAlignment(.center)
                .frame(width: compact ? 46 : 64, height: 44)
        }
        .buttonStyle(PhotoRotateButtonStyle(accent: true))
        .disabled(adjust.isOff)
        .accessibilityLabel("Reset all Adjust settings")
    }

    private func photoTransformButton(_ icon: String, _ title: String, _ label: String, selected: Bool? = nil,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 20)).frame(height: 20)
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .bottom) {
                if selected == true {
                    Capsule().fill(Color.accentColor).frame(width: 12, height: 2).padding(.bottom, 2)
                }
            }
        }
        .buttonStyle(PhotoRotateButtonStyle(selected: selected == true))
        .accessibilityLabel(label)
        .accessibilityValue(selected.map { $0 ? "On" : "Off" } ?? "")
    }

    private struct PhotoRotateButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        var accent = false
        var selected = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(!isEnabled ? Color(.tertiaryLabel) : accent || selected ? Color.accentColor : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground))
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }

    private var rotateControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                squareButton("rotate.left", "Turn left") { change { $0.turns = ($0.turns + 3) % 4; $0.cropRect = nil } }
                squareButton("rotate.right", "Turn right") { change { $0.turns = ($0.turns + 1) % 4; $0.cropRect = nil } }
                // Flips are made before the turn, so after a quarter turn the other one looks right on screen.
                squareButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip across") {
                    change { if $0.turns % 2 == 1 { $0.flippedV.toggle() } else { $0.flipped.toggle() } }
                }
                squareButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip upside down") {
                    change { if $0.turns % 2 == 1 { $0.flipped.toggle() } else { $0.flippedV.toggle() } }
                }
            }
            ValueSlider(value: valueBinding(\.straighten), label: Self.degrees, editing: editing)
                .accessibilityLabel("Straighten")
        }
    }

    private func squareButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    // MARK: Changes

    /// One change, made as a single step (an undo step in the photo editor).
    private func change(_ body: (inout Adjustments) -> Void) {
        var a = adjust
        body(&a)
        guard a != adjust else { return }
        editing(true)
        adjust = a
        editing(false)
    }

    private func valueBinding(_ path: WritableKeyPath<Adjustments, Float>) -> Binding<Float> {
        Binding(get: { adjust[keyPath: path] }, set: { adjust[keyPath: path] = $0 })
    }

    static func degrees(_ v: Float) -> String {
        let d = Double(v) * Adjustments.maxStraighten
        return abs(d) < 0.05 ? "0°" : String(format: "%@%.1f°", d > 0 ? "+" : "−", abs(d))
    }
}

extension AdjustPanel where Accessory == EmptyView {
    init(adjust: Binding<Adjustments>, tool: Binding<AdjustTool>, editing: @escaping (Bool) -> Void = { _ in }, freeCrop: Bool = true, photoCropStyle: Bool = false, photoRotateStyle: Bool = false) {
        self.init(adjust: adjust, tool: tool, editing: editing, freeCrop: freeCrop, photoCropStyle: photoCropStyle, photoRotateStyle: photoRotateStyle, accessory: { EmptyView() })
    }
}

/// A crop shape's outline, fitted in its frame (the photo's own shape is a dashed box).
private struct RatioIcon: View {
    let ratio: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.9
            let r = ratio ?? 1
            let w = r >= 1 ? side : side * r, h = r >= 1 ? side / r : side
            RoundedRectangle(cornerRadius: 2.5)
                .stroke(style: StrokeStyle(lineWidth: 1.6, dash: ratio == nil ? [3, 2] : []))
                .frame(width: w, height: h)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The slider every tool uses: the system slider with its value beside it. Two-way sliders (a range either side of
/// 0) catch at 0 with a tap you can feel. `editing` brackets each drag.
struct ValueSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = -1...1
    var reset: Float?
    var label: ((Float) -> String)?
    var editing: (Bool) -> Void = { _ in }
    var showsValue = true

    /// −100 to +100 for two-way sliders.
    static func label(_ v: Float) -> String {
        let n = Int((v * 100).rounded())
        return n > 0 ? "+\(n)" : n < 0 ? "−\(-n)" : "0"
    }

    private var twoWay: Bool { range.lowerBound < 0 && range.upperBound > 0 }
    private var span: Float { max(0.0001, range.upperBound - range.lowerBound) }

    private func text(_ v: Float) -> String {
        if let label { return label(v) }
        if twoWay { return Self.label(v / max(abs(range.lowerBound), range.upperBound)) }
        return "\(Int(((v - range.lowerBound) / span * 100).rounded()))"
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Slider(value: Binding(get: { value }, set: { v in
                let snapped = twoWay && abs(v) < 0.03 * span / 2 ? 0 : v   // catches at the middle
                if snapped != value { value = snapped }
            }), in: range, onEditingChanged: editing)
            if showsValue {
                Text(text(value))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 44)
        .sensoryFeedback(trigger: twoWay && value == 0) { _, atZero in atZero ? .impact(weight: .light) : nil }
    }
}

/// The Crop tool's frame on the picture: everything outside it dimmed, a thirds grid, and corner marks.
/// `frame` is the crop as a fraction of the picture (top-left origin); the view fills the picture's fitted box.
struct CropFrameOverlay: View {
    let frame: CGRect
    var active = false   // a finger is moving it: the grid shows more
    var edges = false    // Free: marks in the middle of each side, which can be dragged too

    var body: some View {
        GeometryReader { geo in
            let r = CGRect(x: frame.minX * geo.size.width, y: frame.minY * geo.size.height,
                           width: frame.width * geo.size.width, height: frame.height * geo.size.height)
            ZStack {
                Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(r) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { p in
                    for i in 1...2 {
                        let fx = r.minX + r.width * CGFloat(i) / 3, fy = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: fx, y: r.minY)); p.addLine(to: CGPoint(x: fx, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: fy)); p.addLine(to: CGPoint(x: r.maxX, y: fy))
                    }
                }
                .stroke(Color.white.opacity(active ? 0.6 : 0.3), lineWidth: 0.75)
                Path { p in p.addRect(r) }.stroke(Color.white, lineWidth: 1.25)
                Path { p in
                    let r = r.insetBy(dx: 1.5, dy: 1.5)   // inside the picture, so the marks aren't cut off at the canvas edge
                    let l = min(18, r.width / 4, r.height / 4)
                    for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                        (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                        p.move(to: CGPoint(x: c.x + l * dx, y: c.y)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x, y: c.y + l * dy))
                    }
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))
                if edges {
                    Path { p in
                        let r = r.insetBy(dx: 1.5, dy: 1.5)
                        let l = min(11, r.width / 8, r.height / 8)
                        p.move(to: CGPoint(x: r.midX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.midX + l, y: r.minY))
                        p.move(to: CGPoint(x: r.midX - l, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX + l, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: r.midY - l)); p.addLine(to: CGPoint(x: r.minX, y: r.midY + l))
                        p.move(to: CGPoint(x: r.maxX, y: r.midY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY + l))
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
            }
            .animation(.easeOut(duration: 0.15), value: active)
        }
    }
}

/// A thirds-plus grid over the whole picture while Straighten moves, to line things up against.
struct StraightenGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1..<6 {
                    let x = geo.size.width * CGFloat(i) / 6, y = geo.size.height * CGFloat(i) / 6
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
            .shadow(color: .black.opacity(0.4), radius: 0.5)
        }
    }
}
