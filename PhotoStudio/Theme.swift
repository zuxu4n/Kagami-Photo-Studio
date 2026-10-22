import SwiftUI
import UIKit

// MARK: Colour

/// Mioru's colour tokens. Brand screens (home, welcome, About) are warm and light, with dark versions; the editing
/// screens (photo editor, camera, video) are always a dark neutral, so nothing tints the way a photo's colours look.
extension Color {
    // Brand
    /// The rose accent for fills: buttons, the picked tool, slider fills. White text on it passes AA (5.1:1), in
    /// light and dark alike.
    static let mioru = Color(hex: 0xC43871)
    static let mioruPressed = Color(hex: 0xA92D5F)
    /// Rose for text and icons on brand screens (a lighter rose in dark mode, 5.4:1 on its background).
    static let mioruInk = Color(light: 0xC43871, dark: 0xEC74A3)
    /// Rose for text and icons on the dark editing screens (5.7:1 on their panels).
    static let mioruOnDark = Color(hex: 0xEC74A3)
    static let blush = Color(light: 0xF8DDE8, dark: 0x3A2430)
    static let powder = Color(light: 0xDDEFFA, dark: 0x1E2F3A)
    static let powderInk = Color(light: 0x2F6E93, dark: 0x9BCDEB)   // text and icons on powder
    static let blushInk = Color(light: 0xA92D5F, dark: 0xF2A2C1)    // text and icons on blush

    // Brand screens
    static let canvasWarm = Color(light: 0xFFFAFC, dark: 0x151215)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1F1B1F)
    static let ink = Color(light: 0x29232C, dark: 0xF6F1F4)
    static let inkSecondary = Color(light: 0x746D78, dark: 0xADA5B0)
    static let inkTertiary = Color(light: 0xA39CA7, dark: 0x7A7280)  // decorative or disabled only, not body text
    static let hairline = Color(light: 0xEFE4EA, dark: 0x2E282E)

    // Editing screens (always dark and neutral)
    static let studio = Color(hex: 0x0D0D0E)          // behind the photo
    static let studioPanel = Color(hex: 0x161617)     // the tool panel and tool bar
    static let studioRaised = Color(hex: 0x242426)    // controls on the panel
    static let studioText = Color(hex: 0xF4F2F3)
    static let studioSecondary = Color(hex: 0x9F9CA2) // 6.3:1 on the panel
    static let studioHairline = Color.white.opacity(0.08)
    static let scrim = Color.black.opacity(0.55)

    /// The face guides and the Position oval: cyan, so they read on any skin tone.
    static let faceGuide = Color(red: 0.2, green: 0.85, blue: 0.95)

    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
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
    /// The wordmark and large editorial titles: New York, Apple's serif.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .serif) }
    static let toolLabel = Font.system(size: 11, weight: .medium)
    static let panelTitle = Font.system(size: 15, weight: .semibold)
    static let panelValue = Font.system(size: 15, weight: .medium).monospacedDigit()
    static let hint = Font.system(size: 12)
    static let chip = Font.system(size: 13, weight: .medium)
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
    static let mioruQuick = Animation.snappy(duration: 0.22)
    static let mioruSoft = Animation.smooth(duration: 0.35)
}

// MARK: Buttons

/// Shrinks a little and dims while pressed: the feel every tappable thing in Mioru shares.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.mioruQuick, value: configuration.isPressed)
    }
}

/// The rose call to action (Get started, Save).
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(configuration.isPressed ? Color.mioruPressed : Color.mioru,
                        in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.mioruQuick, value: configuration.isPressed)
    }
}

/// A small rose button for the editing screens' top bars (Save, Done).
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(configuration.isPressed ? Color.mioruPressed : Color.mioru, in: Capsule())
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.mioruQuick, value: configuration.isPressed)
    }
}

/// A round icon button on the editing screens: plain on the panel, or on a dark disc over a photo or the camera.
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
                .foregroundStyle(Color.studioText)
                .frame(width: 40, height: 40)
                .background(onPhoto ? Color.black.opacity(0.35) : Color.clear, in: Circle())
                .opacity(enabled ? 1 : 0.3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

// MARK: Panel parts

/// Text tabs with a sliding highlight, for a tool's modes (Heal's Spot / People / Brush / Erase and the like).
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
                    withAnimation(.mioruQuick) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 13, weight: on ? .semibold : .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? Color.studioText : Color.studioSecondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.14))
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
        .background(Color.studioRaised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension ModeTabs where Value: RawRepresentable, Value.RawValue == String {
    init(items: [Value], selection: Binding<Value>) {
        self.init(items: items, selection: selection, title: { $0.rawValue })
    }
}

/// A small text chip (the Face subtabs, the camera's effects). The picked one is filled rose; `dot` marks a change.
struct Chip: View {
    let title: String
    let on: Bool
    var dot = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1).fixedSize()
                if dot { Circle().fill(on ? Color.white : Color.mioruOnDark).frame(width: 5, height: 5) }
            }
            .font(.chip)
            .foregroundStyle(on ? Color.white : Color.studioText.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(on ? Color.mioru : Color.studioRaised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityValue(dot ? "changed" : "")
    }
}

/// A small text button on the panel (Reset all, Clear, Add shadow).
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
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.studioText)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(prominent ? Color.mioru : Color.studioRaised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
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
                .foregroundStyle(Color.studioSecondary)
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
            .foregroundStyle(Color.studioSecondary)
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
            if let icon { Image(systemName: icon).foregroundStyle(Color.mioruOnDark) }
            Text(text).lineLimit(2).multilineTextAlignment(.leading)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.studioText)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.studioPanel.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.studioHairline))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
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
                withAnimation(.mioruSoft) { shown = message }
            }
            .task(id: id) {
                guard shown != nil else { return }
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.mioruSoft) { shown = nil }
            }
    }
}

/// Work under way on the photo: a spinner and what it's doing, over a light dimming.
struct BusyBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.studioText).controlSize(.small)
            Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.studioText)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Color.studioPanel.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(Color.studioHairline))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}
