import Foundation

// MARK: - Finding math in Markdown

/// Locates TeX math in Markdown text: `$…$` and `\(…\)` inline, `$$…$$` and `\[…\]` display.
enum MathSyntax {
    enum Piece: Equatable {
        case text(String)
        case math(String, display: Bool)
    }

    /// Splits inline Markdown into text and math, leaving code spans and escaped characters alone.
    static func split(_ source: String) -> [Piece] {
        guard source.contains("$") || source.contains("\\") else { return [.text(source)] }
        let chars = Array(source)
        var pieces: [Piece] = []
        var text = ""
        var i = 0

        func emit(_ body: ArraySlice<Character>, display: Bool) {
            if !text.isEmpty { pieces.append(.text(text)); text = "" }
            pieces.append(.math(String(body).trimmingCharacters(in: .whitespacesAndNewlines), display: display))
        }

        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                let run = chars[i...].prefix { $0 == "`" }.count
                let stop = closingBackticks(chars, from: i + run, count: run).map { $0 + run } ?? i + run
                text += String(chars[i..<stop])
                i = stop
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "(" || n == "[", let end = find(["\\", n == "(" ? ")" : "]"], in: chars, from: i + 2) {
                    emit(chars[(i + 2)..<end], display: n == "[")
                    i = end + 2
                    continue
                }
                text.append(c)
                text.append(n)
                i += 2
                continue
            }
            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    if let end = find(["$", "$"], in: chars, from: i + 2), end > i + 2 {
                        emit(chars[(i + 2)..<end], display: true)
                        i = end + 2
                    } else {
                        text += "$$"
                        i += 2
                    }
                    continue
                }
                if let end = inlineDollarEnd(chars, open: i) {
                    emit(chars[(i + 1)..<end], display: false)
                    i = end + 1
                    continue
                }
            }
            text.append(c)
            i += 1
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    /// Private-use characters stand in for math while the surrounding Markdown is parsed.
    static func placeholder(_ index: Int) -> Character {
        Character(Unicode.Scalar(0xE000 + UInt32(index))!)
    }

    static func placeholderIndex(_ c: Character) -> Int? {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value, (0xE000...0xF8FF).contains(v) else { return nil }
        return Int(v - 0xE000)
    }

    private static func closingBackticks(_ chars: [Character], from start: Int, count: Int) -> Int? {
        var j = start
        while j < chars.count {
            guard chars[j] == "`" else { j += 1; continue }
            let run = chars[j...].prefix { $0 == "`" }.count
            if run == count { return j }
            j += run
        }
        return nil
    }

    private static func find(_ needle: [Character], in chars: [Character], from start: Int) -> Int? {
        var j = start
        while j + needle.count <= chars.count {
            if chars[j..<(j + needle.count)].elementsEqual(needle) { return j }
            j += chars[j] == "\\" ? 2 : 1
        }
        return nil
    }

    /// Pandoc's rule: `$` opens only before a non-space, and closes only after a non-space and not
    /// before a digit, so prices like "$5 and $10" stay text.
    private static func inlineDollarEnd(_ chars: [Character], open: Int) -> Int? {
        guard open + 1 < chars.count, !chars[open + 1].isWhitespace, chars[open + 1] != "$" else { return nil }
        var j = open + 1
        while j < chars.count {
            switch chars[j] {
            case "\\":
                j += 2
                continue
            case "$":
                let validClose = !chars[j - 1].isWhitespace && (j + 1 >= chars.count || !chars[j + 1].isNumber)
                return validClose ? j : nil
            default:
                j += 1
            }
        }
        return nil
    }
}

// MARK: - Math model

enum MathStyle: Int {
    case display, text, script, scriptScript

    var script: MathStyle { rawValue <= MathStyle.text.rawValue ? .script : .scriptScript }
    var fraction: MathStyle {
        switch self {
        case .display: return .text
        case .text: return .script
        default: return .scriptScript
        }
    }
    var isScript: Bool { rawValue >= MathStyle.script.rawValue }
}

enum MathClass: Int { case ord, op, bin, rel, open, close, punct, inner }

enum MathAccent: Equatable {
    case hat, wideHat, check, tilde, wideTilde, bar, overline, underline, vec
    case rightArrow, leftArrow, leftRightArrow, dot, ddot, breve, acute, grave, ring
    case overbrace, underbrace
}

enum MathArrayKind: Equatable {
    case matrix, cases, aligned, gathered
    case array([Character])
}

indirect enum MathNode: Equatable {
    case symbol(String, MathClass)
    case text(String, bold: Bool, italic: Bool)
    /// ∑, ∫, …; `limits` nil means limits in display style only.
    case largeOp(String, limits: Bool?)
    /// Upright operator names such as sin, log, lim.
    case function(String, limits: Bool?)
    case group([MathNode], MathClass)
    case scripts(MathNode, sub: [MathNode]?, sup: [MathNode]?)
    case fraction([MathNode], [MathNode], rule: Bool, style: MathStyle?)
    case radical([MathNode], index: [MathNode]?)
    case fenced(String, [MathNode], String)
    case delimiter(String, scale: CGFloat, MathClass)
    case accent([MathNode], MathAccent)
    case stack([MathNode], over: [MathNode]?, under: [MathNode]?, MathClass)
    case boxed([MathNode])
    case array([[[MathNode]]], MathArrayKind)
    case space(CGFloat)
    case phantom([MathNode])
    case styled(MathStyle, [MathNode])
}

