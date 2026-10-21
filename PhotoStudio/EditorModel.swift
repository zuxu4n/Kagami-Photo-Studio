import SwiftUI
import Photos

enum Tool: String, CaseIterable, Identifiable {
    case enhance = "Enhance", smooth = "Smooth", retouch = "Retouch", blur = "Background", heal = "Heal", face = "Face", reshape = "Reshape"
    var id: String { rawValue }
}

/// Holds the photo and runs every tool on the device. Enhance and Heal change the working image.
/// Smooth and Face shape are live sliders, rendered on a preview and again at full size on Save.
@MainActor
final class EditorModel: ObservableObject {
    @Published var display: UIImage?
    @Published var original: UIImage?
    @Published var busy: String?
    @Published var error: String?
    @Published var tool: Tool = .enhance
    @Published var smooth: Float = 0
    @Published var slim: Float = 0          // Jawline; every Face slider shows the selected face's values
    @Published var eyes: Float = 0
    @Published var eyeWidth: Float = 0
    @Published var eyeHeight: Float = 0
    @Published var eyeTilt: Float = 0
    @Published var eyeDistance: Float = 0
    @Published var nose: Float = 0
    @Published var noseSize: Float = 0
    @Published var noseWidth: Float = 0
    @Published var noseLift: Float = 0
    @Published var noseTip: Float = 0
    @Published var size: Float = 0          // size, width, perspective, jaw, chin, lips, smile, smirk and forehead use the MediaPipe face mesh
    @Published var width: Float = 0
    @Published var headHeight: Float = 0
    @Published var perspective: Float = 0
    @Published var positionX: Float = 0     // Position: the oval's place across and down the face, in half-widths and half-heights
    @Published var positionY: Float = 0
    @Published var jaw: Float = 0
    @Published var chin: Float = 0
    @Published var jawSize: Float = 0
    @Published var define: Float = 0
    @Published var jawLength: Float = 0
    @Published var lips: Float = 0
    @Published var lipSize: Float = 0
    @Published var lipWidth: Float = 0
    @Published var browThick: Float = 0
    @Published var browLift: Float = 0
    @Published var browShape: Float = 0
    @Published var browTilt: Float = 0
    @Published var browRaise: Float = 0
    @Published var smile: Float = 0
    @Published var smirk: Float = 0
    @Published var forehead: Float = 0
    @Published var teeth: Float = 0         // Retouch: whiten teeth, brighten eyes, even skin tone (the selected face's values)
    @Published var brightEyes: Float = 0
    @Published var tone: Float = 0
    @Published var blur: Float = 0          // Blur: background blur strength, 0...1
    @Published private(set) var findingPeople = false
    @Published var brush: Float = 0.025      // heal brush radius as a fraction of the image width
    @Published var faceCount = 0
    var reshaping: Bool { tool == .reshape }  // the Reshape tab: a one-finger drag on a face pushes it
    @Published var reshapeSize: Float = 0.22  // Reshape brush radius as a fraction of the face's width
    @Published var reshapeStrength: Float = 1 // how far the content moves for each point the finger moves
    @Published var timings: [(String, Double)] = []
    @Published var info: String = ""

    private(set) var working: RGBAImage?     // full resolution, after Enhance/Heal
    private(set) var preview: RGBAImage? { didSet { sourceVersion &+= 1 } }   // long side <= previewSide, for live sliders
    @Published private(set) var faces: [FaceGeometry] = [] { didSet { sourceVersion &+= 1 } }
    private(set) var sourceVersion = 0       // changes with the preview photo or the faces, so cached renders aren't reused
    @Published private(set) var selectedFace: Int?   // the face the Face and Reshape tabs edit
    private var shapes: [FaceShape] = []             // Face tab values for each face, same order as `faces`
    private var smoothed: (version: Int, smooth: Float, retouch: [FaceRetouch], image: RGBAImage)?  // the preview after Smooth and Retouch, reused while Blur or Face values move
    private var blurred: (version: Int, smooth: Float, retouch: [FaceRetouch], blur: Float, edits: Int, cut: BackgroundChoice, image: RGBAImage)?  // and after Blur, reused while only Face values move
    /// The people on the working photo, found when Blur is first needed and again only after Enhance or Heal change it.
    @Published var personMatte: PersonMatte? { didSet { sourceVersion &+= 1 } }
    @Published var blurMode: BlurMode = .view
    @Published var blurBrush: Float = 0.04            // Blur › Brush and Erase radius as a fraction of the image width
    @Published var blurOverlay: UIImage?              // the people as they'll stay sharp, tinted while Brush or Erase is on
    @Published var blurPanel: BlurPanel = .blur
    @Published var background: BackgroundChoice = .off   // Blur › Remove background
    var removeOpened = false
    var blurEdits = MatteEdits.none { didSet { blurEditsVersion &+= 1 } }   // hand-painted fixes, see EditorModel+Blur
    private var blurEditsVersion = 0
    var blurStroke: (start: UndoStep, last: CGPoint?)?   // the Blur brush stroke under way
    var workingVersion = 0      // changes with the working photo, so a cutout found for an older one is dropped
    private var rendering = false       // a preview frame is being drawn
    private var renderAgain = false     // values changed while it was drawn
    private var lastPreviewLog: CFAbsoluteTime = 0
    private var dragFrames = (count: 0, start: CFAbsoluteTime(0))   // frames shown during the current slider drag
    @Published var enhanceOn = false
    private var unenhanced: RGBAImage?  // the photo as it was before Enhance, kept while Enhance is on
    private var enhancedFull: RGBAImage?   // Enhance's own output, kept while Enhance is on, so Strength can blend again
    private var enhanceBase: RGBAImage?    // `unenhanced` at the enhanced size: Strength 0
    @Published var enhanceStrength: Float = 0.7   // how much of Enhance's output is shown over the photo before it
    let enhanceStrengthDefault: Float = 0.7
    private var strengthDrag: (base: RGBAImage, enhanced: RGBAImage, start: Float)?  // preview-size copies while dragging
    var healsSinceEnhance: [HealRecord] = []  // replayed on `unenhanced` when Enhance goes off
    // Heal › People, Brush and Erase: the area picked to remove, on the preview (see EditorModel+Remove.swift).
    @Published var healMode: HealMode = .spot
    @Published var selectionOverlay: UIImage?
    @Published var hasSelection = false
    var selection: [UInt8] = []
    var people: (version: Int, masks: [[UInt8]])?   // the person cutouts on the current preview
    var peopleTask: Task<[[UInt8]], Never>?
    var largeWarmed = false                         // LaMa 1024 loads the first time People, Brush or Erase opens
    var brushStroke: CGPoint?                       // the last point of the brush stroke under way
    var lastOverlay: CFAbsoluteTime = 0
    private var warmedUp = false
    private var history = UndoHistory()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var sliderStart: UndoStep?  // the state when a slider drag began
    private var reshape: (start: UndoStep, face: Int, base: [FacePush], anchor: CGPoint, r: CGFloat, strength: CGFloat, added: [FacePush],
                          sliders: [WarpOp])?  // the Reshape drag under way, with the slider warp it's made under

