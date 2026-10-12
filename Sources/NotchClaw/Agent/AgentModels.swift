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