// MARK: - Parsing LaTeX

/// A forgiving parser for the LaTeX math people (and models) actually write.
/// Unknown commands render as their name; unbalanced input never fails.
struct MathParser {
    private let chars: [Character]
    private var i = 0
    private var font: MathAlphabet.Font = .italic

    private init(_ source: String) { chars = Array(source) }

    static func parse(_ latex: String) -> [MathNode] {
        var parser = MathParser(latex)
        let rows = parser.parseRows(environment: nil)
        if rows.count == 1, rows[0].count == 1 { return rows[0][0] }
        let kind: MathArrayKind = rows.contains { $0.count > 1 } ? .aligned : .gathered
        return [.array(rows, kind)]
    }

    // MARK: Structure

    private mutating func parseRows(environment: String?) -> [[[MathNode]]] {
        var rows: [[[MathNode]]] = []
        var row: [[MathNode]] = []
        var cell: [MathNode] = []
        while true {
            cell += parseList()
            guard i < chars.count else { break }
            if chars[i] == "&" {
                i += 1
                row.append(cell)
                cell = []
                continue
            }
            let name = peekCommandName()
            if name == "\\" || name == "cr" {
                skipCommand()
                _ = readOptionalBracket()
                row.append(cell)
                rows.append(row)
                row = []
                cell = []
                continue
            }
            if name == "end" {
                skipCommand()
                let ended = readRawArgument()
                if environment != nil { _ = ended; break }
                continue
            }
            // A stray `}` or `\right` at this level: drop it and keep going.
            skipToken()
        }
        row.append(cell)
        rows.append(row)
        if rows.count > 1, let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
        return rows
    }

