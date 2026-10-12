import SwiftUI

/// A small, dependency-free syntax highlighter for fenced code blocks.
///
/// It is a single-pass scanner, not a parser: it recognizes comments, strings, numbers,
/// keywords, literals, built-ins, types, decorators, and function names well enough to
/// make code readable at a glance, and degrades to plain text for unknown languages.
enum SyntaxHighlighter {
    /// Colors tuned for the notch's black surface (close to Xcode's dark theme).
    enum Palette {
        static let plain = Color.white.opacity(0.88)
        static let keyword = Color(red: 1.0, green: 0.48, blue: 0.70)
        static let literal = Color(red: 1.0, green: 0.48, blue: 0.70)
        static let string = Color(red: 0.99, green: 0.55, blue: 0.45)
        static let number = Color(red: 0.85, green: 0.79, blue: 0.49)
        static let comment = Color(red: 0.50, green: 0.55, blue: 0.60)
        static let type = Color(red: 0.36, green: 0.85, blue: 1.0)
        static let function = Color(red: 0.40, green: 0.83, blue: 0.70)
        static let builtin = Color(red: 0.70, green: 0.55, blue: 1.0)
        static let decorator = Color(red: 0.99, green: 0.62, blue: 0.30)
        static let variable = Color(red: 0.55, green: 0.80, blue: 1.0)
        static let key = Color(red: 0.55, green: 0.80, blue: 1.0)
    }

    enum Kind: Equatable {
        case plain, keyword, literal, string, number, comment, type, function, builtin, decorator, variable, key
    }

    struct Token: Equatable {
        var text: String
        var kind: Kind
    }

    struct Language {
        var keywords: Set<String> = []
        var literals: Set<String> = []
        var builtins: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<Character> = ["\"", "'"]
        var tripleQuotes = false
        var decorators = false
        var dollarVariables = false
        var caseInsensitive = false
        /// Keywords after which the next identifier is a declared name.
        var declarations: Set<String> = []
        var jsonKeys = false
        var yamlKeys = false
    }

    // MARK: Languages

    static func language(for raw: String?) -> Language? {
        guard let name = raw?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        switch name {
        case "python", "py", "python3": return python
        case "swift": return swift
        case "javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx": return javascript
        case "bash", "sh", "shell", "zsh", "console", "shell-session", "fish": return shell
        case "json", "jsonc", "json5": return json
        case "go", "golang": return go
        case "rust", "rs": return rust
        case "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "cs", "csharp", "c#": return cFamily
        case "java", "kotlin", "kt", "scala", "dart": return java
        case "ruby", "rb": return ruby
        case "sql", "postgres", "postgresql", "mysql", "sqlite": return sql
        case "yaml", "yml", "toml", "ini": return yaml
        case "css", "scss", "less": return css
        case "php": return php
        case "lua": return lua
        default: return nil
        }
    }

