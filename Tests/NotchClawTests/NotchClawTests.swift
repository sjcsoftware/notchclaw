import CryptoKit
import Foundation
import Testing
@testable import NotchClaw

struct MarkdownParserTests {
    @Test func testHeadingsParagraphsAndRules() {
        let blocks = MarkdownParser.parse("# Title\n\nSome **bold** text\nwraps here.\n\n---\n## Next")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\nwraps here."),
            .rule,
            .heading(level: 2, text: "Next"),
        ])
    }

    @Test func testFencedCodeKeepsContentAndToleratesMissingClose() {
        #expect(MarkdownParser.parse("```swift\nlet x = 1\n\nprint(x)\n```") == [.code(language: "swift", code: "let x = 1\n\nprint(x)")])
        // Streaming: fence not closed yet.
        #expect(MarkdownParser.parse("```\npartial") == [.code(language: nil, code: "partial")])
    }

    @Test func testListsWithNestingAndTasks() {
        let blocks = MarkdownParser.parse("- one\n- [x] done\n  - nested\n1. first\n2. second")
        guard case .list(false, _, let items) = blocks.first else { Issue.record("expected bullet list"); return }
        #expect(items.count == 2)
        #expect(items[1].checked == true)
        #expect(items[1].blocks.count == 2)
        guard case .list(true, 1, let ordered) = blocks.last else { Issue.record("expected ordered list"); return }
        #expect(ordered.count == 2)
    }

    @Test func testTablesAndAlignment() {
        let blocks = MarkdownParser.parse("| A | B |\n|:--|--:|\n| 1 | `a|b` |\n| 2 |")
        #expect(blocks == [.table(header: ["A", "B"], alignments: [.leading, .trailing], rows: [["1", "`a|b`"], ["2", ""]])])
    }

    @Test func testQuote() {
        #expect(MarkdownParser.parse("> quoted\n> more") == [.quote([.paragraph("quoted\nmore")])])
    }

    @Test func testDisplayMathBlocks() {
        #expect(MarkdownParser.parse("So:\n\\[\n\\frac{a}{b}\n\\]\nDone") == [
            .paragraph("So:"), .math("\\frac{a}{b}"), .paragraph("Done"),
        ])
        #expect(MarkdownParser.parse("$$x^2$$") == [.math("x^2")])
        #expect(MarkdownParser.parse("\\begin{align*}\na &= b\n\\end{align*}") == [.math("\\begin{align*}\na &= b\n\\end{align*}")])
        // Display math with text after it on the same line stays in the paragraph.
        #expect(MarkdownParser.parse("$$x$$ and more") == [.paragraph("$$x$$ and more")])
        // Streaming: not closed yet.
        #expect(MarkdownParser.parse("\\[\n\\sum_i") == [.math("\\sum_i")])
    }
}

struct MathTests {
    @Test func testSplitsInlineAndDisplayMath() {
        #expect(MathSyntax.split("**\\(d_u/2\\)가 아닌 이유**") == [.text("**"), .math("d_u/2", display: false), .text("가 아닌 이유**")])
        #expect(MathSyntax.split("Euler $e^{i\\pi}$ and \\[x\\]") == [
            .text("Euler "), .math("e^{i\\pi}", display: false), .text(" and "), .math("x", display: true),
        ])
        #expect(MathSyntax.split("a $$b$$ c") == [.text("a "), .math("b", display: true), .text(" c")])
    }

    @Test func testLeavesPricesCodeAndEscapesAlone() {
        #expect(MathSyntax.split("Costs $5 and $10 today") == [.text("Costs $5 and $10 today")])
        #expect(MathSyntax.split("Run `echo $HOME $PATH` now") == [.text("Run `echo $HOME $PATH` now")])
        #expect(MathSyntax.split("Literal \\$x\\$ and \\*") == [.text("Literal \\$x\\$ and \\*")])
        #expect(MathSyntax.split("no close \\( here") == [.text("no close \\( here")])
    }

    @Test func testParsesCommonConstructs() {
        #expect(MathParser.parse("\\frac{1}{2}") == [.fraction([.symbol("1", .ord)], [.symbol("2", .ord)], rule: true, style: nil)])
        #expect(MathParser.parse("x_i^2") == [.scripts(.symbol("𝑥", .ord), sub: [.symbol("𝑖", .ord)], sup: [.symbol("2", .ord)])])
        #expect(MathParser.parse("\\mathbb{R} \\le \\alpha") == [.symbol("ℝ", .ord), .symbol("≤", .rel), .symbol("𝛼", .ord)])
        #expect(MathParser.parse("\\sin x") == [.function("sin", limits: false), .symbol("𝑥", .ord)])
        #expect(MathParser.parse("\\text{a b}") == [.text("a b", bold: false, italic: false)])
        #expect(MathParser.parse("a \\\\ b").count == 1)  // rows become an array
    }

    @Test func testParserToleratesBrokenInput() {
        for latex in ["\\frac{a", "}}x{", "\\left( x", "x \\right)", "\\begin{pmatrix} 1 & 2", "^_", "\\", "\\unknown{x}", "\\sqrt["] {
            _ = MathParser.parse(latex)
        }
    }

    @MainActor @Test func testRendersWithBaseline() {
        let inline = MathRenderer.render("\\frac{a}{b}", size: 13, display: false)
        #expect(inline.image.size.width > 0)
        #expect(inline.descent > 0 && inline.ascent > inline.descent)
        let display = MathRenderer.render("\\sum_{i=1}^n i", size: 13, display: true)
        #expect(display.image.size.height > inline.image.size.height)
    }
}