    /// Parses atoms until the end of input or a `}`, `&`, `\\`, `\end` or `\right` (not consumed).
    private mutating func parseList() -> [MathNode] {
        var list: [MathNode] = []
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "}" || c == "&" { return list }
            if c == "\\", ["\\", "cr", "end", "right"].contains(peekCommandName()) { return list }
            if c == "^" || c == "_" {
                i += 1
                attachScript(to: &list, parseArgument(), superscript: c == "^")
                continue
            }
            if c == "'" {
                let count = chars[i...].prefix { $0 == "'" }.count
                i += count
                list.append(.symbol(["′", "″", "‴"][min(count, 3) - 1], .ord))
                continue
            }
            parseItem(into: &list, single: false)
        }
        return list
    }

    /// After `{`: everything up to the matching `}`.
    private mutating func parseGroupBody() -> [MathNode] {
        var list: [MathNode] = []
        while true {
            list += parseList()
            guard i < chars.count else { break }
            if chars[i] == "}" { i += 1; break }
            skipToken()
        }
        return list
    }

    /// One argument: a `{group}` or a single token.
    private mutating func parseArgument() -> [MathNode] {
        skipSpaces()
        guard i < chars.count else { return [] }
        let c = chars[i]
        if c == "{" { i += 1; return parseGroupBody() }
        if c == "}" || c == "&" { return [] }
        if c == "\\", ["\\", "cr", "end", "right"].contains(peekCommandName()) { return [] }
        var list: [MathNode] = []
        parseItem(into: &list, single: true)
        return list
    }

    private mutating func attachScript(to list: inout [MathNode], _ script: [MathNode], superscript: Bool) {
        let last = list.popLast() ?? .group([], .ord)
        switch last {
        case .scripts(let base, let sub, let sup) where superscript ? sup == nil : sub == nil:
            list.append(.scripts(base, sub: superscript ? sub : script, sup: superscript ? script : sup))
        case .symbol(let s, _) where "′″‴".contains(s) && superscript:
            // f'^2: keep the prime and the exponent together in the superscript.
            list.append(.scripts(.group([], .ord), sub: nil, sup: [last] + script))
        default:
            list.append(.scripts(last, sub: superscript ? nil : script, sup: superscript ? script : nil))
        }
    }

    // MARK: Atoms

    private mutating func parseItem(into list: inout [MathNode], single: Bool) {
        let c = chars[i]
        switch c {
        case "{":
            i += 1
            let body = parseGroupBody()
            list.append(body.count == 1 ? body[0] : .group(body, .ord))
        case "\\":
            i += 1
            command(readCommandName(), into: &list)
        case "0"..."9":
            var digits = String(c)
            i += 1
            if !single {
                while i < chars.count, chars[i].isASCII,
                      chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                    digits.append(chars[i])
                    i += 1
                }
            }
            list.append(.symbol(MathAlphabet.map(digits, font), .ord))
        case "~":
            i += 1
            list.append(.space(0.33))
        default:
            i += 1
            if c.isASCII && c.isLetter {
                list.append(.symbol(MathAlphabet.map(String(c), font), .ord))
            } else if let entry = MathSymbols.characters[c] {
                list.append(.symbol(entry.0, entry.1))
            } else if c.unicodeScalars.first.map({ (0x391...0x3FF).contains($0.value) }) == true {
                list.append(.symbol(MathAlphabet.map(String(c), font), .ord))
            } else if c.isLetter {
                // Hangul, CJK and other prose typed straight into math: set it as text.
                var run = String(c)
                while i < chars.count, !chars[i].isASCII, chars[i].isLetter || chars[i].isNumber {
                    run.append(chars[i])
                    i += 1
                }
                list.append(.text(run, bold: false, italic: false))
            } else {
                list.append(.symbol(String(c), MathSymbols.unicodeClass(c)))
            }
        }
    }

    private mutating func command(_ name: String, into list: inout [MathNode]) {
        if let entry = MathSymbols.commands[name] {
            list.append(.symbol(entry.0, entry.1))
            return
        }
        if let letter = MathSymbols.greek[name] {
            // LaTeX sets lowercase Greek italic and capitals upright.
            let upright = letter.first!.isUppercase && !name.hasPrefix("var")
            list.append(.symbol(upright ? letter : MathAlphabet.map(letter, font), .ord))
            return
        }
        if let entry = MathSymbols.largeOperators[name] {
            list.append(.largeOp(entry.0, limits: entry.1))
            return
        }
        if let entry = MathSymbols.functions[name] {
            list.append(.function(entry.0, limits: entry.1))
            return
        }
        if let alphabet = MathAlphabet.Font(command: name) {
            let saved = font
            font = alphabet
            let body = parseArgument()
            font = saved
            list.append(body.count == 1 ? body[0] : .group(body, .ord))
            return
        }
        if let accent = MathSymbols.accents[name] {
            list.append(.accent(parseArgument(), accent))
            return
        }
        if let em = MathSymbols.spaces[name] {
            list.append(.space(em))
            return
        }
        if let style = MathSymbols.styles[name] {
            list.append(.styled(style, parseList()))
            return
        }

        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let num = parseArgument(), den = parseArgument()
            let style: MathStyle? = name == "dfrac" || name == "cfrac" ? .display : name == "tfrac" ? .text : nil
            list.append(.fraction(num, den, rule: true, style: style))
        case "binom", "dbinom", "tbinom":
            let top = parseArgument(), bottom = parseArgument()
            let style: MathStyle? = name == "dbinom" ? .display : name == "tbinom" ? .text : nil
            list.append(.fenced("(", [.fraction(top, bottom, rule: false, style: style)], ")"))
        case "sqrt":
            let index = readOptionalBracket().map(MathParser.parse)
            list.append(.radical(parseArgument(), index: index))
        case "left":
            let open = readDelimiter()
            let body = parseList()
            var close = "."
            if peekCommandName() == "right" {
                skipCommand()
                close = readDelimiter()
            }
            list.append(.fenced(open, body, close))
        case "right":
            _ = readDelimiter()
        case "middle":
            let d = readDelimiter()
            if d != "." { list.append(.symbol(d, .ord)) }
        case "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl",
             "bigr", "Bigr", "biggr", "Biggr", "bigm", "Bigm", "biggm", "Biggm":
            let scale: CGFloat = name.hasPrefix("Bigg") ? 3.0 : name.hasPrefix("bigg") ? 2.4 : name.hasPrefix("Big") ? 1.8 : 1.2
            let cls: MathClass = name.hasSuffix("l") ? .open : name.hasSuffix("r") ? .close : name.hasSuffix("m") ? .rel : .ord
            let d = readDelimiter()
            if d != "." { list.append(.delimiter(d, scale: scale, cls)) }
        case "text", "textrm", "textnormal", "textup", "textsf", "texttt", "textmd", "mbox", "hbox", "fbox", "textbf", "textit", "emph", "textsl":
            let nodes = textNodes(readRawArgument(), bold: name == "textbf", italic: ["textit", "emph", "textsl"].contains(name))
            list.append(name == "fbox" ? .boxed(nodes) : nodes.count == 1 ? nodes[0] : .group(nodes, .ord))
        case "operatorname":
            let limits = i < chars.count && chars[i] == "*"
            if limits { i += 1 }
            list.append(.function(Self.plainText(readRawArgument()), limits: limits ? nil : false))
        case "boxed", "framebox":
            _ = readOptionalBracket()
            list.append(.boxed(parseArgument()))
        case "overset", "stackrel", "underset":
            let annotation = parseArgument(), base = parseArgument()
            let cls: MathClass = name == "stackrel" ? .rel : Self.classOf(base)
            list.append(name == "underset"
                ? .stack(base, over: nil, under: annotation, cls)
                : .stack(base, over: annotation, under: nil, cls))
        case "xrightarrow", "xleftarrow", "xRightarrow", "xLeftarrow", "xleftrightarrow":
            let under = readOptionalBracket().map(MathParser.parse)
            let over = parseArgument()
            let arrow = ["xrightarrow": "⟶", "xleftarrow": "⟵", "xRightarrow": "⟹", "xLeftarrow": "⟸"][name] ?? "⟷"
            list.append(.stack([.symbol(arrow, .rel)], over: over, under: under, .rel))
        case "substack":
            list.append(.group(MathParser.parse(readRawArgument()), .ord))
        case "phantom", "hphantom", "vphantom":
            list.append(.phantom(parseArgument()))
        case "color":
            _ = readRawArgument()
        case "textcolor", "mathcolor", "colorbox":
            _ = readRawArgument()
            let body = parseArgument()
            list.append(body.count == 1 ? body[0] : .group(body, .ord))
        case "hspace", "mspace", "hskip", "kern", "mkern", "mskip":
            if i < chars.count, chars[i] == "*" { i += 1 }
            skipSpaces()
            let raw = i < chars.count && chars[i] == "{" ? readRawArgument() : readDimension()
            list.append(.space(Self.ems(raw)))
        case "limits", "nolimits":
            let limits = name == "limits"
            if let last = list.popLast() {
                switch last {
                case .largeOp(let s, _): list.append(.largeOp(s, limits: limits))
                case .function(let s, _): list.append(.function(s, limits: limits))
                default: list.append(last)
                }
            }
        case "not":
            var next: [MathNode] = []
            skipSpaces()
            if i < chars.count { parseItem(into: &next, single: true) }
            if case .symbol(let s, let cls)? = next.first, next.count == 1 {
                list.append(.symbol(MathSymbols.negated[s] ?? s + "\u{338}", cls))
            } else {
                list += next
            }
        case "mod":
            list += [.space(0.5), .function("mod", limits: false), .space(0.2)]
        case "bmod":
            list.append(.group([.function("mod", limits: false)], .bin))
        case "pmod":
            let arg = parseArgument()
            list += [.space(0.5), .symbol("(", .open), .function("mod", limits: false), .space(0.2)]
            list += arg + [.symbol(")", .close)]
        case "begin":
            list += environment(readRawArgument())
        case "tag", "label", "eqref", "ref":
            _ = readRawArgument()
        case "nonumber", "notag", "displaylimits", "relax", "nobreak", "allowbreak", "centering", "quad*":
            break
        case "":
            break
        default:
            list.append(.function(name, limits: false))
        }
    }

    private mutating func environment(_ name: String) -> [MathNode] {
        let bare = name.replacingOccurrences(of: "*", with: "")
        if bare == "alignat" || bare == "alignedat" { _ = readRawArgument() }
        let spec: [Character]? = bare == "array" ? Array(readRawArgument()).filter { "lcr".contains($0) } : nil
        let rows = parseRows(environment: name)
        switch bare {
        case "matrix", "smallmatrix": return [.array(rows, .matrix)]
        case "pmatrix": return [.fenced("(", [.array(rows, .matrix)], ")")]
        case "bmatrix": return [.fenced("[", [.array(rows, .matrix)], "]")]
        case "Bmatrix": return [.fenced("{", [.array(rows, .matrix)], "}")]
        case "vmatrix": return [.fenced("|", [.array(rows, .matrix)], "|")]
        case "Vmatrix": return [.fenced("‖", [.array(rows, .matrix)], "‖")]
        case "cases", "dcases": return [.fenced("{", [.array(rows, .cases)], ".")]
        case "rcases": return [.fenced(".", [.array(rows, .cases)], "}")]
        case "array": return [.array(rows, .array(spec ?? []))]
        case "aligned", "align", "alignat", "alignedat", "split", "eqnarray", "flalign":
            return [.array(rows, .aligned)]
        default:
            if rows.count == 1, rows[0].count == 1 { return rows[0][0] }
            return [.array(rows, .gathered)]
        }
    }

    /// `\text{…}` content, with any `$…$` inside it set as math.
    private func textNodes(_ raw: String, bold: Bool, italic: Bool) -> [MathNode] {
        var nodes: [MathNode] = []
        for (k, part) in raw.components(separatedBy: "$").enumerated() where !part.isEmpty {
            if k.isMultiple(of: 2) {
                nodes.append(.text(Self.plainText(part), bold: bold, italic: italic))
            } else {
                nodes.append(.group(MathParser.parse(part), .ord))
            }
        }
        return nodes
    }

    /// Text-mode escapes (`\%`, `\&`, `~`) as the characters they print.
    private static func plainText(_ raw: String) -> String {
        var out = ""
        var escaped = false
        for c in raw {
            if escaped { out.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "{" || c == "}" { continue }
            out.append(c == "~" ? "\u{00A0}" : c)
        }
        return out
    }

    private static func classOf(_ nodes: [MathNode]) -> MathClass {
        if nodes.count == 1, case .symbol(_, let cls) = nodes[0] { return cls }
        return .ord
    }

    /// A TeX dimension (`1em`, `3mu`, `5pt`) in ems.
    private static func ems(_ raw: String) -> CGFloat {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let number = Double(t.prefix { $0.isNumber || $0 == "." || $0 == "-" }) ?? 0.5
        if t.hasSuffix("mu") { return number / 18 }
        if t.hasSuffix("pt") { return number / 10 }
        if t.hasSuffix("ex") { return number * 0.45 }
        return number
    }

    // MARK: Low-level reading

    private mutating func skipSpaces() {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }

    private func peekCommandName() -> String {
        guard i < chars.count, chars[i] == "\\" else { return "" }
        var j = i + 1
        guard j < chars.count else { return "" }
        guard chars[j].isASCII && chars[j].isLetter else { return String(chars[j]) }
        var name = ""
        while j < chars.count, chars[j].isASCII && chars[j].isLetter { name.append(chars[j]); j += 1 }
        return name
    }

    private mutating func skipCommand() {
        i += 1
        _ = readCommandName()
    }

    /// After `\`: a run of letters, or one other character.
    private mutating func readCommandName() -> String {
        guard i < chars.count else { return "" }
        guard chars[i].isASCII && chars[i].isLetter else {
            defer { i += 1 }
            return String(chars[i])
        }
        var name = ""
        while i < chars.count, chars[i].isASCII && chars[i].isLetter { name.append(chars[i]); i += 1 }
        return name
    }

    private mutating func skipToken() {
        guard i < chars.count else { return }
        if chars[i] == "\\" { skipCommand() } else { i += 1 }
    }

    /// A `{…}` argument as raw text (or a single character / command).
    private mutating func readRawArgument() -> String {
        skipSpaces()
        guard i < chars.count else { return "" }
        if chars[i] == "\\" {
            let start = i
            skipCommand()
            return String(chars[start..<i])
        }
        guard chars[i] == "{" else {
            defer { i += 1 }
            return String(chars[i])
        }
        i += 1
        var depth = 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(c)
                out.append(chars[i + 1])
                i += 2
                continue
            }
            i += 1
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            out.append(c)
        }
        return out
    }

    /// An optional `[…]` argument.
    private mutating func readOptionalBracket() -> String? {
        let start = i
        skipSpaces()
        guard i < chars.count, chars[i] == "[" else { i = start; return nil }
        i += 1
        var depth = 0
        var out = ""
        while i < chars.count {
            let c = chars[i]
            i += 1
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            if c == "]" && depth == 0 { break }
            out.append(c)
        }
        return out
    }

    private mutating func readDimension() -> String {
        var out = ""
        while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "-" { out.append(chars[i]); i += 1 }
        while i < chars.count, chars[i].isASCII && chars[i].isLetter, out.count < 12 {
            out.append(chars[i])
            i += 1
            if ["em", "mu", "pt", "ex"].contains(where: { out.hasSuffix($0) }) { break }
        }
        return out
    }

    /// The delimiter after `\left`, `\right`, `\big`…; "." means none.
    private mutating func readDelimiter() -> String {
        skipSpaces()
        guard i < chars.count else { return "." }
        if chars[i] == "\\" {
            i += 1
            let name = readCommandName()
            return MathSymbols.delimiters[name] ?? MathSymbols.commands[name]?.0 ?? "."
        }
        let c = chars[i]
        i += 1
        switch c {
        case "<": return "⟨"
        case ">": return "⟩"
        default: return String(c)
        }
    }
}

