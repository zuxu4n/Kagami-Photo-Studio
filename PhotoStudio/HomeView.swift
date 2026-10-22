import SwiftUI

/// The first screen: open a photo (straight into a tool, if one is picked), the beauty camera or a video.
struct HomeView: View {
    var busy: String?
    var openPhoto: (Tool?) -> Void
    var openVideo: () -> Void
    var openCamera: () -> Void
    var showWelcome: () -> Void
    @State private var showAbout = false
    @State private var welcomeAfterAbout = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                hero
                HStack(spacing: Space.m) {
                    tile(title: "Camera", subtitle: "Film with your look", icon: "camera", tint: .babyBlue, ink: .blueInk, action: openCamera)
                    tile(title: "Video", subtitle: "Smooth and reshape", icon: "play.rectangle", tint: .petal, ink: .pinkInk, action: openVideo)
                }
                tools
                privacy
            }
            .padding(.horizontal, 20)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Color.surface.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .overlay {
            DelayedPresence(value: busy) { text in
                ZStack {
                    Color.shade.opacity(0.12).ignoresSafeArea()
                    HStack(spacing: 10) {
                        ProgressView().tint(Color.pinkInk)
                        Text(text).font(.ui(15, .medium)).foregroundStyle(Color.ink)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .floating(0.14, radius: 20, y: 8)
                }
                .transition(.opacity)
            }
        }
        // The welcome opens once About has finished closing (one sheet can't open while another closes).
        .sheet(isPresented: $showAbout, onDismiss: {
            if welcomeAfterAbout { welcomeAfterAbout = false; showWelcome() }
        }) {
            AboutView(showWelcome: { welcomeAfterAbout = true; showAbout = false })
                .presentationDetents([.large])
                .presentationCornerRadius(28)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Wordmark(size: 30)
            Spacer()
            Button { showAbout = true } label: {
                Image(systemName: "info")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 38, height: 38)
                    .background(Color.surface, in: Circle())
                    .overlay(Circle().stroke(Color.hairline))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("About Miyori")
        }
        .padding(.top, Space.s)
    }

    /// The main way in: a large white card that opens the photo picker.
    private var hero: some View {
        Button { openPhoto(nil) } label: {
            ZStack(alignment: .topLeading) {
                if !typeSize.isAccessibilitySize {   // the larger text needs the room
                    ArchArt(width: 0.36, height: 0.6, inset: 0.07)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit a photo")
                        .font(.display(.title))
                        .foregroundStyle(Color.ink)
                    Text("Retouch, reshape and enhance, right here on your iPhone.")
                        .font(.ui(15))
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 16)
                    HStack(spacing: 6) {
                        Text("Choose a photo")
                        Image(systemName: "arrow.right").font(.ui(13, .semibold))
                    }
                    .font(.ui(15, .semibold))
                    .foregroundStyle(Color.pinkInk)
                    .padding(.horizontal, 18).frame(height: 44)
                    .background(Color.petal, in: Capsule())
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 300)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.hairline))
            .compositingGroup()
            .shadow(color: Color.pink.opacity(0.22), radius: 22, y: 10)   // a soft pink glow under the white card
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityLabel("Edit a photo")
        .accessibilityHint("Opens your photo library")
    }

    private func tile(title: String, subtitle: String, icon: String, tint: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(ink)
                    .frame(width: 44, height: 44)
                    .background(Color.surface, in: Circle())
                Spacer(minLength: 18)
                Text(title).font(.ui(17, .semibold)).foregroundStyle(Color.ink)
                Text(subtitle).font(.ui(13)).foregroundStyle(Color.inkSecondary).padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.97))
    }

    /// Every photo tool, so they're easy to find: each opens the photo picker and then that tool. The beauty tools are
    /// pink, the ones that fix or remove are blue.
    private var tools: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start with a tool")
                .font(.display(.title3))
                .foregroundStyle(Color.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: typeSize.isAccessibilitySize ? 2 : 4),
                      spacing: 18) {
                ForEach(Tool.groups.flatMap { $0 }) { t in
                    Button { openPhoto(t) } label: {
                        VStack(spacing: 7) {
                            Image(systemName: t.icon)
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(Tool.groups[1].contains(t) ? Color.pinkInk : Color.blueInk)
                                .frame(width: 56, height: 56)
                                .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.hairline))
                            Text(t.rawValue).font(.ui(12, .medium)).foregroundStyle(Color.ink).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                    .accessibilityLabel("\(t.rawValue): \(t.blurb)")
                    .accessibilityHint("Choose a photo to open in \(t.rawValue)")
                }
            }
        }
    }

    private var privacy: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.blueInk)
                .frame(width: 26, height: 26).background(Color.babyBlue, in: Circle())
            Text("Everything happens on this iPhone. Your photos are never uploaded.")
                .font(.ui(13))
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Space.xs)
    }
}

/// "miyori" set in New York, with a small pink dot: the app's name wherever it appears.
struct Wordmark: View {
    var size: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
            Text("miyori").font(.display(size, weight: .medium)).tracking(-0.5).foregroundStyle(Color.ink)
            Circle().fill(Color.pink).frame(width: size * 0.2, height: size * 0.2)
        }
        .accessibilityElement()
        .accessibilityLabel("Miyori")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Miyori's motif: an arched mirror in baby blue standing on the bottom edge, with a pink sun rising behind it.
