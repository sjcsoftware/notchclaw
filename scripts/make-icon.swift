// Renders the NotchClaw app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset> [preview.png]
//
// Design: a graphite squircle with the notch cut into its top edge, lit from
// below by a soft spectrum glow, and three tapered claw marks raking across.
import AppKit

let args = CommandLine.arguments.dropFirst()
let output = URL(fileURLWithPath: args.first ?? "AppIcon.iconset")
let preview = args.dropFirst().first.map { URL(fileURLWithPath: $0) }
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
let pink = color(1.00, 0.24, 0.58)
let violet = color(0.62, 0.36, 1.00)
let blue = color(0.26, 0.55, 1.00)
let cyan = color(0.20, 0.88, 0.95)

/// Continuous-corner rounded rect approximating Apple's squircle.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.28  // corner extension for continuous curvature
    let c = radius * k
    p.move(to: CGPoint(x: r.minX + c, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + c),
               control1: CGPoint(x: r.maxX - c * 0.35, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + c * 0.35))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
    p.addCurve(to: CGPoint(x: r.maxX - c, y: r.maxY),
               control1: CGPoint(x: r.maxX, y: r.maxY - c * 0.35), control2: CGPoint(x: r.maxX - c * 0.35, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - c),
               control1: CGPoint(x: r.minX + c * 0.35, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - c * 0.35))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
    p.addCurve(to: CGPoint(x: r.minX + c, y: r.minY),
               control1: CGPoint(x: r.minX, y: r.minY + c * 0.35), control2: CGPoint(x: r.minX + c * 0.35, y: r.minY))
    p.closeSubpath()
    return p
}

/// A tapered, slightly curved slash: sharp at both ends, widest in the middle.
func clawMark(from a: CGPoint, to b: CGPoint, bend: CGFloat, width: CGFloat) -> CGPath {
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    let dx = b.x - a.x, dy = b.y - a.y
    let len = sqrt(dx * dx + dy * dy)
    let nx = -dy / len, ny = dx / len
    let outer = CGPoint(x: mid.x + nx * (bend + width), y: mid.y + ny * (bend + width))
    let inner = CGPoint(x: mid.x + nx * (bend - width), y: mid.y + ny * (bend - width))
    let p = CGMutablePath()
    p.move(to: a)
    p.addQuadCurve(to: b, control: outer)
    p.addQuadCurve(to: a, control: inner)
    p.closeSubpath()
    return p
}

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body, radius: 150)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0, 0, 0, 0.5))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0.05, 0.05, 0.07))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Graphite body, slightly lighter at the bottom where the glow lives.
    let bg = CGGradient(colorsSpace: space, colors: [color(0.10, 0.10, 0.13), color(0.035, 0.035, 0.05)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

    // Spectrum bloom rising from below the notch.
    let bloom = CGGradient(colorsSpace: space, colors: [color(0.55, 0.30, 1.0, 0.55), color(0.2, 0.5, 1.0, 0.18), color(0, 0, 0, 0)] as CFArray,
                           locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 430, options: [])

    // Claw marks: three tapered slashes with a spectrum fill and neon glow.
    let marks: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 400, y: 690), CGPoint(x: 300, y: 300)),
        (CGPoint(x: 540, y: 715), CGPoint(x: 440, y: 270)),
        (CGPoint(x: 680, y: 690), CGPoint(x: 580, y: 300)),
    ]
    let claws = CGMutablePath()
    for (a, b) in marks { claws.addPath(clawMark(from: a, to: b, bend: 24, width: 44)) }

    for (blur, alpha) in [(60.0, 0.55), (22.0, 0.7)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: color(0.6, 0.35, 1.0, alpha))
        ctx.addPath(claws)
        ctx.setFillColor(color(0.6, 0.35, 1.0, 0.9))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(claws)
    ctx.clip()
    let spectrum = CGGradient(colorsSpace: space, colors: [pink, violet, blue, cyan] as CFArray, locations: [0, 0.35, 0.7, 1])!
    ctx.drawLinearGradient(spectrum, start: CGPoint(x: 330, y: 700), end: CGPoint(x: 640, y: 290), options: [])
    // Glossy highlight along the top of each mark.
    let gloss = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.35), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: 720), end: CGPoint(x: 0, y: 520), options: [])
    ctx.restoreGState()

    // The notch, cut into the top edge, with a thin lit rim.
    let notchW: CGFloat = 330, notchH: CGFloat = 92, ear: CGFloat = 22, r: CGFloat = 40
    let nx = body.midX - notchW / 2, top = body.maxY, ny = top - notchH
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: nx - ear, y: top + 2))
    notch.addQuadCurve(to: CGPoint(x: nx, y: top - ear), control: CGPoint(x: nx, y: top))
    notch.addLine(to: CGPoint(x: nx, y: ny + r))
    notch.addQuadCurve(to: CGPoint(x: nx + r, y: ny), control: CGPoint(x: nx, y: ny))
    notch.addLine(to: CGPoint(x: nx + notchW - r, y: ny))
    notch.addQuadCurve(to: CGPoint(x: nx + notchW, y: ny + r), control: CGPoint(x: nx + notchW, y: ny))
    notch.addLine(to: CGPoint(x: nx + notchW, y: top - ear))
    notch.addQuadCurve(to: CGPoint(x: nx + notchW + ear, y: top + 2), control: CGPoint(x: nx + notchW, y: top))
    notch.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: color(0.55, 0.4, 1.0, 0.75))
    ctx.addPath(notch)
    ctx.setStrokeColor(color(0.75, 0.6, 1.0, 0.9))
    ctx.setLineWidth(5)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(notch)
    ctx.setFillColor(color(0, 0, 0))
    ctx.fillPath()

    // Subtle top sheen across the body.
    let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.07), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(color(1, 1, 1, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let data = render(size: px).representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent("\(name).png"))
}
if let preview {
    try render(size: 1024).representation(using: .png, properties: [:])!.write(to: preview)
}
print("Wrote \(output.path)")
