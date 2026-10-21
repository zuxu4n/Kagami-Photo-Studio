import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var comparing = false
    @State private var sliding = false     // a slider is being dragged
    @State private var touching = false    // a finger is on the photo
    @State private var zoom: CGFloat = 1       // 1 = whole photo fits
    @State private var pan: CGSize = .zero     // offset of the zoomed photo from the centre, in points
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize)?
    @State private var pinchCentre: CGPoint?       // the two fingers' middle point when the current two-finger move began
    @State private var pinchScale: (now: CGFloat, base: CGFloat) = (1, 1)   // the pinch's scale, and its value at that start
    @State private var twoFingers: Set<Int> = []   // which of the pinch (0) and two-finger pan (1) are under way
    @State private var dragStart: CGSize?      // pan when a one-finger drag began
    @State private var brushRing = false       // show the Heal brush size while its slider moves
    @State private var area: FaceArea = .face          // the Face main tab shown
    @State private var subtabs: [FaceArea: String] = [:]  // the subtab picked in each main tab
    @State private var reshapeDrag: Bool?      // Reshape on: nil until the finger moves, then true (pushing a face) or false (panning)
    @State private var positionDrag: Bool?     // Position shown: nil until the finger moves, then true (moving the oval) or false (panning)
    @State private var paintDrag: Bool?        // Heal › Brush or Erase: nil until the finger moves, then true (painting) or false (panning)
    private let maxZoom: CGFloat = 8

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                canvas
                if model.hasImage {
                    toolPicker
                    toolPanel
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .navigationTitle("PhotoStudio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Photo", systemImage: "photo.on.rectangle")
                        }
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                            .disabled(model.busy != nil)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await model.undo() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!model.canUndo || model.busy != nil)
                    Button { Task { await model.redo() } } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!model.canRedo || model.busy != nil)
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.hasImage || model.busy != nil)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                zoom = 1; pan = .zero
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { await model.load(data: data) }
                }
            }
            .fullScreenCover(isPresented: $showCamera) { CameraView() }
            .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.error ?? "")
            }
            .task {
                await model.warmUp()
                if EnhanceBench.requested { await model.runEnhanceBench() }
                if RemoveBench.requested { await model.runRemoveBench() }
            }
            .onChange(of: model.tool) { _, t in
                model.toolShown(t)
                if t == .heal, model.healMode.selects { model.preparePeople() }
            }
            .onChange(of: model.healMode) { _, m in if m.selects { model.preparePeople() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                model.noteMemoryWarning()
            }
        }
    }

    // MARK: Canvas with pinch zoom, pan, hold-to-compare and tap-to-heal

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = comparing ? model.original : model.display {
                    ZStack {
                        Image(uiImage: img).resizable().scaledToFit()
                        if model.selectionTint, !comparing, let sel = model.selectionOverlay {
                            Image(uiImage: sel).resizable().scaledToFit().allowsHitTesting(false)
                        }
                        if model.blurTint, !comparing, let sel = model.blurOverlay {
                            Image(uiImage: sel).resizable().scaledToFit().allowsHitTesting(false)
                        }
                        if model.tool == .face || model.tool == .reshape || (model.tool == .retouch && model.faceCount > 1), model.display != nil {
                            FaceGuides(model: model, zoom: zoom)
                                .opacity(sliding || touching || comparing || model.busy != nil ? 0.3 : 1)  // dim, don't hide, while adjusting
                                .animation(.easeInOut(duration: sliding || touching ? 0.15 : 0.35), value: sliding || touching || comparing)
                                .allowsHitTesting(false)
                            if positionOn, !comparing {
                                PositionHandle(model: model, zoom: zoom).allowsHitTesting(false)
                            }
                        }
                    }
                    .scaleEffect(zoom)
                    .offset(pan)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.largeTitle)
                        Text("Choose a photo to start").font(.callout)
                        Text("Everything runs on this iPhone. Nothing is uploaded.").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if brushRing, model.tool == .heal || model.tool == .blur || reshapeOn {
                    // The brush as it will land on the photo at this zoom (Reshape's is sized to the selected face).
                    let r = model.tool == .heal ? CGFloat(model.brush) : model.tool == .blur ? CGFloat(model.blurBrush) : model.reshapeRadiusFraction
                    let d = r * 2 * fittedSize(geo.size).width * zoom
                    Circle().stroke(Color.white, lineWidth: 1.5).frame(width: d, height: d)
                        .shadow(color: .black.opacity(0.6), radius: 1).allowsHitTesting(false)
                }
                if zoom > 1.01 {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero }
                    } label: {
                        Text(String(format: "%.1f× · Fit", zoom)).font(.caption.bold()).monospacedDigit()
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
                }
                if let b = model.busy {
                    ProgressView(b).padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if comparing { Text("Original").font(.caption.bold()).padding(6).background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .top).padding(.top, 8) }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard model.busy == nil, let p = imagePoint(location, in: geo.size) else { return }
                switch model.tool {
                case .heal:
                    switch model.healMode {
                    case .spot: Task { await model.heal(at: p) }
                    case .people: Task { await model.peopleTap(at: p) }
                    case .brush, .erase:
                        model.paint(to: p, erase: model.healMode == .erase, finished: true)
                    }
                case .blur where model.blurMode.paints: model.paintBlur(to: p, finished: true)
                case .face, .reshape, .retouch: model.selectFace(at: p)
                default: break
                }
            }
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 30, pressing: { pressing in
                // While zoomed a one-finger drag pans, so holding the photo doesn't compare (the Compare button still does).
                // With Reshape on, holding a face is the start of a push, so only the Compare button compares.
                // With Position shown, holding the photo is the start of moving the oval.
                if model.tool != .heal, !reshapeOn, !positionOn, !paintOn { comparing = pressing && zoom <= 1.01 && pinchStart == nil }
            }, perform: {})
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !touching { touching = true }
                    if reshapeOn {
                        if pinchStart != nil {
                            // A second finger came down: this is a pinch, not a push.
                            if reshapeDrag == true { model.cancelReshape() }
                            reshapeDrag = false
                        } else if reshapeDrag == nil {
                            // Wait for a little movement so the first finger of a pinch doesn't push.
                            guard hypot(v.translation.width, v.translation.height) > 6 else { return }
                            reshapeDrag = imagePoint(v.startLocation, in: geo.size).map { model.beginReshape(at: $0) } ?? false
                        }
                        if reshapeDrag == true {
                            model.moveReshape(to: imagePoint(v.location, in: geo.size, clamp: false)!)
                            return
                        }
                    }
                    if paintOn {
                        if pinchStart != nil {
                            // A second finger came down: a pinch, so the stroke so far stays and painting stops.
                            if paintDrag == true { endPaint() }
                            paintDrag = false
                        } else if paintDrag == nil {
                            guard hypot(v.translation.width, v.translation.height) > 6 else { return }
                            paintDrag = true
                            if let a = imagePoint(v.startLocation, in: geo.size, clamp: false) { paint(a) }
                        }
                        if paintDrag == true, let b = imagePoint(v.location, in: geo.size, clamp: false) {
                            paint(b)
                            return
                        }
                    }
                    if positionOn {
                        if pinchStart != nil {
                            if positionDrag == true { model.cancelPosition() }
                            positionDrag = false
                        } else if positionDrag == nil {
                            guard hypot(v.translation.width, v.translation.height) > 4 else { return }
                            positionDrag = model.beginPosition()
                        }
                        if positionDrag == true, let a = imagePoint(v.startLocation, in: geo.size, clamp: false),
                           let b = imagePoint(v.location, in: geo.size, clamp: false) {
                            model.movePosition(by: CGSize(width: b.x - a.x, height: b.y - a.y))
                            return
                        }
                    }
                    guard zoom > 1.01, pinchStart == nil else { dragStart = nil; return }
                    // Starts from where the photo is now, so lifting one finger after a pinch doesn't jump.
                    let start = dragStart ?? CGSize(width: pan.width - v.translation.width, height: pan.height - v.translation.height)
                    dragStart = start
                    pan = clampedPan(CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height), zoom: zoom, view: geo.size)
                }
                .onEnded { _ in
                    touching = false; dragStart = nil
                    if reshapeDrag == true { model.endReshape() }
                    reshapeDrag = nil
                    if positionDrag == true { model.endPosition() }
                    positionDrag = nil
                    if paintDrag == true { endPaint() }
                    paintDrag = nil
                })
            .gesture(PinchRecognizer { state, centre, scale in twoFingerEvent(0, state, centre, scale, view: geo.size) })
            .gesture(TwoFingerPanRecognizer { state, centre, _ in twoFingerEvent(1, state, centre, nil, view: geo.size) })
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Two fingers pinch and move the photo together: the photo point that was under the fingers' middle when they
    /// came down stays under it, at the pinch's zoom. Either recognizer starting again (a finger lifted and came back)
    /// starts from where the photo is now, so nothing jumps.
    private func twoFingerEvent(_ kind: Int, _ state: UIGestureRecognizer.State, _ centre: CGPoint, _ scale: CGFloat?, view: CGSize) {
        guard model.hasImage else { return }
        switch state {
        case .began, .changed:
            twoFingers.insert(kind)
            if state == .began, scale != nil { pinchScale = (1, 1) }
            if let scale { pinchScale.now = scale }
            if state == .began || pinchCentre == nil || pinchStart == nil {
                pinchStart = (zoom, pan)
                pinchCentre = centre
                pinchScale.base = pinchScale.now
            }
            guard let start = pinchStart, let c0 = pinchCentre else { return }
            comparing = false
            let z = min(maxZoom, max(1, start.zoom * pinchScale.now / max(0.01, pinchScale.base)))
            let k = z / start.zoom
            let a = CGPoint(x: c0.x - view.width / 2, y: c0.y - view.height / 2)
            let c = CGPoint(x: centre.x - view.width / 2, y: centre.y - view.height / 2)
            zoom = z
            // Past the photo's edges (always, at the fitted size) it follows the fingers a third as far, then springs
            // back when they lift, so the move is visible but the photo can't be lost off screen.
            let want = CGSize(width: c.x - (a.x - start.pan.width) * k, height: c.y - (a.y - start.pan.height) * k)
            let fit = clampedPan(want, zoom: z, view: view)
            pan = CGSize(width: fit.width + (want.width - fit.width) / 3, height: fit.height + (want.height - fit.height) / 3)
        default:
            twoFingers.remove(kind)
            pinchCentre = nil   // the other one, if still going, starts again from here
            guard twoFingers.isEmpty else { return }
            pinchStart = nil
            dragStart = nil
            withAnimation(.easeOut(duration: 0.2)) {
                if zoom < 1.05 { zoom = 1; pan = .zero } else { pan = clampedPan(pan, zoom: zoom, view: view) }
            }
        }
    }

    /// The photo's aspect-fit size in the canvas at zoom 1.
    private func fittedSize(_ view: CGSize) -> CGSize {
        let img = model.previewSize
        guard img.width > 0, img.height > 0 else { return view }
        let s = min(view.width / img.width, view.height / img.height)
        return CGSize(width: img.width * s, height: img.height * s)
    }

    /// Stops the zoomed photo being dragged past its edges (a dimension smaller than the canvas stays centred).
    private func clampedPan(_ p: CGSize, zoom z: CGFloat, view: CGSize) -> CGSize {
        let f = fittedSize(view)
        let mx = max(0, (f.width * z - view.width) / 2), my = max(0, (f.height * z - view.height) / 2)
        return CGSize(width: min(mx, max(-mx, p.width)), height: min(my, max(-my, p.height)))
    }

    private var reshapeOn: Bool { model.tool == .reshape }
    /// Heal › Brush or Erase: a one-finger drag paints the selection (two fingers pinch and move around).
    /// Blur › Brush or Erase works the same way on the people kept sharp.
    private var paintOn: Bool { (model.tool == .heal && (model.healMode == .brush || model.healMode == .erase)) || model.blurTint }

    private func paint(_ p: CGPoint) {
        if model.tool == .blur { model.paintBlur(to: p) } else { model.paint(to: p, erase: model.healMode == .erase) }
    }

    private func endPaint() {
        if model.tool == .blur { model.endBlurStroke() } else { model.endStroke() }
    }
    /// The Face › Position oval is on the photo: a one-finger drag anywhere on the canvas moves it (instead of panning).
    private var positionOn: Bool { model.tool == .face && feature == .position && model.selectedHasMesh }

    /// Maps a tap in the view to preview pixel coordinates, undoing the zoom and pan first (the image is aspect-fit).
    /// Points off the photo are nil unless `clamp` is false (a drag that runs past the edge).
    private func imagePoint(_ tap: CGPoint, in view: CGSize, clamp: Bool = true) -> CGPoint? {
        let img = model.previewSize
        guard img.width > 0, img.height > 0 else { return nil }
        // The photo layer is scaled about the canvas centre, then moved by `pan`.
        let p = CGPoint(x: view.width / 2 + (tap.x - view.width / 2 - pan.width) / zoom,
                        y: view.height / 2 + (tap.y - view.height / 2 - pan.height) / zoom)
        let s = min(view.width / img.width, view.height / img.height)
        let ox = (view.width - img.width * s) / 2, oy = (view.height - img.height * s) / 2
        let x = (p.x - ox) / s, y = (p.y - oy) / s
        guard !clamp || (x >= 0 && y >= 0 && x < img.width && y < img.height) else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: Tools

    /// The tools as a row that scrolls sideways (eight don't fit across a phone), styled like a segmented control.
    /// The picked tool scrolls into view.
    private var toolPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Tool.allCases) { t in
                        Button {
                            model.tool = t
                        } label: {
                            Text(t.rawValue).font(.subheadline.weight(t == model.tool ? .semibold : .regular)).lineLimit(1).fixedSize()
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(Color.primary)
                                .background(t == model.tool ? Color(.systemBackground) : .clear, in: Capsule())
                                .shadow(color: .black.opacity(t == model.tool ? 0.12 : 0), radius: 2, y: 1)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(t)
                    }
                }
                .padding(2)
            }
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .onChange(of: model.tool) { _, t in withAnimation { proxy.scrollTo(t, anchor: .center) } }
        }
    }

    @ViewBuilder private var toolPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.tool {
            case .enhance:
                HStack {
                    Button {
                        Task { await model.runEnhance() }
                    } label: {
                        Label(model.enhanceOn ? "Enhance on · tap to undo" : "Enhance",
                              systemImage: model.enhanceOn ? "checkmark.circle.fill" : "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy != nil)
                    Spacer()
                    compareButton
                }
                if model.enhanceOn {
                    HStack {
                        Text("Strength").font(.subheadline).frame(width: 96, alignment: .leading)
                        Slider(value: $model.enhanceStrength, in: 0...1) { editing in
                            sliding = editing
                            if editing { model.beginEnhanceStrength() } else { Task { await model.applyEnhanceStrength() } }
                        }
                        Button {
                            model.beginEnhanceStrength()
                            model.enhanceStrength = model.enhanceStrengthDefault
                            Task { await model.applyEnhanceStrength() }
                        } label: {
                            Image(systemName: "arrow.counterclockwise").font(.footnote.bold())
                        }
                        .buttonStyle(.borderless)
                        .disabled(abs(model.enhanceStrength - model.enhanceStrengthDefault) < 0.001)
                        .accessibilityLabel("Reset Strength")
                    }
                    .disabled(model.busy != nil)
                }
                Text(model.enhanceOn
                     ? "Strength fades between your photo and the enhanced one. Faces stay as they are. Tap Enhance again to undo."
                     : "Real-ESRGAN on device, from the photo's own pixels. Never smaller than the original (up to 4x for small photos); faces stay as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            case .smooth:
                sliderRow("Smooth skin", value: $model.smooth)
                HStack { Text(model.faceCount == 0 ? "No face found" : "Edges, eyes and lips stay sharp").font(.caption).foregroundStyle(.secondary); Spacer(); compareButton }
            case .retouch:
                sliderRow("Whiten teeth", value: $model.teeth)
                sliderRow("Brighten eyes", value: $model.brightEyes)
                sliderRow("Even tone", value: $model.tone)
                HStack { Text(retouchCaption).font(.caption).foregroundStyle(.secondary); Spacer(); compareButton }
            case .blur:
                Picker("Blur part", selection: Binding(get: { model.blurPanel }, set: { model.showBlurPanel($0) })) {
                    ForEach(BlurPanel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.blurPanel == .blur {
                    sliderRow("Strength", value: $model.blur)
                        .disabled(model.background != .off)
                } else {
                    Picker("Background", selection: Binding(get: { model.background }, set: { model.setBackground($0) })) {
                        ForEach(BackgroundChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.busy != nil)
                }
                Picker("Blur", selection: $model.blurMode) {
                    ForEach(BlurMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.personMatte == nil)
                if model.blurMode.paints {
                    HStack {
                        sliderRow("Brush", value: $model.blurBrush, range: 0.005...0.15, reset: 0.04, undoable: false)
                        Button("Reset") { model.resetBlurEdits() }
                            .font(.caption.bold()).disabled(model.blurEdits.isEmpty || model.busy != nil)
                    }
                }
                HStack { Text(blurCaption).font(.caption).foregroundStyle(.secondary); Spacer(); compareButton }
            case .heal:
                Picker("Heal", selection: $model.healMode) {
                    ForEach(HealMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.healMode != .people {
                    sliderRow("Brush", value: $model.brush, range: 0.004...0.08, reset: 0.025, undoable: false)
                }
                if model.healMode.selects {
                    HStack {
                        Button("Add shadow") { Task { await model.addShadow() } }
                        Button("Clear") { model.clearSelection() }
                        Spacer()
                        Button { Task { await model.removeSelection() } } label: { Label("Remove", systemImage: "wand.and.stars") }
                            .buttonStyle(.borderedProminent)
                    }
                    .font(.subheadline)
                    .disabled(!model.hasSelection || model.busy != nil)
                }
                HStack {
                    Text(healCaption).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    compareButton
                }
            case .face:
                areaTabs
                subtabChips
                if feature == .position {
                    HStack {
                        Text("Drag the oval around the head").font(.subheadline)
                        Spacer()
                        Button { model.resetPosition() } label: {
                            Image(systemName: "arrow.counterclockwise").font(.footnote.bold())
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.positionMoved || model.busy != nil)
                        .accessibilityLabel("Reset Position")
                    }
                    .disabled(!model.selectedHasMesh)
                } else if let f = feature {
                    sliderRow(f.title, value: Binding(get: { model[keyPath: f.value] }, set: { model[keyPath: f.value] = $0 }),
                              range: f.range)
                        .disabled(f.needsMesh && !model.selectedHasMesh)
                }
                HStack {
                    Text(faceCaption).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset all") { model.resetFaceSliders() }
                        .font(.caption.bold()).disabled(!model.faceSlidersMoved || model.busy != nil)
                    compareButton
                }
            case .reshape:
                sliderRow("Size", value: $model.reshapeSize, range: 0.08...0.5, reset: 0.22, undoable: false)
                sliderRow("Strength", value: $model.reshapeStrength, range: 0.1...1, reset: 1, undoable: false)
                HStack {
                    Text("Drag on a face to push it. Pinch to zoom; drag off the face to move around.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset face") { model.resetReshape() }
                        .font(.caption.bold()).disabled(!model.selectedHasPushes || model.busy != nil)
                }
                HStack { Text(faceCaption).font(.caption).foregroundStyle(.secondary); Spacer(); compareButton }
            }
            Text(model.info).font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: model.smooth) { _, _ in model.renderPreview() }
        .onChange(of: model.enhanceStrength) { _, _ in model.dragEnhanceStrength() }
        .onChange(of: model.slim) { _, _ in model.renderPreview() }
        .onChange(of: model.eyes) { _, _ in model.renderPreview() }
        .onChange(of: model.eyeWidth) { _, _ in model.renderPreview() }
        .onChange(of: model.eyeHeight) { _, _ in model.renderPreview() }
        .onChange(of: model.eyeTilt) { _, _ in model.renderPreview() }
        .onChange(of: model.eyeDistance) { _, _ in model.renderPreview() }
        .onChange(of: model.nose) { _, _ in model.renderPreview() }
        .onChange(of: model.noseSize) { _, _ in model.renderPreview() }
        .onChange(of: model.noseWidth) { _, _ in model.renderPreview() }
        .onChange(of: model.noseLift) { _, _ in model.renderPreview() }
        .onChange(of: model.noseTip) { _, _ in model.renderPreview() }
        .onChange(of: model.size) { _, _ in model.renderPreview() }
        .onChange(of: model.width) { _, _ in model.renderPreview() }
        .onChange(of: model.perspective) { _, _ in model.renderPreview() }
        .onChange(of: model.positionX) { _, _ in model.renderPreview() }
        .onChange(of: model.positionY) { _, _ in model.renderPreview() }
        .onChange(of: model.smirk) { _, _ in model.renderPreview() }
        .onChange(of: model.jaw) { _, _ in model.renderPreview() }
        .onChange(of: model.chin) { _, _ in model.renderPreview() }
        .onChange(of: model.jawSize) { _, _ in model.renderPreview() }
        .onChange(of: model.define) { _, _ in model.renderPreview() }
        .onChange(of: model.jawLength) { _, _ in model.renderPreview() }
        .onChange(of: model.lips) { _, _ in model.renderPreview() }
        .onChange(of: model.lipSize) { _, _ in model.renderPreview() }
        .onChange(of: model.lipWidth) { _, _ in model.renderPreview() }
        .onChange(of: model.browThick) { _, _ in model.renderPreview() }
        .onChange(of: model.browLift) { _, _ in model.renderPreview() }
        .onChange(of: model.browShape) { _, _ in model.renderPreview() }
        .onChange(of: model.browTilt) { _, _ in model.renderPreview() }
        .onChange(of: model.browRaise) { _, _ in model.renderPreview() }
        .onChange(of: model.smile) { _, _ in model.renderPreview() }
        .onChange(of: model.forehead) { _, _ in model.renderPreview() }
        .onChange(of: model.headHeight) { _, _ in model.renderPreview() }
        .onChange(of: model.teeth) { _, _ in model.renderPreview() }
        .onChange(of: model.brightEyes) { _, _ in model.renderPreview() }
        .onChange(of: model.tone) { _, _ in model.renderPreview() }
        .onChange(of: model.blur) { _, _ in model.renderPreview() }
        .onChange(of: model.blurMode) { _, _ in model.updateBlurOverlay() }
    }

    private var subtab: String { subtabs[area] ?? area.subtabs[0] }
    /// The working slider behind the picked subtab, if one is built yet.
    private var feature: FaceFeature? { area.feature(subtab) }

    /// Whether any slider in this main tab (or behind this subtab) is moved on the selected face.
    private func changed(_ a: FaceArea, _ sub: String? = nil) -> Bool {
        (sub.map { [a.feature($0)] } ?? a.subtabs.map(a.feature)).contains { f in
            guard let f else { return false }
            return f == .position ? model.positionMoved : abs(model[keyPath: f.value]) > 0.001
        }
    }

    /// The main Face tabs; a dot marks the ones with a slider moved on the selected face.
    private var areaTabs: some View {
        // Scrolls sideways, as seven names don't fit across a phone at full size.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(FaceArea.allCases) { a in
                    Button { area = a } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 3) {
                                Text(a.rawValue).lineLimit(1).fixedSize()
                                if changed(a) { Circle().frame(width: 4, height: 4) }
                            }
                            .font(.subheadline.weight(a == area ? .bold : .regular))
                            .foregroundStyle(a == area ? Color.primary : Color.secondary)
                            Capsule().frame(height: 2)
                                .foregroundStyle(a == area ? Color(red: 0.2, green: 0.85, blue: 0.95) : .clear)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// The picked main tab's subtabs; a dot marks a moved slider.
    private var subtabChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(area.subtabs, id: \.self) { sub in
                    Button { subtabs[area] = sub } label: {
                        HStack(spacing: 4) {
                            Text(sub)
                            if changed(area, sub) { Circle().frame(width: 5, height: 5) }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(sub == subtab ? Color.black : Color.primary)
                        .background(sub == subtab ? Color(red: 0.2, green: 0.85, blue: 0.95) : Color.secondary.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var faceCaption: String {
        if model.faceCount == 0 { return "No face found" }
        if !model.reshaping, feature == nil { return "\(area.rawValue) \(subtab): coming soon" }
        if !model.reshaping, let f = feature, f.needsMesh, !model.selectedHasMesh { return "Couldn't map this face closely enough for \(subtab)" }
        let hint = model.reshaping ? "" : feature?.hint ?? ""
        if model.faceCount == 1 { return hint }
        let which = "Face \((model.selectedFace ?? 0) + 1) of \(model.faceCount) · tap another face to switch"
        return hint.isEmpty ? which : "\(hint) · \(which)"
    }

    private var healCaption: String {
        switch model.healMode {
        case .spot: return "Tap a spot to remove it. Pinch to zoom in on small spots."
        case .people: return model.hasSelection ? "Tap another person to add them, or tap the outline to remove" : "Tap a person to outline them; tap again to remove"
        case .brush: return "Paint over anything to remove. Two fingers move and zoom."
        case .erase: return "Paint to take parts out of the selection"
        }
    }

    private var retouchCaption: String {
        if model.faceCount == 0 { return "No face found" }
        if model.faceCount == 1 { return "Colour only; the face's shape stays" }
        return "Face \((model.selectedFace ?? 0) + 1) of \(model.faceCount) · tap another face to switch"
    }

    private var blurCaption: String {
        switch model.blurMode {
        case .brush: return "Paint parts that should stay sharp"
        case .erase: return "Paint parts that should be blurred"
        case .view: break
        }
        if model.blurPanel == .blur, model.background != .off { return "Remove background is on; set it to Off to blur instead" }
        if model.blurPanel == .remove, model.personMatte?.hasPerson == false { return "No person found. Use Brush to paint what to keep" }
        if model.blurPanel == .remove, model.background == .clear { return "Saves as a see-through PNG" }
        guard let m = model.personMatte else { return model.findingPeople ? "Finding people…" : "Blurs what's behind the people" }
        return m.hasPerson ? "Everyone found stays sharp" : "No person found, so the whole photo is blurred"
    }

    private var compareButton: some View {
        Text("Hold to compare")
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { comparing = $0 }, perform: {})
    }

    /// A labelled slider with a reset button that puts it back to `reset` (greyed out while it's already there).
    /// Two-way sliders (ranges below zero) snap to 0 when released within 4% of it.
    /// For undoable sliders the reset is one undo step, like a drag.
    private func sliderRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float> = 0...1, reset: Float = 0, undoable: Bool = true) -> some View {
        HStack {
            Text(title).font(.subheadline).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range) { editing in
                sliding = editing
                // Two-way sliders snap back to the middle when let go close to it, so "off" is easy to hit.
                if !editing, range.lowerBound < 0, abs(value.wrappedValue) < 0.04 { value.wrappedValue = 0 }
                if undoable { model.sliderEditing(editing) } else { brushRing = editing }
            }
            Button {
                if undoable { model.sliderEditing(true) }
                value.wrappedValue = reset
                if undoable { model.sliderEditing(false) }
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.footnote.bold())
            }
            .buttonStyle(.borderless)
            .disabled(abs(value.wrappedValue - reset) < 0.001 || model.busy != nil)
            .accessibilityLabel("Reset \(title)")
        }
    }
}

/// The Face tab's main tabs and their subtabs. Subtabs without a FaceFeature are buttons only for now.
private enum FaceArea: String, CaseIterable, Identifiable {
    case face = "Face", head = "Head", jaw = "Jaw", nose = "Nose", eyes = "Eyes", lips = "Lips", eyebrows = "Eyebrows", forehead = "Forehead"
    var id: String { rawValue }

    var subtabs: [String] {
        switch self {
        case .face: return ["Size", "Width", "Smile", "Position", "Perspective", "Smirk"]
        case .head: return ["Size", "Width", "Height"]
        case .jaw: return ["Jaw", "Jawline", "Chin", "Size", "Define", "Length"]
        case .nose: return ["Size", "Width", "Narrow", "Lift", "Tip"]
        case .eyes: return ["Size", "Width", "Height", "Tilt", "Distance"]
        case .lips: return ["Size", "Height", "Width"]
        case .eyebrows: return ["Thick", "Lift", "Shape", "Tilt", "Raise"]
        case .forehead: return ["Height"]
        }
    }

    /// The slider each subtab drives.
    func feature(_ sub: String) -> FaceFeature? {
        switch (self, sub) {
        case (.face, "Size"): return .size
        case (.face, "Width"): return .width
        case (.face, "Smile"): return .smile
        case (.face, "Position"): return .position
        case (.face, "Perspective"): return .perspective
        case (.face, "Smirk"): return .smirk
        case (.head, "Size"): return .size
        case (.head, "Width"): return .width
        case (.head, "Height"): return .headHeight
        case (.jaw, "Jaw"): return .jaw
        case (.jaw, "Jawline"): return .slim
        case (.jaw, "Chin"): return .chin
        case (.jaw, "Size"): return .jawSize
        case (.jaw, "Define"): return .define
        case (.jaw, "Length"): return .jawLength
        case (.nose, "Size"): return .noseSize
        case (.nose, "Width"): return .noseWidth
        case (.nose, "Narrow"): return .nose
        case (.nose, "Lift"): return .noseLift
        case (.nose, "Tip"): return .noseTip
        case (.eyes, "Size"): return .eyes
        case (.eyes, "Width"): return .eyeWidth
        case (.eyes, "Height"): return .eyeHeight
        case (.eyes, "Tilt"): return .eyeTilt
        case (.eyes, "Distance"): return .eyeDistance
        case (.lips, "Size"): return .lipSize
        case (.lips, "Height"): return .lips
        case (.lips, "Width"): return .lipWidth
        case (.eyebrows, "Thick"): return .browThick
        case (.eyebrows, "Lift"): return .browLift
        case (.eyebrows, "Shape"): return .browShape
        case (.eyebrows, "Tilt"): return .browTilt
        case (.eyebrows, "Raise"): return .browRaise
        case (.forehead, "Height"): return .forehead
        default: return nil
        }
    }
}

/// The Face tab's sliders. Jawline and Eyes use Apple Vision's landmarks; the rest use MediaPipe's face mesh.
private enum FaceFeature: String, CaseIterable, Identifiable {
    case slim = "Slim", size = "Size", width = "Width", headHeight = "Head height", position = "Position", perspective = "Perspective", eyes = "Eyes", eyeWidth = "Eye width", eyeHeight = "Eye height",
         eyeTilt = "Eye tilt", eyeDistance = "Eye distance", nose = "Nose",
         noseSize = "Nose size", noseWidth = "Nose width", noseLift = "Nose lift", noseTip = "Nose tip", jaw = "Jaw",
         chin = "Chin", jawSize = "Jaw size", define = "Define", jawLength = "Jaw length", lips = "Lips", lipSize = "Lip size",
         lipWidth = "Lip width", browThick = "Brow thick", browLift = "Brow lift", browShape = "Brow shape", browTilt = "Brow tilt",
         browRaise = "Brow raise", smile = "Smile", smirk = "Smirk",
         forehead = "Forehead"
    var id: String { rawValue }

    var value: ReferenceWritableKeyPath<EditorModel, Float> {
        switch self {
        case .slim: return \.slim
        case .size: return \.size
        case .width: return \.width
        case .headHeight: return \.headHeight
        case .perspective: return \.perspective
        case .position: return \.positionX   // Position has an oval on the photo instead of a slider
        case .eyes: return \.eyes
        case .eyeWidth: return \.eyeWidth
        case .eyeHeight: return \.eyeHeight
        case .eyeTilt: return \.eyeTilt
        case .eyeDistance: return \.eyeDistance
        case .nose: return \.nose
        case .noseSize: return \.noseSize
        case .noseWidth: return \.noseWidth
        case .noseLift: return \.noseLift
        case .noseTip: return \.noseTip
        case .jaw: return \.jaw
        case .chin: return \.chin
        case .jawSize: return \.jawSize
        case .define: return \.define
        case .jawLength: return \.jawLength
        case .lips: return \.lips
        case .lipSize: return \.lipSize
        case .lipWidth: return \.lipWidth
        case .browThick: return \.browThick
        case .browLift: return \.browLift
        case .browShape: return \.browShape
        case .browTilt: return \.browTilt
        case .browRaise: return \.browRaise
        case .smile: return \.smile
        case .smirk: return \.smirk
        case .forehead: return \.forehead
        }
    }

    var title: String {
        switch self {
        case .slim: return "Jawline"
        case .jawSize: return "Size"
        case .jawLength: return "Length"
        case .lips: return "Height"
        case .lipSize: return "Size"
        case .lipWidth: return "Width"
        case .browThick: return "Thick"
        case .browLift: return "Lift"
        case .browShape: return "Shape"
        case .browTilt: return "Tilt"
        case .browRaise: return "Raise"
        case .forehead: return "Height"
        case .headHeight: return "Height"
        case .eyes: return "Size"
        case .eyeWidth: return "Width"
        case .eyeHeight: return "Height"
        case .eyeTilt: return "Tilt"
        case .eyeDistance: return "Distance"
        case .nose: return "Narrow"
        case .noseSize: return "Size"
        case .noseWidth: return "Width"
        case .noseLift: return "Lift"
        case .noseTip: return "Tip"
        case .jaw: return "Jaw"
        default: return rawValue
        }
    }

    /// Two-way sliders start in the middle: left makes it smaller, right bigger.
    var range: ClosedRange<Float> {
        [.slim, .size, .width, .headHeight, .perspective, .eyes, .eyeWidth, .eyeHeight, .eyeTilt, .eyeDistance, .noseSize, .noseWidth, .noseLift, .noseTip, .jaw, .chin, .jawSize, .jawLength, .lips, .lipSize, .lipWidth, .browThick, .browLift, .browShape, .browTilt, .browRaise, .smirk,
         .forehead].contains(self) ? -1...1 : 0...1
    }

    var hint: String {
        switch self {
        case .size: return "Left smaller, right bigger"
        case .width: return "Left narrower, right wider"
        case .headHeight: return "Left shorter, right taller"
        case .perspective: return "Left as if further away, right closer"
        case .position: return "The head turns towards the oval"
        case .smirk: return "Left lifts the left corner, right the right one"
        case .slim: return "Left slimmer, right fuller"
        case .eyes: return "Left smaller, right bigger"
        case .eyeWidth: return "Left shorter, right longer, corner to corner"
        case .eyeHeight: return "Left less open, right more open"
        case .eyeTilt: return "Left outer corners down, right up"
        case .eyeDistance: return "Left closer together, right further apart"
        case .nose: return "Slims the bridge of the nose"
        case .noseSize: return "Left smaller, right bigger"
        case .noseWidth: return "Left narrower, right wider"
        case .noseLift: return "Left tip down, right tip up"
        case .noseTip: return "Left smaller tip, right bigger"
        case .jaw: return "Left narrower, right wider"
        case .chin: return "Left shorter, right longer"
        case .jawSize: return "Left smaller, right bigger"
        case .define: return "Tightens under the jaw and sharpens its corners"
        case .jawLength: return "Left shorter, right longer"
        case .lips: return "Left thinner, right fuller"
        case .lipSize: return "Left smaller, right bigger"
        case .lipWidth: return "Left narrower, right wider"
        case .browThick: return "Left thinner, right thicker"
        case .browLift: return "Left outer ends down, right up; inner ends stay"
        case .browShape: return "Left flatter, right more arched"
        case .browTilt: return "Left outer ends down, right up, turning about the middle"
        case .browRaise: return "Left lower, right higher"
        case .forehead: return "Left lower hairline, right higher"
        default: return ""
        }
    }

    var needsMesh: Bool { ![.slim, .eyes].contains(self) }   // these two fall back to Apple Vision's landmarks
}

/// Face › Position: the oval to drag, on the selected face, drawn over the aspect-fit photo. Its long radius is at least
/// 18 points on screen, so it stays easy to see and grab on small faces.
private struct PositionHandle: View {
    @ObservedObject var model: EditorModel
    var zoom: CGFloat = 1

    var body: some View {
        let imageSize = model.previewSize
        GeometryReader { geo in
            if let h = model.positionHandle() {
                let s = min(geo.size.width / max(imageSize.width, 1), geo.size.height / max(imageSize.height, 1))
                let fw = imageSize.width * s, fh = imageSize.height * s
                let ox = (geo.size.width - fw) / 2, oy = (geo.size.height - fh) / 2
                let major = max(h.major * fw, 18 / zoom), minor = major * h.minor / h.major
                // The frame's height is the short axis; turned so it points along `angle`, at the middle of the face.
                Ellipse().fill(Color.white.opacity(0.3))
                    .overlay(Ellipse().stroke(Color(red: 0.2, green: 0.85, blue: 0.95), lineWidth: 2.5 / zoom))
                    .frame(width: 2 * major, height: 2 * minor)
                    .rotationEffect(.radians(h.angle - .pi / 2))
                    .position(x: ox + h.puck.x * fw, y: oy + h.puck.y * fh)
            }
        }
    }
}

/// Two thin curves bracketing each face, drawn over the aspect-fit photo: cyan on the selected face, white on the others.
private struct FaceGuides: View {
    // Observed directly (not passed in as a closure) so the guides redraw whenever the picked face or a slider changes.
    @ObservedObject var model: EditorModel
    var zoom: CGFloat = 1   // the canvas zoom, so lines stay the same width on screen

    var body: some View {
        let imageSize = model.previewSize
        GeometryReader { geo in
            let s = min(geo.size.width / max(imageSize.width, 1), geo.size.height / max(imageSize.height, 1))
            let fw = imageSize.width * s, fh = imageSize.height * s
            let ox = (geo.size.width - fw) / 2, oy = (geo.size.height - fh) / 2
            let faces = model.faceGuides(minGap: 14 / max(s * zoom, 0.001))   // never closer than 14 points on screen
            let style = StrokeStyle(lineWidth: 1.75 / zoom, lineCap: .round, lineJoin: .round)
            ZStack {
                Self.path(faces.filter { !$0.selected }.flatMap(\.curves), ox, oy, fw, fh).stroke(Color.white, style: style)
                Self.path(faces.filter(\.selected).flatMap(\.curves), ox, oy, fw, fh).stroke(Color(red: 0.2, green: 0.85, blue: 0.95), style: style)
            }
        }
    }

    /// Smooth curves through the landmarks (quadratic segments between midpoints), placed on the fitted photo.
    private static func path(_ curves: [[CGPoint]], _ ox: CGFloat, _ oy: CGFloat, _ fw: CGFloat, _ fh: CGFloat) -> Path {
        Path { p in
            for c in curves where c.count > 1 {
                let v = c.map { CGPoint(x: ox + $0.x * fw, y: oy + $0.y * fh) }
                p.move(to: v[0])
                for i in 1..<v.count - 1 {
                    let mid = CGPoint(x: (v[i].x + v[i + 1].x) / 2, y: (v[i].y + v[i + 1].y) / 2)
                    p.addQuadCurve(to: mid, control: v[i])
                }
                p.addLine(to: v[v.count - 1])
            }
        }
    }
}
