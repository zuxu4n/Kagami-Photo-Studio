import Foundation
import CoreGraphics

/// Finds and follows faces in camera frames. Apple Vision (with the mesh placed on each new face) runs now and then on
/// its own queue to find faces; between those, each face's 478-point mesh is carried from frame to frame with one
/// mesh pass on the crop the last frame's mesh places, as MediaPipe's own tracking does. The points are steadied
/// with a One Euro filter, so a still face doesn't shimmer and a moving one doesn't lag.
final class LiveFaceTracker {
    private struct Tracked {
        var raw: [CGPoint]      // the last mesh, frame pixels; places the next crop
        var depth: [CGFloat]    // towards the camera, frame pixels
        var filter = OneEuro()
        var shown: [Double] = []   // steadied x, y pairs then depths
    }

    private var tracked: [Tracked] = []
    private var pending: [(points: [CGPoint], depth: [CGFloat])]?   // a finished detection, merged on the next frame
    private var detecting = false
    private var framesSinceDetect = 0
    private let lock = NSLock()
    private let detectQueue = DispatchQueue(label: "camera.detect", qos: .userInitiated)
    let maxFaces = 3

    /// Forgets every face (after the camera is switched).
    func reset() {
        lock.lock(); pending = nil; lock.unlock()
        tracked = []
    }

    /// The faces in this frame (`img`, at `time` seconds), normalised to the frame, biggest first.
    func update(_ img: RGBAImage, time: Double) -> [FaceGeometry] {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        lock.lock()
        let found = pending
        pending = nil
        lock.unlock()
        if let found {
            for f in found where tracked.count < maxFaces {
                let c = centre(f.points)
                if !tracked.contains(where: { bounds($0.raw).insetBy(dx: -4, dy: -4).contains(c) }) {
                    tracked.append(Tracked(raw: f.points, depth: f.depth))
                }
            }
        }
        var kept: [Tracked] = []
        for var t in tracked {
            guard let m = try? FaceMeshEngine.shared.track(in: img, previous: t.raw) else { continue }
            let c = centre(m.points)
            if kept.contains(where: { bounds($0.raw).contains(c) }) { continue }   // two tracks have landed on one face
            t.raw = m.points
            t.depth = m.depth
            t.shown = t.filter.filter(m.points.flatMap { [Double($0.x), Double($0.y)] } + m.depth.map { Double($0) }, time: time)
            kept.append(t)
        }
        tracked = kept

        // Look for faces again: often while there are none, and once a second for faces that walk in.
        framesSinceDetect += 1
        if framesSinceDetect >= (tracked.isEmpty ? 3 : 30) {
            framesSinceDetect = 0
            lock.lock()
            let busy = detecting
            if !busy { detecting = true }
            lock.unlock()
            if !busy {
                detectQueue.async { [weak self] in
                    let faces = FaceAnalyzer.detect(img.cgImage())
                    let found = faces.filter { $0.mesh.count == 478 }.map { f in
                        (points: f.mesh.map { CGPoint(x: $0.x * w, y: $0.y * h) }, depth: f.meshDepth.map { $0 * w })
                    }
                    guard let self else { return }
                    self.lock.lock()
                    self.pending = found
                    self.detecting = false
                    self.lock.unlock()
                }
            }
        }

        return tracked.map { t in
            let n = 478
            let pts = (0..<n).map { CGPoint(x: t.shown[$0 * 2] / Double(w), y: t.shown[$0 * 2 + 1] / Double(h)) }
            let depth = (0..<n).map { CGFloat(t.shown[2 * n + $0]) / w }
            return LiveFaceTracker.geometry(mesh: pts, depth: depth)
        }.sorted { $0.box.width > $1.box.width }
    }

    private func centre(_ p: [CGPoint]) -> CGPoint { let b = bounds(p); return CGPoint(x: b.midX, y: b.midY) }
    private func bounds(_ p: [CGPoint]) -> CGRect {
        let xs = p.map(\.x), ys = p.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// A face's geometry built from its mesh alone (normalised points), with the outline, eyes, brows, lips and nose
    /// that Apple Vision would give taken from the mesh, so Smooth and Retouch masks need no Vision pass per frame.
    static func geometry(mesh m: [CGPoint], depth: [CGFloat]) -> FaceGeometry {
        let oval = FaceAnalyzer.faceOval.map { m[$0] }
        let xs = oval.map(\.x), ys = oval.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let eyes = FaceAnalyzer.meshEyes.map { e in ([e.outer] + e.upper + [e.inner] + e.lower.reversed()).map { m[$0] } }
        let brows = FaceAnalyzer.meshBrows.map { b in (b.upper + b.lower.reversed()).map { m[$0] } }
        let nose = [168, 6, 197, 195, 5, 4, 1, 19, 94, 2, 98, 327, 129, 358].map { m[$0] }
        var g = FaceGeometry(box: box, contour: FaceAnalyzer.lowerOutline.map { m[$0] }, leftEye: eyes[0], rightEye: eyes[1],
                             leftBrow: brows[0], rightBrow: brows[1], outerLips: FaceAnalyzer.outerLips.map { m[$0] }, nose: nose)
        g.mesh = m
        g.meshDepth = depth
        return g
    }
}

/// The One Euro filter (Casiez, Roussel and Vogel, 2012) over a whole face at once: smooths hard when the face is
/// still, and less as it moves faster, so jitter goes without making movement lag. The speed is the face's average,
/// so every point is smoothed alike and the face keeps its shape.
struct OneEuro {
    var minCutoff = 1.2     // Hz, when still
    var beta = 0.02         // how fast the cutoff rises with speed (per pixel a second)
    var dCutoff = 1.0       // Hz, for the speed itself
    private var x: [Double] = []
    private var speed = 0.0
    private var last = 0.0

    mutating func filter(_ v: [Double], time t: Double) -> [Double] {
        guard x.count == v.count, t > last else { x = v; last = t; speed = 0; return v }
        let dt = t - last
        last = t
        func alpha(_ cutoff: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }
        let pairs = min(v.count / 2, 478)
        var moved = 0.0
        for i in 0..<pairs { moved += hypot(v[2 * i] - x[2 * i], v[2 * i + 1] - x[2 * i + 1]) }
        let raw = moved / Double(max(pairs, 1)) / dt
        speed += alpha(dCutoff) * (raw - speed)
        let a = alpha(minCutoff + beta * speed)
        for i in v.indices { x[i] += a * (v[i] - x[i]) }
        return x
    }
}
