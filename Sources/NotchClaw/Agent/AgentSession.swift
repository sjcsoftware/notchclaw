import Foundation
import Observation

/// Conversation + run state for one OpenClaw session, driven by gateway events.
@MainActor
@Observable
final class AgentSession {
    nonisolated static let markdownInstruction =
        "<notchclaw-format>Reply in GitHub-flavored Markdown. Structure answers with short headings, "
        + "bullet or numbered lists, tables for comparisons, **bold** for key terms, and fenced code blocks "
        + "with a language tag for any code or commands. Keep it skimmable.</notchclaw-format>"

    internal(set) var items: [ChatItem] = []
    private(set) var activity: AgentActivity = .idle
    private(set) var attention: AttentionReason?
    private(set) var approvals: [PendingApproval] = []
    internal(set) var usage: UsageInfo?
    private(set) var models: [ModelOption] = []
    internal(set) var sessionSettings = SessionSettings()
    private(set) var toast: String?
    private(set) var historyLoaded = false

    @ObservationIgnored private let gateway: GatewayClient
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var activeRunId: String?
    @ObservationIgnored private var usageTimer: Timer?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var usageRetries = 0

    /// Lets the UI suppress attention while the user is already looking.
    @ObservationIgnored var isUserLooking: () -> Bool = { false }
    @ObservationIgnored var onAttention: ((AttentionReason) -> Void)?
    /// Fired when the agent starts producing (or finishes) visible reply text.
    @ObservationIgnored var onAssistantOutput: (() -> Void)?

