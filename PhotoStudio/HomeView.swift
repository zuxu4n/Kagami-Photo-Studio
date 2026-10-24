import SwiftUI

/// The first screen: open a photo (straight into a tool, if one is picked), the beauty camera or a video.
struct HomeView: View {
    var busy: String?
    var openPhoto: (Tool?) -> Void
    var openVideo: () -> Void
    var openCamera: () -> Void
    var showWelcome: () -> Void
    @State private var showAbout = false
    @State private var welcomeAfterAbout = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { openPhoto(nil) } label: {
                        Label("Edit a photo", systemImage: "photo")
                    }
                    Button(action: openCamera) {
                        Label("Camera", systemImage: "camera")
                    }
                    Button(action: openVideo) {
                        Label("Edit a video", systemImage: "play.rectangle")
                    }
                }
                Section {
                    ForEach(Tool.groups.flatMap { $0 }) { t in
                        Button { openPhoto(t) } label: {
                            LabeledContent {
                                Text(t.blurb)
                            } label: {
                                Label(t.rawValue, systemImage: t.icon)
                            }
                        }
                        .accessibilityHint("Choose a photo to open in \(t.rawValue)")
                    }
                } header: {
                    Text("Start with a tool")
                } footer: {
                    Text("Everything happens on this iPhone. Your photos are never uploaded.")
                }
            }
            .navigationTitle("Yumiro")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAbout = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("About Yumiro")
                }
            }
            .disabled(busy != nil)
        }
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
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/zuxu4n/Kagami-Photo-Studio")!)
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
