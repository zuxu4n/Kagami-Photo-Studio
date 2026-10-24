import SwiftUI
import AVFoundation

/// The live camera screen: the camera with the look drawn on it and hold-to-compare on the picture, then a panel below
/// it with a slider for each part of the look and the record row (Compare, Record, Switch camera). The looks tile at
/// the top right hides the sliders, so more of the picture shows.
struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @StateObject private var camera = CameraController()
    @State private var look = LiveLook()   // every effect starts at none ((a design call))
    @State private var control = LookControl.all[0]
    @State private var comparing = false   // holding the picture or the Compare tile
    @AppStorage("cameraLooksHidden") private var looksHidden = false   // stays as left, the next time too

    var body: some View {
        ZStack {
            (camera.denied ? Color(.systemBackground) : Color.black).ignoresSafeArea()
            if camera.denied {
                CameraAccessView { dismiss() }
            } else {
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        CameraPreview(layer: camera.displayLayer)
                            .ignoresSafeArea(edges: .top)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { _ in if !comparing { comparing = true } }
                                .onEnded { _ in comparing = false })
                        topBar
                    }
                    controls
                }
            }
            if let message = camera.message {
                Toast(text: message, icon: message == "Saved to Photos" ? "checkmark.circle.fill" : nil)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        if camera.message == message { withAnimation { camera.message = nil } }
                    }
            }
        }
        .animation(.default, value: camera.message)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .statusBarHidden()
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.recording)
        .onAppear { camera.look = look; camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: look) { _, new in camera.look = new }
        .onChange(of: comparing) { _, new in camera.comparing = new }
    }

    /// Close on the left of the picture, what the camera is doing in the middle, and the looks tile on the right. The
    /// tiles either side are the same size, so the status stays in the middle.
    private var topBar: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .buttonStyle(CameraButtonStyle(fill: .material, neutral: true))
                .disabled(camera.recording)
                .accessibilityLabel("Close camera")
            Spacer(minLength: Space.s)
            status
            Spacer(minLength: Space.s)
            // Tinted while the sliders show; it works while recording too.
            Button { withAnimation { looksHidden.toggle() } } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }
            .buttonStyle(CameraButtonStyle(fill: looksHidden ? .material : .picked))
            .accessibilityLabel(looksHidden ? "Show looks" : "Hide looks")
        }
        .padding(.horizontal, Space.m)
        .frame(height: 52)
    }

    /// Looking for a face, the hint to compare, or the recording time in white on red.
    private var status: some View {
        Group {
            if camera.recording {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 7, height: 7)
                    Text(String(format: "%d:%02d", camera.seconds / 60, camera.seconds % 60)).monospacedDigit()
                }
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            } else {
                Text(camera.faceCount == 0 ? "Looking for a face" : "Hold the picture to compare")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12).frame(height: 32)
        .background {
            if camera.recording { Capsule().fill(Color.recordingTime) } else { Capsule().fill(.regularMaterial) }
        }
        .animation(.default, value: camera.recording)
    }

    /// The effects on a panel below the picture, then the record row. With the looks hidden only the record row is
    /// left, and the picture grows into the space.
    private var controls: some View {
        VStack(spacing: Space.m) {
            if !looksHidden { LookControls(look: $look, control: $control) }
            recordRow
        }
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
    }

    /// Compare, Record and Switch camera. The tiles either side are the same size, so Record stays in the middle.
    private var recordRow: some View {
        HStack {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(comparing ? Color.toolTile(scheme) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { comparing = $0 }, perform: {})
                .accessibilityLabel("Hold to compare with the original")
                .accessibilityAddTraits(.isButton)
            Spacer()
            recordButton
            Spacer()
            Button { camera.switchCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath").frame(width: 44, height: 44)
            }
            .buttonStyle(CameraButtonStyle())
            .disabled(camera.recording)
            .accessibilityLabel("Switch camera")
        }
        .padding(.horizontal, Space.l)
    }

    private var recordButton: some View {
        Button {
            if camera.recording { camera.stopRecording() } else { camera.startRecording() }
        } label: {
            // A red dot in a ring that becomes a square while recording, like the system camera.
            ZStack {
                Circle().stroke(Color.recordRing, lineWidth: 4).frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: camera.recording ? 6 : 31)
                    .fill(.red)
                    .frame(width: camera.recording ? 30 : 62, height: camera.recording ? 30 : 62)
            }
            .animation(.default, value: camera.recording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(camera.recording ? "Stop recording" : "Record")
    }
}

/// The look's controls, shared by the camera and the video editor: a chip for each effect, then its slider field and
/// reset tile, like the photo editor's slider rows.
struct LookControls: View {
    @Binding var look: LiveLook
    @Binding var control: LookControl

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LookControl.all) { c in
                        Chip(title: c.name, on: c.id == control.id, dot: abs(c.get(look)) > 0.001) { control = c }
                    }
                }
                .padding(.horizontal, Space.l)
            }
            .sensoryFeedback(.selection, trigger: control.id)
            HStack(spacing: Space.s) {
                ValueSlider(value: Binding(get: { control.get(look) }, set: { control.set(&look, $0) }), range: control.range,
                            title: control.name)
                    .accessibilityLabel(control.name)
                ResetButton(label: "Reset \(control.name)", tile: true) { withAnimation { control.set(&look, 0) } }
                    .disabled(abs(control.get(look)) < 0.001)
            }
            .frame(height: 44)
            .padding(.horizontal, Space.l)
        }
    }
}

