import SwiftUI

/// The first screen: open a photo (straight into a tool, if one is picked), the beauty camera or a video. Drawn like
/// the photo editor: grey tiles with its corners, the main way in filled like Save, and the tools as cards under the
/// tool bar's group names.
struct HomeView: View {
    var busy: String?
    var openPhoto: (Tool?) -> Void
    var openVideo: () -> Void
    var openCamera: () -> Void
    var showWelcome: () -> Void
    @State private var showAbout = false
    @State private var welcomeAfterAbout = false

    /// Nothing can be tapped while a photo opens.
    private var live: Bool { busy == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    Button { openPhoto(nil) } label: {
                        Label("Edit a photo", systemImage: "photo")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(HomeTileStyle(primary: true))
                    HStack(spacing: Space.s) {
                        Button(action: openCamera) { actionLabel("Camera", icon: "camera") }
                        Button(action: openVideo) { actionLabel("Video", icon: "play.rectangle") }
                            .accessibilityLabel("Edit a video")
                            .accessibilityInputLabels(["Video", "Edit a video"])
                    }
                    .buttonStyle(HomeTileStyle())
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Start with a tool")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 20)
                    ForEach(Array(Tool.groups.enumerated()), id: \.offset) { i, group in
                        toolGroup(Tool.groupTitles[i], group)
                    }
                    privacyNote.padding(.top, Space.m)
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.s)
                .padding(.bottom, Space.l)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .disabled(!live)
        .overlay {
            DelayedPresence(value: busy) { BusyBadge(text: $0) }
        }
        // The welcome opens once About has finished closing (one sheet can't open while another closes).
        .sheet(isPresented: $showAbout, onDismiss: {
            if welcomeAfterAbout { welcomeAfterAbout = false; showWelcome() }
        }) {
            AboutView(showWelcome: { welcomeAfterAbout = true; showAbout = false })
        }
    }

    /// The app's name, and About on a grey tile like the photo editor's Close.
    private var header: some View {
        HStack {
            Text("Yumiro")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { showAbout = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(live ? Color.secondary : Color(.tertiaryLabel))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(HomeTileStyle())
            .accessibilityLabel("About Yumiro")
        }
        .padding(.horizontal, Space.l)
        .frame(minHeight: 52)
    }

    /// Camera or Video: the accent icon beside its name.
    private func actionLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title).foregroundStyle(live ? Color.primary : Color(.tertiaryLabel))
        } icon: {
            Image(systemName: icon).font(.title3).foregroundStyle(live ? Color.accentColor : Color(.tertiaryLabel))
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, Space.m)
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: .infinity)
    }

    /// One of the tool bar's groups: its name, then its tools two to a row.
    private func toolGroup(_ title: String, _ tools: [Tool]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(live ? Color.toolMuted : Color(.tertiaryLabel))
                .padding(.leading, Space.s)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(stride(from: 0, to: tools.count, by: 2)), id: \.self) { j in
                HStack(spacing: Space.s) {
                    ForEach(tools[j..<min(j + 2, tools.count)]) { t in toolCard(t) }
                    if j + 1 == tools.count { Color.clear.frame(maxWidth: .infinity) }
                }
                .fixedSize(horizontal: false, vertical: true)   // both cards in a row as tall as the taller one
            }
        }
        .padding(.top, Space.xs)
    }

    /// A tool to start in: its icon, name and one line about it. The photo picked next opens in it.
    private func toolCard(_ t: Tool) -> some View {
        Button { openPhoto(t) } label: {
            HStack(spacing: 10) {
                Image(systemName: t.icon)
                    .font(.title3)
                    .foregroundStyle(live ? Color.accentColor : Color(.tertiaryLabel))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(live ? Color.primary : Color(.tertiaryLabel))
                    Text(t.blurb)
                        .font(.footnote)
                        .foregroundStyle(live ? Color.toolMuted : Color(.tertiaryLabel))
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(HomeTileStyle())
        .accessibilityHint("Choose a photo to open in \(t.rawValue)")
    }

    /// The promise that nothing leaves the phone, under the tools.
    private var privacyNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock").accessibilityHidden(true)
            Text("Everything happens on this iPhone. Your photos are never uploaded.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(live ? Color.toolMuted : Color(.tertiaryLabel))
    }
}

/// A way in on the home screen: a grey tile with the photo editor's corners, or, for the main one, filled with the
/// accent colour like Save (faded while disabled).
private struct HomeTileStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return configuration.label
            .background(shape.fill(primary ? Color.accentColor.opacity(isEnabled ? 1 : 0.35) : Color(.secondarySystemBackground)))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: Welcome

/// Shown once, the first time Yumiro opens.
struct WelcomeView: View {
    var done: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("A photo studio that lives on your iPhone.")
                }
                Section {
                    Label("Every edit happens on this iPhone. Nothing is uploaded.", systemImage: "lock")
                    Label("Enhance, smooth skin, reshape features and remove what doesn't belong.", systemImage: "wand.and.stars")
                    Label("Free and open source. No subscription, no watermark, no account.", systemImage: "heart")
                }
            }
            .navigationTitle("Welcome to Yumiro")
            .safeAreaInset(edge: .bottom) {
                Button(action: done) {
                    Text("Get started").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
    }
}

// MARK: About

/// About Yumiro: privacy, the source code, the open models it runs on, and the welcome again.
struct AboutView: View {
    var showWelcome: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version", value: version)
                }
                Section("Privacy") {
                    Text("Yumiro has no servers and no network code. Photos and videos are only read when you pick them, and saved copies go straight to Photos.")
                }
                Section("Open source") {
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/zuxu4n/Yumiro")!)
                }
                Section("Built with open models") {
                    LabeledContent("Real-ESRGAN", value: "Enhance · BSD-3-Clause")
                    LabeledContent("LaMa", value: "Heal · Apache-2.0")
                    LabeledContent("MediaPipe Face Mesh", value: "Face · Apache-2.0")
                }
                Section {
                    Button("Show the welcome again", action: showWelcome)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