struct VoiceCommandTests {
    @Test func testParsesControlPhrases() {
        #expect(VoiceCommand.parse("Set effort to high.") == .setEffort(level: "high"))
        #expect(VoiceCommand.parse("thinking max") == .setEffort(level: "xhigh"))
        #expect(VoiceCommand.parse("Compact the context") == .compact)
        #expect(VoiceCommand.parse("start a new session") == .newSession)
        #expect(VoiceCommand.parse("Stop") == .stop)
        #expect(VoiceCommand.parse("switch model to sonnet") == .setModel(query: "sonnet"))
    }

    @Test func testOrdinarySentencesAreMessages() {
        #expect(VoiceCommand.parse("What's the weather like in Seoul tomorrow?") == nil)
        #expect(VoiceCommand.parse("Can you compact this paragraph for my essay please and thanks") == nil)
    }

    @Test func testModelMatching() {
        let models = [
            ModelOption(id: "openai-codex/gpt-5.1-codex", name: "GPT-5.1 Codex", provider: "openai-codex"),
            ModelOption(id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5", provider: "anthropic"),
        ]
        #expect(VoiceCommand.matchModel("sonnet", in: models)?.provider == "anthropic")
        #expect(VoiceCommand.matchModel("gpt five point one codex", in: models)?.provider == "openai-codex")
    }
}

struct GatewayTests {
    @Test func testURLNormalization() {
        #expect(GatewayClient.normalizedURL("127.0.0.1:18789")?.absoluteString == "ws://127.0.0.1:18789")
        #expect(GatewayClient.normalizedURL("https://claw.example.com")?.absoluteString == "wss://claw.example.com")
        #expect(GatewayClient.normalizedURL(" ws://host:1/ ")?.absoluteString == "ws://host:1/")
        #expect(GatewayClient.normalizedURL("   ") == nil)
    }

    @Test func testDeviceSignatureVerifies() throws {
        let identity = DeviceIdentity.generate()
        let payload = DeviceAuthPayload.v2(
            deviceId: identity.deviceId, clientId: "openclaw-macos", clientMode: "ui", role: "operator",
            scopes: ["operator.read", "operator.write"], signedAtMs: 1_737_264_000_000, token: "t", nonce: "n")
        #expect(payload == "v2|\(identity.deviceId)|openclaw-macos|ui|operator|operator.read,operator.write|1737264000000|t|n")
        let signature = try #require(identity.sign(payload))
        var b64 = signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let publicKey = try #require(Data(base64Encoded: identity.publicKey))
        let signatureData = try #require(Data(base64Encoded: b64))
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        #expect(key.isValidSignature(signatureData, for: Data(payload.utf8)))
        #expect(identity.deviceId == DeviceIdentity.fingerprint(publicKey))
    }

    @Test func testJSONRoundTripKeepsIntegers() throws {
        let value: JSON = ["ts": .int(1_737_264_000_000), "ok": true, "list": ["a", 1.5]]
        let text = String(decoding: try value.encoded(), as: UTF8.self)
        #expect(text.contains("1737264000000"))
        #expect(try JSON.decode(Data(text.utf8)) == value)
    }
}

@MainActor
struct AgentSessionTests {
    @Test func testSessionKeyAliases() {
        #expect(AgentSession.matches("agent:main:main", "main"))
        #expect(AgentSession.matches("main", "agent:main:main"))
        #expect(AgentSession.matches("MAIN", "main"))
        #expect(!AgentSession.matches("agent:main:work", "main"))
    }

