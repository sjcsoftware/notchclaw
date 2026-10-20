import AppKit
import CoreText
import SwiftUI

/// Typeset LaTeX, ready to show inline in `Text` or as a display block.
final class MathImage {
    let image: NSImage
    let ascent: CGFloat
    let descent: CGFloat

    init(image: NSImage, ascent: CGFloat, descent: CGFloat) {
        self.image = image
        self.ascent = ascent
        self.descent = descent
    }

    /// For concatenating into a line of text; sits on the text baseline and takes the text color.
    var text: Text {
        Text(Image(nsImage: image).renderingMode(.template)).baselineOffset(-descent)
    }
}

/// Renders LaTeX math with a small TeX-style box layout, set in the STIX Two Math font that ships with macOS.
enum MathRenderer {
    /// STIX has a smaller x-height than SF; this scale matches math to the surrounding text.
    static let textScale: CGFloat = 1.1

    private static let cache: NSCache<NSString, MathImage> = {
        let cache = NSCache<NSString, MathImage>()
        cache.countLimit = 400
        return cache
    }()

    static func render(_ latex: String, size: CGFloat, display: Bool) -> MathImage {
        let key = "\(display ? "D" : "T")\(size)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let box = MathTypesetter(size: size).layout(MathParser.parse(latex), display ? .display : .text)
        let padX = size * 0.08, padY = size * 0.1
        let width = max(1, ceil(box.width + 2 * padX))
        let descent = ceil(box.descent + padY)
        let ascent = ceil(box.ascent + padY)

        let scale: CGFloat = 2
        let image: NSImage
        if let ctx = CGContext(data: nil, width: Int(width * scale), height: Int((ascent + descent) * scale),
                               bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.scaleBy(x: scale, y: scale)
            ctx.textMatrix = .identity
            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            box.draw(ctx, CGPoint(x: padX, y: descent))
            image = ctx.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: width, height: ascent + descent)) }
                ?? NSImage(size: NSSize(width: width, height: ascent + descent))
        } else {
            image = NSImage(size: NSSize(width: width, height: ascent + descent))
        }
        image.isTemplate = true
        image.accessibilityDescription = latex

        let result = MathImage(image: image, ascent: ascent, descent: descent)
        cache.setObject(result, forKey: key)
        return result
    }
}

// MARK: - Boxes

/// A TeX box: a width, a height above the baseline and a depth below it, and how to draw it
/// with its baseline origin at a point (y up).
private struct MathBox {
    var width: CGFloat = 0
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var draw: (CGContext, CGPoint) -> Void = { _, _ in }

    static func kern(_ width: CGFloat) -> MathBox { MathBox(width: width) }

    /// Moves the box up by `dy`.
    func raised(_ dy: CGFloat) -> MathBox {
        let draw = self.draw
        return MathBox(width: width, ascent: ascent + dy, descent: descent - dy) { ctx, p in
            draw(ctx, CGPoint(x: p.x, y: p.y + dy))
        }
    }

    static func row(_ boxes: [MathBox]) -> MathBox {
        var offsets: [CGFloat] = []
        var x: CGFloat = 0
        for box in boxes {
            offsets.append(x)
            x += box.width
        }
        return MathBox(width: x,
                       ascent: boxes.map(\.ascent).max() ?? 0,
                       descent: boxes.map(\.descent).max() ?? 0) { ctx, p in
            for (box, dx) in zip(boxes, offsets) { box.draw(ctx, CGPoint(x: p.x + dx, y: p.y)) }
        }
    }
}

// MARK: - Layout

private struct MathTypesetter {
    let size: CGFloat

    private static let mathFontName = "STIXTwoMath-Regular"

    func fontSize(_ style: MathStyle) -> CGFloat {
        switch style {
        case .display, .text: return size
        case .script: return max(size * 0.71, 6.5)
        case .scriptScript: return max(size * 0.55, 5.5)
        }
    }

    private func axis(_ s: CGFloat) -> CGFloat { s * 0.25 }
    private func rule(_ s: CGFloat) -> CGFloat { max(s * 0.066, 0.6) }

