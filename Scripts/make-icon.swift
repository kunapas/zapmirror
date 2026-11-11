// Draws the Zapmirror app icon as a 1024 px PNG: an Android-style phone and a big window showing its screen stand on
// a still, glossy floor at night, reflected beneath; a pointer clicks the window. Zapdrop's sibling: the phone,
// gallery and lighting are Zapdrop's (Ferry/Scripts/make-icon.swift). No Apple or Google marks (App Review guideline
// 5.2.5, Android brand rules): the window has plain dots, not Apple's window controls.
//   swift Scripts/make-icon.swift <output.png>
// Scripts/make-icon.sh turns it into App/Zapmirror/AppIcon.icns.
import AppKit
import SwiftUI

/// macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
let canvas: CGFloat = 1024
let tile: CGFloat = 824
let tileShape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)

func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        .opacity(alpha)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
/// Tile coordinates (0…1 of the tile) to points.
func T(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * tile, y: y * tile) }
func polyline(_ pts: [CGPoint]) -> Path { var p = Path(); p.addLines(pts); return p }

/// A closed polygon in unit coordinates (0…1 of its frame).
struct Poly: Shape {
    let pts: [CGPoint]
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addLines(pts.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) })
        p.closeSubpath()
        return p
    }
}

/// SplitMix64, so the sparkles land in the same places on every run.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(UInt64(1) << 53)
    }
}

let darkInk = rgb(0x111318)
let textLine = rgb(0xC5CBD3)
let playTriangle = Poly(pts: [P(0.38, 0.27), P(0.78, 0.5), P(0.38, 0.73)])

// MARK: - Content

/// A tiny landscape (sky, sun, two hill bands) standing in for a photo or a video frame.
struct PhotoScene: View {
    let i: Int
    var body: some View {
        let palettes: [(sky: [UInt32], sun: UInt32, far: UInt32, near: UInt32)] = [
            ([0xFF9A6B, 0xFFD27A], 0xFFF4D6, 0x9B5DE5, 0x5B2A86), // sunset
            ([0x4CC3FF, 0xBFEFFF], 0xFFE066, 0x5FBF8F, 0x2F8F5B), // meadow
            ([0x2E3192, 0xC86DD7], 0xFFD1F0, 0x4B2C82, 0x1F1446), // dusk
            ([0x7FDBFF, 0xFFF1C1], 0xFFFFFF, 0x00A6C8, 0xF7D59C), // beach
            ([0xFFB199, 0xFFE3A3], 0xFFFFFF, 0xE76F51, 0x8E3B2E), // desert
        ]
        let p = palettes[i % palettes.count]
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: p.sky.map { rgb($0) }, startPoint: .top, endPoint: .bottom)
                Circle().fill(rgb(p.sun)).frame(width: g.size.width * 0.2, height: g.size.width * 0.2)
                    .position(x: g.size.width * 0.72, y: g.size.height * 0.32)
                Poly(pts: [P(0, 0.75), P(0.25, 0.42), P(0.45, 0.62), P(0.62, 0.38), P(1, 0.70), P(1, 1), P(0, 1)]).fill(rgb(p.far))
                Poly(pts: [P(0, 0.88), P(0.35, 0.70), P(0.7, 0.84), P(1, 0.76), P(1, 1), P(0, 1)]).fill(rgb(p.near))
            }
        }
    }
}

/// One tile of the phone's gallery: a photo, a video (photo with a play button) or a document.
struct GalleryTile: View {
    enum Kind { case photo, video, document }
    let kind: Kind
    let scene: Int
    var body: some View {
        GeometryReader { g in
            let m = min(g.size.width, g.size.height)
            ZStack {
                switch kind {
                case .document:
                    Color.white
                    VStack(alignment: .leading, spacing: m * 0.1) {
                        RoundedRectangle(cornerRadius: m * 0.05).fill(rgb(scene % 2 == 0 ? 0xE5484D : 0x3B82F6))
                            .frame(width: m * 0.32, height: m * 0.2)
                        ForEach([0.6, 0.45, 0.55], id: \.self) { f in Capsule().fill(textLine).frame(width: m * f, height: m * 0.07) }
                    }
                case .photo, .video:
                    PhotoScene(i: scene)
                    if kind == .video {
                        Circle().fill(Color.white.opacity(0.92)).frame(width: m * 0.38, height: m * 0.38)
                        playTriangle.fill(darkInk).frame(width: m * 0.38, height: m * 0.38)
                    }
                }
            }
        }
    }
}

