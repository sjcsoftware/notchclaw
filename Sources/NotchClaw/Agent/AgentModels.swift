import Foundation

struct ChatItem: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, notice, error }

    var id: String
    var role: Role
    var text: String
    var date: Date = Date()
    var runId: String?
    var isStreaming = false
    var images: [ImageAttachment] = []
}

/// An image the agent produced (e.g. via `image_generate`), referenced by artifact id or inlined.
struct ImageAttachment: Identifiable, Equatable, Hashable {
    var id: String
    var artifactId: String?
    var inlineBase64: String?
    var mimeType: String?
    var alt: String?
    var width: Double?
    var height: Double?

    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width / height
    }
}

enum AgentActivity: Equatable {
    case idle
    case thinking(phase: String?)
    case streaming
    case compacting

    var isBusy: Bool { self != .idle }
}

enum AttentionReason: Equatable {
    case reply
    case needsInput
    case error
}

struct PendingApproval: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String?
    var decisions: [String]
    var expiresAt: Date?
}

struct UsageWindowInfo: Equatable, Identifiable {
    var label: String
    var usedPercent: Double
    var resetAt: Date?
    var id: String { label }

    /// Which user-facing bucket this window represents.
    var choice: UsageWindowChoice? {
        let l = label.lowercased()
        if l.contains("week") || l == "7d" { return .weekly }
        if l.contains("day") || l == "24h" || l == "1d" { return .daily }
        if l.hasSuffix("h"), let hours = Int(l.dropLast()), hours < 24 { return .fiveHour }
        return nil
    }
}

struct UsageInfo: Equatable {
    var providerName: String
    var plan: String?
    var windows: [UsageWindowInfo]
    var error: String?

    func window(for choice: UsageWindowChoice) -> UsageWindowInfo? {
        windows.first { $0.choice == choice }
    }

    /// The preferred window, falling back to whatever the provider reports.
    func bestWindow(for choice: UsageWindowChoice) -> UsageWindowInfo? {
        window(for: choice) ?? windows.first
    }
}

struct ModelOption: Identifiable, Hashable {
    var id: String  // "provider/model"
    var name: String
    var provider: String
}

/// Snapshot of the session's effective settings as reported by the gateway.
struct SessionSettings: Equatable {
    var model: String?
    var modelProvider: String?
    var thinkingLevel: String?
    var thinkingOptions: [String] = SessionSettings.defaultThinkingOptions
    var totalTokens: Double?
    var contextTokens: Double?

    static let defaultThinkingOptions = ["off", "minimal", "low", "medium", "high", "xhigh"]

    var modelRef: String? {
        guard let model else { return nil }
        if model.contains("/") { return model }
        return modelProvider.map { "\($0)/\(model)" } ?? model
    }

    var contextFraction: Double? {
        guard let total = totalTokens, let ctx = contextTokens, ctx > 0 else { return nil }
        return (total / ctx).clamped(to: 0...1)
    }

    mutating func merge(row: JSON) {
        if let m = row["model"]?.text { model = m }
        if let p = row["modelProvider"]?.text { modelProvider = p }
        if let t = row["thinkingLevel"] {
            thinkingLevel = t.text
        }
        if let opts = row["thinkingOptions"]?.array?.compactMap(\.text), !opts.isEmpty {
            thinkingOptions = opts
        }
        if let v = row["totalTokens"]?.double { totalTokens = v }
        if let v = row["contextTokens"]?.double { contextTokens = v }
    }
}

/// A session row for the session picker.
struct SessionSummary: Identifiable, Equatable {
    var key: String
    var title: String
    var updatedAt: Date?
    var id: String { key }

    nonisolated static func title(for row: JSON) -> String {
        if let explicit = row["label"]?.text ?? row["displayName"]?.text ?? row["derivedTitle"]?.text ?? row["autoLabel"]?.text {
            return explicit
        }
        return title(forKey: row["key"]?.string ?? "")
    }

    /// "agent:main:main" → "Main"; "agent:main:abc123" → "abc123".
    nonisolated static func title(forKey key: String) -> String {
        let last = key.split(separator: ":").last.map(String.init) ?? key
        if last.lowercased() == "main" || key.lowercased() == "main" { return "Main" }
        return last.isEmpty ? "Session" : last
    }
}

/// Live view of what the agent is doing during a run: tool steps, its latest
/// commentary ("I'll check the logs first…"), and any plan it published.
struct RunProgress: Equatable {
    struct Step: Identifiable, Equatable {
        var id: String
        var title: String
        var isActive: Bool
        var isError = false
    }

    struct PlanItem: Equatable {
        var text: String
        var status: String  // pending | in_progress | completed
    }

    var startedAt: Date?
    var steps: [Step] = []
    var note: String?
    var plan: [PlanItem] = []
    /// Coarse startup phase from `chat` status events ("Waking the model").
    var phase: String?

    var activeStep: Step? { steps.last { $0.isActive } }
    var completedCount: Int { steps.filter { !$0.isActive }.count }
    var isEmpty: Bool { steps.isEmpty && note == nil && plan.isEmpty }

    /// One line for headers and bubbles: what's happening right now.
    var headline: String? {
        if let active = activeStep { return active.title }
        if let current = plan.first(where: { $0.status == "in_progress" }) { return current.text }
        if let note { return note }
        if let last = steps.last { return "Done: \(last.title)" }
        return phase
    }

    mutating func upsert(id: String, title: String?, active: Bool, error: Bool = false) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            if let title, !title.isEmpty { steps[index].title = title }
            steps[index].isActive = active
            steps[index].isError = steps[index].isError || error
        } else if let title, !title.isEmpty {
            steps.append(Step(id: id, title: title, isActive: active, isError: error))
        }
        if steps.count > 30 { steps.removeFirst(steps.count - 30) }
    }

    mutating func finishAll() {
        for index in steps.indices { steps[index].isActive = false }
    }
}

enum ToolTitles {
    /// Fallback labels when the gateway sends a raw tool name without a title.
    nonisolated static func title(name: String, args: JSON?) -> String {
        let lower = name.lowercased()
        func arg(_ keys: String...) -> String? {
            for key in keys { if let v = args?[key]?.text { return v } }
            return nil
        }
        func clip(_ s: String, _ n: Int = 48) -> String {
            let line = s.split(separator: "\n").first.map(String.init) ?? s
            return line.count > n ? String(line.prefix(n - 1)) + "…" : line
        }
        if lower.contains("exec") || lower == "bash" || lower.contains("shell") || lower.contains("command") {
            return arg("command", "cmd", "input").map { "Running `\(clip($0))`" } ?? "Running a command"
        }
        if lower.contains("search") { return arg("query", "q").map { "Searching “\(clip($0, 40))”" } ?? "Searching the web" }
        if lower.contains("fetch") || lower.contains("browse") || lower.contains("web") {
            return arg("url").map { "Reading \(clip($0, 44))" } ?? "Browsing"
        }
        if lower.contains("read") { return arg("path", "file").map { "Reading \(clip($0, 44))" } ?? "Reading files" }
        if lower.contains("write") || lower.contains("edit") || lower.contains("patch") {
            return arg("path", "file").map { "Editing \(clip($0, 44))" } ?? "Editing files"
        }
        if lower.contains("image") { return "Generating an image" }
        if lower.contains("memory") { return "Checking memory" }
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        return "Using " + words
    }
}