    private func mathFont(_ s: CGFloat) -> NSFont {
        NSFont(name: Self.mathFontName, size: s) ?? NSFont.systemFont(ofSize: s)
    }

    private func textFont(_ s: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let name = switch (bold, italic) {
        case (false, false): "STIXTwoText"
        case (true, false): "STIXTwoText_Bold"
        case (false, true): "STIXTwoText-Italic"
        case (true, true): "STIXTwoText-Italic_Bold-Italic"
        }
        return NSFont(name: name, size: s) ?? NSFont.systemFont(ofSize: s, weight: bold ? .bold : .regular)
    }

    // MARK: Lists and spacing

    func layout(_ nodes: [MathNode], _ style: MathStyle) -> MathBox {
        var classes = nodes.map(Self.classOf)
        // A binary operator with nothing to bind on one side acts as an ordinary symbol (TeX rule 5/6).
        var previous: Int?
        for k in classes.indices {
            guard let cls = classes[k] else { continue }
            if cls == .bin, previous.map({ [.bin, .op, .rel, .open, .punct].contains(classes[$0]!) }) ?? true {
                classes[k] = .ord
            }
            if [.rel, .close, .punct].contains(cls), let p = previous, classes[p] == .bin { classes[p] = .ord }
            previous = k
        }
        if let p = previous, classes[p] == .bin { classes[p] = .ord }

        var boxes: [MathBox] = []
        var last: MathClass?
        for (node, cls) in zip(nodes, classes) {
            if let cls {
                if let last { boxes.append(.kern(spacing(last, cls, style))) }
                last = cls
            }
            boxes.append(box(node, style))
        }
        return .row(boxes)
    }

    private static func classOf(_ node: MathNode) -> MathClass? {
        switch node {
        case .symbol(_, let cls), .group(_, let cls), .delimiter(_, _, let cls), .stack(_, _, _, let cls): return cls
        case .largeOp, .function: return .op
        case .scripts(let base, _, _): return classOf(base) ?? .ord
        case .fraction, .fenced: return .inner
        case .space: return nil
        default: return .ord
        }
    }

    /// TeX's inter-atom spacing table, in mu (1/18 em). Negative entries apply only outside scripts.
    private static let spacingTable: [[Int]] = [
        //  ord op  bin rel open close punct inner
        [0, 3, -4, -5, 0, 0, 0, -3],      // ord
        [3, 3, 0, -5, 0, 0, 0, -3],       // op
        [-4, -4, 0, 0, -4, 0, 0, -4],     // bin
        [-5, -5, 0, 0, -5, 0, 0, -5],     // rel
        [0, 0, 0, 0, 0, 0, 0, 0],         // open
        [0, 3, -4, -5, 0, 0, 0, -3],      // close
        [-3, -3, 0, -3, -3, -3, -3, -3],  // punct
        [-3, 3, -4, -5, -3, 0, -3, -3],   // inner
    ]

    private func spacing(_ left: MathClass, _ right: MathClass, _ style: MathStyle) -> CGFloat {
        let mu = Self.spacingTable[left.rawValue][right.rawValue]
        if mu < 0 && style.isScript { return 0 }
        return CGFloat(abs(mu)) * fontSize(style) / 18
    }

    // MARK: Atoms