    @Test func testUsageParsingPicksCodexWindows() {
        let result: JSON = [
            "updatedAt": 1,
            "providers": [
                ["provider": "anthropic", "displayName": "Claude", "windows": [["label": "5h", "usedPercent": 10]]],
                ["provider": "openai", "displayName": "Codex", "plan": "plus", "windows": [
                    ["label": "5h", "usedPercent": 42.5, "resetAt": 1_700_000_000_000],
                    ["label": "Week", "usedPercent": 12],
                ]],
            ],
        ]
        let usage = AgentSession.parseUsage(result)
        #expect(usage?.providerName == "Codex")
        #expect(usage?.window(for: .fiveHour)?.usedPercent == 42.5)
        #expect(usage?.window(for: .weekly)?.usedPercent == 12)
        #expect(usage?.window(for: .daily) == nil)
        #expect(usage?.bestWindow(for: .daily)?.label == "5h")
    }

    @Test func testMessageTextExtraction() {
        let message: JSON = ["role": "assistant", "content": [["type": "text", "text": "Hello"], ["type": "image"], ["type": "text", "text": "World"]]]
        #expect(MessageText.extract(message) == "Hello\n\nWorld")
        #expect(MessageText.stripInstruction(AgentSession.markdownInstruction + "\n\nhi there") == "hi there")
    }
}

struct RichContentTests {
    @Test func testChartSpecParsesSeriesAndNumbers() throws {
        let spec = try #require(ChartSpec.parse("""
        {"type":"line","title":"Latency","x":"Day","y":"ms","data":[
          {"x":"Mon","y":412,"series":"p95"},{"x":"Tue","y":"398","series":"p95"},{"x":"Mon","y":180,"series":"p50"}]}
        """))
        #expect(spec.kind == .line)
        #expect(spec.title == "Latency")
        #expect(spec.points.count == 3)
        #expect(spec.points[1].y == 398)
        #expect(spec.hasSeries)
        #expect(!spec.numericX)
    }

    @Test func testChartSpecAcceptsAliasesAndRejectsGarbage() {
        let spec = ChartSpec.parse(#"{"kind":"pie","points":[{"label":"A","value":2},{"label":"B","value":3}]}"#)
        #expect(spec?.kind == .pie)
        #expect(spec?.points.map(\.x) == ["A", "B"])
        #expect(ChartSpec.parse("{\"type\":\"bar\",\"data\":[") == nil)
        #expect(ChartSpec.parse("not json") == nil)
    }

    @Test func testImageBlocksFromArtifactsAndInlineData() {
        let message: JSON = ["role": "assistant", "content": [
            ["type": "text", "text": "Here you go"],
            ["type": "image", "artifactId": "art_1", "mimeType": "image/png", "alt": "A robot", "width": 1024, "height": 768],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]],
            ["type": "image"],
        ]]
        let images = MessageText.images(message)
        #expect(images.count == 2)
        #expect(images[0].artifactId == "art_1")
        #expect(images[0].alt == "A robot")
        #expect(images[0].aspectRatio == 1024.0 / 768.0)
        #expect(images[1].inlineBase64 == "iVBORw0KGgo=")
        #expect(MessageText.extract(message) == "Here you go")
    }
}

struct MediaURLTests {
    @Test func testMediaTicketResolvesAgainstGatewayOrigin() {
        let gateway = URL(string: "wss://pi5.example.ts.net/control")!
        let resolved = GatewayClient.httpURL(gateway: gateway, path: "/api/chat/media/outgoing/agent%3Amain%3Amain/abc/full?mediaTicket=v1.x")
        #expect(resolved?.absoluteString == "https://pi5.example.ts.net/api/chat/media/outgoing/agent%3Amain%3Amain/abc/full?mediaTicket=v1.x")
        let local = GatewayClient.httpURL(gateway: URL(string: "ws://127.0.0.1:18789")!, path: "/api/x?t=1")
        #expect(local?.absoluteString == "http://127.0.0.1:18789/api/x?t=1")
        #expect(GatewayClient.httpURL(gateway: gateway, path: "https://cdn.example.com/a.png")?.host == "cdn.example.com")
    }
}

@MainActor
struct NotchSizeTests {
    @Test func testMinimizedSizeMatchesHardwareAndAppliesFineTuning() {
        let notch = NotchViewModel()
        notch.geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 185, notchHeight: 32, hasNotch: true)
        // Visible body = hardware notch; the concave top ears add the corner radius on each side.
        #expect(notch.closedSize == CGSize(width: 185 + NotchLayout.closedCorners.top * 2, height: 32))
        notch.sizeAdjust = CGSize(width: 10, height: -4)
        #expect(notch.closedSize == CGSize(width: 195 + NotchLayout.closedCorners.top * 2, height: 28))
        notch.sizeAdjust = CGSize(width: -1000, height: -1000)
        #expect(notch.closedSize.width >= 40 && notch.closedSize.height >= 8)
    }
}

struct SyntaxHighlighterTests {
    private func kinds(_ code: String, _ lang: String) -> [(String, SyntaxHighlighter.Kind)] {
        SyntaxHighlighter.tokenize(code, language: SyntaxHighlighter.language(for: lang)!)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ($0.text.trimmingCharacters(in: .whitespaces), $0.kind) }
    }

    @Test func testPythonFunction() {
        let tokens = kinds("def inverse(root):\n    if root is None:\n        return None  # done\n    s = \"x\"\n", "python")
        func kind(of word: String) -> SyntaxHighlighter.Kind? { tokens.first { $0.0 == word }?.1 }
        #expect(kind(of: "def") == .keyword)
        #expect(kind(of: "inverse") == .function)
        #expect(kind(of: "None") == .literal)
        #expect(tokens.contains { $0.0 == "# done" && $0.1 == .comment })
        #expect(tokens.contains { $0.0 == "\"x\"" && $0.1 == .string })
    }

    @Test func testTripleQuotesSwiftTypesAndNumbers() {
        let py = kinds("x = \"\"\"multi\nline\"\"\"\n", "py")
        #expect(py.contains { $0.0.hasPrefix("\"\"\"multi") && $0.1 == .string })
        let swift = kinds("let n: Int = 42 // answer\n@MainActor func go() {}", "swift")
        #expect(swift.contains { $0.0 == "Int" && $0.1 == .type })
        #expect(swift.contains { $0.0 == "42" && $0.1 == .number })
        #expect(swift.contains { $0.0 == "@MainActor" && $0.1 == .decorator })
        #expect(swift.contains { $0.0 == "go" && $0.1 == .function })
    }

    @Test func testJSONKeysShellVariablesAndUnknownLanguages() {
        let json = kinds("{\"name\": \"claw\", \"n\": 1}", "json")
        #expect(json.contains { $0.0 == "\"name\"" && $0.1 == .key })
        #expect(json.contains { $0.0 == "\"claw\"" && $0.1 == .string })
        let sh = kinds("echo $HOME # where", "bash")
        #expect(sh.contains { $0.0 == "$HOME" && $0.1 == .variable })
        #expect(sh.contains { $0.0 == "# where" && $0.1 == .comment })
        #expect(SyntaxHighlighter.language(for: "brainfuck") == nil)
        #expect(SyntaxHighlighter.language(for: nil) == nil)
    }
}

struct AdminScopeTests {
    @Test func testDetectsMissingAdminScopeErrors() {
        let structured = GatewayError(frame: ["code": "FORBIDDEN", "message": "missing scope: operator.admin",
                                              "details": ["code": "MISSING_SCOPE", "missingScope": "operator.admin"]])
        #expect(AgentSession.isMissingAdmin(structured))
        let legacy = GatewayError(code: "INVALID_REQUEST", message: "Reset failed: missing scope: operator.admin")
        #expect(AgentSession.isMissingAdmin(legacy))
        #expect(!AgentSession.isMissingAdmin(GatewayError(code: "FORBIDDEN", message: "missing scope: operator.pairing")))
        #expect(!AgentSession.isMissingAdmin(GatewayError.notConnected))
    }
}

struct SessionPickerTests {
    @Test func testSessionTitlesAndBackgroundFiltering() {
        #expect(SessionSummary.title(forKey: "agent:main:main") == "Main")
        #expect(SessionSummary.title(forKey: "main") == "Main")
        #expect(SessionSummary.title(forKey: "agent:main:s-abc") == "s-abc")
        #expect(SessionSummary.title(for: ["key": "agent:main:x", "derivedTitle": "Trip planning"]) == "Trip planning")
        #expect(SessionSummary.title(for: ["key": "agent:main:x", "label": "Work", "derivedTitle": "Ignored"]) == "Work")
        #expect(AgentSession.isBackgroundSession(["key": "agent:main:subagent:123"]))
        #expect(AgentSession.isBackgroundSession(["key": "agent:main:x", "spawnedBy": "agent:main:main"]))
        #expect(!AgentSession.isBackgroundSession(["key": "agent:main:main"]))
    }
}
