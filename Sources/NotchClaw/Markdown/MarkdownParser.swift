import Foundation

/// Block-level Markdown model. Inline formatting is rendered by `AttributedString(markdown:)`.
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    /// Display math (`$$…$$`, `\[…\]`, or a bare `\begin{align}…`), as LaTeX source.
    case math(String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [ListItem])
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case rule

    struct ListItem: Equatable {
        var checked: Bool?
        var blocks: [MarkdownBlock]
    }
}

enum TableAlignment: Equatable { case leading, center, trailing }

/// A small, forgiving GitHub-flavored Markdown block parser.
/// Handles streaming input gracefully (e.g. an unterminated code fence).
enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var parser = LineParser(lines: lines)
        return parser.parseBlocks()
    }

    private struct LineParser {
        let lines: [String]
        var index = 0

        init(lines: [String]) { self.lines = lines }

        mutating func parseBlocks() -> [MarkdownBlock] {
            var blocks: [MarkdownBlock] = []
            var paragraph: [String] = []

            func flushParagraph() {
                guard !paragraph.isEmpty else { return }
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }

            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    flushParagraph()
                    index += 1
                    continue
                }

                // Fenced code
                if let fence = Self.fenceMarker(trimmed) {
                    flushParagraph()
                    let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                    index += 1
                    var code: [String] = []
                    let indent = line.prefix { $0 == " " }.count
                    while index < lines.count {
                        let l = lines[index]
                        if l.trimmingCharacters(in: .whitespaces).hasPrefix(fence),
                           l.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.first }) {
                            index += 1
                            break
                        }
                        code.append(String(l.dropFirst(min(indent, l.prefix { $0 == " " }.count))))
                        index += 1
                    }
                    blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                    continue
                }

                // Display math
                if let math = parseDisplayMath(trimmed) {
                    flushParagraph()
                    blocks.append(.math(math.latex))
                    if !math.trailing.isEmpty { paragraph.append(math.trailing) }
                    continue
                }

                // Heading
                if let heading = Self.heading(trimmed) {
                    flushParagraph()
                    blocks.append(heading)
                    index += 1
                    continue
                }

                // Setext heading underline (only directly after a paragraph line)
                if !paragraph.isEmpty, trimmed.count >= 2,
                   trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                    let text = paragraph.joined(separator: " ")
                    paragraph.removeAll()
                    blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, text: text))
                    index += 1
                    continue
                }

                // Horizontal rule
                if Self.isRule(trimmed) {
                    flushParagraph()
                    blocks.append(.rule)
                    index += 1
                    continue
                }

                // Block quote
                if trimmed.hasPrefix(">") {
                    flushParagraph()
                    var quoted: [String] = []
                    while index < lines.count {
                        let t = lines[index].trimmingCharacters(in: .whitespaces)
                        guard t.hasPrefix(">") else { break }
                        var content = String(t.dropFirst())
                        if content.hasPrefix(" ") { content.removeFirst() }
                        quoted.append(content)
                        index += 1
                    }
                    var inner = LineParser(lines: quoted)
                    blocks.append(.quote(inner.parseBlocks()))
                    continue
                }

                // Table
                if index + 1 < lines.count, trimmed.contains("|"),
                   let alignments = Self.tableDelimiter(lines[index + 1]) {
                    flushParagraph()
                    let header = Self.tableCells(trimmed)
                    index += 2
                    var rows: [[String]] = []
                    while index < lines.count {
                        let t = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty, t.contains("|") else { break }
                        var cells = Self.tableCells(t)
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        index += 1
                    }
                    let aligns = alignments.count >= header.count
                        ? Array(alignments.prefix(header.count))
                        : alignments + Array(repeating: .leading, count: header.count - alignments.count)
                    blocks.append(.table(header: header, alignments: aligns, rows: rows))
                    continue
                }

                // List
                if Self.listMarker(line) != nil {
                    flushParagraph()
                    blocks.append(parseList())
                    continue
                }

                paragraph.append(trimmed)
                index += 1
            }
            flushParagraph()
            return blocks
        }

        /// Display math starting on this line, through its closing delimiter (or the end, while streaming).
        /// Text after the closing delimiter on its last line is returned as `trailing`.
        mutating func parseDisplayMath(_ trimmed: String) -> (latex: String, trailing: String)? {
            let closer: String
            var keepDelimiters = false
            if trimmed.hasPrefix("$$") {
                closer = "$$"
            } else if trimmed.hasPrefix("\\[") {
                closer = "\\]"
            } else if let env = Self.mathEnvironment(trimmed) {
                closer = "\\end{\(env)}"
                keepDelimiters = true
            } else {
                return nil
            }
            let openerLength = keepDelimiters ? 0 : 2
            var body = String(trimmed.dropFirst(openerLength))
            let searchFrom = keepDelimiters ? body.index(after: body.startIndex) : body.startIndex
            // A single line with text after the closing delimiter is inline math in a paragraph.
            if let close = body.range(of: closer, range: searchFrom..<body.endIndex) {
                let after = body[close.upperBound...].trimmingCharacters(in: .whitespaces)
                guard after.isEmpty else { return nil }
                body = String(body[..<(keepDelimiters ? close.upperBound : close.lowerBound)])
                index += 1
                return (body.trimmingCharacters(in: .whitespaces), "")
            }
            var latex = [body]
            var trailing = ""
            index += 1
            while index < lines.count {
                let line = lines[index]
                index += 1
                if let close = line.range(of: closer) {
                    latex.append(String(line[..<(keepDelimiters ? close.upperBound : close.lowerBound)]))
                    trailing = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
                    break
                }
                latex.append(line)
            }
            return (latex.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), trailing)
        }

        static func mathEnvironment(_ t: String) -> String? {
            guard t.hasPrefix("\\begin{"), let close = t.firstIndex(of: "}") else { return nil }
            let name = String(t[t.index(t.startIndex, offsetBy: 7)..<close])
            let known = ["equation", "align", "aligned", "gather", "gathered", "multline", "split", "alignat", "eqnarray", "displaymath"]
            return known.contains(name.replacingOccurrences(of: "*", with: "")) ? name : nil
        }

        mutating func parseList() -> MarkdownBlock {
            guard let first = Self.listMarker(lines[index]) else { return .paragraph(lines[index]) }
            var items: [MarkdownBlock.ListItem] = []
            let baseIndent = first.indent

            while index < lines.count {
                guard let marker = Self.listMarker(lines[index]),
                      marker.indent <= baseIndent + 1, marker.ordered == first.ordered
                else { break }
                var itemLines = [marker.content]
                index += 1
                // Continuation lines: indented further than the marker, or lazy paragraph lines.
                while index < lines.count {
                    let l = lines[index]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    let indent = l.prefix { $0 == " " || $0 == "\t" }.count
                    if t.isEmpty {
                        // Blank line: continue only if the next line is still part of this item.
                        if index + 1 < lines.count {
                            let next = lines[index + 1]
                            let nextIndent = next.prefix { $0 == " " || $0 == "\t" }.count
                            if nextIndent > baseIndent + 1, !next.trimmingCharacters(in: .whitespaces).isEmpty {
                                itemLines.append("")
                                index += 1
                                continue
                            }
                        }
                        break
                    }
                    if let m = Self.listMarker(l), m.indent <= baseIndent + 1 { break }
                    if indent > baseIndent {
                        itemLines.append(String(l.dropFirst(min(indent, marker.contentIndent))))
                    } else if Self.listMarker(l) == nil, !Self.startsBlock(t) {
                        itemLines.append(t)
                    } else {
                        break
                    }
                    index += 1
                }
                var checked: Bool?
                if let firstLine = itemLines.first {
                    if firstLine.hasPrefix("[ ] ") { checked = false; itemLines[0] = String(firstLine.dropFirst(4)) }
                    else if firstLine.lowercased().hasPrefix("[x] ") { checked = true; itemLines[0] = String(firstLine.dropFirst(4)) }
                }
                var inner = LineParser(lines: itemLines)
                items.append(.init(checked: checked, blocks: inner.parseBlocks()))
            }
            return .list(ordered: first.ordered, start: first.number, items: items)
        }

        struct ListMarker: Equatable {
            var ordered: Bool
            var number: Int
            var indent: Int
            var content: String
            var contentIndent: Int
        }

        static func listMarker(_ line: String) -> ListMarker? {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let rest = line.dropFirst(indent)
            if let c = rest.first, c == "-" || c == "*" || c == "+" {
                let after = rest.dropFirst()
                guard after.first == " " else { return nil }
                if isRule(String(rest).trimmingCharacters(in: .whitespaces)) { return nil }
                return ListMarker(ordered: false, number: 1, indent: indent,
                                  content: String(after.dropFirst()), contentIndent: indent + 2)
            }
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let delim = after.first, delim == "." || delim == ")", after.dropFirst().first == " " else { return nil }
            return ListMarker(ordered: true, number: Int(digits) ?? 1, indent: indent,
                              content: String(after.dropFirst(2)), contentIndent: indent + digits.count + 2)
        }

        static func startsBlock(_ t: String) -> Bool {
            fenceMarker(t) != nil || heading(t) != nil || t.hasPrefix(">") || isRule(t)
                || t.hasPrefix("$$") || t.hasPrefix("\\[") || mathEnvironment(t) != nil
        }

        static func fenceMarker(_ t: String) -> String? {
            if t.hasPrefix("```") { return String(t.prefix { $0 == "`" }) }
            if t.hasPrefix("~~~") { return String(t.prefix { $0 == "~" }) }
            return nil
        }

        static func heading(_ t: String) -> MarkdownBlock? {
            let hashes = t.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count) else { return nil }
            let rest = t.dropFirst(hashes.count)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
        }

        static func isRule(_ t: String) -> Bool {
            let compact = t.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 3, let c = compact.first, c == "-" || c == "*" || c == "_" else { return false }
            return compact.allSatisfy { $0 == c }
        }

        static func tableDelimiter(_ line: String) -> [TableAlignment]? {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("-"), t.contains("|") || t.contains(":") else { return nil }
            let cells = tableCells(t)
            guard !cells.isEmpty else { return nil }
            var result: [TableAlignment] = []
            for cell in cells {
                let c = cell.trimmingCharacters(in: .whitespaces)
                guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
                switch (c.hasPrefix(":"), c.hasSuffix(":")) {
                case (true, true): result.append(.center)
                case (false, true): result.append(.trailing)
                default: result.append(.leading)
                }
            }
            return result
        }

        static func tableCells(_ line: String) -> [String] {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
            var cells: [String] = []
            var current = ""
            var escaped = false
            var inCode = false
            for ch in t {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; current.append(ch); continue }
                if ch == "`" { inCode.toggle() }
                if ch == "|" && !inCode {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
        }
    }
}