    private func box(_ node: MathNode, _ style: MathStyle) -> MathBox {
        let s = fontSize(style)
        switch node {
        case .symbol(let text, _):
            return glyphs(text, mathFont(s))
        case .text(let text, let bold, let italic):
            // STIX has no Hangul/CJK, and its fallback sets them letter-spaced; use the UI font for those.
            if text.unicodeScalars.contains(where: { $0.value >= 0x1100 && !(0x2000...0x2BFF).contains($0.value) }) {
                return glyphs(text, NSFont.systemFont(ofSize: s * 0.92, weight: bold ? .bold : .regular))
            }
            return glyphs(text, textFont(s, bold: bold, italic: italic))
        case .function(let name, _):
            return glyphs(name, mathFont(s))
        case .largeOp(let glyph, _):
            let integral = "∫∬∭∮∯".contains(glyph)
            let scale: CGFloat = style == .display ? (integral ? 1.75 : 1.45) : (integral ? 1.2 : 1.05)
            let op = glyphs(glyph, mathFont(s * scale))
            return op.raised(axis(s) - (op.ascent - op.descent) / 2)
        case .group(let list, _):
            return layout(list, style)
        case .scripts(let base, let sub, let sup):
            return scripts(base, sub: sub, sup: sup, style)
        case .fraction(let num, let den, let rule, let forced):
            return fraction(num, den, rule: rule, forced ?? style)
        case .radical(let body, let index):
            return radical(body, index: index, style)
        case .fenced(let left, let body, let right):
            return fence(layout(body, style), left, right, style)
        case .delimiter(let d, let scale, _):
            return delimiter(d, height: scale * s, style)
        case .accent(let body, let kind):
            return accent(body, kind, style)
        case .stack(let base, let over, let under, _):
            return limits(layout(base, style), sup: over.map { layout($0, style.script) },
                          sub: under.map { layout($0, style.script) }, s)
        case .boxed(let body):
            return boxed(layout(body, style), s)
        case .array(let rows, let kind):
            return array(rows, kind, style)
        case .space(let em):
            return .kern(em * s)
        case .phantom(let list):
            var box = layout(list, style)
            box.draw = { _, _ in }
            return box
        case .styled(let inner, let list):
            return layout(list, inner)
        }
    }

    private func glyphs(_ text: String, _ font: NSFont) -> MathBox {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let empty = ink.isNull || ink.isEmpty
        return MathBox(width: width, ascent: empty ? 0 : max(0, ink.maxY), descent: empty ? 0 : max(0, -ink.minY)) { ctx, p in
            ctx.textPosition = p
            CTLineDraw(line, ctx)
        }
    }

    private static func isGlyph(_ node: MathNode) -> Bool {
        switch node {
        case .symbol, .function, .text: return true
        default: return false
        }
    }

    // MARK: Scripts and limits

    private func scripts(_ baseNode: MathNode, sub: [MathNode]?, sup: [MathNode]?, _ style: MathStyle) -> MathBox {
        let s = fontSize(style)
        let base = box(baseNode, style)
        let supBox = sup.map { layout($0, style.script) }
        let subBox = sub.map { layout($0, style.script) }

        if usesLimits(baseNode, style) { return limits(base, sup: supBox, sub: subBox, s) }

        let glyph = Self.isGlyph(baseNode)
        let scriptSize = fontSize(style.script)
        var supShift: CGFloat = 0, subShift: CGFloat = 0
        if let supBox {
            supShift = max(style == .display ? 0.41 * s : 0.36 * s,
                           glyph ? 0 : base.ascent - 0.39 * scriptSize,
                           supBox.descent + 0.11 * s)
        }
        if let subBox {
            subShift = max(0.17 * s, glyph ? 0 : base.descent + 0.05 * scriptSize, subBox.ascent - 0.38 * s)
        }
        if let supBox, let subBox {
            subShift = max(subShift, 0.25 * s)
            let gap = (supShift - supBox.descent) - (subBox.ascent - subShift)
            if gap < 4 * rule(s) { subShift += 4 * rule(s) - gap }
        }
        // Integrals tuck the subscript under their slant.
        let subKern: CGFloat = if case .largeOp(let g, _) = baseNode, "∫∬∭∮∯".contains(g) { -0.2 * s } else { 0 }
        let scriptWidth = max((supBox?.width ?? 0), (subBox?.width ?? 0) + subKern)
        let width = base.width + scriptWidth + 0.05 * s
        let ascent = max(base.ascent, supBox.map { supShift + $0.ascent } ?? 0)
        let descent = max(base.descent, subBox.map { subShift + $0.descent } ?? 0)
        return MathBox(width: width, ascent: ascent, descent: descent) { ctx, p in
            base.draw(ctx, p)
            supBox?.draw(ctx, CGPoint(x: p.x + base.width, y: p.y + supShift))
            subBox?.draw(ctx, CGPoint(x: p.x + base.width + subKern, y: p.y - subShift))
        }
    }

