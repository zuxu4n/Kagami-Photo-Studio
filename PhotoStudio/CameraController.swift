import AVFoundation
import Photos
import UIKit

/// The live camera: frames come in on one queue, the faces are tracked, the look is drawn on the GPU, and the result
/// goes to the screen and, while recording, into a video file with the microphone's sound. Saved videos go to Photos.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0               // length of the recording so far
    @Published private(set) var denied = false             // camera access was refused
    @Published private(set) var stats = ""                // frame rate and time per frame, for testing
    @Published private(set) var faceCount = 0
    @Published private(set) var front = true
    @Published var message: String?

    let displayLayer = AVSampleBufferDisplayLayer()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "camera.audio", qos: .userInitiated)
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private lazy var renderer = LiveRenderer()
    private let tracker = LiveFaceTracker()

    private let lock = NSLock()   // guards the values below, read on the video and audio queues
    private var _look = LiveLook()
    private var _comparing = false
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStart: CMTime?
    private var stopping = false
    private var lastSecond = 0

    /// The beauty settings drawn on each frame.
    var look: LiveLook {
        get { lock.lock(); defer { lock.unlock() }; return _look }
        set { lock.lock(); _look = newValue; lock.unlock() }
    }
    /// Show the camera as it is (Hold to compare). The recording keeps the look.
    var comparing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _comparing }
        set { lock.lock(); _comparing = newValue; lock.unlock() }
    }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspectFill
    }

    // MARK: Session

    func start() {
        Task {
            let video = await AVCaptureDevice.requestAccess(for: .video)
            guard video else {
                await MainActor.run { denied = true }
                return
            }
            let audio = await AVCaptureDevice.requestAccess(for: .audio)
            sessionQueue.async { [self] in
                if !configured { configure(audio: audio) }
                if !session.isRunning { session.startRunning() }
            }
        }
    }

    func stop() {
        if recording { stopRecording() }
        sessionQueue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    func switchCamera() {
        guard !recording else { return }
        sessionQueue.async { [self] in
            let wantFront = !(videoInput?.device.position == .front)
            session.beginConfiguration()
            if let videoInput { session.removeInput(videoInput) }
            addCamera(front: wantFront)
            session.commitConfiguration()
            videoQueue.async { self.tracker.reset() }
            DispatchQueue.main.async { self.front = wantFront }
        }
    }

    private func configure(audio: Bool) {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        addCamera(front: true)
        if audio, let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
        }
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true   // a slow frame is dropped rather than queued, so the picture never lags
        videoOut.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
        audioOut.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOut) { session.addOutput(audioOut) }
        orient()
        session.commitConfiguration()
        configured = true
    }

    private func addCamera(front: Bool) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        videoInput = input
        if (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }
        orient()
    }

    /// Upright portrait frames, mirrored for the front camera like a mirror.
    private func orient() {
        guard let c = videoOut.connection(with: .video) else { return }
        if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = videoInput?.device.position == .front
        }
    }

    // MARK: Frames

    private var statFrames = 0, statTrack = 0.0, statDraw = 0.0, statStart = 0.0, logStart = 0.0
    private var lastSize = (0, 0)

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOut { appendAudio(sb); return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let look = self.look
        let t0 = CACurrentMediaTime()
        let frame = LiveRenderer.rgba(pb)
        let faces = tracker.update(frame, time: pts.seconds)
        let plan = LiveRenderer.plan(faces: faces, look: look, width: frame.width, height: frame.height, frame: frame)
        let t1 = CACurrentMediaTime()
        let out = renderer.render(pb, plan: plan)
        let t2 = CACurrentMediaTime()
        lastSize = (frame.width, frame.height)
        show(comparing ? pb : out, at: pts)
        appendVideo(out, at: pts)

        statFrames += 1; statTrack += t1 - t0; statDraw += t2 - t1
        if statStart == 0 { statStart = t0; logStart = t0 }
        if t0 - statStart >= 1 {
            let fps = Double(statFrames) / (t0 - statStart)
            let track = statTrack / Double(statFrames) * 1000, draw = statDraw / Double(statFrames) * 1000
            let text = String(format: "%.0f fps · faces %.0f ms · draw %.0f ms", fps, track, draw)
            let n = faces.count
            DispatchQueue.main.async { self.stats = text; self.faceCount = n }
            if t0 - logStart >= 5 {
                logStart = t0
                CameraController.log(["fps": fps, "faces_ms": track, "draw_ms": draw, "faces": Double(n),
                                      "recording": isWriting ? 1 : 0, "thermal": Double(ProcessInfo.processInfo.thermalState.rawValue),
                                      "width": Double(frame.width), "height": Double(frame.height),
                                      "mem_mb": MemoryMeter.footprintMB()])
            }
            statFrames = 0; statTrack = 0; statDraw = 0; statStart = t0
        }
    }

    private func show(_ pb: CVPixelBuffer, at pts: CMTime) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let r = displayLayer.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(sample)
    }

    // MARK: Recording

    func startRecording() {
        videoQueue.async { [self] in
            let (w, h) = lastSize
            guard w > 0, writer == nil else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Yumiro-\(UUID().uuidString).mov")
            guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
            vIn.expectsMediaDataInRealTime = true
            guard wr.canAdd(vIn) else { return }
            wr.add(vIn)
            var aIn: AVAssetWriterInput?
            if let settings = audioOut.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                a.expectsMediaDataInRealTime = true
                if wr.canAdd(a) { wr.add(a); aIn = a }
            }
            guard wr.startWriting() else { return }
            lock.lock()
            writer = wr; videoIn = vIn; audioIn = aIn; sessionStart = nil; stopping = false; lastSecond = 0
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: nil)
            lock.unlock()
            DispatchQueue.main.async { self.recording = true; self.seconds = 0 }
        }
    }

    func stopRecording() {
        videoQueue.async { [self] in
            lock.lock()
            guard let wr = writer, !stopping else { lock.unlock(); return }
            stopping = true
            let started = sessionStart != nil
            videoIn?.markAsFinished(); audioIn?.markAsFinished()
            writer = nil; videoIn = nil; audioIn = nil; adaptor = nil; sessionStart = nil
            lock.unlock()
            DispatchQueue.main.async { self.recording = false }
            guard started else { wr.cancelWriting(); return }
            wr.finishWriting {
                guard wr.status == .completed else {
                    DispatchQueue.main.async { self.message = "The video couldn't be saved (\(wr.error?.localizedDescription ?? "unknown error"))." }
                    return
                }
                CameraController.saveToPhotos(wr.outputURL) { error in
                    DispatchQueue.main.async { self.message = error ?? "Saved to Photos" }
                }
            }
        }
    }

    private var isWriting: Bool { lock.lock(); defer { lock.unlock() }; return writer != nil }

    private func appendVideo(_ pb: CVPixelBuffer, at pts: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let wr = writer, let vIn = videoIn, let adaptor, !stopping else { return }
        if sessionStart == nil { wr.startSession(atSourceTime: pts); sessionStart = pts }
        if vIn.isReadyForMoreMediaData { adaptor.append(pb, withPresentationTime: pts) }
        let s = Int((pts - sessionStart!).seconds)
        if s != lastSecond { lastSecond = s; DispatchQueue.main.async { self.seconds = s } }
    }

    private func appendAudio(_ sb: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let aIn = audioIn, let start = sessionStart, !stopping,
              CMSampleBufferGetPresentationTimeStamp(sb) >= start, aIn.isReadyForMoreMediaData else { return }
        aIn.append(sb)
    }

    private static func saveToPhotos(_ url: URL, done: @escaping (String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                done("Yumiro can't add to Photos. You can allow it in Settings › Yumiro."); return
            }
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
            }) { ok, error in done(ok ? nil : "The video couldn't be saved (\(error?.localizedDescription ?? "unknown error")).") }
        }
    }

    // MARK: Timings (Documents/camera_timings.json, for collection over USB)

    private static let logQueue = DispatchQueue(label: "camera-log", qos: .utility)

    private static func log(_ values: [String: Double]) {
        var entry: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date())]
        for (k, v) in values { entry[k] = (v * 10).rounded() / 10 }
        logQueue.async {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("camera_timings.json")
            var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            all.append(entry)
            if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]) { try? d.write(to: url) }
        }
    }
}
