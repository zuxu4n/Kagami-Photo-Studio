import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Draws Yumiro's app icon: a baby-blue arched mirror standing on a soft pink ground, a pink sun behind its shoulder,
// and two white sparkles. 1024 x 1024, no transparency. Run on a Mac:
//   swift tools/icon/make_icon.swift PhotoStudio/Assets.xcassets/AppIcon.appiconset/AppIcon.png
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let s: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Flip so y grows downwards, like the app's drawing code.
ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)

// Ground: petal pink, paler at the top.
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(0xFFF1F6), color(0xFFD3E4)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: s), options: [])

let archW: CGFloat = 470, archTop: CGFloat = 250
let arch = CGRect(x: (s - archW) / 2 + 40, y: archTop, width: archW, height: s - archTop + 10)
func archPath(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let radius = r.width / 2
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
    p.addArc(center: CGPoint(x: r.midX, y: r.minY + radius), radius: radius, startAngle: .pi, endAngle: 0, clockwise: false)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.closeSubpath()
    return p
}
// The sun, behind the arch's left shoulder.
let sun: CGFloat = 250
ctx.setFillColor(color(0xFF85B2))
ctx.fillEllipse(in: CGRect(x: arch.minX - sun * 0.52, y: arch.minY + 40, width: sun, height: sun))
// The arch, with a thin bevel line.
ctx.addPath(archPath(arch)); ctx.setFillColor(color(0xC4E6FF)); ctx.fillPath()
ctx.addPath(archPath(arch.insetBy(dx: 38, dy: 38))); ctx.setStrokeColor(color(0xFFFFFF, 0.9)); ctx.setLineWidth(7); ctx.strokePath()
// Sparkles.
func sparkle(_ c: CGPoint, _ r: CGFloat) {
    let k = r * 0.22
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
    ctx.addPath(p); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
}
sparkle(CGPoint(x: arch.midX + 80, y: arch.minY + 210), 62)
sparkle(CGPoint(x: arch.midX - 30, y: arch.minY + 320), 30)

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