/// The camera screen when access to the camera was turned off: why it's needed where the picture would be, and the
/// way to Settings below it, where the panel would be.
struct CameraAccessView: View {
    var close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(.secondarySystemBackground).ignoresSafeArea(edges: .top)
                VStack(spacing: 6) {
                    Image(systemName: "camera")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.toolMuted)
                        .padding(.bottom, 10)
                        .accessibilityHidden(true)
                    Text("Allow the camera")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Yumiro films with your look applied live. Everything stays on this iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(Color.toolMuted)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(CameraButtonStyle(fill: .background, neutral: true))
                    .accessibilityLabel("Close camera")
                    .padding(.horizontal, Space.m)
                    .frame(height: 52)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Open Settings").frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(CameraButtonStyle(fill: .accent))
            .padding(Space.l)
        }
    }
}

/// The camera's buttons: 44-point tiles like the photo editor's top bar (Close, the looks tile, Switch camera) and
/// the filled Open Settings. `fill` is the tile: a material over the picture (tinted when `picked`), grey on the
/// panel, or the background colour on the grey of the camera-off screen.
private struct CameraButtonStyle: ButtonStyle {
    enum Fill { case accent, grey, background, material, picked }

    var fill: Fill = .grey
    var neutral = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    private var foreground: Color {
        if !isEnabled { return Color(.tertiaryLabel) }
        if fill == .accent { return .white }
        return neutral ? .secondary : .accentColor
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return configuration.label
            .font(fill == .accent ? .body.weight(.semibold) : .system(size: 20))
            .foregroundStyle(foreground)
            .background {
                switch fill {
                case .accent: shape.fill(Color.accentColor)
                case .grey: shape.fill(Color(.secondarySystemBackground))
                case .background: shape.fill(Color(.systemBackground))
                case .material: shape.fill(.regularMaterial)
                case .picked: shape.fill(.regularMaterial).overlay(shape.fill(Color.toolTile(scheme)))
                }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private extension Color {
    /// The recording time's pill: a darker red than the system's, so the white time keeps 4.5:1 (about 5.4:1).
    static let recordingTime = Color(red: 0.843, green: 0, blue: 0.082)

    /// The record button's ring: white on the dark panel, grey on the light one, where white wouldn't show.
    static let recordRing = Color(UIColor { $0.userInterfaceStyle == .dark ? .white : .systemGray3 })
}

/// One slider on the camera screen: what it's called, its range and which part of the look it sets.
struct LookControl: Identifiable {
    let id: String
    let name: String
    let range: ClosedRange<Float>
    let get: (LiveLook) -> Float
    let set: (inout LiveLook, Float) -> Void

    static let all: [LookControl] = [
        LookControl(id: "smooth", name: "Smooth", range: 0...1, get: { $0.smooth }, set: { $0.smooth = $1 }),
        LookControl(id: "headSize", name: "Head size", range: -1...1, get: { $0.shape.size }, set: { $0.shape.size = $1 }),
        LookControl(id: "headWidth", name: "Head width", range: -1...1, get: { $0.shape.width }, set: { $0.shape.width = $1 }),
        LookControl(id: "headHeight", name: "Head height", range: -1...1, get: { $0.shape.headHeight }, set: { $0.shape.headHeight = $1 }),
        LookControl(id: "slim", name: "Slim", range: 0...1, get: { max(0, -$0.shape.slim) }, set: { $0.shape.slim = -$1 }),
        LookControl(id: "eyes", name: "Eyes", range: -1...1, get: { $0.shape.eyes }, set: { $0.shape.eyes = $1 }),
        LookControl(id: "nose", name: "Nose", range: -1...1, get: { $0.shape.noseSize }, set: { $0.shape.noseSize = $1 }),
        LookControl(id: "lips", name: "Lips", range: -1...1, get: { $0.shape.lipSize }, set: { $0.shape.lipSize = $1 }),
        LookControl(id: "jaw", name: "Jaw", range: -1...1, get: { $0.shape.jaw }, set: { $0.shape.jaw = $1 }),
        LookControl(id: "chin", name: "Chin", range: -1...1, get: { $0.shape.chin }, set: { $0.shape.chin = $1 }),
        LookControl(id: "teeth", name: "Whiten teeth", range: 0...1, get: { $0.shape.retouch.teeth }, set: { $0.shape.retouch.teeth = $1 }),
        LookControl(id: "brighten", name: "Brighten eyes", range: 0...1, get: { $0.shape.retouch.eyes }, set: { $0.shape.retouch.eyes = $1 }),
        LookControl(id: "tone", name: "Even tone", range: 0...1, get: { $0.shape.retouch.tone }, set: { $0.shape.retouch.tone = $1 }),
    ]
}

/// Shows the camera's processed frames (an AVSampleBufferDisplayLayer) filling the screen.
struct CameraPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    final class LayerView: UIView {
        var shown: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            shown?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.layer.addSublayer(layer)
        v.shown = layer
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {}
}
