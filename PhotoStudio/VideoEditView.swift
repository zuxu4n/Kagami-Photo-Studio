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
    @Environment(\.dismiss) private var dismiss
    @State private var look = LiveLook()   // every effect starts at none, as on the camera
    @State private var control = LookControl.all[0]
    @State private var adjust = Adjustments()
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
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: player)
                .ignoresSafeArea()
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !box.comparing { box.comparing = true; refresh() } }
                    .onEnded { _ in box.comparing = false; refresh() })
            VStack(spacing: 0) {
                topBar
                Spacer()
                controls
            }
            if let saving {
                VStack(spacing: 10) {
                    ProgressView(value: saving).tint(.white).frame(width: 200)
                    Text("Saving \(Int(saving * 100))%").font(.callout.monospacedDigit())
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        if self.message == message { self.message = nil }
                    }
            }
        }
        .foregroundStyle(.white)
        .statusBarHidden()
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
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                .disabled(saving != nil)
            Spacer()
            Text("Hold to compare").font(.caption.weight(.medium))
            Spacer()
            Button("Save") { Task { await save() } }
                .font(.headline)
                .frame(height: 44)
                .disabled(saving != nil || composition == nil)
        }
        .padding(.horizontal, 12)
        .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 36, height: 36)
                }
                Picker("Settings", selection: $panel) {
                    Text("Face").tag("Face")
                    Text("Adjust").tag("Adjust")
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            if panel == "Adjust" {
                AdjustPanel(adjust: $adjust).padding(.horizontal, 16)
            } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LookControl.all) { c in
                        Button { control = c } label: {
                            Text(c.name)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(c.id == control.id ? Color.white : Color.white.opacity(0.18), in: Capsule())
                                .foregroundStyle(c.id == control.id ? Color.black : Color.white)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                Slider(value: Binding(get: { Double(control.get(look)) }, set: { control.set(&look, Float($0)) }),
                       in: Double(control.range.lowerBound)...Double(control.range.upperBound))
                    .tint(.white)
                Text("\(Int((control.get(look) * 100).rounded()))")
                    .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                Button { control.set(&look, 0) } label: { Image(systemName: "arrow.counterclockwise") }
            }
            .padding(.horizontal, 16)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
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
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoStudio-\(UUID().uuidString).mov")
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
            message = "PhotoStudio can't add to Photos. You can allow it in Settings › PhotoStudio."; return
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
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {}
}
