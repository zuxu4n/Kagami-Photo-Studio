import SwiftUI
import UIKit

// MARK: Colour

/// Miyori's colour tokens: one light look, the same with the phone in light or dark mode (the app always asks for
/// light). Mostly white, with a sweet pink as the main colour and baby blue as the second. The light pink and blue
/// are for fills and marks; pink or blue text, and text on them, uses the darker inks so it stays readable. The photo
/// and video sit on a neutral grey, so nothing tints the way their colours look.
extension Color {
    // Pink, the main colour
    /// Fills and marks with no text on them: slider fills, the record button, the tab underline, the wordmark's dot.
    static let pink = Color(hex: 0xFF85B2)
    /// The same pink, dark enough to read: pink text and icons, and text on petal (4.6:1 on petal, 5.5:1 on white).
    static let pinkInk = Color(hex: 0xCB1A5C)
    /// Pale petal pink for soft backgrounds: buttons, the picked tool, the welcome art.
    static let petal = Color(hex: 0xFFE4EE)
    static let petalPressed = Color(hex: 0xFFD2E3)

    // Baby blue, the second colour
    /// The picked chip or mode, the Camera tile, the arch.
    static let babyBlue = Color(hex: 0xC4E6FF)
    /// A deeper sky blue where the blue needs more presence: outlines and marks on white.
    static let sky = Color(hex: 0x80C4F0)
    /// Blue text and icons, and text on baby blue (5.0:1 on baby blue, 6.5:1 on white).
    static let blueInk = Color(hex: 0x1F6198)

    // Neutrals
    static let surface = Color.white                  // backgrounds, panels, bars and cards
    static let fill = Color(hex: 0xF4F2F5)            // unpicked chips and small buttons on white
    static let track = Color(hex: 0xE6E2E8)           // slider tracks
    static let ink = Color(hex: 0x29232C)
    static let inkSecondary = Color(hex: 0x655E6B)    // 6.2:1 on white, 5.2:1 on petal, 4.8:1 on baby blue
    static let inkTertiary = Color(hex: 0xA39CA7)     // decorative or disabled only, not body text
    static let hairline = Color(hex: 0xEEE8EC)
    /// The soft grey behind the photo and the video.
    static let backdrop = Color(hex: 0xEEEEF0)
    /// For soft shadows under white things that float (with an opacity).
    static let shade = Color(hex: 0x29232C)

    /// The face guides and the Position oval: cyan, so they read on any skin tone.
    static let faceGuide = Color(red: 0.2, green: 0.85, blue: 0.95)

    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Type, spacing, shape, motion

extension Font {
    /// The wordmark: New York, Apple's serif, at a fixed size.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .serif) }
    /// Editorial titles in New York that follow the reader's text size.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font { .system(style, design: .serif, weight: weight) }

    /// The system font in the text style nearest `size` (its size at the default text size), so it follows the
    /// reader's text size.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let style: Font.TextStyle
        switch size {
        case ..<11.5: style = .caption2
        case ..<12.5: style = .caption
        case ..<13.5: style = .footnote
        case ..<15.5: style = .subheadline
        case ..<16.5: style = .callout
        case ..<18: style = .body
        case ..<21: style = .title3
        case ..<25: style = .title2
        case ..<31: style = .title
        default: style = .largeTitle
        }
        return .system(style, weight: weight)
    }
    static let panelTitle = Font.ui(15, .semibold)
    static let panelValue = Font.ui(15, .medium).monospacedDigit()
    static let hint = Font.ui(12)
    static let chip = Font.ui(13, .medium)
}

enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
}

enum Radius {
    static let control: CGFloat = 10   // chips, small buttons, segmented controls
    static let card: CGFloat = 20      // home cards
    static let button: CGFloat = 16    // large buttons
}

extension Animation {
    static let quick = Animation.snappy(duration: 0.22)
    static let gentle = Animation.smooth(duration: 0.35)
}

extension View {
    /// A soft shadow under something white that floats over the photo, the camera or the page. The view is composited
    /// first, so the text and icons on it don't cast shadows of their own.
    func floating(_ opacity: Double = 0.18, radius: CGFloat = 6, y: CGFloat = 2) -> some View {
        compositingGroup().shadow(color: Color.shade.opacity(opacity), radius: radius, y: y)
    }
}

// MARK: Buttons

/// Shrinks a little and dims while pressed: the feel every tappable thing in Miyori shares.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.quick, value: configuration.isPressed)
    }
}

/// The call to action (Get started, Enhance photo): dark pink text on petal, which reads where white text on the light
/// pink would be too faint.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(16, .semibold))
            .foregroundStyle(Color.pinkInk)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(configuration.isPressed ? Color.petalPressed : Color.petal,
                        in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.quick, value: configuration.isPressed)
    }
}