    private func usesLimits(_ node: MathNode, _ style: MathStyle) -> Bool {
        switch node {
        case .largeOp(_, let limits), .function(_, let limits): return limits ?? (style == .display)
        case .accent(_, .overbrace), .accent(_, .underbrace): return true
        default: return false
        }
    }

    private func limits(_ base: MathBox, sup: MathBox?, sub: MathBox?, _ s: CGFloat) -> MathBox {
        let gap = 0.14 * s
        let width = max(base.width, sup?.width ?? 0, sub?.width ?? 0)
        let supBaseline = base.ascent + gap + (sup?.descent ?? 0)
        let subBaseline = base.descent + gap + (sub?.ascent ?? 0)
        let ascent = sup.map { supBaseline + $0.ascent } ?? base.ascent
        let descent = sub.map { subBaseline + $0.descent } ?? base.descent
        return MathBox(width: width, ascent: ascent, descent: descent) { ctx, p in
            base.draw(ctx, CGPoint(x: p.x + (width - base.width) / 2, y: p.y))
            if let sup { sup.draw(ctx, CGPoint(x: p.x + (width - sup.width) / 2, y: p.y + supBaseline)) }
            if let sub { sub.draw(ctx, CGPoint(x: p.x + (width - sub.width) / 2, y: p.y - subBaseline)) }
        }
    }

    // MARK: Fractions and radicals

    private func fraction(_ numNodes: [MathNode], _ denNodes: [MathNode], rule hasRule: Bool, _ style: MathStyle) -> MathBox {
        let s = fontSize(style)
        let num = layout(numNodes, style.fraction)
        let den = layout(denNodes, style.fraction)
        let display = style == .display
        let thickness = hasRule ? rule(s) : 0
        let gap = display ? 3 * rule(s) : rule(s) * 1.2
        let a = axis(s)
        let numShift = max(display ? 0.68 * s : 0.4 * s, a + thickness / 2 + gap + num.descent)
        let denShift = max(display ? 0.69 * s : 0.34 * s, den.ascent + gap + thickness / 2 - a)
        let pad = 0.12 * s
        let width = max(num.width, den.width) + 2 * pad
        return MathBox(width: width, ascent: numShift + num.ascent, descent: denShift + den.descent) { ctx, p in
            num.draw(ctx, CGPoint(x: p.x + (width - num.width) / 2, y: p.y + numShift))
            den.draw(ctx, CGPoint(x: p.x + (width - den.width) / 2, y: p.y - denShift))
            if hasRule {
                ctx.fill(CGRect(x: p.x + pad / 2, y: p.y + a - thickness / 2, width: width - pad, height: thickness))
            }
        }
    }

    private func radical(_ bodyNodes: [MathNode], index indexNodes: [MathNode]?, _ style: MathStyle) -> MathBox {
        let s = fontSize(style)
        let body = layout(bodyNodes, style)
        let t = rule(s)
        let gap = style == .display ? t + 0.12 * s : t * 1.25 + 0.06 * s
        let top = max(body.ascent, 0.68 * s) + gap
        let bottom = max(body.descent, 0.08 * s) + 0.06 * s
        let height = top + bottom
        let signWidth = min(0.62 * s, 0.48 * s + height * 0.05)
        let index = indexNodes.map { layout($0, .scriptScript) }
        let indexRaise = -bottom + height * 0.58
        let lead = index.map { max(0, $0.width - signWidth * 0.45) } ?? 0
        let width = lead + signWidth + body.width + 0.1 * s
        var ascent = top + t
        if let index { ascent = max(ascent, indexRaise + index.descent + index.ascent) }
        return MathBox(width: width, ascent: ascent, descent: bottom) { ctx, p in
            let x0 = p.x + lead, yb = p.y - bottom, yt = p.y + top
            if let index {
                index.draw(ctx, CGPoint(x: x0 + signWidth * 0.45 - index.width, y: p.y + indexRaise + index.descent))
            }
            let hook = CGPoint(x: x0 + signWidth * 0.2, y: yb + height * 0.48)
            let foot = CGPoint(x: x0 + signWidth * 0.5, y: yb)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(t)
            ctx.move(to: CGPoint(x: x0, y: yb + height * 0.42))
            ctx.addLine(to: hook)
            ctx.strokePath()
            ctx.setLineWidth(t * 1.9)
            ctx.move(to: hook)
            ctx.addLine(to: foot)
            ctx.strokePath()
            ctx.setLineWidth(t)
            ctx.setLineCap(.butt)
            ctx.move(to: foot)
            ctx.addLine(to: CGPoint(x: x0 + signWidth, y: yt))
            ctx.addLine(to: CGPoint(x: x0 + signWidth + body.width + 0.1 * s, y: yt))
            ctx.strokePath()
            body.draw(ctx, CGPoint(x: x0 + signWidth + 0.04 * s, y: p.y))
        }
    }