/// `width` and `height` are the arch's share of the space; it sits `inset` (a share of the width) from the right.
struct ArchArt: View {
    var width: CGFloat = 0.42
    var height: CGFloat = 0.86
    var inset: CGFloat = 0.08

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let archW = min(w * width, 200), archH = min(h * height, archW * 1.7)
            let arch = CGRect(x: w - archW - w * inset, y: h - archH, width: archW, height: archH + 2)
            // The sun, behind the arch's shoulder.
            let sun = archW * 0.42
            ctx.fill(Path(ellipseIn: CGRect(x: arch.minX - sun * 0.45, y: arch.minY + archW * 0.12, width: sun, height: sun)),
                     with: .color(.pink))
            ctx.fill(archPath(arch), with: .color(.babyBlue))
            // A thin inner line, like a mirror's bevel.
            ctx.stroke(archPath(arch.insetBy(dx: archW * 0.09, dy: archW * 0.09)), with: .color(.white.opacity(0.75)), lineWidth: 1.2)
            // Two small sparkles.
            for (p, r) in [(CGPoint(x: arch.midX + archW * 0.18, y: arch.minY + archW * 0.42), archW * 0.07),
                           (CGPoint(x: arch.midX - archW * 0.05, y: arch.minY + archW * 0.62), archW * 0.04)] {
                ctx.fill(sparkle(at: p, r: r), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func archPath(_ r: CGRect) -> Path {
        Path { p in
            let radius = r.width / 2
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            p.addArc(center: CGPoint(x: r.midX, y: r.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
        }
    }

    private func sparkle(at c: CGPoint, r: CGFloat) -> Path {
        Path { p in
            let k = r * 0.22
            p.move(to: CGPoint(x: c.x, y: c.y - r))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
            p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
        }
    }
}

// MARK: Welcome

/// Shown once, the first time Miyori opens.
struct WelcomeView: View {
    var done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ArchArt()
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .background(Color.petal)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(.top, Space.l)
                Text("Welcome to Miyori")
                    .font(.display(.largeTitle))
                    .foregroundStyle(Color.ink)
                    .padding(.top, 28)
                Text("A photo studio that lives on your iPhone.")
                    .font(.ui(16))
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 20) {
                    point("lock", "Private by design", "Every edit happens on this iPhone. Nothing is uploaded.", blue: true)
                    point("wand.and.stars", "Studio retouching", "Enhance, smooth skin, reshape features and remove what doesn't belong.")
                    point("heart", "Free and open source", "No subscription, no watermark, no account.")
                }
                .padding(.top, 28)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, Space.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button("Get started", action: done)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.vertical, Space.s)
                .background(Color.surface)
        }
        .background(Color.surface.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .presentationCornerRadius(28)
    }

    private func point(_ icon: String, _ title: String, _ text: String, blue: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(blue ? Color.blueInk : Color.pinkInk)
                .frame(width: 40, height: 40)
                .background(blue ? Color.babyBlue : Color.petal, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(16, .semibold)).foregroundStyle(Color.ink)
                Text(text).font(.ui(14)).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: About

/// About Miyori: privacy, the source code, the open models it runs on, and the welcome again.
struct AboutView: View {
    var showWelcome: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.inkSecondary)
                            .frame(width: 30, height: 30).background(Color.hairline, in: Circle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .accessibilityLabel("Close")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Wordmark(size: 34)
                    Text(version).font(.ui(13)).foregroundStyle(Color.inkSecondary)
                }
                group("Privacy") {
                    row(icon: "lock", title: "On this iPhone only",
                        text: "Miyori has no servers and no network code. Photos and videos are only read when you pick them, and saved copies go straight to Photos.",
                        blue: true)
                }
                group("Open source") {
                    Link(destination: URL(string: "https://github.com/zuxu4n/Kagami-Photo-Studio")!) {
                        row(icon: "chevron.left.forwardslash.chevron.right", title: "Source code on GitHub",
                            text: "Free to use, read and improve.", trailing: "arrow.up.right")
                    }
                }
                group("Built with open models") {
                    row(icon: "sparkles", title: "Real-ESRGAN", text: "Enhance · BSD-3-Clause")
                    divider
                    row(icon: "bandage", title: "LaMa", text: "Heal · Apache-2.0")
                    divider
                    row(icon: "face.smiling", title: "MediaPipe Face Mesh", text: "Face · Apache-2.0")
                }
                Button(action: showWelcome) {
                    Text("Show the welcome again").font(.ui(15, .semibold)).foregroundStyle(Color.pinkInk)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, Space.l)
        }
        .background(Color.surface.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var divider: some View { Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, 56) }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.ui(12, .semibold)).tracking(0.6).foregroundStyle(Color.inkSecondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.hairline))
        }
    }

    private func row(icon: String, title: String, text: String, trailing: String? = nil, blue: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(blue ? Color.blueInk : Color.pinkInk)
                .frame(width: 32, height: 32).background(blue ? Color.babyBlue : Color.petal, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(15, .semibold)).foregroundStyle(Color.ink)
                Text(text).font(.ui(13)).foregroundStyle(Color.inkSecondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let trailing { Image(systemName: trailing).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.inkTertiary) }
        }
        .padding(12)
    }
}
