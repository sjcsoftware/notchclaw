import AppKit
import SwiftUI

/// Renders Markdown on the notch's dark surface.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    var baseSize: CGFloat = 13

    init(_ text: String, baseSize: CGFloat = 13) {
        blocks = MarkdownParser.parse(text)
        self.baseSize = baseSize
    }

    init(blocks: [MarkdownBlock], baseSize: CGFloat = 13) {
        self.blocks = blocks
        self.baseSize = baseSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: baseSize * 0.7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, baseSize: baseSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let baseSize: CGFloat

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text, size: headingSize(level), weight: level <= 2 ? .bold : .semibold)
                .padding(.top, level <= 2 ? baseSize * 0.35 : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            InlineText(text, size: baseSize)
        case .code(let language, let code):
            if language?.lowercased() == "chart" {
                ChartBlockView(source: code, size: baseSize)
            } else {
                CodeBlockView(language: language, code: code, size: baseSize - 1.5)
            }
        case .math(let latex):
            MathBlockView(latex: latex, size: baseSize)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(NotchPalette.accentGradient)
                    .frame(width: 3)
                MarkdownView(blocks: inner, baseSize: baseSize)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: baseSize * 0.35) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        marker(ordered: ordered, number: start + offset, checked: item.checked)
                        MarkdownView(blocks: item.blocks, baseSize: baseSize)
                    }
                }
            }
        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows, size: baseSize - 1)
        case .rule:
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: baseSize - 1))
                .foregroundStyle(checked ? AnyShapeStyle(NotchPalette.accentGradient) : AnyShapeStyle(.white.opacity(0.5)))
        } else if ordered {
            Text("\(number).")
                .font(.system(size: baseSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
        } else {
            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: 4.5, height: 4.5)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + baseSize * 0.3 }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 5
        case 2: return baseSize + 3
        case 3: return baseSize + 1.5
        default: return baseSize
        }
    }
}

/// Inline Markdown (bold, italics, code, links, strikethrough) via Foundation's parser,
/// with LaTeX math typeset in place.
struct InlineText: View {
    let attributed: AttributedString
    let math: [MathImage]
    let size: CGFloat
    let weight: Font.Weight

    init(_ source: String, size: CGFloat, weight: Font.Weight = .regular) {
        self.size = size
        self.weight = weight
        // Math is cut out before Markdown parsing (which would eat its backslashes and underscores)
        // and stands in as placeholder characters until the text is assembled.
        var markdown = ""
        var math: [MathImage] = []
        for piece in MathSyntax.split(source) {
            switch piece {
            case .text(let text):
                markdown += text
            case .math(let latex, let display):
                markdown.append(MathSyntax.placeholder(math.count))
                math.append(MathRenderer.render(latex, size: size * MathRenderer.textScale, display: display))
            }
        }
        self.math = math
        attributed = Self.render(markdown, size: size)
    }

    var body: some View {
        text
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white.opacity(0.92))
            .lineSpacing(size * 0.22)
            .fixedSize(horizontal: false, vertical: true)
            .tint(Color(red: 0.55, green: 0.75, blue: 1.0))
    }

    private var text: Text {
        guard !math.isEmpty else { return Text(attributed) }
        var result = Text(verbatim: "")
        var start = attributed.startIndex
        var index = start
        while index < attributed.endIndex {
            let next = attributed.characters.index(after: index)
            if let k = MathSyntax.placeholderIndex(attributed.characters[index]), k < math.count {
                if start < index { result = result + Text(AttributedString(attributed[start..<index])) }
                result = result + math[k].text
                start = next
            }
            index = next
        }
        if start < attributed.endIndex { result = result + Text(AttributedString(attributed[start...])) }
        return result
    }

    static func render(_ source: String, size: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            attributed[run.range].font = .system(size: size - 1, design: .monospaced)
            attributed[run.range].foregroundColor = Color(red: 1.0, green: 0.72, blue: 0.62)
            attributed[run.range].backgroundColor = Color.white.opacity(0.09)
        }
        return attributed
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    let size: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.snappy) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(copied ? 0.9 : 0.5))
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.04))

            HorizontalScroll {
                Text(SyntaxHighlighter.highlight(code, language: language, size: size))
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

/// A display equation, centered, scrolling sideways if it's wider than the chat.
struct MathBlockView: View {
    let latex: String
    let size: CGFloat

    var body: some View {
        let math = MathRenderer.render(latex, size: size * MathRenderer.textScale, display: true)
        let image = Image(nsImage: math.image).renderingMode(.template)
        ViewThatFits(in: .horizontal) {
            image.frame(maxWidth: .infinity)
            HorizontalScroll { image }
        }
        .foregroundStyle(.white.opacity(0.92))
        .accessibilityLabel(latex)
        .contextMenu {
            Button("Copy LaTeX") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(latex, forType: .string)
            }
        }
    }
}

private struct TableBlockView: View {
    let header: [String]
    let alignments: [TableAlignment]
    let rows: [[String]]
    let size: CGFloat

    var body: some View {
        HorizontalScroll {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { i, cell in
                        cellView(cell, column: i, bold: true)
                    }
                }
                .background(.white.opacity(0.08))
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                            cellView(cell, column: i, bold: false)
                        }
                    }
                    .background(r.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.03))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
    }

    private func cellView(_ text: String, column: Int, bold: Bool) -> some View {
        let alignment: Alignment = switch alignments[safe: column] ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return InlineText(text, size: size, weight: bold ? .semibold : .regular)
            .frame(minWidth: 40, maxWidth: 320, alignment: alignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gridColumnAlignment(alignment.horizontal)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct NotchSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering static screenshots, where scroll views can't be captured.
    var notchSnapshot: Bool {
        get { self[NotchSnapshotKey.self] }
        set { self[NotchSnapshotKey.self] = newValue }
    }
}

/// A horizontal scroller that lays content out flat when rendering screenshots.
struct HorizontalScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.notchSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            content.frame(maxWidth: .infinity, alignment: .leading).clipped()
        } else {
            ScrollView(.horizontal) { content.background(ScrollerHider(vertical: .invisible)) }
        }
    }
}