/// A small petal button for the editing screens' top bars (Save, Done).
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(15, .semibold))
            .foregroundStyle(Color.pinkInk)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(configuration.isPressed ? Color.petalPressed : Color.petal, in: Capsule())
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.quick, value: configuration.isPressed)
    }
}

/// A round icon button on the editing screens: plain on a bar, or on a white disc over a photo or the camera.
struct StudioIconButton: View {
    let icon: String
    let label: String
    var onPhoto = false
    var action: () -> Void

    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.ink)
                .frame(width: 40, height: 40)
                .background(onPhoto ? Color.surface.opacity(0.92) : Color.clear, in: Circle())
                .floating(onPhoto ? 0.18 : 0)
                .opacity(enabled ? 1 : 0.3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

// MARK: Panel parts

/// Text tabs with a sliding baby-blue highlight, for a tool's modes (Heal's Spot / People / Brush / Erase and the like).
struct ModeTabs<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    var title: (Value) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button {
                    withAnimation(.quick) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.ui(13, on ? .semibold : .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? Color.blueInk : Color.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.babyBlue)
                                    .matchedGeometryEffect(id: "tab", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension ModeTabs where Value: RawRepresentable, Value.RawValue == String {
    init(items: [Value], selection: Binding<Value>) {
        self.init(items: items, selection: selection, title: { $0.rawValue })
    }
}

/// A small text chip (the Face subtabs, the camera's effects). The picked one is baby blue; `dot` marks a change.
struct Chip: View {
    let title: String
    let on: Bool
    var dot = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1).fixedSize()
                if dot { Circle().fill(on ? Color.blueInk : Color.pinkInk).frame(width: 5, height: 5) }
            }
            .font(.chip)
            .foregroundStyle(on ? Color.blueInk : Color.ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(on ? Color.babyBlue : Color.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityValue(dot ? "changed" : "")
    }
}

/// A small text button on the panel (Reset all, Clear, Add shadow); the prominent one (Remove) is petal.
struct PanelTextButton: View {
    let title: String
    var icon: String?
    var prominent = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title)
            }
            .font(.ui(13, .semibold))
            .foregroundStyle(prominent ? Color.pinkInk : Color.ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(prominent ? Color.petal : Color.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PressableStyle())
    }
}

/// The reset arrow beside a value.
struct ResetButton: View {
    let label: String
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.inkSecondary)
                .opacity(enabled ? 1 : 0.35)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .accessibilityLabel(label)
    }
}

/// One line of help under a tool's controls.
struct HintText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.hint)
            .foregroundStyle(Color.inkSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
    }
}

// MARK: Feedback

/// A short message over the content that fades away (Saved to Photos, hints after an action).
struct Toast: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(Color.pinkInk) }
            Text(text).lineLimit(2).multilineTextAlignment(.leading)
        }
        .font(.ui(14, .medium))
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.hairline))
        .floating(0.14, radius: 14, y: 4)
        .padding(.horizontal, 24)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// Shows `message` as a toast for a few seconds whenever `id` changes (the same message can show again).
    func toast(_ message: String?, id: Int, icon: @escaping (String) -> String? = { _ in nil }) -> some View {
        modifier(ToastModifier(message: message, id: id, icon: icon))
    }
}

private struct ToastModifier: ViewModifier {
    let message: String?
    let id: Int
    let icon: (String) -> String?
    @State private var shown: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown {
                    Toast(text: shown, icon: icon(shown)).padding(.top, 12).allowsHitTesting(false)
                }
            }
            .onChange(of: id) { _, _ in
                guard let message, !message.isEmpty else { return }
                withAnimation(.gentle) { shown = message }
            }
            .task(id: id) {
                guard shown != nil else { return }
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.gentle) { shown = nil }
            }
    }
}

/// Shows `content` only for work that takes longer than a moment, so quick steps (an undo, a small heal) don't
/// flash a spinner. A change of text while it shows updates it in place.
struct DelayedPresence<Content: View>: View {
    let value: String?
    var delay: Duration = .milliseconds(300)
    @ViewBuilder var content: (String) -> Content
    @State private var shown: String?

    var body: some View {
        ZStack {
            if let shown { content(shown) }
        }
        .animation(.quick, value: shown)
        .task(id: value) {
            guard let value else { shown = nil; return }
            if shown != nil { shown = value; return }
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { shown = value }
        }
    }
}

/// Work under way on the photo: a spinner and what it's doing.
struct BusyBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.pinkInk).controlSize(.small)
            Text(text).font(.ui(14, .medium)).foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Color.surface, in: Capsule())
        .overlay(Capsule().stroke(Color.hairline))
        .floating(0.14, radius: 14, y: 4)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}
