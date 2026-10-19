import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var comparing = false
    @State private var sliding = false     // a slider is being dragged
    @State private var touching = false    // a finger is on the photo

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                canvas
                if model.hasImage {
                    toolPicker
                    toolPanel
                    timingList
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .navigationTitle("PhotoStudio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Photo", systemImage: "photo.on.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.hasImage || model.busy != nil)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { await model.load(data: data) }
                }
            }
            .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.error ?? "")
            }
            .task {
                await model.warmUp()
                if EnhanceBench.requested { await model.runEnhanceBench() }
            }
            .onChange(of: model.tool) { _, t in model.toolShown(t) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                model.noteMemoryWarning()
            }
        }
    }

    // MARK: Canvas with hold-to-compare and tap-to-heal

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = comparing ? model.original : model.display {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.largeTitle)
                        Text("Choose a photo to start").font(.callout)
                        Text("Everything runs on this iPhone. Nothing is uploaded.").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if model.tool == .face, model.display != nil {
                    FaceGuides(curves: model.faceGuides(minGap:), imageSize: model.previewSize)
                        .opacity(sliding || touching || comparing || model.busy != nil ? 0.3 : 1)  // dim, don't hide, while adjusting
                        .animation(.easeInOut(duration: sliding || touching ? 0.15 : 0.35), value: sliding || touching || comparing)
                        .allowsHitTesting(false)
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
                case .heal: Task { await model.heal(at: p) }
                case .face: model.selectFace(at: p)
                default: break
                }
            }
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 30, pressing: { pressing in
                if model.tool != .heal { comparing = pressing }
            }, perform: {})
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !touching { touching = true } }
                .onEnded { _ in touching = false })
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Maps a tap in the view to preview pixel coordinates (the image is aspect-fit).
    private func imagePoint(_ p: CGPoint, in view: CGSize) -> CGPoint? {
        let img = model.previewSize
        guard img.width > 0, img.height > 0 else { return nil }
        let s = min(view.width / img.width, view.height / img.height)
        let ox = (view.width - img.width * s) / 2, oy = (view.height - img.height * s) / 2
        let x = (p.x - ox) / s, y = (p.y - oy) / s
        guard x >= 0, y >= 0, x < img.width, y < img.height else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: Tools

    private var toolPicker: some View {
        Picker("Tool", selection: $model.tool) {
            ForEach(Tool.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
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
                Text("Real-ESRGAN on device, from the photo's own pixels. Never smaller than the original (up to 4x for small photos); faces stay as they are. Tap again to undo.").font(.caption).foregroundStyle(.secondary)
            case .smooth:
                sliderRow("Smooth skin", value: $model.smooth)
                HStack { Text(model.faceCount == 0 ? "No face found" : "Edges, eyes and lips stay sharp").font(.caption).foregroundStyle(.secondary); Spacer(); compareButton }
            case .heal:
                sliderRow("Brush", value: $model.brush, range: 0.01...0.08)
                Text("Tap a spot to remove it (LaMa, on device).").font(.caption).foregroundStyle(.secondary)
            case .face:
                sliderRow("Slim face", value: $model.slim)
                sliderRow("Bigger eyes", value: $model.eyes)
                sliderRow("Slim nose", value: $model.nose)
                HStack { Text(model.faceCount == 0 ? "No face found" : model.faceCount == 1 ? "Apple Vision landmarks" : "Tap a face to edit it; each face keeps its own settings").font(.caption).foregroundStyle(.secondary); Spacer(); compareButton }
            }
            Text(model.info).font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: model.smooth) { _, _ in model.renderPreview() }
        .onChange(of: model.slim) { _, _ in model.renderPreview() }
        .onChange(of: model.eyes) { _, _ in model.renderPreview() }
        .onChange(of: model.nose) { _, _ in model.renderPreview() }
    }

    private var compareButton: some View {
        Text("Hold to compare")
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { comparing = $0 }, perform: {})
    }

    private func sliderRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float> = 0...1) -> some View {
        HStack {
            Text(title).font(.subheadline).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range) { sliding = $0 }
        }
    }

    private var timingList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.timings, id: \.0) { item in
                HStack {
                    Text(item.0).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f ms", item.1)).monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two thin curves bracketing each face, drawn over the aspect-fit photo: cyan on the selected face, white on the others.
private struct FaceGuides: View {
    let curves: (CGFloat) -> [(curves: [[CGPoint]], selected: Bool)]   // normalised, top-left origin; takes the minimum gap in image pixels
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / max(imageSize.width, 1), geo.size.height / max(imageSize.height, 1))
            let fw = imageSize.width * s, fh = imageSize.height * s
            let ox = (geo.size.width - fw) / 2, oy = (geo.size.height - fh) / 2
            let faces = self.curves(14 / max(s, 0.001))   // never closer than 14 points on screen
            let style = StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
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
