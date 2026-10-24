import AVFoundation
import CoreImage
import ImageIO

/// The look for a video, shared by the preview player and the export, and changed from the sliders while it plays.
final class LookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _look = LiveLook()
    private var _comparing = false
    private var _adjust = Adjustments()
    var adjust: Adjustments {
        get { lock.lock(); defer { lock.unlock() }; return _adjust }
        set { lock.lock(); _adjust = newValue; lock.unlock() }
    }
    var look: LiveLook {
        get { lock.lock(); defer { lock.unlock() }; return _look }
        set { lock.lock(); _look = newValue; lock.unlock() }
    }
    var comparing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _comparing }
        set { lock.lock(); _comparing = newValue; lock.unlock() }
    }
}

/// One instruction covering the whole video: which track to read, how to turn it upright, and the look.
final class LookInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let orientation: CGImagePropertyOrientation
    let box: LookBox

    init(range: CMTimeRange, trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation, box: LookBox) {
        timeRange = range
        self.trackID = trackID
        self.orientation = orientation
        self.box = box
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Draws the look on each video frame with the camera's engine: the frame is turned upright and sized to the
/// composition, the faces are tracked from frame to frame, and Smooth, Retouch and the Face warp run on the GPU.
/// AVFoundation makes one for the player and another for the export, each with its own tracking.
final class LookCompositor: NSObject, AVVideoCompositing {
    private let queue = DispatchQueue(label: "video.compose", qos: .userInitiated)
    private let renderer = LiveRenderer()
    private let tracker = LiveFaceTracker()
    private let ci = CIContext(mtlDevice: GPU.shared.device)
    private var lastTime = -1.0

    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let ins = request.videoCompositionInstruction as? LookInstruction,
                  let src = request.sourceFrame(byTrackID: ins.trackID),
                  let upright = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Yumiro", code: 1)); return
            }
            let w = CVPixelBufferGetWidth(upright), h = CVPixelBufferGetHeight(upright)
            var img = CIImage(cvPixelBuffer: src).oriented(ins.orientation)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            if !ins.box.comparing { img = ins.box.adjust.apply(img) }   // crop, turn, flip, light and colour
            img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
            ci.render(img, to: upright, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpaceCreateDeviceRGB())

            let look = ins.box.look
            if ins.box.comparing || look.isOff { request.finish(withComposedVideoFrame: upright); return }
            let t = request.compositionTime.seconds
            if t < lastTime || t - lastTime > 1 { tracker.reset() }   // a seek: start the faces afresh
            lastTime = t
            let frame = LiveRenderer.rgba(upright)
            let faces = tracker.update(frame, time: t)
            let plan = LiveRenderer.plan(faces: faces, look: look, width: w, height: h, frame: frame)
            let out = renderer.render(upright, plan: plan, into: request.renderContext.newPixelBuffer())
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

enum VideoLook {
    /// The longest side videos are drawn at. Bigger ones (4K) are drawn at this size, for speed.
    static let maxSide: CGFloat = 1920

    /// A video composition that draws `box`'s look on the asset's first video track, upright.
    static func composition(for asset: AVAsset, box: LookBox) async throws -> AVVideoComposition? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (natural, transform, fps, duration) = try await (track.load(.naturalSize), track.load(.preferredTransform),
                                                             track.load(.nominalFrameRate), asset.load(.duration))
        let orientation = Self.orientation(transform)
        let turned = [.left, .right].contains(orientation)
        var size = box.adjust.outputSize(for: turned ? CGSize(width: natural.height, height: natural.width) : natural)
        let k = min(1, maxSide / max(size.width, size.height))
        size = CGSize(width: (size.width * k / 2).rounded() * 2, height: (size.height * k / 2).rounded() * 2)

        let c = AVMutableVideoComposition()
        c.customVideoCompositorClass = LookCompositor.self
        c.renderSize = size
        c.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(60, fps.rounded()))))
        c.instructions = [LookInstruction(range: CMTimeRange(start: .zero, duration: duration), trackID: track.trackID,
                                          orientation: orientation, box: box)]
        return c
    }

    /// How a track's transform turns its frames, as an image orientation (phone videos are stored sideways).
    static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(t.b, t.a) * 180 / .pi
        switch angle.rounded() {
        case 90: return .right
        case -90: return .left
        case 180, -180: return .down
        default: return .up
        }
    }
}
