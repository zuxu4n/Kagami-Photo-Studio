import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var comparing = false

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
                if let b = model.busy {
                    ProgressView(b).padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if comparing { Text("Original").font(.caption.bold()).padding(6).background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .top).padding(.top, 8) }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard model.tool == .heal, model.busy == nil, let p = imagePoint(location, in: geo.size) else { return }
                Task { await model.heal(at: p) }
            }
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 30, pressing: { pressing in
                if model.tool != .heal { comparing = pressing }
            }, perform: {})
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
                        Label("Enhance ×4", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy != nil)
                    Spacer()
                    compareButton
                }
                Text("Real-ESRGAN on device. Long side capped at 1024 px in, up to 4096 px out.").font(.caption).foregroundStyle(.secondary)
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
                HStack { Text(model.faceCount == 0 ? "No face found" : "Apple Vision landmarks").font(.caption).foregroundStyle(.secondary); Spacer(); compareButton }
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
            Slider(value: value, in: range)
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