/// The phone's gallery: a grid that cycles photo, video, photo, document.
struct Gallery: View {
    let cols: Int
    let rows: Int
    var body: some View {
        let kinds: [GalleryTile.Kind] = [.photo, .video, .photo, .document]
        GeometryReader { g in
            let gap = g.size.width * 0.045
            let cw = (g.size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
            let ch = (g.size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            ZStack(alignment: .topLeading) {
                ForEach(0..<(cols * rows), id: \.self) { i in
                    GalleryTile(kind: kinds[i % kinds.count], scene: i * 3)
                        .frame(width: cw, height: ch)
                        .clipShape(RoundedRectangle(cornerRadius: min(cw, ch) * 0.14, style: .continuous))
                        .offset(x: gap + CGFloat(i % cols) * (cw + gap), y: gap + CGFloat(i / cols) * (ch + gap))
                }
            }
        }
    }
}

// MARK: - Phone

/// A modern Android-style phone: metal frame, punch-hole camera, a bright gallery on screen.
struct Phone: View {
    let w: CGFloat
    var body: some View {
        let h = w * 2.05
        let frame = RoundedRectangle(cornerRadius: w * 0.17, style: .continuous)
        let screen = RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
        ZStack {
            frame.fill(LinearGradient(colors: [rgb(0x464B55), rgb(0x16181C)], startPoint: .top, endPoint: .bottom))
            frame.strokeBorder(LinearGradient(colors: [rgb(0xF0F3F6), rgb(0x6B727C), rgb(0xC3C9D1)], startPoint: .topLeading,
                                              endPoint: .bottomTrailing), lineWidth: w * 0.025)
            ZStack {
                screen.fill(LinearGradient(colors: [rgb(0xFFFFFF), rgb(0xD8F7FF), rgb(0x8AD0FF)], startPoint: .top, endPoint: .bottom))
                Gallery(cols: 3, rows: 5).padding(.top, w * 0.16).padding(.bottom, w * 0.10).padding(.horizontal, w * 0.02)
                // Glass reflection across the screen.
                screen.fill(LinearGradient(colors: [Color.white.opacity(0.30), .clear], startPoint: .topLeading, endPoint: .center))
            }
            .clipShape(screen)
            .padding(w * 0.055)
            Circle().fill(Color.black).frame(width: w * 0.07, height: w * 0.07).offset(y: -h * 0.43)
        }
        .frame(width: w, height: h)
    }
}


// MARK: - The Mac side

/// The phone's screen content on its own, so the window on the Mac shows the same thing as the phone.
struct ScreenContent: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [rgb(0xFFFFFF), rgb(0xD8F7FF), rgb(0x8AD0FF)], startPoint: .top, endPoint: .bottom)
            Gallery(cols: 3, rows: 5).padding(.top, 6).padding(.bottom, 4)
        }
    }
}

/// A generic dark window showing the phone's screen. Neutral dots, not Apple's window controls.
struct MirrorWindow: View {
    let w: CGFloat
    var ratio: CGFloat = 1.75
    var body: some View {
        let outer = RoundedRectangle(cornerRadius: w * 0.07, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: w * 0.045, style: .continuous)
        ZStack(alignment: .top) {
            outer.fill(LinearGradient(colors: [rgb(0x2A2F3A), rgb(0x12141A)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 0) {
                HStack(spacing: w * 0.03) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.45)).frame(width: w * 0.04) }
                    Spacer()
                }
                .padding(.horizontal, w * 0.05)
                .frame(height: w * 0.1)
                ZStack {
                    ScreenContent()
                    inner.fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear], startPoint: .topLeading, endPoint: .center))
                }
                .clipShape(inner)
                .padding([.horizontal, .bottom], w * 0.04)
            }
            outer.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.08)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: w * 0.012)
        }
        .frame(width: w, height: w * ratio)
    }
}

/// A mouse pointer whose tip is the frame's top-left corner.
struct Pointer: View {
    let s: CGFloat
    var body: some View {
        let arrow = Poly(pts: [P(0.04, 0.03), P(0.04, 0.80), P(0.25, 0.63), P(0.41, 0.97), P(0.57, 0.90),
                               P(0.42, 0.57), P(0.72, 0.57)])
        ZStack {
            arrow.fill(LinearGradient(colors: [rgb(0xFFFFFF), rgb(0xDDE3EA)], startPoint: .top, endPoint: .bottom))
            arrow.stroke(darkInk, style: StrokeStyle(lineWidth: s * 0.06, lineJoin: .round))
        }
        .frame(width: s, height: s * 1.45)
        .shadow(color: .black.opacity(0.4), radius: s * 0.08, x: s * 0.04, y: s * 0.08)
    }
}

/// Rings spreading from a click.
struct Ripples: View {
    let r: CGFloat
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle().stroke(rgb(0x0EA5E9, 0.9 - Double(i) * 0.25), lineWidth: r * (0.09 - CGFloat(i) * 0.02))
                    .frame(width: r * CGFloat(i + 1) * 0.75, height: r * CGFloat(i + 1) * 0.75)
            }
            Circle().fill(rgb(0x0EA5E9)).frame(width: r * 0.22, height: r * 0.22)
        }
        .frame(width: r * 2.4, height: r * 2.4)
    }
}