// MARK: - Alphabets

/// Maps letters to the Unicode math alphabets (𝑥, 𝐱, ℝ, 𝒜…) that math fonts are designed around.
enum MathAlphabet {
    enum Font {
        case italic, roman, bold, boldItalic, blackboard, script, fraktur, sansSerif, monospace

        init?(command: String) {
            switch command {
            case "mathrm", "mathup", "rm": self = .roman
            case "mathit", "mathnormal": self = .italic
            case "mathbf", "bf": self = .bold
            case "boldsymbol", "bm", "pmb": self = .boldItalic
            case "mathbb", "Bbb": self = .blackboard
            case "mathcal", "mathscr", "cal": self = .script
            case "mathfrak": self = .fraktur
            case "mathsf": self = .sansSerif
            case "mathtt": self = .monospace
            default: return nil
            }
        }
    }

    static func map(_ text: String, _ font: Font) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            out.append(map(scalar, font))
        }
        return String(out)
    }

    private static func map(_ c: Unicode.Scalar, _ font: Font) -> Unicode.Scalar {
        let v = c.value
        let upper = (0x41...0x5A).contains(v), lower = (0x61...0x7A).contains(v), digit = (0x30...0x39).contains(v)
        let greek = (0x3B1...0x3C9).contains(v)
        func at(_ base: UInt32, _ offset: UInt32) -> Unicode.Scalar { Unicode.Scalar(base + offset) ?? c }
        if let special = exceptions[font]?[Character(c)] { return Unicode.Scalar(special)! }
        switch font {
        case .roman:
            return c
        case .italic:
            if upper { return at(0x1D434, v - 0x41) }
            if lower { return at(0x1D44E, v - 0x61) }
            if greek { return at(0x1D6FC, v - 0x3B1) }
            return italicGreekVariants[v].flatMap(Unicode.Scalar.init) ?? c
        case .bold:
            if upper { return at(0x1D400, v - 0x41) }
            if lower { return at(0x1D41A, v - 0x61) }
            if digit { return at(0x1D7CE, v - 0x30) }
            if greek { return at(0x1D6C2, v - 0x3B1) }
        case .boldItalic:
            if upper { return at(0x1D468, v - 0x41) }
            if lower { return at(0x1D482, v - 0x61) }
            if digit { return at(0x1D7CE, v - 0x30) }
            if greek { return at(0x1D736, v - 0x3B1) }
        case .blackboard:
            if upper { return at(0x1D538, v - 0x41) }
            if lower { return at(0x1D552, v - 0x61) }
            if digit { return at(0x1D7D8, v - 0x30) }
        case .script:
            if upper { return at(0x1D49C, v - 0x41) }
            if lower { return at(0x1D4B6, v - 0x61) }
        case .fraktur:
            if upper { return at(0x1D504, v - 0x41) }
            if lower { return at(0x1D51E, v - 0x61) }
        case .sansSerif:
            if upper { return at(0x1D5A0, v - 0x41) }
            if lower { return at(0x1D5BA, v - 0x61) }
            if digit { return at(0x1D7E2, v - 0x30) }
        case .monospace:
            if upper { return at(0x1D670, v - 0x41) }
            if lower { return at(0x1D68A, v - 0x61) }
            if digit { return at(0x1D7F6, v - 0x30) }
        }
        return c
    }

    /// Letters that live in the Letterlike Symbols block instead of the math alphabets.
    private static let exceptions: [Font: [Character: UInt32]] = [
        .italic: ["h": 0x210E],
        .blackboard: ["C": 0x2102, "H": 0x210D, "N": 0x2115, "P": 0x2119, "Q": 0x211A, "R": 0x211D, "Z": 0x2124],
        .script: ["B": 0x212C, "E": 0x2130, "F": 0x2131, "H": 0x210B, "I": 0x2110, "L": 0x2112, "M": 0x2133,
                  "R": 0x211B, "e": 0x212F, "g": 0x210A, "o": 0x2134],
        .fraktur: ["C": 0x212D, "H": 0x210C, "I": 0x2111, "R": 0x211C, "Z": 0x2128],
    ]

    /// ϵ ϑ ϰ ϕ ϱ ϖ in math italic.
    private static let italicGreekVariants: [UInt32: UInt32] = [
        0x3F5: 0x1D716, 0x3D1: 0x1D717, 0x3F0: 0x1D718, 0x3D5: 0x1D719, 0x3F1: 0x1D71A, 0x3D6: 0x1D71B,
    ]
}