    let maxWorkingSide = 4032
    let previewSide = 1600

    var hasImage: Bool { working != nil }
    var previewSize: CGSize { preview.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    /// Outline guides for the Face and Reshape tabs, on every face, each following its own Slim, Jaw and Chin values and pushes.
    /// `selected` marks the face the sliders change. `minGap` is the smallest gap between a face and its guide, in preview pixels.
    func faceGuides(minGap: CGFloat) -> [(curves: [[CGPoint]], selected: Bool)] {
        guard let prev = preview else { return [] }
        return faces.indices.map { i in
            var s = i < shapes.count ? shapes[i] : FaceShape()
            if i == selectedFace { s = sliderShape(keeping: s) }
            return (FaceAnalyzer.guideCurves(for: faces[i], width: prev.width, height: prev.height, shape: s, minGap: minGap), i == selectedFace)
        }
    }

    /// Whether the selected face has the MediaPipe mesh that every Face slider but Slim jawline, Eyes and Nose needs.
    var selectedHasMesh: Bool { selectedFace.map { $0 < faces.count && !faces[$0].mesh.isEmpty } ?? false }

    // MARK: Which face the Face and Reshape tabs edit

    /// Selects the face whose area holds `point` (preview pixels) and shows its own slider values.
    /// Where face areas overlap, the face whose centre is nearest wins. A tap outside every face changes nothing.
    func selectFace(at point: CGPoint) {
        guard let i = faceIndex(at: point), i != selectedFace else { return }
        storeShape()
        selectedFace = i
        showSliders(shapes[i])
        renderPreview()
    }

    /// The face whose area holds `point` (preview pixels), nearest centre first where areas overlap.
    private func faceIndex(at point: CGPoint) -> Int? {
        guard let prev = preview else { return nil }
        let p = CGPoint(x: point.x / CGFloat(prev.width), y: point.y / CGFloat(prev.height))
        let hits = faces.indices.filter { faces[$0].box.insetBy(dx: -faces[$0].box.width * 0.15, dy: -faces[$0].box.height * 0.15).contains(p) }
        return hits.min(by: { centreDistance(faces[$0], p) < centreDistance(faces[$1], p) })
    }

    private func centreDistance(_ f: FaceGeometry, _ p: CGPoint) -> CGFloat { hypot(f.box.midX - p.x, f.box.midY - p.y) }

    /// Keeps the sliders' values as the selected face's own.
    private func storeShape() {
        guard let i = selectedFace, i < shapes.count else { return }
        shapes[i] = sliderShape(keeping: shapes[i])
    }

    /// `base` (for its pushes) with the sliders' current values.
    private func sliderShape(keeping base: FaceShape) -> FaceShape {
        var v = base
        v.slim = slim; v.eyes = eyes; v.nose = nose
        v.eyeWidth = eyeWidth; v.eyeHeight = eyeHeight; v.eyeTilt = eyeTilt; v.eyeDistance = eyeDistance
        v.noseSize = noseSize; v.noseWidth = noseWidth; v.noseLift = noseLift; v.noseTip = noseTip
        v.size = size; v.width = width; v.headHeight = headHeight; v.perspective = perspective; v.positionX = positionX; v.positionY = positionY
        v.jaw = jaw; v.chin = chin; v.jawSize = jawSize; v.define = define; v.jawLength = jawLength; v.lips = lips; v.lipSize = lipSize; v.lipWidth = lipWidth;
        v.browThick = browThick; v.browLift = browLift; v.browShape = browShape; v.browTilt = browTilt; v.browRaise = browRaise; v.smile = smile; v.smirk = smirk; v.forehead = forehead
        v.retouch = FaceRetouch(teeth: teeth, eyes: brightEyes, tone: tone)
        return v
    }

    /// Shows a face's own values on the sliders.
    private func showSliders(_ v: FaceShape) {
        slim = v.slim; eyes = v.eyes; nose = v.nose
        eyeWidth = v.eyeWidth; eyeHeight = v.eyeHeight; eyeTilt = v.eyeTilt; eyeDistance = v.eyeDistance
        noseSize = v.noseSize; noseWidth = v.noseWidth; noseLift = v.noseLift; noseTip = v.noseTip
        size = v.size; width = v.width; headHeight = v.headHeight; perspective = v.perspective; positionX = v.positionX; positionY = v.positionY
        jaw = v.jaw; chin = v.chin; jawSize = v.jawSize; define = v.define; jawLength = v.jawLength; lips = v.lips; lipSize = v.lipSize; lipWidth = v.lipWidth;
        browThick = v.browThick; browLift = v.browLift; browShape = v.browShape; browTilt = v.browTilt; browRaise = v.browRaise; smile = v.smile; smirk = v.smirk; forehead = v.forehead
        teeth = v.retouch.teeth; brightEyes = v.retouch.eyes; tone = v.retouch.tone
    }

    /// Starts the Face tab on the biggest face, with every face's sliders at zero.
    private func resetFaces() {
        shapes = Array(repeating: FaceShape(), count: faces.count)
        selectedFace = faces.indices.max(by: { faces[$0].box.width < faces[$1].box.width })
        showSliders(FaceShape())
    }

    /// After faces are found again (Enhance on or off), gives each new face the values of the old face nearest it,
    /// so settings and the selection stay with the same person.
    private func carryShapes(to found: [FaceGeometry]) {
        storeShape()
        let old = faces, oldShapes = shapes, oldSel = selectedFace
        func nearest(_ f: FaceGeometry) -> Int? {
            let c = CGPoint(x: f.box.midX, y: f.box.midY)
            return old.indices.filter { centreDistance(old[$0], c) < max(old[$0].box.width, f.box.width) * 0.5 }
                .min(by: { centreDistance(old[$0], c) < centreDistance(old[$1], c) })
        }
        let match = found.map(nearest)
        faces = found
        shapes = match.map { $0.map { oldShapes[$0] } ?? FaceShape() }
        selectedFace = match.firstIndex(where: { $0 != nil && $0 == oldSel })
            ?? found.indices.max(by: { found[$0].box.width < found[$1].box.width })
        showSliders(selectedFace.map { shapes[$0] } ?? FaceShape())
    }

    // MARK: Reshape (drag a face to push it)

    /// Starts a Reshape drag at `point` (preview pixels) on the face under it, selecting that face first.
    /// Returns false when the finger isn't on a face, so the drag can pan instead.
    func beginReshape(at point: CGPoint) -> Bool {
        guard busy == nil, reshape == nil, let i = faceIndex(at: point), let prev = preview else { return false }
        if i != selectedFace {
            storeShape()
            selectedFace = i
            showSliders(shapes[i])
        }
        // Size and strength are read once, so moving them mid-drag can't change a push already under way.
        let r = faces[i].box.width * CGFloat(reshapeSize) * CGFloat(prev.width)
        // Pushes go under the sliders, so a slider moved later carries them along. The slider warp is read once here.
        let noPushes = shapes.map { var s = $0; s.pushes = []; return s }
        let sliders = FaceAnalyzer.warpOps(faces: faces, shapes: noPushes, width: prev.width, height: prev.height)
        reshape = (undoStep(.unchanged), i, shapes[i].pushes, point, r, CGFloat(reshapeStrength), [], sliders)
        return true
    }

    /// Follows the finger (preview pixels). The path is cut into steps of under half the push radius, each pushing
    /// the content from the previous step to the next, so a long or curved drag carries the face along without folding.
    func moveReshape(to point: CGPoint) {
        guard var d = reshape, let prev = preview, d.face < shapes.count else { return }
        let W = CGFloat(prev.width), H = CGFloat(prev.height)
        let step = d.r * 0.45
        // Pushes this drag may add: the overall limit less every other push (on all faces, and this face's earlier drags).
        let room = FaceAnalyzer.maxPushes - shapes.reduce(0) { $0 + $1.pushes.count } + (shapes[d.face].pushes.count - d.base.count)
        // The finger moves over the photo as the sliders show it; each push is placed where that content sits
        // before the sliders.
        func push(_ a: CGPoint, _ b: CGPoint) -> FacePush {
            let sa = FaceAnalyzer.sliderSource(SIMD2(Float(a.x), Float(a.y)), d.sliders)
            let sb = FaceAnalyzer.sliderSource(SIMD2(Float(b.x), Float(b.y)), d.sliders)
            return FacePush(x: sa.x / Float(W), y: sa.y / Float(H), r: Float(d.r / W),
                            dx: (sb.x - sa.x) * Float(d.strength / W), dy: (sb.y - sa.y) * Float(d.strength / W))
        }
        while hypot(point.x - d.anchor.x, point.y - d.anchor.y) > step, d.added.count < room - 1 {
            let len = hypot(point.x - d.anchor.x, point.y - d.anchor.y)
            let next = CGPoint(x: d.anchor.x + (point.x - d.anchor.x) * step / len, y: d.anchor.y + (point.y - d.anchor.y) * step / len)
            d.added.append(push(d.anchor, next))
            d.anchor = next
        }
        if d.added.count >= room - 1 { info = "Reshape limit reached · undo or reset a face to push more" }
        // The rest of the way to the finger, redone on every move until it's a full step.
        let tail = hypot(point.x - d.anchor.x, point.y - d.anchor.y) > 0.5 && d.added.count < room ? [push(d.anchor, point)] : []
        reshape = d
        shapes[d.face].pushes = d.base + d.added + tail
        renderPreview()
    }

    /// Ends the drag as one undo step.
    func endReshape() {
        guard let d = reshape else { return }
        reshape = nil
        storeShape()
        if d.start.shapes != shapes || d.start.selectedFace != selectedFace { pushUndo(d.start) }
    }

    /// Drops the drag under way (a second finger turned it into a pinch).
    func cancelReshape() {
        guard let d = reshape else { return }
        reshape = nil
        if d.face < shapes.count { shapes[d.face].pushes = d.base }
        renderPreview()
    }

    /// Removes the selected face's Reshape pushes (one undo step).
    func resetReshape() {
        guard let i = selectedFace, i < shapes.count, !shapes[i].pushes.isEmpty else { return }
        pushUndo(undoStep(.unchanged))
        shapes[i].pushes = []
        renderPreview()
    }

    /// The Reshape brush radius on the selected face, as a fraction of the photo's width (for the size ring).
    var reshapeRadiusFraction: CGFloat { selectedFace.map { faces[$0].box.width * CGFloat(reshapeSize) } ?? 0 }

    var selectedHasPushes: Bool { selectedFace.map { $0 < shapes.count && !shapes[$0].pushes.isEmpty } ?? false }

    // MARK: Position (drag an oval around the head to turn it)

    private var positionDrag: (face: Int, start: SIMD2<Float>)?   // the face and the oval's place when the drag began

    /// How far out the oval can go, in half-widths and half-heights of the face (1 = on the outline).
    let positionReach: Float = 1.7

    /// The Position oval on the selected face: its centre in normalised photo coordinates (0...1), its long and short
    /// radii (fractions of the photo's width) and the direction of its short axis (radians, y down). It's drawn like a
    /// disc on the surface of the head facing out from its middle: round in the middle of the face, flatter towards
    /// the outline and beyond, with the short axis pointing at the middle. Nil when the face has no mesh.
    func positionHandle() -> (puck: CGPoint, major: CGFloat, minor: CGFloat, angle: CGFloat)? {
        guard let i = selectedFace, i < faces.count, let prev = preview,
              let o = FaceAnalyzer.positionFrame(for: faces[i], width: prev.width, height: prev.height) else { return nil }
        let W = CGFloat(prev.width), H = CGFloat(prev.height)
        let offset = o.across * o.ra * positionX + o.down * o.rb * positionY
        let puck = o.centre + offset
        let d = hypot(positionX, positionY)
        let major = CGFloat(o.ra) * 0.4 / W
        return (CGPoint(x: CGFloat(puck.x) / W, y: CGFloat(puck.y) / H), major, major * CGFloat(max(0.38, 1 - 0.5 * d * d)),
                CGFloat(atan2(offset.y, offset.x)))
    }

    /// Starts moving the selected face's Position oval: a drag anywhere moves it (a tap on another face picks that
    /// face). Returns false when there's nothing to move, so the drag can pan instead.
    func beginPosition() -> Bool {
        guard busy == nil, positionDrag == nil, let i = selectedFace, i < faces.count, !faces[i].mesh.isEmpty else { return false }
        sliderEditing(true)
        positionDrag = (i, SIMD2(positionX, positionY))
        return true
    }

    /// Moves the oval by the finger's travel since the drag began (preview pixels). It goes up to `positionReach`
    /// out from the middle of the face, and stays on the photo.
    func movePosition(by t: CGSize) {
        guard let d = positionDrag, let prev = preview, d.face < faces.count,
              let o = FaceAnalyzer.positionFrame(for: faces[d.face], width: prev.width, height: prev.height) else { return }
        let v = SIMD2(Float(t.width), Float(t.height))
        var p = d.start + SIMD2(simd_dot(v, o.across) / o.ra, simd_dot(v, o.down) / o.rb)
        if simd_length(p) > positionReach { p *= positionReach / simd_length(p) }
        // Pull it back along the same line if it would leave the photo.
        let u = o.across * o.ra * p.x + o.down * o.rb * p.y
        var k: Float = 1
        for (c, du, side) in [(o.centre.x, u.x, Float(prev.width)), (o.centre.y, u.y, Float(prev.height))] {
            if c + du > side { k = min(k, (side - c) / du) }
            if c + du < 0 { k = min(k, -c / du) }
        }
        p *= max(0, k)
        positionX = p.x
        positionY = p.y
    }

    /// Ends the drag as one undo step.
    func endPosition() {
        guard positionDrag != nil else { return }
        positionDrag = nil
        sliderEditing(false)
    }

    /// Puts the oval back where the drag began (a second finger turned it into a pinch).
    func cancelPosition() {
        guard let d = positionDrag else { return }
        positionX = d.start.x
        positionY = d.start.y
        positionDrag = nil
        sliderEditing(false)
    }

    /// Puts the selected face's oval back in the middle (one undo step).
    func resetPosition() {
        sliderEditing(true)
        positionX = 0
        positionY = 0
        sliderEditing(false)
    }

    var positionMoved: Bool { hypot(positionX, positionY) > 0.001 }

    // MARK: Warm-up at launch, so the first tap on each tool isn't slow

    /// Compiles the slider GPU code, then loads the Heal and Enhance models in the background, one at a time.
    /// A tap that needs a model while it's still loading waits for that load instead of starting another.
    func warmUp() async {
        guard !warmedUp else { return }
        warmedUp = true
        let (gpuMs, gpuPeak) = await Task.detached(priority: .userInitiated) { () -> (Double, Double) in
            let meter = MemoryMeter()
            let t0 = CFAbsoluteTimeGetCurrent()
            GPU.shared.warmUp()
            Retouch.shared.warmUp()
            return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
        }.value
        record("Warm-up: slider GPU code", gpuMs, peakMB: gpuPeak)
        await warmModel("Face mesh") { try FaceMeshEngine.shared.warmUp() }  // small, and needed as each photo opens
        let (cutMs, cutPeak) = await Task.detached(priority: .userInitiated) { () -> (Double, Double) in
            let meter = MemoryMeter()
            let t0 = CFAbsoluteTimeGetCurrent()
            BackgroundBlur.shared.warmUp()   // the person cutout's model load is the slow part
            return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
        }.value
        record("Warm-up: Blur and person cutout", cutMs, peakMB: cutPeak)
        await warmModel("Heal") { try HealEngine.shared.warmUp() }  // biggest first-use cost (about 3.5 s), so first
        await warmModel("Enhance") { try EnhanceEngine.shared.warmUp() }
        await warmModel("Enhance Neural Engine + GPU") { try EnhanceEngine.shared.warmUpSplit() }  // for 12 MP photos
    }

    private func warmModel(_ name: String, _ body: @escaping @Sendable () throws -> (load: Double, run: Double)?) async {
        let (times, peak, failure) = await Task.detached(priority: .userInitiated) { () -> ((load: Double, run: Double)?, Double, String?) in
            let meter = MemoryMeter()
            do { return (try body(), meter.stop(), nil) } catch { return (nil, meter.stop(), error.localizedDescription) }
        }.value
        if let failure {
            record("Warm-up: \(name) failed (\(failure))", 0, peakMB: peak)
        } else if let times {  // nil when a tap loaded the model first
            record("Warm-up: \(name) model", times.load + times.run, peakMB: peak,
                   extra: ["load_ms": times.load, "first_run_ms": times.run])
        }
    }

    /// Test builds: times the Enhance options on this phone (see EnhanceBench), keeping the screen awake meanwhile.
    func runEnhanceBench() async {
        busy = "Timing Enhance options… keep the app open"
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            busy = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let ok = await Task.detached(priority: .userInitiated) { EnhanceBench.runAndSave() }.value
        info = ok ? "Enhance timing done" : "Enhance timing failed"
    }

    func noteMemoryWarning() {
        record("Memory warning", 0)
    }

    // MARK: Loading

    func load(data: Data) async {
        busy = "Opening…"
        defer { busy = nil }
        let meter = MemoryMeter()
        let td = CFAbsoluteTimeGetCurrent()
        guard let ui = UIImage(data: data), let cg = ui.normalizedCGImage(maxSide: maxWorkingSide) else {
            error = "Couldn't read that photo."
            return
        }
        let decodeMs = (CFAbsoluteTimeGetCurrent() - td) * 1000
        let (full, prev, found, ms) = await Task.detached(priority: .userInitiated) { () -> (RGBAImage, RGBAImage, [FaceGeometry], Double) in
            let t0 = CFAbsoluteTimeGetCurrent()
            let full = RGBAImage(cgImage: cg)
            let prev = RGBAImage(cgImage: cg, maxSide: 1600)
            let found = FaceAnalyzer.detect(prev.cgImage())
            return (full, prev, found, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }.value
        working = full
        workingVersion &+= 1
        personMatte = nil
        blur = 0
        blurEdits = .none
        blurMode = .view
        background = .off
        removeOpened = false
        blurOverlay = nil
        preview = prev
        faces = found
        faceCount = found.count
        resetFaces()
        original = prev.uiImage()
        display = original
        smooth = 0
        smoothOpened = false
        enhanceOn = false
        unenhanced = nil
        enhancedFull = nil
        enhanceBase = nil
        healsSinceEnhance = []
        clearSelection()
        history.clear()
        canUndo = false
        canRedo = false
        toolShown(tool)
        info = "\(full.width)×\(full.height) · \(found.count) face(s)"
        record("Open + face landmarks", ms, peakMB: meter.stop(), extra: ["decode_ms": decodeMs])
    }

    // MARK: Where Smooth starts

    /// The Smooth slider's starting value the first time the Smooth tool is shown on a photo ((picked in testing)).
    /// Photos that never go into Smooth aren't smoothed.
    let smoothStart: Float = 0.3
    private var smoothOpened = false

    func toolShown(_ t: Tool) {
        if t == .blur { findPeople() }
        updateBlurOverlay()
        guard t == .smooth, !smoothOpened, hasImage else { return }
        smoothOpened = true
        if smooth < 0.001 { smooth = smoothStart }
    }

    // MARK: Enhance (Real-ESRGAN from the photo's own pixels, faces kept as they are; destructive)

    /// Enhance is a switch. The first tap enhances the photo; the next tap puts back the photo as it was before Enhance,
    /// with any spots healed since then healed again on it. So Enhance never runs on its own result.
    func runEnhance() async {
        if enhanceOn {
            await enhanceOff()
            return
        }
        guard let src = working else { return }
        busy = "Enhancing…"
        defer { busy = nil }
        let before = undoStep(.whole(src))
        let faces = self.faces, strength = enhanceStrength
        do {
            let (out, base, shown, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, RGBAImage, RGBAImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let engine = EnhanceEngine.shared
                let out = try engine.enhance(src, plan: engine.plan(width: src.width, height: src.height), faces: faces)
                let base = src.width == out.width && src.height == out.height ? src : src.scaled(toWidth: out.width, height: out.height)
                let shown = RGBAImage.blend(base, out, strength)
                return (out, base, shown, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Enhance (\(out.width)×\(out.height))", ms, peakMB: peak)
            pushUndo(before)
            unenhanced = src
            enhancedFull = out
            enhanceBase = base
            healsSinceEnhance = []
            enhanceOn = true
            await setWorking(shown)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func enhanceOff() async {
        guard var base = unenhanced else {
            enhanceOn = false
            return
        }
        busy = "Turning Enhance off…"
        defer { busy = nil }
        let before = working.map { undoStep(.whole($0)) }
        let heals = healsSinceEnhance
        do {
            let (out, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                for h in heals { try h.redo(on: &base) }
                return (base, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Enhance off (\(heals.count) heal(s) redone)", ms, peakMB: peak)
            if let before { pushUndo(before) }
            unenhanced = nil
            enhancedFull = nil
            enhanceBase = nil
            healsSinceEnhance = []
            enhanceOn = false
            await setWorking(out)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Enhance strength (a blend of the photo before Enhance and Enhance's output)

    /// The finger went down on the Strength slider: makes preview-size copies of both ends to blend live. Spots healed
    /// since Enhance are copied into both from the current preview, so they stay healed while the slider moves.
    func beginEnhanceStrength() {
        guard enhanceOn, strengthDrag == nil, let full = enhancedFull, let base = enhanceBase, let prev = preview else { return }
        var b = base.scaled(toWidth: prev.width, height: prev.height)
        var e = full.scaled(toWidth: prev.width, height: prev.height)
        for case let .area(mask, mw, mh) in healsSinceEnhance {
            // Removed areas: their pixels as healed now, on both ends.
            let m = mw == prev.width && mh == prev.height ? mask : MaskOps.resize(mask, w: mw, h: mh, to: prev.width, prev.height)
            let grown = MaskOps.dilate(m.map { $0 > 127 ? 255 : 0 }, w: prev.width, h: prev.height, r: 4)
            for i in grown.indices where grown[i] > 0 {
                for c in 0..<4 { b.pixels[i * 4 + c] = prev.pixels[i * 4 + c]; e.pixels[i * 4 + c] = prev.pixels[i * 4 + c] }
            }
        }
        for case let .spot(center, brush) in healsSinceEnhance {
            let h = (center: center, brush: brush)
            let r = Int(h.brush * Double(prev.width) * 1.5) + 2
            let cx = Int(h.center.x * CGFloat(prev.width)), cy = Int(h.center.y * CGFloat(prev.height))
            for y in max(0, cy - r)...min(prev.height - 1, cy + r) {
                for x in max(0, cx - r)...min(prev.width - 1, cx + r) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
                    let o = (y * prev.width + x) * 4
                    for c in 0..<4 { b.pixels[o + c] = prev.pixels[o + c]; e.pixels[o + c] = prev.pixels[o + c] }
                }
            }
        }
        strengthDrag = (b, e, enhanceStrength)
    }

    /// Shows the blend at the slider's value while it moves.
    func dragEnhanceStrength() {
        guard let d = strengthDrag else { return }
        preview = RGBAImage.blend(d.base, d.enhanced, enhanceStrength)
        renderPreview()
    }

    /// The finger lifted: blends the full-size photo at the new strength and heals again the spots healed since
    /// Enhance (one undo step).
    func applyEnhanceStrength() async {
        guard let d = strengthDrag, let full = enhancedFull, let base = enhanceBase, let current = working else { return }
        strengthDrag = nil
        guard abs(enhanceStrength - d.start) > 0.001 else {
            await setWorking(current, redetectFaces: false)
            return
        }
        busy = "Applying strength…"
        defer { busy = nil }
        var before = undoStep(.whole(current))
        before.enhanceStrength = d.start
        let strength = enhanceStrength, heals = healsSinceEnhance
        do {
            let (out, ms) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Double) in
                let t0 = CFAbsoluteTimeGetCurrent()
                var out = RGBAImage.blend(base, full, strength)
                for h in heals { try h.redo(on: &out) }
                return (out, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }.value
            record("Enhance strength \(Int(strength * 100))% (\(heals.count) heal(s) redone)", ms)
            pushUndo(before)
            await setWorking(out, redetectFaces: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Heal (LaMa, destructive)

    /// `point` is in preview pixel coordinates.
    func heal(at point: CGPoint) async {
        guard var img = working, let prev = preview else { return }
        busy = "Healing…"
        defer { busy = nil }
        let center = CGPoint(x: point.x / CGFloat(prev.width), y: point.y / CGFloat(prev.height))
        let brushFraction = Double(brush)
        var before = undoStep(.unchanged)
        do {
            let (out, radius, undo, ms, peak) = try await Task.detached(priority: .userInitiated) { () -> (RGBAImage, Int, PixelUndo, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let old = img
                let radius = try EditorModel.healSpot(&img, center: center, brush: brushFraction)
                // Keep only the pixels the heal changed, for undo.
                let undo = img.changedRect(from: old).map { PixelUndo.patch(x: Int($0.minX), y: Int($0.minY), old.crop($0)) } ?? .unchanged
                return (img, radius, undo, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            record("Heal spot r=\(radius)px", ms, peakMB: peak)
            before.pixels = undo
            pushUndo(before)
            if enhanceOn { healsSinceEnhance.append(.spot(center: center, brush: brushFraction)) }
            await setWorking(out, redetectFaces: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Heals one round spot. `center` is normalised (0...1) and `brush` is the radius as a fraction of the image width,
    /// so the same tap can be redone on another version of the photo. Returns the radius in pixels.
    nonisolated static func healSpot(_ img: inout RGBAImage, center: CGPoint, brush: Double) throws -> Int {
        try HealEngine.healSpot(&img, center: center, brush: brush)
    }

    /// `matte`: the people already found on `img` (Undo and Redo), so the cutout isn't made again.
    func setWorking(_ img: RGBAImage, redetectFaces: Bool = true, matte: PersonMatte? = nil) async {
        let prevSide = previewSide
        let detect = redetectFaces
        let (prev, found) = await Task.detached(priority: .userInitiated) { () -> (RGBAImage, [FaceGeometry]?) in
            let prev = RGBAImage(cgImage: img.cgImage(), maxSide: prevSide)
            return (prev, detect ? FaceAnalyzer.detect(prev.cgImage()) : nil)
        }.value
        working = img
        workingVersion &+= 1
        personMatte = matte   // Enhance and Heal change the pixels; the cutout is made again when Blur needs it
        findPeopleIfNeeded()
        preview = prev
        if let found {
            carryShapes(to: found)
            faceCount = found.count
        }
        info = "\(img.width)×\(img.height) · \(faceCount) face(s)"
        renderPreview()
    }

    // MARK: Undo

    func undoStep(_ pixels: PixelUndo) -> UndoStep {
        storeShape()
        return UndoStep(pixels: pixels, enhanceOn: enhanceOn, unenhanced: unenhanced, enhancedFull: enhancedFull, enhanceBase: enhanceBase,
                        enhanceStrength: enhanceStrength, healsSinceEnhance: healsSinceEnhance,
                        faces: faces, shapes: shapes, selectedFace: selectedFace, smooth: smooth, blur: blur, personMatte: personMatte, blurEdits: blurEdits, background: background)
    }

    func pushUndo(_ step: UndoStep) {
        history.push(step)
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// A slider drag is one undo step: the values from when the finger went down.
    func sliderEditing(_ editing: Bool) {
        if editing {
            sliderStart = undoStep(.unchanged)
            dragFrames = (0, CFAbsoluteTimeGetCurrent())
        } else if let start = sliderStart {
            sliderStart = nil
            let secs = CFAbsoluteTimeGetCurrent() - dragFrames.start
            if secs > 0.3 {
                record("Slider drag: \(dragFrames.count) frames, \(Int(Double(dragFrames.count) / secs)) per second", secs * 1000)
            }
            storeShape()
            if start.smooth != smooth || start.blur != blur || start.shapes != shapes { pushUndo(start) }
        }
    }

    /// Puts back the photo, the Enhance switch and the slider values from before the last change.
    func undo() async {
        guard busy == nil, working != nil, let step = history.pop() else { return }
        let back = await restore(step, label: "Undo")
        history.pushRedo(back)
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// Puts back the last change that was undone.
    func redo() async {
        guard busy == nil, working != nil, let step = history.popRedo() else { return }
        let back = await restore(step, label: "Redo")
        history.pushUndo(back)
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// Applies `step` and returns the step that reverses it (the state just before, with the same pixels saved).
    private func restore(_ step: UndoStep, label: String) async -> UndoStep {
        let t0 = CFAbsoluteTimeGetCurrent()
        let current = working!
        let reverse: PixelUndo
        switch step.pixels {
        case .unchanged: reverse = .unchanged
        case .whole: reverse = .whole(current)
        case .patch(let x, let y, let old): reverse = .patch(x: x, y: y, current.crop(CGRect(x: x, y: y, width: old.width, height: old.height)))
        }
        let back = undoStep(reverse)
        enhanceOn = step.enhanceOn
        unenhanced = step.unenhanced
        enhancedFull = step.enhancedFull
        enhanceBase = step.enhanceBase
        enhanceStrength = step.enhanceStrength
        healsSinceEnhance = step.healsSinceEnhance
        faces = step.faces
        faceCount = step.faces.count
        shapes = step.shapes
        selectedFace = step.selectedFace
        showSliders(step.selectedFace.map { shapes[$0] } ?? FaceShape())
        smooth = step.smooth
        blur = step.blur
        blurEdits = step.blurEdits
        background = step.background
        if case .unchanged = step.pixels, let m = step.personMatte { personMatte = m }
        defer {
            // The people as they were with those fixes, or made again from the cutout if the step didn't hold them.
            if let m = personMatte, m.edits != blurEdits { rebuildEditedMatte() }
            updateBlurOverlay()
        }
        switch step.pixels {
        case .unchanged:
            renderPreview()
        case .whole(let old):
            busy = label == "Undo" ? "Undoing…" : "Redoing…"
            defer { busy = nil }
            await setWorking(old, redetectFaces: false, matte: step.personMatte)
        case .patch(let x, let y, let old):
            busy = label == "Undo" ? "Undoing…" : "Redoing…"
            defer { busy = nil }
            var img = current
            img.paste(old, x: x, y: y)
            await setWorking(img, redetectFaces: false, matte: step.personMatte)
        }
        record(label, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        return back
    }

    // MARK: Live sliders (Smooth, Face shape)

    /// Draws the preview with the current values. Frames are drawn one after another: a change made while a frame
    /// is drawn is picked up as soon as it's done, with the values as they are by then. So a dragged slider updates
    /// continuously instead of each new tick throwing away the frame in progress.
    func renderPreview() {
        guard let prev = preview else { return }
        storeShape()
        if rendering {
            renderAgain = true
            return
        }
        rendering = true
        renderAgain = false
        let smooth = self.smooth, shapes = self.shapes, faces = self.faces, version = sourceVersion
        let retouch = shapes.map(\.retouch)
        if blur > 0.001 || background != .off, personMatte == nil { findPeople() }   // blurs once the people are found
        let matte = personMatte, blur = matte == nil ? 0 : self.blur, edits = blurEdits, editsVersion = blurEditsVersion
        let cut = matte == nil ? nil : background.previewMode, cutKey = matte == nil ? BackgroundChoice.off : background
        let cached = smoothed.flatMap { $0.version == version && $0.smooth == smooth && $0.retouch == retouch ? $0.image : nil }
        let cachedBlur = blurred.flatMap { $0.version == version && $0.smooth == smooth && $0.retouch == retouch && $0.blur == blur && $0.edits == editsVersion && $0.cut == cutKey ? $0.image : nil }
        Task {
            let (base, withBlur, img, ms, peak) = await Task.detached(priority: .userInitiated) { () -> (RGBAImage, RGBAImage, UIImage, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                let base = cached ?? EditorModel.apply(prev, faces: faces, smooth: smooth, shapes: shapes, warp: false)
                let withBlur = cachedBlur ?? EditorModel.apply(base, faces: faces, smooth: 0, shapes: shapes, retouch: false,
                                                               blur: blur, matte: matte, edits: edits, cut: cut, warp: false)
                let out = EditorModel.apply(withBlur, faces: faces, smooth: 0, shapes: shapes, retouch: false)
                let ui = out.uiImage()
                return (base, withBlur, ui, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            rendering = false
            if version == sourceVersion {   // a new photo or new faces make this frame stale; the next one replaces it
                smoothed = (version, smooth, retouch, base)
                blurred = (version, smooth, retouch, blur, editsVersion, cutKey, withBlur)
                display = img
                dragFrames.count += 1
            }
            // Logged at most twice a second, so dragging doesn't rewrite the log file on every frame.
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPreviewLog > 0.5 {
                lastPreviewLog = now
                let reused = cachedBlur != nil ? " (Smooth + Blur reused)" : cached != nil ? " (Smooth reused)" : ""
                record("Preview render \(prev.width)×\(prev.height)\(blur > 0.001 ? " blur" : "")\(reused)", ms, peakMB: peak)
            }
            if renderAgain || version != sourceVersion { renderPreview() }
        }
    }

    /// Smooth, then Retouch, then Blur, then warp. Runs at any resolution because the face geometry and the people's
    /// matte are normalised. The preview does the first three once (`warp: false`) and reuses them while only the
    /// Face values move. Blur comes before the warp, on the photo's own layout where the cutout was made, so the warp
    /// then moves the sharp person and the blurred background together and they can't come apart.
    nonisolated static func apply(_ img: RGBAImage, faces: [FaceGeometry], smooth: Float, shapes: [FaceShape],
                                  retouch: Bool = true, blur: Float = 0, matte: PersonMatte? = nil, edits: MatteEdits? = nil,
                                  cut: CutMode? = nil, warp: Bool = true) -> RGBAImage {
        var out = img
        if smooth > 0.001, !faces.isEmpty {
            let s = min(1.0, 1024.0 / Double(max(img.width, img.height)))
            let mw = max(1, Int(Double(img.width) * s)), mh = max(1, Int(Double(img.height) * s))
            let mask = FaceAnalyzer.skinMask(faces: faces, width: mw, height: mh)
            let faceW = Float((faces.map { $0.box.width }.max() ?? 0.2)) * Float(img.width)
            out = GPU.shared.smooth(out, mask: mask, maskWidth: mw, maskHeight: mh, strength: smooth, radius: max(3, faceW / 40))
        }
        if retouch {
            out = Retouch.apply(out, faces: faces, retouch: shapes.map(\.retouch))
        }
        if let cut, let matte {   // Remove background takes the place of Blur
            out = BackgroundBlur.cutOut(out, matte: matte, mode: cut, edits: edits)
        } else if blur > 0.001, let matte {
            out = BackgroundBlur.apply(out, matte: matte, strength: blur, edits: edits)
        }
        if warp, shapes.contains(where: { !$0.isOff }) {
            let ops = FaceAnalyzer.warpOps(faces: faces, shapes: shapes, width: img.width, height: img.height)
            out = GPU.shared.warp(out, ops: ops)
        }
        return out
    }

    // MARK: Blur (find the people once per photo)

    /// Runs the person cutout on the working photo in the background, unless it's done or under way. The preview
    /// redraws with the blur when it's ready.
    func findPeople() {
        guard personMatte == nil, !findingPeople, let img = working else { return }
        findingPeople = true
        let version = workingVersion, edits = blurEdits
        Task {
            let (matte, ms, peak) = await Task.detached(priority: .userInitiated) { () -> (PersonMatte?, Double, Double) in
                let meter = MemoryMeter()
                let t0 = CFAbsoluteTimeGetCurrent()
                var m = try? BackgroundBlur.personMatte(img)
                if let found = m, !edits.isEmpty { m = BackgroundBlur.withEdits(found, edits, image: img) }   // fixes stay
                return (m, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
            }.value
            findingPeople = false
            guard version == workingVersion else { findPeopleIfNeeded(); return }   // the photo changed meanwhile
            guard let matte else { error = "Couldn't find the people in this photo."; return }
            record("Person cutout (\(matte.hasPerson ? "found" : "none"))", ms, peakMB: peak)
            personMatte = matte
            if matte.edits != blurEdits { rebuildEditedMatte() }   // painted while it was found
            updateBlurOverlay()
            renderPreview()
        }
    }

    private func findPeopleIfNeeded() {
        if tool == .blur || blur > 0.001 { findPeople() }
    }

    // MARK: Save

    func save() async {
        guard let img = working else { return }
        busy = "Saving…"
        defer { busy = nil }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            error = "Allow PhotoStudio to add photos in Settings to save."
            return
        }
        storeShape()
        let smooth = self.smooth, shapes = self.shapes, blur = self.blur, background = self.background
        let faces = self.faces, matte = self.personMatte, edits = blurEdits
        let (data, ms, peak) = await Task.detached(priority: .userInitiated) { () -> (Data?, Double, Double) in
            let meter = MemoryMeter()
            let t0 = CFAbsoluteTimeGetCurrent()
            var m = blur > 0.001 || background != .off ? (matte ?? (try? BackgroundBlur.personMatte(img))) : nil
            if let found = m, found.edits != edits { m = BackgroundBlur.withEdits(found, edits, image: img) }
            let data: Data?
            if background == .clear, let m {
                // See-through: the people's colours, plus their coverage warped the same way as the photo for alpha (PNG).
                var out = EditorModel.apply(img, faces: faces, smooth: smooth, shapes: shapes, matte: m, cut: .foreground)
                var alpha = BackgroundBlur.cutOut(img, matte: m, mode: .mask)
                if shapes.contains(where: { !$0.isOff }) {
                    alpha = GPU.shared.warp(alpha, ops: FaceAnalyzer.warpOps(faces: faces, shapes: shapes, width: img.width, height: img.height))
                }
                for k in 0..<(out.width * out.height) { out.pixels[k * 4 + 3] = alpha.pixels[k * 4] }
                data = out.uiImageWithAlpha().pngData()
            } else {
                let out = EditorModel.apply(img, faces: faces, smooth: smooth, shapes: shapes, blur: blur, matte: m, cut: background.previewMode)
                data = out.uiImage().jpegData(compressionQuality: 0.95)
            }
            return (data, (CFAbsoluteTimeGetCurrent() - t0) * 1000, meter.stop())
        }.value
        record("Full-size render + \(background == .clear ? "PNG" : "JPEG") (\(img.width)×\(img.height))", ms, peakMB: peak)
        guard let data else { error = "Couldn't encode the photo."; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            info = "Saved to Photos"
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Whether any Face slider (Position included) is moved on the selected face.
    var faceSlidersMoved: Bool {
        var v = sliderShape(keeping: FaceShape())
        v.retouch = FaceRetouch()
        return v != FaceShape()
    }

    /// Puts every Face slider on the selected face back to the middle (one undo step). Its Reshape pushes,
    /// Retouch values and Smooth stay.
    func resetFaceSliders() {
        sliderEditing(true)
        var v = FaceShape()
        v.retouch = sliderShape(keeping: v).retouch
        showSliders(v)
        sliderEditing(false)
    }

    // MARK: Timings (also written to Documents/timings.json for collection over USB)

    private static let logQueue = DispatchQueue(label: "timings-log", qos: .utility)  // one file writer at a time

    /// Logs a timing with this app's memory: mem_mb now, peak_mb during the tool, avail_mb left before iOS would
    /// close the app, and the working photo's size.
    func record(_ label: String, _ ms: Double, peakMB: Double? = nil, extra: [String: Double] = [:]) {
        timings.removeAll { $0.0 == label }
        timings.insert((label, ms), at: 0)
        if timings.count > 8 { timings.removeLast() }
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        var entry: [String: Any] = ["label": label, "ms": r1(ms), "at": ISO8601DateFormatter().string(from: Date()),
                                    "mem_mb": r1(MemoryMeter.footprintMB())]
        if let peakMB { entry["peak_mb"] = r1(peakMB) }
        if let free = MemoryMeter.availableMB() { entry["avail_mb"] = r1(free) }
        if let w = working { entry["photo"] = "\(w.width)x\(w.height)" }
        for (k, v) in extra { entry[k] = r1(v) }
        EditorModel.logQueue.async {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("timings.json")
            var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            all.append(entry)
            if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]) { try? d.write(to: url) }
        }
    }
}