    static let python = Language(
        keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
                   "import", "from", "as", "try", "except", "finally", "raise", "with", "yield", "lambda", "pass",
                   "break", "continue", "global", "nonlocal", "assert", "del", "async", "await", "match", "case"],
        literals: ["None", "True", "False", "self", "cls"],
        builtins: ["print", "len", "range", "enumerate", "zip", "map", "filter", "sorted", "list", "dict", "set",
                   "tuple", "str", "int", "float", "bool", "open", "isinstance", "super", "min", "max", "sum",
                   "abs", "any", "all", "type", "input", "reversed", "iter", "next", "getattr", "setattr", "hasattr"],
        lineComments: ["#"], tripleQuotes: true, decorators: true, declarations: ["def", "class"])

    static let swift = Language(
        keywords: ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch",
                   "case", "default", "break", "continue", "struct", "class", "enum", "protocol", "extension",
                   "import", "init", "deinit", "self", "Self", "super", "throws", "throw", "try", "catch", "do",
                   "async", "await", "some", "any", "where", "private", "fileprivate", "internal", "public", "open",
                   "static", "final", "override", "mutating", "inout", "typealias", "associatedtype", "defer",
                   "weak", "unowned", "lazy", "actor", "nonisolated", "is", "as", "get", "set", "didSet", "willSet"],
        literals: ["true", "false", "nil"],
        builtins: ["print", "max", "min", "zip", "stride", "abs", "fatalError", "precondition", "assert"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], tripleQuotes: true, decorators: true,
        declarations: ["func", "struct", "class", "enum", "protocol", "actor", "typealias"])

    static let javascript = Language(
        keywords: ["function", "const", "let", "var", "return", "if", "else", "for", "while", "do", "switch", "case",
                   "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class",
                   "extends", "super", "this", "import", "export", "from", "as", "try", "catch", "finally", "throw",
                   "async", "await", "yield", "interface", "type", "enum", "implements", "public", "private",
                   "protected", "readonly", "static", "get", "set", "declare", "namespace", "keyof", "satisfies"],
        literals: ["true", "false", "null", "undefined", "NaN", "Infinity"],
        builtins: ["console", "Math", "JSON", "Promise", "Array", "Object", "String", "Number", "Boolean", "Map",
                   "Set", "Date", "Error", "fetch", "window", "document", "require", "module", "process"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], decorators: true,
        declarations: ["function", "class", "interface", "type", "enum"])

    static let shell = Language(
        keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
                   "function", "return", "export", "local", "readonly", "set", "unset", "source", "alias", "exit"],
        literals: ["true", "false"],
        builtins: ["echo", "cd", "ls", "cat", "grep", "sed", "awk", "curl", "git", "npm", "npx", "brew", "sudo",
                   "mkdir", "rm", "cp", "mv", "chmod", "printf", "read", "test", "openclaw", "swift", "python",
                   "python3", "pip", "node", "docker", "kubectl", "make", "xattr", "open", "find", "tar"],
        lineComments: ["#"], dollarVariables: true)

    static let json = Language(literals: ["true", "false", "null"], quotes: ["\""], jsonKeys: true)

    static let go = Language(
        keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go",
                   "defer", "return", "if", "else", "for", "range", "switch", "case", "default", "break",
                   "continue", "select", "fallthrough", "goto"],
        literals: ["true", "false", "nil", "iota"],
        builtins: ["len", "cap", "make", "new", "append", "copy", "delete", "panic", "recover", "print", "println",
                   "string", "int", "int64", "float64", "bool", "byte", "rune", "error", "any"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], declarations: ["func", "type"])

    static let rust = Language(
        keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "in", "while",
                   "loop", "if", "else", "match", "return", "break", "continue", "use", "mod", "pub", "crate",
                   "super", "self", "Self", "where", "as", "ref", "move", "async", "await", "dyn", "unsafe", "type"],
        literals: ["true", "false", "None", "Some", "Ok", "Err"],
        builtins: ["println", "print", "format", "vec", "panic", "assert", "assert_eq", "String", "Vec", "Option",
                   "Result", "Box", "i32", "i64", "u32", "u64", "usize", "f32", "f64", "bool", "str"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], decorators: true,
        declarations: ["fn", "struct", "enum", "trait", "type"])

    static let cFamily = Language(
        keywords: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "const",
                   "static", "struct", "union", "enum", "typedef", "return", "if", "else", "for", "while", "do",
                   "switch", "case", "default", "break", "continue", "sizeof", "class", "public", "private",
                   "protected", "virtual", "override", "namespace", "using", "template", "typename", "new",
                   "delete", "this", "auto", "inline", "extern", "bool", "include", "define", "string", "var",
                   "async", "await", "readonly", "sealed", "interface"],
        literals: ["true", "false", "NULL", "nullptr", "null", "nil", "YES", "NO"],
        builtins: ["printf", "malloc", "free", "std", "cout", "cin", "endl", "vector", "Console", "NSLog"],
        lineComments: ["//"], blockComment: ("/*", "*/"), decorators: true, declarations: ["class", "struct", "enum"])

    static let java = Language(
        keywords: ["public", "private", "protected", "class", "interface", "enum", "extends", "implements", "static",
                   "final", "void", "int", "long", "double", "float", "boolean", "char", "byte", "short", "new",
                   "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
                   "try", "catch", "finally", "throw", "throws", "import", "package", "this", "super", "fun", "val",
                   "var", "when", "object", "data", "sealed", "override", "suspend", "is", "in", "as", "abstract",
                   "record", "def", "lazy", "companion"],
        literals: ["true", "false", "null"],
        builtins: ["System", "String", "List", "Map", "println", "print", "listOf", "mapOf", "Integer"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], tripleQuotes: true, decorators: true,
        declarations: ["class", "interface", "enum", "fun", "record", "object"])

    static let ruby = Language(
        keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in",
                   "do", "return", "yield", "begin", "rescue", "ensure", "raise", "case", "when", "then", "require",
                   "attr_accessor", "attr_reader", "include", "extend", "self", "super", "and", "or", "not", "lambda"],
        literals: ["true", "false", "nil"],
        builtins: ["puts", "print", "p", "require_relative", "each", "map", "select"],
        lineComments: ["#"], decorators: false, declarations: ["def", "class", "module"])

    static let sql = Language(
        keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                   "delete", "create", "table", "drop", "alter", "add", "index", "on", "join", "left", "right",
                   "inner", "outer", "full", "group", "by", "order", "having", "limit", "offset", "as", "distinct",
                   "union", "all", "case", "when", "then", "else", "end", "primary", "key", "foreign", "references",
                   "default", "unique", "in", "is", "like", "between", "exists", "with", "returning", "desc", "asc"],
        literals: ["null", "true", "false"],
        builtins: ["count", "sum", "avg", "min", "max", "coalesce", "now", "lower", "upper", "integer", "text",
                   "varchar", "boolean", "timestamp", "serial", "bigint", "date", "json", "jsonb", "uuid"],
        lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""], caseInsensitive: true)

    static let yaml = Language(literals: ["true", "false", "null", "yes", "no", "on", "off"],
                               lineComments: ["#"], yamlKeys: true)

    static let css = Language(
        keywords: ["important", "media", "import", "keyframes", "from", "to", "supports"],
        literals: ["none", "auto", "inherit", "initial", "block", "flex", "grid", "absolute", "relative"],
        blockComment: ("/*", "*/"), jsonKeys: false)

    static let php = Language(
        keywords: ["function", "class", "public", "private", "protected", "static", "return", "if", "else", "elseif",
                   "foreach", "for", "while", "as", "new", "echo", "use", "namespace", "try", "catch", "throw",
                   "extends", "implements", "interface", "const", "fn", "match"],
        literals: ["true", "false", "null"],
        lineComments: ["//", "#"], blockComment: ("/*", "*/"), dollarVariables: true,
        declarations: ["function", "class", "interface"])

    static let lua = Language(
        keywords: ["function", "local", "return", "if", "then", "else", "elseif", "end", "for", "in", "do", "while",
                   "repeat", "until", "and", "or", "not", "break"],
        literals: ["true", "false", "nil"],
        builtins: ["print", "pairs", "ipairs", "require", "table", "string", "math"],
        lineComments: ["--"], declarations: ["function"])

    // MARK: Highlighting

    /// Very long blocks render plain to keep streaming smooth.
    static let maxHighlightedLength = 30_000

    static func highlight(_ code: String, language name: String?, size: CGFloat) -> AttributedString {
        let font = Font.system(size: size, design: .monospaced)
        guard let language = language(for: name), code.count <= maxHighlightedLength else {
            var plain = AttributedString(code)
            plain.font = font
            plain.foregroundColor = Palette.plain
            return plain
        }
        var result = AttributedString()
        for token in tokenize(code, language: language) {
            var piece = AttributedString(token.text)
            piece.font = token.kind == .comment ? font.italic() : font
            piece.foregroundColor = color(for: token.kind)
            result.append(piece)
        }
        return result
    }

    static func color(for kind: Kind) -> Color {
        switch kind {
        case .plain: return Palette.plain
        case .keyword: return Palette.keyword
        case .literal: return Palette.literal
        case .string: return Palette.string
        case .number: return Palette.number
        case .comment: return Palette.comment
        case .type: return Palette.type
        case .function: return Palette.function
        case .builtin: return Palette.builtin
        case .decorator: return Palette.decorator
        case .variable: return Palette.variable
        case .key: return Palette.key
        }
    }

    static func tokenize(_ code: String, language: Language) -> [Token] {
        let chars = Array(code)
        var tokens: [Token] = []
        var i = 0
        var pendingDeclaration = false

        func emit(_ text: String, _ kind: Kind) {
            if let last = tokens.last, last.kind == kind {
                tokens[tokens.count - 1].text += text
            } else {
                tokens.append(Token(text: text, kind: kind))
            }
        }
        func starts(_ s: String, at index: Int) -> Bool {
            let pattern = Array(s)
            guard index + pattern.count <= chars.count else { return false }
            return Array(chars[index..<(index + pattern.count)]) == pattern
        }
        func lineStartIndex(_ index: Int) -> Int {
            var j = index
            while j > 0, chars[j - 1] != "\n" { j -= 1 }
            return j
        }

        while i < chars.count {
            let c = chars[i]

            // Comments
            if let marker = language.lineComments.first(where: { starts($0, at: i) }),
               !(marker == "#" && language.dollarVariables && i > 0 && chars[i - 1] == "$") {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), .comment)
                i = j
                continue
            }
            if let block = language.blockComment, starts(block.open, at: i) {
                var j = i + block.open.count
                while j < chars.count, !starts(block.close, at: j) { j += 1 }
                j = min(chars.count, j + block.close.count)
                emit(String(chars[i..<j]), .comment)
                i = j
                continue
            }

            // Strings (including Python/Swift/Kotlin triple quotes)
            if language.quotes.contains(c) {
                let triple = language.tripleQuotes && (starts("\"\"\"", at: i) || starts("'''", at: i))
                let delimiter = triple ? String(repeating: c, count: 3) : String(c)
                var j = i + delimiter.count
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if starts(delimiter, at: j) { j += delimiter.count; break }
                    if !triple, c != "`", chars[j] == "\n" { break }
                    j += 1
                }
                j = min(j, chars.count)
                let text = String(chars[i..<j])
                var kind: Kind = .string
                if language.jsonKeys {
                    var k = j
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    if k < chars.count, chars[k] == ":" { kind = .key }
                }
                emit(text, kind)
                i = j
                continue
            }

            // Decorators / attributes (@decorator, @MainActor, #[derive])
            if language.decorators, c == "@", i + 1 < chars.count, chars[i + 1].isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
                emit(String(chars[i..<j]), .decorator)
                i = j
                continue
            }

            // Shell/PHP variables
            if language.dollarVariables, c == "$", i + 1 < chars.count {
                var j = i + 1
                if chars[j] == "{" {
                    while j < chars.count, chars[j] != "}" { j += 1 }
                    j = min(chars.count, j + 1)
                } else {
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                    if j == i + 1, j < chars.count, "?@#!*0123456789".contains(chars[j]) { j += 1 }
                }
                emit(String(chars[i..<j]), .variable)
                i = j
                continue
            }

            // Numbers
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber && (i == 0 || !isIdentifier(chars[i - 1]))) {
                if i > 0, isIdentifier(chars[i - 1]) {
                    emit(String(c), .plain)
                    i += 1
                    continue
                }
                var j = i
                while j < chars.count, chars[j].isHexDigit || "xXoObB._eE".contains(chars[j])
                    || ((chars[j] == "+" || chars[j] == "-") && j > i && "eE".contains(chars[j - 1])) {
                    j += 1
                }
                emit(String(chars[i..<j]), .number)
                i = j
                continue
            }

            // Identifiers
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, isIdentifier(chars[j]) || (language.yamlKeys && chars[j] == "-") { j += 1 }
                let word = String(chars[i..<j])
                let lookup = language.caseInsensitive ? word.lowercased() : word
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let nextChar: Character? = k < chars.count ? chars[k] : nil

                let kind: Kind
                if language.yamlKeys, nextChar == ":", chars[lineStartIndex(i)..<i].allSatisfy({ $0 == " " || $0 == "-" }) {
                    kind = .key
                } else if pendingDeclaration {
                    kind = word.first?.isUppercase == true ? .type : .function
                    pendingDeclaration = false
                } else if language.keywords.contains(lookup) {
                    kind = .keyword
                    pendingDeclaration = language.declarations.contains(lookup)
                } else if language.literals.contains(lookup) {
                    kind = .literal
                } else if language.builtins.contains(lookup) {
                    kind = .builtin
                } else if nextChar == "(" {
                    kind = .function
                } else if word.first?.isUppercase == true, word.count > 1, !language.caseInsensitive {
                    kind = .type
                } else {
                    kind = .plain
                }
                emit(word, kind)
                i = j
                continue
            }

            emit(String(c), .plain)
            i += 1
        }
        return tokens
    }

    private static func isIdentifier(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
