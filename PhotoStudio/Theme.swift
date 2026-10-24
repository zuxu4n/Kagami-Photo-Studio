import SwiftUI

// Plain building blocks on top of the system's own controls, colours and fonts. No look of its own: this is a
// starting point to design from.

extension Color {
    /// The face guides and the Position oval: cyan, so they read on any skin tone.
    static let faceGuide = Color(red: 0.2, green: 0.85, blue: 0.95)

    /// A slider field's value while it's at its default: darker than `.secondary`, which is about 3.4:1 on white, so
    /// the number keeps 4.5:1 on the field's grey (darker still with Increase Contrast).
    static let sliderMuted = Color(UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: high ? 0.75 : 0.60, alpha: 1)
            : UIColor(white: high ? 0.30 : 0.42, alpha: 1)
    })
}

enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
}

// MARK: Buttons

/// An icon button with a 44 point target. `onPhoto` puts it on a small round backing so it reads over a picture.
struct StudioIconButton: View {
    let icon: String
    let label: String
    var onPhoto = false
    var action: () -> Void

    var body: some View {
        if onPhoto {
            Button(action: action) { Image(systemName: icon).frame(width: 28, height: 28) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel(label)
        } else {
            Button(action: action) { Image(systemName: icon).frame(width: 44, height: 44) }
                .accessibilityLabel(label)
        }
    }
}

// MARK: Panel parts

/// A tool's modes (Heal's Spot / People / Brush / Erase and the like), as a segmented control.
struct ModeTabs<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    var title: (Value) -> String

    var body: some View {
        Picker("Mode", selection: $selection) {
            ForEach(items, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension ModeTabs where Value: RawRepresentable, Value.RawValue == String {
    init(items: [Value], selection: Binding<Value>) {
        self.init(items: items, selection: selection, title: { $0.rawValue })
    }
}

/// A small choice button (the Face subtabs, the camera's effects). The picked one is filled; `dot` marks a change.
struct Chip: View {
    let title: String
    let on: Bool
    var dot = false
    var action: () -> Void

    var body: some View {
        Group {
            if on {
                Button(action: action) { label }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { label }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityValue(dot ? "changed" : "")
    }

    private var label: some View {
        Text(dot ? "\(title) •" : title).lineLimit(1).fixedSize()
    }
}

/// A small text button on the panel (Reset all, Clear, Add shadow); the prominent one (Remove) is filled.
struct PanelTextButton: View {
    let title: String
    var icon: String?
    var prominent = false
    var action: () -> Void

    var body: some View {
        Group {
            if prominent {
                Button(action: action) { label }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { label }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var label: some View {
        if let icon { Label(title, systemImage: icon) } else { Text(title) }
    }
}

/// The reset arrow beside a value. `tile` puts it on a 44 point rounded tile, like the photo editor's top bar.
struct ResetButton: View {
    let label: String
    var tile = false
    var action: () -> Void

    var body: some View {
        if tile {
            Button(action: action) { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(ResetTileStyle())
                .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Image(systemName: "arrow.counterclockwise").frame(width: 36, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        }
    }
}

/// ResetButton's tile: the accent arrow on the grey of the top bar's buttons, greyed out when there's nothing to reset.
private struct ResetTileStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18))
            .foregroundStyle(isEnabled ? Color.accentColor : Color(.tertiaryLabel))
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// One line of help under a tool's controls.
struct HintText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Feedback

/// A short message over the content that fades away (Saved to Photos, hints after an action).
struct Toast: View {
    let text: String
    var icon: String?

    var body: some View {
        Group {
            if let icon { Label(text, systemImage: icon) } else { Text(text) }
        }
        .font(.subheadline)
        .lineLimit(2)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
        .transition(.opacity)
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
                withAnimation { shown = message }
            }
            .task(id: id) {
                guard shown != nil else { return }
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation { shown = nil }
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
        .animation(.default, value: shown)
        .task(id: value) {
            guard let value else { shown = nil; return }
            if shown != nil { shown = value; return }
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { shown = value }
        }
    }
}

/// Work under way: a spinner and what it's doing.
struct BusyBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.subheadline)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .transition(.opacity)
    }
}
