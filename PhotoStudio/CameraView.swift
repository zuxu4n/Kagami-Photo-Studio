import SwiftUI
import AVFoundation

/// The live camera screen: the camera with the look drawn on it, a slider for each part of the look, a record button,
/// and hold-to-compare on the picture.
struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()
    @State private var look: LiveLook
    @State private var control = LookControl.all[0]
    private let fromPhoto: Bool

    /// `initial` is the open photo's look, if there is one; otherwise the camera starts with a light default.
    init(initial: LiveLook?) {
        fromPhoto = initial != nil
        var start = LiveLook()
        start.shape.slim = -0.3
        start.shape.eyes = 0.2
        _look = State(initialValue: initial ?? start)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
            if let message = camera.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        if camera.message == message { camera.message = nil }
                    }
            }
        }
        .statusBarHidden()
        .onAppear { camera.look = look; camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: look) { _, new in camera.look = new }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                .disabled(camera.recording)
            Spacer()
            VStack(spacing: 2) {
                if camera.recording {
                    Text(String(format: "● %d:%02d", camera.seconds / 60, camera.seconds % 60))
                        .font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(.red)
                } else {
                    Text(camera.faceCount == 0 ? "Looking for a face" : fromPhoto ? "Your photo's settings" : "Hold to compare")
                        .font(.caption.weight(.medium))
                }
                Text(camera.stats).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button { camera.switchCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3).frame(width: 44, height: 44)
            }
            .disabled(camera.recording)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var controls: some View {
        VStack(spacing: 12) {
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
                    .font(.caption.monospacedDigit()).foregroundStyle(.white).frame(width: 34, alignment: .trailing)
                Button { control.set(&look, 0) } label: { Image(systemName: "arrow.counterclockwise").foregroundStyle(.white) }
            }
            .padding(.horizontal, 20)
            recordButton
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var recordButton: some View {
        Button {
            if camera.recording { camera.stopRecording() } else { camera.startRecording() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: camera.recording ? 6 : 30)
                    .fill(.red)
                    .frame(width: camera.recording ? 30 : 60, height: camera.recording ? 30 : 60)
            }
            .animation(.easeInOut(duration: 0.15), value: camera.recording)
        }
        .accessibilityLabel(camera.recording ? "Stop recording" : "Record")
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
