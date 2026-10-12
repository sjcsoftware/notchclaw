// Renders the NotchClaw app icon (1024px master) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824pt rounded square centered in 1024.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient (deep graphite)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.16, green: 0.15, blue: 0.22, alpha: 1).cgColor,
        NSColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Notch silhouette with neon glow at the top of the icon.
    let notchW = 430 * s, notchH = 150 * s
    let nx = body.midX - notchW / 2, ny = body.maxY - notchH
    let ear = 26 * s, r = 58 * s
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: nx - ear, y: body.maxY))
    notch.addQuadCurve(to: CGPoint(x: nx, y: body.maxY - ear), control: CGPoint(x: nx, y: body.maxY))
    notch.addLine(to: CGPoint(x: nx, y: ny + r))
    notch.addQuadCurve(to: CGPoint(x: nx + r, y: ny), control: CGPoint(x: nx, y: ny))
    notch.addLine(to: CGPoint(x: nx + notchW - r, y: ny))
    notch.addQuadCurve(to: CGPoint(x: nx + notchW, y: ny + r), control: CGPoint(x: nx + notchW, y: ny))
    notch.addLine(to: CGPoint(x: nx + notchW, y: body.maxY - ear))
    notch.addQuadCurve(to: CGPoint(x: nx + notchW + ear, y: body.maxY), control: CGPoint(x: nx + notchW, y: body.maxY))
    notch.closeSubpath()

    let neon: [NSColor] = [
        NSColor(red: 1.0, green: 0.18, blue: 0.58, alpha: 1),
        NSColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1),
        NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1),
        NSColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1),
    ]
    for (width, alpha, blur) in [(34.0, 0.55, 40.0), (14.0, 0.9, 14.0), (5.0, 1.0, 0.0)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur * s, color: neon[1].withAlphaComponent(alpha).cgColor)
        ctx.addPath(notch)
        ctx.setLineWidth(width * s)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: neon.map(\.cgColor) as CFArray, locations: nil)!
        ctx.setAlpha(alpha)
        ctx.drawLinearGradient(g, start: CGPoint(x: nx - ear, y: 0), end: CGPoint(x: nx + notchW + ear, y: 0), options: [])
        ctx.restoreGState()
    }
    ctx.addPath(notch)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Lobster mark below the notch.
    let emoji = "🦞" as NSString
    let font = NSFont.systemFont(ofSize: 380 * s)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let textSize = emoji.size(withAttributes: attrs)
    emoji.draw(at: CGPoint(x: body.midX - textSize.width / 2, y: body.minY + 120 * s), withAttributes: attrs)

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
print("Wrote \(output.path)")
