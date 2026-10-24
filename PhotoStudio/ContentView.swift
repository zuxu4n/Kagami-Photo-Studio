import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The app's one window: the home screen until a photo or video is open, then its editor. The camera opens over it.
struct ContentView: View {
    @StateObject private var model = EditorModel()
    @AppStorage("welcomeSeen") private var welcomeSeen = false
    @State private var picking = false
    @State private var pickerFilter = PHPickerFilter.images   // what the photo picker shows: photos, or videos
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showWelcome = false
    @State private var movie: PickedMovie?
    @State private var comparing = false
    @State private var sliding = false     // a slider is being dragged
    @State private var touching = false    // a finger is on the photo
    @State private var confirmClose = false
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
    @State private var cropDrag: (frame: CGRect, handle: CropHandle)?   // Adjust › Crop: the frame when a finger took hold of it, and where
    @State private var cropPan = false         // Adjust › Crop: this drag started off the frame, so it pans
    private let maxZoom: CGFloat = 8

    var body: some View {
        ZStack {
            // The video editor is shown in place, not as a full-screen cover: a cover that opens as the photo picker
            // closes is laid out without the screen's safe areas.
            if let movie {
                VideoEditView(movie: movie) { withAnimation { self.movie = nil } }
                    .transition(.opacity)
            } else if model.hasImage {
                editor.transition(.opacity)
            } else {
                HomeView(busy: model.busy,
                         openPhoto: { tool in openPhoto(tool) },
                         openVideo: { pickerFilter = .videos; picking = true },
                         openCamera: { showCamera = true },
                         showWelcome: { showWelcome = true })
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.hasImage)
        .animation(.default, value: movie?.id)
        // One picker for photos and videos (two pickers on one view mix up their selections).
        .photosPicker(isPresented: $picking, selection: $pickerItem, matching: pickerFilter)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                Task {
                    do { movie = try await item.loadTransferable(type: PickedMovie.self) }
                    catch { model.error = "This video can't be opened (\(error.localizedDescription))." }
                }
                return
            }
            zoom = 1; pan = .zero
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await model.load(data: data) }
                else { model.error = "This photo can't be opened. It may still be downloading from iCloud." }
            }
        }
        .fullScreenCover(isPresented: $showCamera) { CameraView() }
        .sheet(isPresented: $showWelcome) {
            WelcomeView { welcomeSeen = true; showWelcome = false }
                .interactiveDismissDisabled(!welcomeSeen)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
        .task {
            if !welcomeSeen { showWelcome = true }
            await model.warmUp()
            if EnhanceBench.requested { await model.runEnhanceBench() }
            if RemoveBench.requested { await model.runRemoveBench() }
        }
        .onChange(of: model.tool) { old, t in
            model.toolShown(t)
            if old == .adjust || t == .adjust {
                // The crop and turn show only in Adjust, so the picture changes shape: start from the whole of it.
                if !model.adjust.shapeOff { zoom = 1; pan = .zero }
                model.renderPreview()
            }
            if t == .heal, model.healMode.selects { model.preparePeople() }
        }
        .onChange(of: model.healMode) { _, m in if m.selects { model.preparePeople() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.noteMemoryWarning()
        }
    }

    /// Opens the photo picker; a tool picked on the home screen is the one the photo opens in.
    private func openPhoto(_ tool: Tool?) {
        if let tool { model.tool = tool }
        pickerFilter = .images
        picking = true
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            topBar
            canvas
            toolPanel
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
                .frame(maxWidth: .infinity, minHeight: 184, alignment: .center)
            Divider()
            toolBar
        }
        .disabled(model.busy != nil)
        .allowsHitTesting(model.busy == nil)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)   // the tool panel is dense; past this it would push the photo away
        .sensoryFeedback(.success, trigger: model.info) { _, new in new == "Saved to Photos" }
        .confirmationDialog("Close this photo?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) { closePhoto() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your edits haven't been saved to Photos.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            StudioIconButton(icon: "xmark", label: "Close photo") {
                if model.edited { confirmClose = true } else { closePhoto() }
            }
            .disabled(model.busy != nil)
            Spacer()
            StudioIconButton(icon: "arrow.uturn.backward", label: "Undo") { Task { await model.undo() } }
                .disabled(!model.canUndo || model.busy != nil)
            StudioIconButton(icon: "arrow.uturn.forward", label: "Redo") { Task { await model.redo() } }
                .disabled(!model.canRedo || model.busy != nil)
            Spacer()
            Button("Save") { Task { await model.save() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
                .accessibilityHint("Saves a copy to Photos")
        }
        .padding(.horizontal, Space.s)
        .padding(.trailing, Space.s)
        .frame(height: 52)
    }

    private func closePhoto() {
        withAnimation { model.close() }
        zoom = 1; pan = .zero
    }

    // MARK: Canvas with pinch zoom, pan, hold-to-compare and tap-to-heal

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                ZStack {
                    Color(.secondarySystemBackground)
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
                            if model.tool == .adjust, !comparing, model.display != nil {
                                if cropOn {
                                    CropFrameOverlay(frame: model.adjust.cropFrame(for: shownSize), active: cropDrag != nil, edges: model.adjust.crop == .free)
                                        .aspectRatio(shownSize, contentMode: .fit)
                                        .allowsHitTesting(false)
                                } else if model.adjustTool == .rotate, sliding {
                                    StraightenGrid().aspectRatio(shownSize, contentMode: .fit).allowsHitTesting(false)
                                }
                            }
                        }
                        .scaleEffect(zoom)
                        .offset(pan)
                    }
                    if brushRing, model.tool == .heal || model.tool == .blur || reshapeOn {
                        // The brush as it will land on the photo at this zoom (Reshape's is sized to the selected face).
                        let r = model.tool == .heal ? CGFloat(model.brush) : model.tool == .blur ? CGFloat(model.blurBrush) : model.reshapeRadiusFraction
                        let d = r * 2 * fittedSize(geo.size).width * zoom
                        Circle().stroke(Color.white, lineWidth: 1.5).frame(width: d, height: d)
                            .shadow(color: .black.opacity(0.6), radius: 1).allowsHitTesting(false)
                    }
                    if comparing {
                        Text("Original")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 10)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.default, value: comparing)
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
                    if model.tool != .heal, !reshapeOn, !positionOn, !paintOn, !cropOn { comparing = pressing && zoom <= 1.01 && pinchStart == nil }
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
                        if cropOn {
                            if pinchStart != nil {
                                if cropDrag != nil { model.sliderEditing(false) }
                                cropDrag = nil
                                cropPan = true
                            } else if !cropPan {
                                let size = shownSize, fit = fittedSize(geo.size)
                                guard size.width > 0, let a = imagePoint(v.startLocation, in: geo.size, clamp: false),
                                      let b = imagePoint(v.location, in: geo.size, clamp: false) else { return }
                                if cropDrag == nil {
                                    guard hypot(v.translation.width, v.translation.height) > 4 else { return }
                                    // A corner or edge within about 30 points resizes; inside the frame moves it; outside pans.
                                    let f = model.adjust.cropFrame(for: size)
                                    let reach = CGSize(width: 30 / (fit.width * zoom), height: 30 / (fit.height * zoom))
                                    if let h = Adjustments.cropHandle(at: CGPoint(x: a.x / size.width, y: a.y / size.height), frame: f,
                                                                      reach: reach, edges: model.adjust.crop == .free) {
                                        cropDrag = (f, h)
                                        model.sliderEditing(true)
                                    } else {
                                        cropPan = true
                                    }
                                }
                                if let drag = cropDrag {
                                    let d = CGVector(dx: (b.x - a.x) / size.width, dy: (b.y - a.y) / size.height)
                                    model.adjust.cropRect = Adjustments.dragged(drag.frame, drag.handle, by: d, keepShape: model.adjust.crop != .free)
                                    return
                                }
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
                        if cropDrag != nil { model.sliderEditing(false) }
                        cropDrag = nil
                        cropPan = false
                    })
                .gesture(PinchRecognizer { state, centre, scale in twoFingerEvent(0, state, centre, scale, view: geo.size) })
                .gesture(TwoFingerPanRecognizer { state, centre, _ in twoFingerEvent(1, state, centre, nil, view: geo.size) })
                // On top of the photo's gestures, so a tap on these never lands on the photo.
                canvasControls
                DelayedPresence(value: model.busy) { BusyBadge(text: $0) }
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .toast(model.info, id: model.infoID) { $0 == "Saved to Photos" ? "checkmark.circle.fill" : nil }
    }

    /// Hold-to-compare at the bottom left of the photo, and the zoom (tap to fit) at the bottom right.
    private var canvasControls: some View {
        HStack(alignment: .bottom) {
            Image(systemName: "square.split.2x1")
                .foregroundStyle(comparing ? Color.accentColor : Color.primary)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { comparing = $0 }, perform: {})
                .accessibilityLabel("Hold to compare with the original")
                .accessibilityAddTraits(.isButton)
                .opacity(model.busy == nil && !cropOn ? 1 : 0)   // in Crop the frame's corner is there
                .allowsHitTesting(!cropOn)
            Spacer()
            if zoom > 1.01 {
                Button {
                    withAnimation { zoom = 1; pan = .zero }
                } label: {
                    Label(String(format: "%.1f×", zoom), systemImage: "arrow.down.right.and.arrow.up.left")
                        .monospacedDigit()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .background(.regularMaterial, in: Capsule())
                .accessibilityLabel("Zoom \(String(format: "%.1f", zoom)) times. Fit the photo")
                .transition(.opacity)
            }
        }
        .padding(Space.m)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .animation(.default, value: zoom > 1.01)
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
        let img = shownSize
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

    /// The size of the picture on screen: in Adjust it's turned (and cropped, outside Crop), elsewhere it's the preview.
    private var shownSize: CGSize {
        guard model.tool == .adjust, let d = model.display else { return model.previewSize }
        return CGSize(width: d.size.width * d.scale, height: d.size.height * d.scale)
    }

    private var reshapeOn: Bool { model.tool == .reshape }
    /// Adjust › Crop with a shape picked: a one-finger drag moves the frame (two fingers pinch and move around).
    private var cropOn: Bool { model.tool == .adjust && model.adjustTool == .crop && model.adjust.crop != .original }
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
        let img = shownSize
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

    /// The Focus rail: a continuous strip, grouped into fix and frame, beauty, then remove and replace.
    private var toolBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(Tool.groups.enumerated()), id: \.offset) { i, group in
                        if i > 0 {
                            Divider().frame(height: 24).padding(.horizontal, 5)
                        }
                        ForEach(group) { t in toolButton(t).id(t) }
                    }
                }
                .padding(.horizontal, Space.s)
            }
            .onChange(of: model.tool) { _, t in withAnimation { proxy.scrollTo(t, anchor: .center) } }
            .onAppear { proxy.scrollTo(model.tool, anchor: .center) }
        }
        .frame(height: 66)
        .sensoryFeedback(.selection, trigger: model.tool)
    }

    /// The selected tool has a soft accent backing and underline; a dot marks other tools with edits.
    private func toolButton(_ t: Tool) -> some View {
        let on = t == model.tool
        let changed = toolChanged(t)
        return Button {
            model.tool = t
        } label: {
            VStack(spacing: 4) {
                Image(systemName: t.icon)
                    .font(.title3)
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if changed && !on {
                            Circle().fill(.secondary).frame(width: 6, height: 6).offset(x: 6, y: -2)
                        }
                    }
                Text(t.rawValue)
                    .font(.caption2.weight(on ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 66)
            .frame(height: 58)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(on ? 0.12 : 0))
            }
            .overlay(alignment: .bottom) {
                if on {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 2)
                        .padding(.bottom, 3)
                }
            }
            .frame(height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.rawValue + (changed ? ", changed" : ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Whether a tool has changed the photo (for the dot in the tool bar). Face and Warp count the selected face.
    private func toolChanged(_ t: Tool) -> Bool {
        switch t {
        case .enhance: return model.enhanceOn
        case .smooth: return model.smooth > 0.001
        case .retouch: return model.teeth > 0.001 || model.brightEyes > 0.001 || model.tone > 0.001
        case .blur: return model.blur > 0.001 || model.background != .off
        case .heal: return false
        case .face: return model.faceSlidersMoved
        case .reshape: return model.selectedHasPushes
        case .adjust: return !model.adjust.isOff
        }
    }

    @ViewBuilder private var toolPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.tool {
            case .enhance:
                if model.enhanceOn {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Enhanced").font(.headline)
                        Spacer()
                        PanelTextButton(title: "Turn off") { Task { await model.runEnhance() } }
                            .disabled(model.busy != nil)
                    }
                    .frame(height: 36)
                    sliderRow("Strength", value: $model.enhanceStrength, reset: model.enhanceStrengthDefault, undoable: false) { editing in
                        if editing { model.beginEnhanceStrength() } else { Task { await model.applyEnhanceStrength() } }
                    } onReset: {
                        model.beginEnhanceStrength()
                        model.enhanceStrength = model.enhanceStrengthDefault
                        Task { await model.applyEnhanceStrength() }
                    }
                    HintText("Fades between your photo and the enhanced one. Faces stay as they are.")
                } else {
                    HintText("Sharpens detail and cleans up noise from the photo's own pixels, up to 4× for small photos. Faces stay as they are.")
                        .padding(.top, 2)
                    Button { Task { await model.runEnhance() } } label: {
                        Label("Enhance photo", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.busy != nil)
                }
            case .smooth:
                sliderRow("Smooth skin", value: $model.smooth)
                HintText(model.faceCount == 0 ? "No face found in this photo" : "Edges, eyes and lips stay sharp")
            case .retouch:
                sliderRow("Whiten teeth", value: $model.teeth)
                sliderRow("Brighten eyes", value: $model.brightEyes)
                sliderRow("Even tone", value: $model.tone)
                HintText(retouchCaption)
            case .blur:
                ModeTabs(items: BlurPanel.allCases, selection: Binding(get: { model.blurPanel }, set: { model.showBlurPanel($0) }),
                         title: { $0 == .remove ? "Remove" : $0.rawValue })
                if model.blurPanel == .blur {
                    sliderRow("Strength", value: $model.blur)
                        .disabled(model.background != .off)
                } else {
                    HStack(spacing: Space.s) {
                        ForEach(BackgroundChoice.allCases) { c in
                            Chip(title: c.rawValue, on: model.background == c) { model.setBackground(c) }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 44)
                    .disabled(model.busy != nil)
                }
                HStack(spacing: Space.s) {
                    Text("Refine").font(.subheadline).foregroundStyle(.secondary)
                    ModeTabs(items: BlurMode.allCases, selection: $model.blurMode, title: { $0 == .view ? "Auto" : $0.rawValue })
                }
                .disabled(model.personMatte == nil)
                if model.blurMode.paints {
                    HStack(spacing: Space.s) {
                        sliderRow("Brush size", value: $model.blurBrush, range: 0.005...0.15, reset: 0.04, undoable: false)
                        PanelTextButton(title: "Reset") { model.resetBlurEdits() }
                            .disabled(model.blurEdits.isEmpty || model.busy != nil)
                    }
                }
                HintText(blurCaption)
            case .heal:
                ModeTabs(items: HealMode.allCases, selection: $model.healMode)
                if model.healMode != .people {
                    sliderRow("Brush size", value: $model.brush, range: 0.004...0.08, reset: 0.025, undoable: false)
                }
                if model.healMode.selects {
                    HStack(spacing: Space.s) {
                        PanelTextButton(title: "Add shadow") { Task { await model.addShadow() } }
                        PanelTextButton(title: "Clear") { model.clearSelection() }
                        Spacer()
                        PanelTextButton(title: "Remove", icon: "wand.and.stars", prominent: true) { Task { await model.removeSelection() } }
                    }
                    .disabled(!model.hasSelection || model.busy != nil)
                }
                HintText(healCaption)
            case .face:
                areaTabs
                subtabChips
                if feature == .position {
                    HStack {
                        Text("Drag the oval around the head").font(.subheadline)
                        Spacer()
                        ResetButton(label: "Reset Position") { model.resetPosition() }
                            .disabled(!model.positionMoved || model.busy != nil)
                    }
                    .frame(height: 44)
                    .disabled(!model.selectedHasMesh)
                } else if let f = feature {
                    sliderRow(f.title, value: Binding(get: { model[keyPath: f.value] }, set: { model[keyPath: f.value] = $0 }),
                              range: f.range)
                        .disabled(f.needsMesh && !model.selectedHasMesh)
                } else {
                    Color.clear.frame(height: 44)
                }
                HStack(alignment: .firstTextBaseline) {
                    HintText(faceCaption)
                    PanelTextButton(title: "Reset all") { model.resetFaceSliders() }
                        .disabled(!model.faceSlidersMoved || model.busy != nil)
                }
            case .adjust:
                AdjustPanel(adjust: $model.adjust, tool: $model.adjustTool, editing: { e in
                    sliding = e
                    model.sliderEditing(e)
                })
                .disabled(model.busy != nil)
                .onChange(of: model.adjust) { old, new in
                    // Moving the crop frame in Crop changes only the frame on top; the picture under it stays.
                    var o = old; o.cropRect = new.cropRect
                    if !(o == new && model.adjustTool == .crop) { model.renderPreview() }
                }
                .onChange(of: model.adjustTool) { _, _ in model.renderPreview() }
            case .reshape:
                sliderRow("Brush size", value: $model.reshapeSize, range: 0.08...0.5, reset: 0.22, undoable: false)
                sliderRow("Strength", value: $model.reshapeStrength, range: 0.1...1, reset: 1, undoable: false)
                HStack(alignment: .firstTextBaseline) {
                    HintText(model.faceCount == 0 ? "No face found in this photo" : warpCaption)
                    PanelTextButton(title: "Reset face") { model.resetReshape() }
                        .disabled(!model.selectedHasPushes || model.busy != nil)
                }
            }
        }
        .animation(.default, value: model.tool)
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

    /// The main Face tabs; the picked one is bold, and a dot marks the ones with a slider moved on the selected face.
    private var areaTabs: some View {
        // Scrolls sideways, as eight names don't fit across a phone at full size.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(FaceArea.allCases) { a in
                        let on = a == area
                        Button { withAnimation { area = a } } label: {
                            Text(changed(a) ? "\(a.rawValue) •" : a.rawValue)
                                .lineLimit(1).fixedSize()
                                .font(.subheadline.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.primary : Color.secondary)
                                .frame(minHeight: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(a)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: area) { _, a in withAnimation { proxy.scrollTo(a, anchor: .center) } }
        }
        .sensoryFeedback(.selection, trigger: area)
    }

    /// The picked main tab's subtabs; a dot marks a moved slider.
    private var subtabChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(area.subtabs, id: \.self) { sub in
                    Chip(title: sub, on: sub == subtab, dot: changed(area, sub)) { subtabs[area] = sub }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: subtab)
    }

    private var faceCaption: String {
        if model.faceCount == 0 { return "No face found in this photo" }
        if !model.reshaping, feature == nil { return "\(area.rawValue) \(subtab) is coming soon" }
        if !model.reshaping, let f = feature, f.needsMesh, !model.selectedHasMesh { return "Couldn't map this face closely enough for \(subtab)" }
        let hint = model.reshaping ? "" : feature?.hint ?? ""
        if model.faceCount == 1 { return hint }
        let which = "Face \((model.selectedFace ?? 0) + 1) of \(model.faceCount) · tap another face to switch"
        return hint.isEmpty ? which : "\(hint) · \(which)"
    }

    private var warpCaption: String {
        let how = "Drag on a face to push it. Drag off the face to move around."
        guard model.faceCount > 1 else { return how }
        return "Face \((model.selectedFace ?? 0) + 1) of \(model.faceCount) · tap another face to switch"
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
        if model.faceCount == 0 { return "No face found in this photo" }
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

    /// A labelled slider with a reset button that puts it back to `reset` (greyed out while it's already there).
    /// For undoable sliders a drag or a reset is one undo step; the others show the brush size on the photo while
    /// they move. `onEditing` and `onReset` replace that for sliders with their own steps (Enhance's Strength).
    private func sliderRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float> = 0...1, reset: Float = 0, undoable: Bool = true,
                           onEditing: ((Bool) -> Void)? = nil, onReset: (() -> Void)? = nil) -> some View {
        HStack(spacing: Space.s) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 92, alignment: .leading)
            ValueSlider(value: value, range: range, reset: reset, editing: { editing in
                sliding = editing
                if let onEditing { onEditing(editing) } else if undoable { model.sliderEditing(editing) } else { brushRing = editing }
            })
            .accessibilityLabel(title)
            ResetButton(label: "Reset \(title)") {
                if let onReset { onReset(); return }
                if undoable { model.sliderEditing(true) }
                value.wrappedValue = reset
                if undoable { model.sliderEditing(false) }
            }
            .disabled(abs(value.wrappedValue - reset) < 0.001 || model.busy != nil)
        }
        .frame(height: 42)
    }
}