// MARK: - Symbol tables

enum MathSymbols {
    static let characters: [Character: (String, MathClass)] = [
        "+": ("+", .bin), "-": ("−", .bin), "*": ("∗", .bin), "/": ("/", .ord),
        "=": ("=", .rel), "<": ("<", .rel), ">": (">", .rel), ":": (":", .rel),
        ",": (",", .punct), ";": (";", .punct), ".": (".", .ord), "!": ("!", .close), "?": ("?", .close),
        "(": ("(", .open), "[": ("[", .open), ")": (")", .close), "]": ("]", .close), "|": ("|", .ord),
        "@": ("@", .ord), "\"": ("\"", .ord), "#": ("#", .ord), "%": ("%", .ord),
        "−": ("−", .bin), "·": ("⋅", .bin), "×": ("×", .bin), "÷": ("÷", .bin), "±": ("±", .bin),
    ]

    static func unicodeClass(_ c: Character) -> MathClass {
        if "≤≥≠≈≡→←↔⇒⇐⇔∈∉∋⊂⊆⊃⊇∼≃≅∝≪≫⟶⟵⟹⟸⟺↦∣∥⊥⊢⊨≺≻".contains(c) { return .rel }
        if "∓⋅∘∙∩∪∧∨⊕⊗⊖⊙∖⊔⊓†‡⋆".contains(c) { return .bin }
        if "⟨⌊⌈".contains(c) { return .open }
        if "⟩⌋⌉".contains(c) { return .close }
        return .ord
    }

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "varkappa": "ϰ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ",
        "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    static let commands: [String: (String, MathClass)] = [
        // Relations
        "le": ("≤", .rel), "leq": ("≤", .rel), "ge": ("≥", .rel), "geq": ("≥", .rel), "leqslant": ("⩽", .rel),
        "geqslant": ("⩾", .rel), "ne": ("≠", .rel), "neq": ("≠", .rel), "approx": ("≈", .rel), "equiv": ("≡", .rel),
        "sim": ("∼", .rel), "simeq": ("≃", .rel), "cong": ("≅", .rel), "propto": ("∝", .rel), "doteq": ("≐", .rel),
        "coloneqq": ("≔", .rel), "triangleq": ("≜", .rel), "asymp": ("≍", .rel),
        "in": ("∈", .rel), "notin": ("∉", .rel), "ni": ("∋", .rel), "subset": ("⊂", .rel), "subseteq": ("⊆", .rel),
        "supset": ("⊃", .rel), "supseteq": ("⊇", .rel), "subsetneq": ("⊊", .rel), "supsetneq": ("⊋", .rel),
        "to": ("→", .rel), "rightarrow": ("→", .rel), "leftarrow": ("←", .rel), "gets": ("←", .rel),
        "leftrightarrow": ("↔", .rel), "Rightarrow": ("⇒", .rel), "Leftarrow": ("⇐", .rel),
        "Leftrightarrow": ("⇔", .rel), "iff": ("⟺", .rel), "implies": ("⟹", .rel), "impliedby": ("⟸", .rel),
        "mapsto": ("↦", .rel), "longrightarrow": ("⟶", .rel), "longleftarrow": ("⟵", .rel),
        "Longrightarrow": ("⟹", .rel), "Longleftarrow": ("⟸", .rel), "longleftrightarrow": ("⟷", .rel),
        "Longleftrightarrow": ("⟺", .rel), "longmapsto": ("⟼", .rel), "uparrow": ("↑", .rel),
        "downarrow": ("↓", .rel), "Uparrow": ("⇑", .rel), "Downarrow": ("⇓", .rel), "updownarrow": ("↕", .rel),
        "nearrow": ("↗", .rel), "searrow": ("↘", .rel), "hookrightarrow": ("↪", .rel), "rightleftharpoons": ("⇌", .rel),
        "parallel": ("∥", .rel), "perp": ("⊥", .rel), "mid": ("∣", .rel), "nmid": ("∤", .rel),
        "ll": ("≪", .rel), "gg": ("≫", .rel), "prec": ("≺", .rel), "succ": ("≻", .rel), "preceq": ("⪯", .rel),
        "succeq": ("⪰", .rel), "models": ("⊨", .rel), "vdash": ("⊢", .rel), "dashv": ("⊣", .rel),
        "therefore": ("∴", .rel), "because": ("∵", .rel), "lessgtr": ("≶", .rel), "lesssim": ("≲", .rel),
        "gtrsim": ("≳", .rel), "neg": ("¬", .ord), "lnot": ("¬", .ord),
        // Binary operators
        "pm": ("±", .bin), "mp": ("∓", .bin), "times": ("×", .bin), "div": ("÷", .bin), "cdot": ("⋅", .bin),
        "ast": ("∗", .bin), "star": ("⋆", .bin), "circ": ("∘", .bin), "bullet": ("∙", .bin), "cap": ("∩", .bin),
        "cup": ("∪", .bin), "wedge": ("∧", .bin), "land": ("∧", .bin), "vee": ("∨", .bin), "lor": ("∨", .bin),
        "oplus": ("⊕", .bin), "otimes": ("⊗", .bin), "ominus": ("⊖", .bin), "odot": ("⊙", .bin), "oslash": ("⊘", .bin),
        "setminus": ("∖", .bin), "sqcup": ("⊔", .bin), "sqcap": ("⊓", .bin), "uplus": ("⊎", .bin),
        "dagger": ("†", .bin), "ddagger": ("‡", .bin), "amalg": ("⨿", .bin), "wr": ("≀", .bin),
        "diamond": ("⋄", .bin), "triangleleft": ("◁", .bin), "triangleright": ("▷", .bin),
        // Ordinary symbols
        "infty": ("∞", .ord), "partial": ("∂", .ord), "nabla": ("∇", .ord), "forall": ("∀", .ord),
        "exists": ("∃", .ord), "nexists": ("∄", .ord), "emptyset": ("∅", .ord), "varnothing": ("∅", .ord),
        "angle": ("∠", .ord), "measuredangle": ("∡", .ord), "triangle": ("△", .ord), "hbar": ("ℏ", .ord),
        "hslash": ("ℏ", .ord), "ell": ("ℓ", .ord), "Re": ("ℜ", .ord), "Im": ("ℑ", .ord), "aleph": ("ℵ", .ord),
        "wp": ("℘", .ord), "prime": ("′", .ord), "degree": ("°", .ord), "top": ("⊤", .ord), "bot": ("⊥", .ord),
        "square": ("□", .ord), "Box": ("□", .ord), "blacksquare": ("■", .ord), "checkmark": ("✓", .ord),
        "clubsuit": ("♣", .ord), "diamondsuit": ("♢", .ord), "heartsuit": ("♡", .ord), "spadesuit": ("♠", .ord),
        "flat": ("♭", .ord), "natural": ("♮", .ord), "sharp": ("♯", .ord), "S": ("§", .ord), "P": ("¶", .ord),
        "dots": ("…", .inner), "ldots": ("…", .inner), "cdots": ("⋯", .inner), "dotsc": ("…", .inner),
        "dotsb": ("⋯", .inner), "vdots": ("⋮", .ord), "ddots": ("⋱", .inner), "colon": (":", .punct),
        "lfloor": ("⌊", .open), "rfloor": ("⌋", .close), "lceil": ("⌈", .open), "rceil": ("⌉", .close),
        "langle": ("⟨", .open), "rangle": ("⟩", .close), "lvert": ("|", .open), "rvert": ("|", .close),
        "lVert": ("‖", .open), "rVert": ("‖", .close), "vert": ("|", .ord), "Vert": ("‖", .ord),
        "lbrace": ("{", .open), "rbrace": ("}", .close), "lbrack": ("[", .open), "rbrack": ("]", .close),
        "backslash": ("\\", .ord), "{": ("{", .open), "}": ("}", .close), "|": ("‖", .ord),
        "#": ("#", .ord), "%": ("%", .ord), "&": ("&", .ord), "_": ("_", .ord), "$": ("$", .ord),
        "R": ("ℝ", .ord), "N": ("ℕ", .ord), "Z": ("ℤ", .ord), "Q": ("ℚ", .ord), "C": ("ℂ", .ord),
        "imath": ("ı", .ord), "jmath": ("ȷ", .ord),
    ]

    static let delimiters: [String: String] = [
        "{": "{", "}": "}", "|": "‖", "langle": "⟨", "rangle": "⟩", "lvert": "|", "rvert": "|", "vert": "|",
        "lVert": "‖", "rVert": "‖", "Vert": "‖", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "lbrace": "{", "rbrace": "}", "lbrack": "[", "rbrack": "]", "backslash": "\\",
    ]

    static let largeOperators: [String: (String, Bool?)] = [
        "sum": ("∑", nil), "prod": ("∏", nil), "coprod": ("∐", nil), "bigcup": ("⋃", nil), "bigcap": ("⋂", nil),
        "bigvee": ("⋁", nil), "bigwedge": ("⋀", nil), "bigoplus": ("⨁", nil), "bigotimes": ("⨂", nil),
        "bigodot": ("⨀", nil), "biguplus": ("⨄", nil), "bigsqcup": ("⨆", nil),
        "int": ("∫", false), "iint": ("∬", false), "iiint": ("∭", false), "oint": ("∮", false), "oiint": ("∯", false),
    ]

    static let functions: [String: (String, Bool?)] = {
        var table: [String: (String, Bool?)] = [:]
        for name in ["sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
                     "coth", "log", "ln", "lg", "exp", "dim", "ker", "deg", "arg", "hom"] {
            table[name] = (name, false)
        }
        for name in ["lim", "max", "min", "sup", "inf", "det", "gcd", "Pr"] { table[name] = (name, nil) }
        table["limsup"] = ("lim sup", nil)
        table["liminf"] = ("lim inf", nil)
        table["argmax"] = ("arg max", nil)
        table["argmin"] = ("arg min", nil)
        return table
    }()

    static let accents: [String: MathAccent] = [
        "hat": .hat, "widehat": .wideHat, "check": .check, "tilde": .tilde, "widetilde": .wideTilde,
        "bar": .bar, "overline": .overline, "underline": .underline, "vec": .vec,
        "overrightarrow": .rightArrow, "overleftarrow": .leftArrow, "overleftrightarrow": .leftRightArrow,
        "dot": .dot, "ddot": .ddot, "breve": .breve, "acute": .acute, "grave": .grave, "mathring": .ring,
        "overbrace": .overbrace, "underbrace": .underbrace,
    ]

    static let spaces: [String: CGFloat] = [
        ",": 3 / 18, ":": 4 / 18, ">": 4 / 18, ";": 5 / 18, "!": -3 / 18, " ": 0.33,
        "thinspace": 3 / 18, "medspace": 4 / 18, "thickspace": 5 / 18, "negthinspace": -3 / 18,
        "negmedspace": -4 / 18, "negthickspace": -5 / 18, "enspace": 0.5, "quad": 1, "qquad": 2,
    ]

    static let styles: [String: MathStyle] = [
        "displaystyle": .display, "textstyle": .text, "scriptstyle": .script, "scriptscriptstyle": .scriptScript,
    ]

    static let negated: [String: String] = [
        "=": "≠", "∈": "∉", "⊂": "⊄", "⊆": "⊈", "⊃": "⊅", "⊇": "⊉", "≡": "≢", "<": "≮", ">": "≯",
        "≤": "≰", "≥": "≱", "∼": "≁", "≈": "≉", "≅": "≇", "∣": "∤", "∥": "∦", "∃": "∄", "→": "↛",
    ]
}
