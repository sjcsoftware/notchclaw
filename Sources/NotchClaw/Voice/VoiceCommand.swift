import Foundation

/// Spoken control phrases that adjust the session instead of being sent to the agent.
enum VoiceCommand: Equatable {
    case setModel(query: String)
    case setEffort(level: String)
    case compact
    case newSession
    case stop

    static func parse(_ transcript: String) -> VoiceCommand? {
        let text = transcript.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: "  ", with: " ")
        guard !text.isEmpty, text.split(separator: " ").count <= 9 else { return nil }

        if ["stop", "cancel", "stop it", "stop generating", "abort"].contains(text) { return .stop }
        if text.range(of: #"^(please )?(compact|compress|summarize)( the| my)?( context| session| conversation| history)?( now)?$"#,
                      options: .regularExpression) != nil {
            return .compact
        }
        if text.range(of: #"^(please )?(start a |start |begin a |begin |open a )?(new|fresh) (session|conversation|chat)$"#,
                      options: .regularExpression) != nil
            || ["reset session", "reset the session", "start over", "clear session", "clear the session"].contains(text) {
            return .newSession
        }
        if let level = effortLevel(in: text) { return .setEffort(level: level) }
        if let match = text.firstMatch(of: #/^(?:please )?(?:set|switch|change|use)(?: the)? model(?: to)? (.+)$/#) {
            return .setModel(query: String(match.1))
        }
        if let match = text.firstMatch(of: #/^(?:please )?(?:switch|change) to (?:model )?(.+)$/#) {
            return .setModel(query: String(match.1))
        }
        if let match = text.firstMatch(of: #/^(?:please )?use (.+?) model$/#) {
            return .setModel(query: String(match.1))
        }
        return nil
    }

    private static func effortLevel(in text: String) -> String? {
        guard let match = text.firstMatch(
            of: #/^(?:please )?(?:set |change |switch )?(?:the )?(?:effort|thinking|reasoning)(?: level)?(?: to)? (.+)$/#)
        else { return nil }
        return normalizeEffort(String(match.1))
    }

    static func normalizeEffort(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        switch s {
        case "off", "none", "zero", "no": return "off"
        case "minimal", "minimum", "min": return "minimal"
        case "low", "light": return "low"
        case "medium", "normal", "mid", "default level": return "medium"
        case "high", "hard": return "high"
        case "max", "maximum", "extra high", "x high", "xhigh", "very high", "ultra": return "xhigh"
        default: return nil
        }
    }

    /// Picks the closest model for a spoken name like "gpt five codex" or "sonnet".
    static func matchModel(_ query: String, in models: [ModelOption]) -> ModelOption? {
        let q = normalize(spokenNumbers(query))
        guard !q.isEmpty else { return nil }
        var best: (ModelOption, Int)?
        for model in models {
            let candidates = [normalize(model.id), normalize(model.name), normalize(AgentSession.shortModelName(model.id))]
            var score = 0
            for c in candidates {
                if c == q { score = max(score, 100) }
                else if c.hasSuffix(q) || c.hasPrefix(q) { score = max(score, 80 - abs(c.count - q.count)) }
                else if c.contains(q) { score = max(score, 60 - abs(c.count - q.count)) }
            }
            if score > 0, score > (best?.1 ?? 0) { best = (model, score) }
        }
        return best?.0
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func spokenNumbers(_ s: String) -> String {
        let words = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                     "six": "6", "seven": "7", "eight": "8", "nine": "9", "point": ".", "dot": "."]
        return s.split(separator: " ").map { words[String($0)] ?? String($0) }.joined(separator: " ")
    }
}