    init(gateway: GatewayClient, settings: AppSettings) {
        self.gateway = gateway
        self.settings = settings
        gateway.onEvent = { [weak self] name, payload in self?.handleEvent(name, payload) }
        gateway.onConnected = { [weak self] in self?.didConnect() }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUsage() }
        }
    }

    var sessionKey: String { settings.resolvedSessionKey }
    var latestAssistantText: String? { items.last(where: { $0.role == .assistant })?.text }

    func clearAttention() { attention = nil }

    // MARK: Connection

    private func didConnect() {
        Task {
            _ = try? await gateway.request("sessions.messages.subscribe", ["key": .string(sessionKey)], timeout: 10)
        }
        loadHistory()
        refreshSessionSettings()
        loadModels()
        refreshUsage()
    }

    /// Called when the configured session key changes.
    func sessionChanged() {
        items.removeAll()
        activity = .idle
        activeRunId = nil
        historyLoaded = false
        sessionSettings = SessionSettings()
        guard gateway.state.isConnected else { return }
        didConnect()
    }

    func loadHistory() {
        Task {
            do {
                let result = try await gateway.request(
                    "chat.history", ["sessionKey": .string(sessionKey), "limit": 40], timeout: 20)
                applyHistory(result)
            } catch {
                Log.error("chat.history failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyHistory(_ result: JSON) {
        var restored: [ChatItem] = []
        for (index, message) in (result["messages"]?.array ?? []).enumerated() {
            let role = message["role"]?.string
            guard role == "user" || role == "assistant" else { continue }
            guard var text = MessageText.extract(message), !text.isEmpty else { continue }
            if role == "user" { text = MessageText.stripInstruction(text) }
            let id = message["id"]?.string ?? message["messageId"]?.string ?? "h\(index)"
            var item = ChatItem(id: id, role: role == "user" ? .user : .assistant, text: text)
            if let ts = message["timestamp"]?.double ?? message["ts"]?.double {
                item.date = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
            }
            restored.append(item)
        }
        // Keep a locally-sent message that history doesn't contain yet.
        let pendingLocal = items.filter { $0.isStreaming || ($0.role == .user && $0.runId != nil && activeRunId == $0.runId) }
        items = restored + pendingLocal.filter { local in !restored.contains { $0.text == local.text && $0.role == local.role } }
        if let run = result["inFlightRun"], let runId = run["runId"]?.text {
            activeRunId = runId
            let text = run["text"]?.string ?? ""
            upsertAssistant(runId: runId) { $0.text = text }
            activity = text.isEmpty ? .thinking(phase: nil) : .streaming
        }
        if let info = result["sessionInfo"] {
            sessionSettings.merge(row: info)
        }
        historyLoaded = true
    }

    // MARK: Sending

    func send(_ raw: String) {
        let text = raw.trimmed
        guard !text.isEmpty else { return }
        guard gateway.state.isConnected else {
            showToast("Not connected — message not sent")
            return
        }
        let localId = UUID().uuidString
        let idempotencyKey = UUID().uuidString.lowercased()
        items.append(ChatItem(id: localId, role: .user, text: text, runId: idempotencyKey))
        activity = .thinking(phase: nil)
        attention = nil

        let isCommand = text.hasPrefix("/")
        let message = (settings.injectMarkdownInstruction && !isCommand)
            ? Self.markdownInstruction + "\n\n" + text
            : text
        Task {
            do {
                let ack = try await gateway.request(
                    "chat.send",
                    [
                        "sessionKey": .string(sessionKey),
                        "message": .string(message),
                        "idempotencyKey": .string(idempotencyKey),
                    ],
                    timeout: 30)
                let runId = ack["runId"]?.text ?? idempotencyKey
                activeRunId = runId
                if let index = items.firstIndex(where: { $0.id == localId }) { items[index].runId = runId }
            } catch {
                activity = .idle
                appendError("Couldn't send: \(error.localizedDescription)")
            }
        }
    }

    func abort() {
        Task {
            var params: [String: JSON] = ["sessionKey": .string(sessionKey)]
            if let activeRunId { params["runId"] = .string(activeRunId) }
            do {
                _ = try await gateway.request("chat.abort", .object(params), timeout: 10)
            } catch {
                showToast("Couldn't stop: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Session settings

    func refreshSessionSettings() {
        Task {
            guard let result = try? await gateway.request("sessions.describe", ["key": .string(sessionKey)], timeout: 15)
            else { return }
            sessionSettings.merge(row: result["session"] ?? result["row"] ?? result)
        }
    }

    func loadModels() {
        Task {
            guard let result = try? await gateway.request("models.list", .object([:]), timeout: 25) else { return }
            models = (result["models"]?.array ?? []).compactMap { row in
                guard let id = row["id"]?.text, let provider = row["provider"]?.text else { return nil }
                let ref = id.contains("/") ? id : "\(provider)/\(id)"
                return ModelOption(id: ref, name: row["name"]?.text ?? id, provider: provider)
            }
        }
    }

    func setModel(_ ref: String?) {
        patchSession(["model": JSON(ref)], success: ref.map { "Model → \(Self.shortModelName($0))" } ?? "Model reset to default")
    }

    func setThinking(_ level: String?) {
        patchSession(["thinkingLevel": JSON(level)], success: "Effort → \(level ?? "default")")
    }

    private func patchSession(_ fields: [String: JSON], success: String) {
        var params = fields
        params["key"] = .string(sessionKey)
        Task {
            do {
                let result = try await gateway.request("sessions.patch", .object(params), timeout: 25)
                sessionSettings.merge(row: result["entry"] ?? result["session"] ?? result)
                for (key, value) in fields {
                    if key == "model" {
                        sessionSettings.model = value.text
                        if value.text != nil { sessionSettings.modelProvider = nil }
                    }
                    if key == "thinkingLevel" { sessionSettings.thinkingLevel = value.text }
                }
                refreshSessionSettings()
                showToast(success)
            } catch {
                showToast("Couldn't update: \(error.localizedDescription)")
            }
        }
    }

    func compact() {
        guard activity == .idle else {
            showToast("Wait for the current reply to finish")
            return
        }
        activity = .compacting
        Task {
            do {
                _ = try await gateway.request("sessions.compact", ["key": .string(sessionKey)], timeout: 180)
                showToast("Context compacted")
                refreshSessionSettings()
            } catch {
                showToast("Compaction failed: \(error.localizedDescription)")
            }
            if activity == .compacting { activity = .idle }
        }
    }

    func newSession() {
        Task {
            do {
                _ = try await gateway.request("sessions.reset", ["key": .string(sessionKey)], timeout: 30)
                items.removeAll()
                showToast("Started a fresh session")
                refreshSessionSettings()
            } catch {
                showToast("Reset failed: \(error.localizedDescription)")
            }
        }
    }

    func resolveApproval(_ approval: PendingApproval, decision: String) {
        approvals.removeAll { $0.id == approval.id }
        if approvals.isEmpty, attention == .needsInput { attention = nil }
        Task {
            do {
                _ = try await gateway.request(
                    "exec.approval.resolve", ["id": .string(approval.id), "decision": .string(decision)], timeout: 15)
            } catch {
                showToast("Approval failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Usage

    func refreshUsage() {
        guard gateway.state.isConnected else { return }
        Task {
            guard let result = try? await gateway.request("usage.status", .object([:]), timeout: 30) else { return }
            if result["refreshing"]?.bool == true, (result["providers"]?.array ?? []).isEmpty {
                // Cold cache: the gateway is fetching in the background. Poll briefly.
                guard usageRetries < 6 else { return }
                usageRetries += 1
                try? await Task.sleep(for: .seconds(2.5))
                refreshUsage()
                return
            }
            usageRetries = 0
            usage = Self.parseUsage(result)
        }
    }

    nonisolated static func parseUsage(_ result: JSON) -> UsageInfo? {
        let providers = result["providers"]?.array ?? []
        func isCodex(_ p: JSON) -> Bool {
            let id = (p["provider"]?.string ?? "").lowercased()
            let name = (p["displayName"]?.string ?? "").lowercased()
            return id.contains("codex") || id == "openai" || name.contains("codex") || name.contains("chatgpt")
        }
        guard let provider = providers.first(where: { isCodex($0) && !($0["windows"]?.array ?? []).isEmpty })
            ?? providers.first(where: isCodex)
        else { return nil }
        let windows: [UsageWindowInfo] = (provider["windows"]?.array ?? []).compactMap { w in
            guard let label = w["label"]?.text, let used = w["usedPercent"]?.double else { return nil }
            let reset = w["resetAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
            return UsageWindowInfo(label: label, usedPercent: used.clamped(to: 0...100), resetAt: reset)
        }
        return UsageInfo(
            providerName: provider["displayName"]?.text ?? "Codex",
            plan: provider["plan"]?.text,
            windows: windows,
            error: provider["error"]?.text)
    }

    // MARK: Events

    private func handleEvent(_ name: String, _ payload: JSON) {
        switch name {
        case "chat":
            handleChat(payload)
        case "exec.approval.requested", "plugin.approval.requested":
            handleApprovalRequested(payload)
        case "exec.approval.resolved", "plugin.approval.resolved":
            if let id = payload["id"]?.string ?? payload["approvalId"]?.string {
                approvals.removeAll { $0.id == id }
                if approvals.isEmpty, attention == .needsInput { attention = nil }
            }
        case "sessions.changed":
            if let row = payload["session"], Self.matches(row["key"]?.string, sessionKey) {
                sessionSettings.merge(row: row)
            }
        default:
            break
        }
    }

    nonisolated static func matches(_ incoming: String?, _ current: String) -> Bool {
        guard let incoming = incoming?.lowercased() else { return false }
        let current = current.lowercased()
        if incoming == current { return true }
        // "main" is the alias for the default agent's main session ("agent:<id>:main").
        let parts = incoming.split(separator: ":")
        if parts.count >= 3, parts[0] == "agent", parts.dropFirst(2).joined(separator: ":") == current { return true }
        let cparts = current.split(separator: ":")
        if cparts.count >= 3, cparts[0] == "agent", cparts.dropFirst(2).joined(separator: ":") == incoming { return true }
        return false
    }

    private func handleChat(_ p: JSON) {
        guard Self.matches(p["sessionKey"]?.string, sessionKey) else { return }
        guard let runId = p["runId"]?.text else { return }
        switch p["state"]?.string {
        case "status":
            if activity != .streaming {
                activity = .thinking(phase: Self.phaseText(p["phase"]?.string, retry: p["retry"]))
            }
        case "delta":
            activeRunId = runId
            let delta = p["deltaText"]?.string ?? ""
            let snapshot = p["message"].flatMap(MessageText.extract)
            let replace = p["replace"]?.bool == true
            upsertAssistant(runId: runId) { item in
                if let snapshot { item.text = snapshot }
                else if replace { item.text = delta }
                else { item.text += delta }
            }
            let wasStreaming = activity == .streaming
            activity = .streaming
            if !wasStreaming { onAssistantOutput?() }
        case "final":
            let finalText = p["message"].flatMap { $0["openclawDisplayContent"].flatMap(MessageText.extract) ?? MessageText.extract($0) }
            upsertAssistant(runId: runId) { item in
                if let finalText { item.text = finalText }
                item.isStreaming = false
            }
            removeEmptyAssistant(runId: runId)
            finishRun(runId)
            if items.last?.role == .assistant { onAssistantOutput?() }
            raiseAttention(.reply)
            refreshUsage()
            refreshSessionSettings()
        case "aborted":
            upsertAssistant(runId: runId) { $0.isStreaming = false }
            removeEmptyAssistant(runId: runId)
            finishRun(runId)
            showToast("Stopped")
        case "error":
            upsertAssistant(runId: runId) { $0.isStreaming = false }
            removeEmptyAssistant(runId: runId)
            finishRun(runId)
            appendError(p["errorMessage"]?.text ?? "The agent hit an error.")
            raiseAttention(.error)
        default:
            break
        }
    }

    private func finishRun(_ runId: String) {
        if activeRunId == nil || activeRunId == runId {
            activeRunId = nil
            activity = .idle
        }
    }

    private func upsertAssistant(runId: String, _ update: (inout ChatItem) -> Void) {
        if let index = items.lastIndex(where: { $0.role == .assistant && $0.runId == runId }) {
            update(&items[index])
        } else {
            var item = ChatItem(id: "run-\(runId)", role: .assistant, text: "", runId: runId, isStreaming: true)
            update(&item)
            items.append(item)
        }
    }

    private func removeEmptyAssistant(runId: String) {
        items.removeAll { $0.role == .assistant && $0.runId == runId && $0.text.trimmed.isEmpty }
    }

    private func handleApprovalRequested(_ p: JSON) {
        guard let id = p["id"]?.text ?? p["approvalId"]?.text else { return }
        let request = p["request"] ?? p
        let command = request["command"]?.text
            ?? request["commandText"]?.text
            ?? request["argv"]?.array?.compactMap(\.string).joined(separator: " ")
        let title = command ?? p["title"]?.text ?? request["title"]?.text ?? "The agent needs your approval"
        let detail = request["cwd"]?.text.map { "in \($0)" } ?? request["description"]?.text ?? p["description"]?.text
        let decisions = (p["allowedDecisions"]?.array ?? request["allowedDecisions"]?.array)?.compactMap(\.string)
        let expires = (p["expiresAtMs"]?.double ?? request["expiresAtMs"]?.double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let approval = PendingApproval(
            id: id, title: title, detail: detail,
            decisions: decisions?.isEmpty == false ? decisions! : ["allow-once", "allow-always", "deny"],
            expiresAt: expires)
        approvals.removeAll { $0.id == id }
        approvals.append(approval)
        raiseAttention(.needsInput)
    }

    private func raiseAttention(_ reason: AttentionReason) {
        guard settings.glowOnReply || reason == .needsInput else { return }
        if isUserLooking(), reason != .needsInput { return }
        attention = reason
        onAttention?(reason)
    }

    private func appendError(_ message: String) {
        items.append(ChatItem(id: UUID().uuidString, role: .error, text: message))
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    nonisolated static func phaseText(_ phase: String?, retry: JSON?) -> String? {
        if retry != nil { return "Rate limited — retrying" }
        switch phase {
        case "waiting_for_state": return "Waiting"
        case "preparing_workspace": return "Preparing workspace"
        case "naming_worktree", "creating_worktree": return "Creating worktree"
        case "running_setup": return "Running setup"
        case "provisioning_environment": return "Provisioning"
        case "preparing_context": return "Gathering context"
        case "memory_flushing": return "Saving memory"
        case "starting_model": return "Waking the model"
        default: return nil
        }
    }

    nonisolated static func shortModelName(_ ref: String) -> String {
        ref.split(separator: "/").last.map(String.init) ?? ref
    }
}

/// Extracts display text from gateway message objects (string or content blocks).
enum MessageText {
    static func extract(_ message: JSON) -> String? {
        if let s = message.string { return s }
        if let content = message["content"] {
            if let s = content.string { return s }
            if let blocks = content.array {
                let parts = blocks.compactMap { block -> String? in
                    if let s = block.string { return s }
                    let type = block["type"]?.string ?? "text"
                    guard type == "text" || type == "output_text" || type == "markdown" else { return nil }
                    return block["text"]?.string
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
            }
        }
        if let blocks = message.array {
            return extract(["content": .array(blocks)])
        }
        return message["text"]?.string
    }

    static func stripInstruction(_ text: String) -> String {
        guard let end = text.range(of: "</notchclaw-format>") else { return text }
        guard text.hasPrefix("<notchclaw-format>") else { return text }
        return String(text[end.upperBound...]).trimmed
    }
}