extension Tool {
    /// The tool bar's groups: fix and frame the photo, beauty, then remove and replace.
    static let groups: [[Tool]] = [[.enhance, .adjust], [.smooth, .retouch, .face, .reshape], [.heal, .blur]]

    var icon: String {
        switch self {
        case .enhance: return "sparkles"
        case .smooth: return "drop"
        case .retouch: return "wand.and.stars"
        case .blur: return "person.and.background.dotted"
        case .heal: return "bandage"
        case .face: return "face.smiling"
        case .reshape: return "hand.draw"
        case .adjust: return "slider.horizontal.3"
        }
    }

    /// One line about the tool, for the home screen.
    var blurb: String {
        switch self {
        case .enhance: return "Sharper detail"
        case .smooth: return "Soft, even skin"
        case .retouch: return "Teeth, eyes, tone"
        case .blur: return "Blur or remove"
        case .heal: return "Spots and people"
        case .face: return "Reshape features"
        case .reshape: return "Push by hand"
        case .adjust: return "Crop and light"
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
                    .overlay(Ellipse().stroke(Color.faceGuide, lineWidth: 2.5 / zoom))
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
                Self.path(faces.filter(\.selected).flatMap(\.curves), ox, oy, fw, fh).stroke(Color.faceGuide, style: style)
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