    // MARK: Delimiters

    private func fence(_ body: MathBox, _ left: String, _ right: String, _ style: MathStyle) -> MathBox {
        let s = fontSize(style)
        let half = max(body.ascent - axis(s), body.descent + axis(s))
        let height = max(2 * half * 0.901, 2 * half - 0.5 * s)
        return .row([delimiter(left, height: height, style), body, delimiter(right, height: height, style)])
    }

    private func delimiter(_ d: String, height: CGFloat, _ style: MathStyle) -> MathBox {
        let s = fontSize(style)
        guard !d.isEmpty, d != "." else { return .kern(0.12 * s) }
        let glyph = glyphs(d, mathFont(s))
        if height <= (glyph.ascent + glyph.descent) * 1.05 { return glyph }

        let t = rule(s) * (1.1 + min(height / s, 4) * 0.12)
        let width: CGFloat = switch d {
        case "(", ")": 0.3 * s + height * 0.04
        case "{", "}": 0.36 * s + height * 0.03
        case "⟨", "⟩": 0.3 * s + height * 0.05
        case "|", "‖": 0.26 * s
        default: 0.3 * s
        }
        let pad = 0.06 * s
        let a = axis(s)
        return MathBox(width: width + 2 * pad, ascent: a + height / 2, descent: height / 2 - a) { ctx, p in
            let rect = CGRect(x: p.x + pad, y: p.y + a - height / 2, width: width, height: height)
            Self.drawDelimiter(d, in: rect, thickness: t, glyph: glyph, ctx: ctx)
        }
    }

