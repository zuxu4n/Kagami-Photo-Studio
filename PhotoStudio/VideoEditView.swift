import SwiftUI
import AVFoundation
import Photos
import CoreTransferable
import UniformTypeIdentifiers

/// A video picked from Photos, copied into the app's temporary folder.
struct PickedMovie: Transferable, Identifiable {
    let url: URL
    var id: URL { url }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

/// Plays a video with the look drawn on it, with the camera's sliders, and saves a new copy (with its sound) to Photos.
struct VideoEditView: View {
    let movie: PickedMovie
    var close: () -> Void
    @State private var look = LiveLook()   // every effect starts at none, as on the camera
    @State private var control = LookControl.all[0]
    @State private var adjust = Adjustments()
    @State private var adjustTool: AdjustTool = .brightness
    @State private var panel = "Face"      // which controls show: Face or Adjust
    @State private var asset: AVURLAsset?
    @State private var player = AVPlayer()
    @State private var composition: AVVideoComposition?
    @State private var playing = false
    @State private var saving: Double?     // export progress, 0...1
    @State private var message: String?
    @State private var loop: Any?
    @State private var box = LookBox()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            PlayerLayerView(player: player)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !box.comparing { box.comparing = true; refresh() } }
                    .onEnded { _ in box.comparing = false; refresh() })
                .overlay(alignment: .bottomLeading) { playButton.padding(Space.m) }
            controls
        }
        .background(Color.studio.ignoresSafeArea())
        .overlay {
            if let saving {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.15), lineWidth: 4)
                            Circle().trim(from: 0, to: saving).stroke(Color.rose, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.2), value: saving)
                            Text("\(Int(saving * 100))%").font(.ui(14, .semibold).monospacedDigit())
                        }
                        .frame(width: 64, height: 64)
                        Text("Saving video").font(.ui(15, .medium))
                    }
                    .foregroundStyle(Color.studioText)
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .background(Color.studioPanel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let message {
                Toast(text: message, icon: message == "Saved to Photos" ? "checkmark.circle.fill" : nil)
                    .padding(.top, 60)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        if self.message == message { withAnimation(.gentle) { self.message = nil } }
                    }
            }
        }
        .animation(.gentle, value: message)
        .animation(.quick, value: saving != nil)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .sensoryFeedback(.success, trigger: message) { _, new in new == "Saved to Photos" }
        .task { await load() }
        .onDisappear {
            player.pause()
            if let loop { NotificationCenter.default.removeObserver(loop) }
            try? FileManager.default.removeItem(at: movie.url)   // our own temporary copy
        }
        .onChange(of: look) { _, new in box.look = new; refresh() }
        .onChange(of: adjust) { old, new in
            box.adjust = new
            if old.outputSize(for: CGSize(width: 1000, height: 1600)) == new.outputSize(for: CGSize(width: 1000, height: 1600)) {
                refresh()
            } else {
                Task { await recompose() }   // a new crop or turn changes the picture's size
            }
        }
    }

    private var topBar: some View {
        HStack {
            StudioIconButton(icon: "xmark", label: "Close video") { close() }
                .disabled(saving != nil)
            Spacer()
            Text("Hold the video to compare").font(.ui(13, .medium)).foregroundStyle(Color.studioSecondary)
            Spacer()
            Button("Save") { Task { await save() } }
                .buttonStyle(PillButtonStyle())
                .disabled(saving != nil || composition == nil)
                .accessibilityHint("Saves a copy to Photos")
        }
        .padding(.leading, Space.s).padding(.trailing, Space.l)
        .frame(height: 52)
    }

    private var playButton: some View {
        Button { togglePlay() } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.studioText)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.45), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(playing ? "Pause" : "Play")
    }

    private var controls: some View {
        VStack(spacing: Space.m) {
            ModeTabs(items: ["Face", "Adjust"], selection: $panel, title: { $0 })
                .padding(.horizontal, Space.l)
            if panel == "Adjust" {
                AdjustPanel(adjust: $adjust, tool: $adjustTool, freeCrop: false)
                    .padding(.horizontal, Space.l)
            } else {
                LookControls(look: $look, control: $control)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .frame(height: 236, alignment: .top)
        .background(Color.studioPanel.ignoresSafeArea(edges: .bottom))
    }

    private func load() async {
        box.look = look
        let asset = AVURLAsset(url: movie.url)
        self.asset = asset
        guard let c = try? await VideoLook.composition(for: asset, box: box) else {
            message = "This video can't be opened."
            return
        }
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = c
        composition = c
        player.replaceCurrentItem(with: item)
        loop = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            player.seek(to: .zero)
            player.play()
        }
        player.play()
        playing = true
    }

    /// A new composition for a new picture size, swapped into the player where it is.
    private func recompose() async {
        guard let asset, let c = try? await VideoLook.composition(for: asset, box: box) else { return }
        composition = c
        player.currentItem?.videoComposition = c
        refresh()
    }

    private func togglePlay() {
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    /// Draws the paused frame again with the new look (a playing video picks it up on the next frame).
    private func refresh() {
        guard !playing else { return }
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func save() async {
        guard let composition else { return }
        player.pause(); playing = false
        saving = 0
        defer { saving = nil }
        let asset = AVURLAsset(url: movie.url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            message = "This video can't be saved."; return
        }
        export.videoComposition = composition
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Mioru-\(UUID().uuidString).mov")
        let progress = Task {
            for await state in export.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { await MainActor.run { saving = p.fractionCompleted } }
            }
        }
        do {
            try await export.export(to: out, as: .mov)
        } catch {
            progress.cancel()
            message = "The video couldn't be saved (\(error.localizedDescription))."
            return
        }
        progress.cancel()
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Mioru can't add to Photos. You can allow it in Settings › Mioru."; return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: out, options: options)
            }
            message = "Saved to Photos"
        } catch {
            message = "The video couldn't be saved (\(error.localizedDescription))."
        }
    }
}

/// Shows an AVPlayer's video fitted to the screen.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = UIColor(hex: 0x0D0D0E)
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {}
}
