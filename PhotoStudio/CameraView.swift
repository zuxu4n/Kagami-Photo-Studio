import SwiftUI
import AVFoundation

/// The live camera screen: the camera with the look drawn on it, a slider for each part of the look, a record button,
/// and hold-to-compare on the picture.
struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()
    @State private var look = LiveLook()   // every effect starts at none ((a design call))
    @State private var control = LookControl.all[0]

    var body: some View {
        ZStack {
            (camera.denied ? Color(.systemBackground) : Color.black).ignoresSafeArea()
            if camera.denied {
                CameraAccessView { dismiss() }
            } else {
                CameraPreview(layer: camera.displayLayer)
                    .ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !camera.comparing { camera.comparing = true } }
                        .onEnded { _ in camera.comparing = false })
                VStack(spacing: 0) {
                    topBar
                    Spacer()
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
    }

    private var topBar: some View {
        HStack {
            StudioIconButton(icon: "xmark", label: "Close camera", onPhoto: true) { dismiss() }
                .disabled(camera.recording)
            Spacer()
            Group {
                if camera.recording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text(String(format: "%d:%02d", camera.seconds / 60, camera.seconds % 60)).monospacedDigit()
                    }
                } else {
                    Text(camera.faceCount == 0 ? "Looking for a face" : "Hold the picture to compare")
                }
            }
            .font(.footnote)
            .padding(.horizontal, 12).frame(height: 30)
            .background(.regularMaterial, in: Capsule())
            .animation(.default, value: camera.recording)
            Spacer()
            StudioIconButton(icon: "arrow.triangle.2.circlepath", label: "Switch camera", onPhoto: true) { camera.switchCamera() }
                .disabled(camera.recording)
        }
        .padding(.horizontal, Space.s)
        .padding(.top, Space.xs)
    }

    /// The effects on a panel over the picture, and the record button below it.
    private var controls: some View {
        VStack(spacing: 14) {
            LookControls(look: $look, control: $control)
                .padding(.vertical, Space.m)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))   // the chips scroll under its corners
                .padding(.horizontal, Space.m)
            recordButton
        }
        .padding(.top, Space.l)
        .padding(.bottom, Space.s)
    }

    private var recordButton: some View {
        Button {
            if camera.recording { camera.stopRecording() } else { camera.startRecording() }
        } label: {
            // A red dot in a white ring that becomes a square while recording, like the system camera.
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
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

/// The look's controls, shared by the camera and the video editor: a chip for each effect and its slider.
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
                ValueSlider(value: Binding(get: { control.get(look) }, set: { control.set(&look, $0) }), range: control.range)
                    .accessibilityLabel(control.name)
                ResetButton(label: "Reset \(control.name)") { withAnimation { control.set(&look, 0) } }
                    .disabled(abs(control.get(look)) < 0.001)
            }
            .padding(.leading, Space.l).padding(.trailing, Space.s)
        }
    }
}

/// The camera screen when access to the camera was turned off: why it's needed, and the way to Settings.
struct CameraAccessView: View {
    var close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StudioIconButton(icon: "xmark", label: "Close camera", action: close)
                Spacer()
            }
            .padding(.horizontal, Space.s)
            Spacer()
            ContentUnavailableView {
                Label("Allow the camera", systemImage: "camera")
            } description: {
                Text("Yumiro films with your look applied live. Everything stays on this iPhone.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }
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