    private static func drawDelimiter(_ d: String, in r: CGRect, thickness t: CGFloat, glyph: MathBox, ctx: CGContext) {
        let flip = ")]}⟩⌋⌉".contains(d)
        func x(_ f: CGFloat) -> CGFloat { flip ? r.maxX - f * r.width : r.minX + f * r.width }
        let top = r.maxY - t / 2, bottom = r.minY + t / 2, mid = r.midY
        ctx.setLineWidth(t)
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)
        switch d {
        case "(", ")":
            // A filled crescent: thick in the middle, thin at the tips.
            let end = x(0.95), outer = x(0.05), inner = x(0.05 + 1.7 * t / r.width)
            ctx.move(to: CGPoint(x: end, y: r.maxY))
            ctx.addQuadCurve(to: CGPoint(x: end, y: r.minY), control: CGPoint(x: 2 * outer - end, y: mid))
            ctx.addQuadCurve(to: CGPoint(x: end, y: r.maxY), control: CGPoint(x: 2 * inner - end, y: mid))
            ctx.closePath()
            ctx.fillPath()
            ctx.setLineWidth(t * 0.45)
            ctx.move(to: CGPoint(x: end, y: r.maxY))
            ctx.addQuadCurve(to: CGPoint(x: end, y: r.minY), control: CGPoint(x: outer + inner - end, y: mid))
            ctx.strokePath()
        case "[", "]", "⌊", "⌋", "⌈", "⌉":
            let stem = x(0.25)
            let hasTop = "[]⌈⌉".contains(d), hasBottom = "[]⌊⌋".contains(d)
            ctx.move(to: CGPoint(x: hasTop ? x(0.9) : stem, y: top))
            if hasTop { ctx.addLine(to: CGPoint(x: stem, y: top)) }
            ctx.addLine(to: CGPoint(x: stem, y: bottom))
            if hasBottom { ctx.addLine(to: CGPoint(x: x(0.9), y: bottom)) }
            ctx.strokePath()
        case "{", "}":
            let tip = x(0.85), stem = x(0.5), point = x(0.08)
            let radius = min(r.width * 0.4, r.height * 0.12)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: tip, y: top))
            ctx.addQuadCurve(to: CGPoint(x: stem, y: top - radius), control: CGPoint(x: stem, y: top))
            ctx.addLine(to: CGPoint(x: stem, y: mid + radius))
            ctx.addQuadCurve(to: CGPoint(x: point, y: mid), control: CGPoint(x: stem, y: mid))
            ctx.addQuadCurve(to: CGPoint(x: stem, y: mid - radius), control: CGPoint(x: stem, y: mid))
            ctx.addLine(to: CGPoint(x: stem, y: bottom + radius))
            ctx.addQuadCurve(to: CGPoint(x: tip, y: bottom), control: CGPoint(x: stem, y: bottom))
            ctx.strokePath()
        case "|":
            ctx.move(to: CGPoint(x: r.midX, y: r.maxY))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.minY))
            ctx.strokePath()
        case "‖":
            for f in [0.3, 0.7] as [CGFloat] {
                ctx.move(to: CGPoint(x: r.minX + f * r.width, y: r.maxY))
                ctx.addLine(to: CGPoint(x: r.minX + f * r.width, y: r.minY))
            }
            ctx.strokePath()
        case "⟨", "⟩":
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: x(0.9), y: top))
            ctx.addLine(to: CGPoint(x: x(0.1), y: mid))
            ctx.addLine(to: CGPoint(x: x(0.9), y: bottom))
            ctx.strokePath()
        case "/", "\\":
            ctx.move(to: CGPoint(x: d == "/" ? r.minX : r.maxX, y: r.minY))
            ctx.addLine(to: CGPoint(x: d == "/" ? r.maxX : r.minX, y: r.maxY))
            ctx.strokePath()
        default:
            // Anything else: stretch the glyph to the height.
            let natural = max(glyph.ascent + glyph.descent, 1)
            ctx.saveGState()
            ctx.translateBy(x: r.midX - glyph.width / 2, y: r.minY)
            ctx.scaleBy(x: 1, y: r.height / natural)
            glyph.draw(ctx, CGPoint(x: 0, y: glyph.descent))
            ctx.restoreGState()
        }
    }

    // MARK: Accents, boxes, arrays

    private func accent(_ bodyNodes: [MathNode], _ kind: MathAccent, _ style: MathStyle) -> MathBox {
        let s = fontSize(style)
        let t = rule(s)
        let body = layout(bodyNodes, style)
        let single = bodyNodes.count == 1 && Self.isGlyph(bodyNodes[0])
        // Italic letters lean right, so their accents sit a little to the right.
        let skew: CGFloat = single ? 0.06 * s : 0

        if kind == .underline || kind == .underbrace {
            let h = kind == .underline ? t : 0.28 * s
            let gap = 0.1 * s
            return MathBox(width: body.width, ascent: body.ascent, descent: body.descent + gap + h) { ctx, p in
                body.draw(ctx, p)
                let rect = CGRect(x: p.x, y: p.y - body.descent - gap - h, width: body.width, height: h)
                if kind == .underline { ctx.fill(rect) } else { Self.drawBrace(in: rect, up: false, thickness: t * 1.2, ctx: ctx) }
            }
        }

        let h: CGFloat = switch kind {
        case .bar, .overline: t
        case .hat, .check: 0.17 * s
        case .wideHat: 0.24 * s
        case .tilde, .wideTilde: 0.14 * s
        case .vec, .rightArrow, .leftArrow, .leftRightArrow: 0.22 * s
        case .dot, .ddot: 0.11 * s
        case .overbrace: 0.28 * s
        default: 0.16 * s
        }
        let gap = 0.1 * s
        let top = max(body.ascent, 0.47 * s) + gap
        let accentWidth: CGFloat = switch kind {
        case .hat, .check, .tilde, .dot, .ddot, .breve, .acute, .grave, .ring: min(body.width, 0.42 * s)
        case .vec: max(body.width * 0.9, 0.42 * s)
        case .bar: max(body.width * 0.9, 0.35 * s)
        default: body.width
        }
        return MathBox(width: body.width, ascent: top + h + 0.03 * s, descent: body.descent) { ctx, p in
            body.draw(ctx, p)
            let rect = CGRect(x: p.x + (body.width - accentWidth) / 2 + (kind == .overline ? 0 : skew),
                              y: p.y + top, width: accentWidth, height: h)
            Self.drawAccent(kind, in: rect, size: s, thickness: t, ctx: ctx)
        }
    }

    private static func drawAccent(_ kind: MathAccent, in r: CGRect, size s: CGFloat, thickness t: CGFloat, ctx: CGContext) {
        ctx.setLineWidth(t * 1.1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch kind {
        case .bar, .overline:
            ctx.fill(r)
        case .hat, .wideHat, .check:
            let up = kind != .check
            ctx.move(to: CGPoint(x: r.minX, y: up ? r.minY : r.maxY))
            ctx.addLine(to: CGPoint(x: r.midX, y: up ? r.maxY : r.minY))
            ctx.addLine(to: CGPoint(x: r.maxX, y: up ? r.minY : r.maxY))
            ctx.strokePath()
        case .tilde, .wideTilde:
            ctx.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.25))
            ctx.addCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.75),
                         control1: CGPoint(x: r.minX + r.width * 0.35, y: r.maxY + r.height * 0.4),
                         control2: CGPoint(x: r.minX + r.width * 0.65, y: r.minY - r.height * 0.4))
            ctx.strokePath()
        case .vec, .rightArrow, .leftArrow, .leftRightArrow:
            let y = r.midY, head = min(r.height * 0.6, r.width * 0.4)
            ctx.setLineWidth(t)
            ctx.move(to: CGPoint(x: r.minX, y: y))
            ctx.addLine(to: CGPoint(x: r.maxX, y: y))
            if kind != .leftArrow {
                ctx.move(to: CGPoint(x: r.maxX - head, y: y + head * 0.8))
                ctx.addLine(to: CGPoint(x: r.maxX, y: y))
                ctx.addLine(to: CGPoint(x: r.maxX - head, y: y - head * 0.8))
            }
            if kind == .leftArrow || kind == .leftRightArrow {
                ctx.move(to: CGPoint(x: r.minX + head, y: y + head * 0.8))
                ctx.addLine(to: CGPoint(x: r.minX, y: y))
                ctx.addLine(to: CGPoint(x: r.minX + head, y: y - head * 0.8))
            }
            ctx.strokePath()
        case .dot, .ddot:
            let radius = 0.055 * s
            let centers: [CGFloat] = kind == .dot ? [r.midX] : [r.midX - 0.11 * s, r.midX + 0.11 * s]
            for cx in centers {
                ctx.fillEllipse(in: CGRect(x: cx - radius, y: r.midY - radius, width: 2 * radius, height: 2 * radius))
            }
        case .breve:
            ctx.move(to: CGPoint(x: r.minX, y: r.maxY))
            ctx.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
            ctx.strokePath()
        case .acute, .grave:
            let lean = kind == .acute
            ctx.move(to: CGPoint(x: r.minX + r.width * (lean ? 0.35 : 0.65), y: r.minY))
            ctx.addLine(to: CGPoint(x: r.minX + r.width * (lean ? 0.75 : 0.25), y: r.maxY))
            ctx.strokePath()
        case .ring:
            let d = min(r.width, r.height)
            ctx.strokeEllipse(in: CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d))
        case .overbrace:
            drawBrace(in: r, up: true, thickness: t * 1.2, ctx: ctx)
        case .underline, .underbrace:
            break
        }
    }

    /// A horizontal curly brace whose point faces up (overbrace) or down (underbrace).
    private static func drawBrace(in r: CGRect, up: Bool, thickness t: CGFloat, ctx: CGContext) {
        let edge = up ? r.minY : r.maxY, point = up ? r.maxY : r.minY, mid = r.midY
        let radius = min(r.height, r.width / 4)
        ctx.setLineWidth(t)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: r.minX, y: edge))
        ctx.addQuadCurve(to: CGPoint(x: r.minX + radius, y: mid), control: CGPoint(x: r.minX, y: mid))
        ctx.addLine(to: CGPoint(x: r.midX - radius, y: mid))
        ctx.addQuadCurve(to: CGPoint(x: r.midX, y: point), control: CGPoint(x: r.midX, y: mid))
        ctx.addQuadCurve(to: CGPoint(x: r.midX + radius, y: mid), control: CGPoint(x: r.midX, y: mid))
        ctx.addLine(to: CGPoint(x: r.maxX - radius, y: mid))
        ctx.addQuadCurve(to: CGPoint(x: r.maxX, y: edge), control: CGPoint(x: r.maxX, y: mid))
        ctx.strokePath()
    }

    private func boxed(_ body: MathBox, _ s: CGFloat) -> MathBox {
        let pad = 0.28 * s, t = rule(s)
        return MathBox(width: body.width + 2 * pad, ascent: body.ascent + pad, descent: body.descent + pad) { ctx, p in
            body.draw(ctx, CGPoint(x: p.x + pad, y: p.y))
            ctx.setLineWidth(t)
            ctx.stroke(CGRect(x: p.x + t / 2, y: p.y - body.descent - pad + t / 2,
                              width: body.width + 2 * pad - t, height: body.ascent + body.descent + 2 * pad - t))
        }
    }

    private func array(_ rows: [[[MathNode]]], _ kind: MathArrayKind, _ style: MathStyle) -> MathBox {
        let s = fontSize(style)
        let cellStyle: MathStyle = switch kind {
        case .aligned, .gathered: style
        default: style == .display ? .text : style
        }
        let columns = rows.map(\.count).max() ?? 0
        let cells: [[MathBox]] = rows.map { row in
            row.enumerated().map { c, nodes in
                // In aligned columns `&=` should space the relation as if something preceded it.
                let lead: [MathNode] = kind == .aligned && !c.isMultiple(of: 2) ? [.group([], .ord)] : []
                return layout(lead + nodes, cellStyle)
            }
        }
        var widths = Array(repeating: CGFloat(0), count: columns)
        for row in cells { for (c, cell) in row.enumerated() { widths[c] = max(widths[c], cell.width) } }

        func alignment(_ c: Int) -> CGFloat {  // 0 leading, 0.5 center, 1 trailing
            switch kind {
            case .matrix, .gathered: return 0.5
            case .cases: return 0
            case .aligned: return c.isMultiple(of: 2) ? 1 : 0
            case .array(let spec):
                guard c < spec.count else { return 0.5 }
                return spec[c] == "l" ? 0 : spec[c] == "r" ? 1 : 0.5
            }
        }
        func gapAfter(_ c: Int) -> CGFloat {
            switch kind {
            case .aligned: return c.isMultiple(of: 2) ? 0 : 1.5 * s
            case .cases, .gathered: return 1.0 * s
            default: return 0.8 * s
            }
        }

        let ascents = cells.map { max($0.map(\.ascent).max() ?? 0, 0.72 * s) }
        let descents = cells.map { max($0.map(\.descent).max() ?? 0, 0.3 * s) }
        let rowGap = (kind == .aligned || kind == .gathered ? 0.4 : 0.25) * s
        let height = zip(ascents, descents).map(+).reduce(0, +) + rowGap * CGFloat(max(rows.count - 1, 0))
        let width = widths.reduce(0, +) + (0..<max(columns - 1, 0)).map(gapAfter).reduce(0, +)
        let top = axis(s) + height / 2

        return MathBox(width: width, ascent: top, descent: height - top) { ctx, p in
            var y = p.y + top
            for (r, row) in cells.enumerated() {
                y -= ascents[r]
                var x = p.x
                for c in 0..<columns {
                    if c < row.count {
                        let cell = row[c]
                        cell.draw(ctx, CGPoint(x: x + (widths[c] - cell.width) * alignment(c), y: y))
                    }
                    x += widths[c] + (c < columns - 1 ? gapAfter(c) : 0)
                }
                y -= descents[r] + rowGap
            }
        }
    }
}