// MARK: - Icon

/// Where the scene stands: the floor's horizon, as a fraction of the tile's height.
let horizon: CGFloat = 0.70

/// The phone and the big window showing its screen, standing on the horizon, a pointer clicking the window.
struct Scene: View {
    var body: some View {
        let windowWidth: CGFloat = 0.38, windowRatio: CGFloat = 1.55
        let phoneWidth: CGFloat = 0.20
        let pointerSize = tile * 0.11
        let tipPoint = T(0.675, 0.43)
        ZStack {
            MirrorWindow(w: tile * windowWidth, ratio: windowRatio)
                .shadow(color: rgb(0xA5F3FC, 0.85), radius: 28)
                .position(T(0.635, horizon - windowWidth * windowRatio / 2))
            Phone(w: tile * phoneWidth)
                .shadow(color: rgb(0xA5F3FC, 0.45), radius: 22)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                .position(T(0.265, horizon - phoneWidth * 2.05 / 2))
            Ripples(r: tile * 0.06).position(tipPoint)
            Pointer(s: pointerSize)
                .position(x: tipPoint.x + pointerSize / 2, y: tipPoint.y + pointerSize * 1.45 / 2)
        }
        .frame(width: tile, height: tile)
    }
}

/// Faint stars and a few four-point sparkles in the night sky.
struct Sky: View {
    var body: some View {
        Canvas { ctx, _ in
            var random = SeededGenerator(seed: 3)
            for _ in 0..<26 {
                let c = T(0.04 + random.unit() * 0.92, 0.03 + random.unit() * 0.22)
                let r = tile * (0.002 + random.unit() * 0.003)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(.white.opacity(0.5 + random.unit() * 0.4)))
            }
            for (x, y, r) in [(0.13, 0.12, 0.034), (0.21, 0.07, 0.016), (0.87, 0.09, 0.026), (0.93, 0.19, 0.014), (0.42, 0.06, 0.012)] {
                let c = T(x, y), size = tile * r
                var star = Path()
                star.move(to: CGPoint(x: c.x, y: c.y - size))
                star.addQuadCurve(to: CGPoint(x: c.x + size, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + size), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x - size, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - size), control: c)
                ctx.fill(star, with: .color(.white.opacity(0.95)))
            }
        }
    }
}

/// Thin light lines across the reflection, so the floor reads as still water.
struct WaterLines: View {
    var body: some View {
        Canvas { ctx, _ in
            var random = SeededGenerator(seed: 9)
            for i in 0..<9 {
                let y = horizon + 0.035 + CGFloat(i) * 0.03
                let x = 0.08 + random.unit() * 0.35
                let length = 0.18 + random.unit() * 0.4
                ctx.stroke(polyline([T(x, y), T(min(x + length, 0.94), y)]),
                           with: .color(.white.opacity(0.16 - Double(i) * 0.012)),
                           style: StrokeStyle(lineWidth: tile * 0.005, lineCap: .round))
            }
        }
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            ZStack {
                LinearGradient(colors: [rgb(0x0F172A), rgb(0x1D4ED8), rgb(0x22D3EE)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: horizon))
                RadialGradient(colors: [rgb(0x67E8F9, 0.45), .clear], center: UnitPoint(x: 0.55, y: 0.5), startRadius: 0, endRadius: tile * 0.42)
                Sky()
                // The floor: lit at the horizon, darkening towards the viewer.
                Rectangle().fill(LinearGradient(colors: [rgb(0x1E40AF), rgb(0x0B1530)], startPoint: .top, endPoint: .bottom))
                    .frame(height: tile * (1 - horizon)).position(T(0.5, (1 + horizon) / 2))
                Ellipse().fill(rgb(0x67E8F9, 0.35)).frame(width: tile * 0.8, height: tile * 0.07).blur(radius: 16)
                    .position(T(0.5, horizon + 0.02))
                Scene()
                Scene()
                    .scaleEffect(x: 1, y: -1)
                    .offset(y: tile * (2 * horizon - 1))
                    .blur(radius: 1.5)
                    .opacity(0.55)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: UnitPoint(x: 0.5, y: horizon), endPoint: UnitPoint(x: 0.5, y: 1)))
                WaterLines()
                Capsule().fill(Color.white.opacity(0.85)).frame(width: tile * 0.9, height: 3).blur(radius: 1.5)
                    .shadow(color: rgb(0x67E8F9), radius: 12)
                    .position(T(0.5, horizon))
            }
            .frame(width: tile, height: tile)
            .clipShape(tileShape)
            tileShape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.02)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 3)
        }
        .frame(width: tile, height: tile)
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
func render(to path: String) throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    renderer.isOpaque = false
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
try MainActor.assumeIsolated { try render(to: output) }
print("Wrote \(output)")
