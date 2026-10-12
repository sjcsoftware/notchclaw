import AppKit
import Foundation
import Observation

/// Conversation + run state for one OpenClaw session, driven by gateway events.
@MainActor
@Observable
final class AgentSession {
    nonisolated static let markdownInstruction =
        "<notchclaw-format>Reply in GitHub-flavored Markdown: short headings, lists, tables for comparisons, "
        + "**bold** key terms, and fenced code blocks with a language tag. When numbers are easier to grasp visually, "
        + "add a chart as a fenced ```chart block containing JSON like "
        + "{\"type\":\"bar|line|area|point|pie\",\"title\":\"…\",\"x\":\"axis label\",\"y\":\"axis label\","
        + "\"data\":[{\"x\":\"Mon\",\"y\":3,\"series\":\"optional\"}]}. When a picture is requested or would "
        + "clearly help, use your image generation tool. Keep it skimmable.</notchclaw-format>"

    var items: [ChatItem] = []
    var activity: AgentActivity = .idle
    var attention: AttentionReason?
    private(set) var approvals: [PendingApproval] = []
    var usage: UsageInfo?
    private(set) var models: [ModelOption] = []
    var sessionSettings = SessionSettings()
    private(set) var toast: String?
    private(set) var historyLoaded = false
    /// Decoded agent images keyed by attachment id.
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var imageLoads: Set<String> = []

    @ObservationIgnored private let gateway: GatewayClient
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var activeRunId: String?
    /// Runs whose terminal event was already handled (terminal events can be re-delivered).
    @ObservationIgnored private var finalizedRuns: Set<String> = []
    /// What the user last had on screen per run, to tell genuinely new replies from repeats.
    @ObservationIgnored private var seenContent: [String: String] = [:]
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var usageTimer: Timer?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var usageRetries = 0

    /// Lets the UI suppress attention while the user is already looking.
    @ObservationIgnored var isUserLooking: () -> Bool = { false }
    @ObservationIgnored var onAttention: ((AttentionReason) -> Void)?
    /// What the agent is doing in the current run (tools, commentary, plan).
    private(set) var progress = RunProgress()
    /// Recent sessions for the picker (newest first).
    private(set) var sessions: [SessionSummary] = []
    @ObservationIgnored private var sessionsReload: Task<Void, Never>?
    /// Switches the app to another session key (owned by AppModel, which persists the choice).
    @ObservationIgnored var onSwitchSession: ((String) -> Void)?
    /// Asked when an action needs `operator.admin` that this device doesn't have.
    @ObservationIgnored var onNeedsAdmin: (() -> Void)?
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

    /// Called when the user opens the notch: everything on screen now counts as seen.
    func clearAttention() {
        attention = nil
        for item in items where item.role == .assistant {
            if let runId = item.runId { seenContent[runId] = Self.fingerprint(item) }
        }
    }

    private func markSeen(runId: String) {
        guard let item = items.last(where: { $0.role == .assistant && $0.runId == runId }) else { return }
        seenContent[runId] = Self.fingerprint(item)
    }

    /// True when the reply has text or images the user hasn't had on screen yet.
    private func hasUnseenContent(runId: String) -> Bool {
        guard let item = items.last(where: { $0.role == .assistant && $0.runId == runId }) else { return false }
        return seenContent[runId] != Self.fingerprint(item)
    }

    private func rememberFinal(_ runId: String) {
        finalizedRuns.insert(runId)
        if finalizedRuns.count > 500 { finalizedRuns.removeAll(keepingCapacity: true); finalizedRuns.insert(runId) }
    }

    nonisolated static func fingerprint(_ item: ChatItem) -> String {
        item.text.trimmed + "|" + item.images.map(\.id).joined(separator: ",")
    }

    // MARK: Connection

    private func didConnect() {
        Task {
            _ = try? await gateway.request("sessions.messages.subscribe", ["key": .string(sessionKey)], timeout: 10)
        }
        loadHistory()
        refreshSessionSettings()
        loadModels()
        refreshUsage()
        loadSessions()
    }

    /// Called when the configured session key changes.
    func sessionChanged(from previousKey: String? = nil) {
        if let previousKey, gateway.state.isConnected {
            Task { _ = try? await gateway.request("sessions.messages.unsubscribe", ["key": .string(previousKey)], timeout: 10) }
        }
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
            var text = MessageText.extract(message) ?? ""
            let attachments = role == "assistant" ? MessageText.images(message) : []
            guard !text.isEmpty || !attachments.isEmpty else { continue }
            if role == "user" { text = MessageText.stripInstruction(text) }
            let meta = message["__openclaw"]
            let id = meta?["id"]?.string ?? message["id"]?.string ?? message["messageId"]?.string ?? "h\(index)"
            var item = ChatItem(id: id, role: role == "user" ? .user : .assistant, text: text, images: attachments)
            item.runId = meta?["runId"]?.string
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
        progress = RunProgress(startedAt: Date())
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
        guard requireAdmin(for: "Compact") else { return }
        activity = .compacting
        Task {
            do {
                _ = try await gateway.request("sessions.compact", ["key": .string(sessionKey)], timeout: 180)
                showToast("Context compacted")
                refreshSessionSettings()
            } catch {
                if Self.isMissingAdmin(error) { adminMissing("Compact") } else {
                    showToast("Compaction failed: \(error.localizedDescription)")
                }
            }
            if activity == .compacting { activity = .idle }
        }
    }

    // MARK: Sessions

    var currentSessionTitle: String {
        sessions.first { Self.matches($0.key, sessionKey) }?.title ?? SessionSummary.title(forKey: sessionKey)
    }

    func loadSessions() {
        guard gateway.state.isConnected else { return }
        Task {
            guard let result = try? await gateway.request(
                "sessions.list",
                // Only long-standing params, so older gateways accept the request too.
                ["limit": 25, "sortBy": "updatedAt"],
                timeout: 20)
            else { return }
            sessions = Array((result["sessions"]?.array ?? []).compactMap { row -> SessionSummary? in
                guard let key = row["key"]?.text, row["archived"]?.bool != true, !Self.isBackgroundSession(row) else {
                    return nil
                }
                let updated = row["updatedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
                return SessionSummary(key: key, title: SessionSummary.title(for: row), updatedAt: updated)
            }.prefix(15))
        }
    }

    /// Sub-agent, cron, and other spawned sessions aren't conversations to pick from.
    nonisolated static func isBackgroundSession(_ row: JSON) -> Bool {
        let key = (row["key"]?.string ?? "").lowercased()
        if key.contains(":subagent:") || key.contains(":cron:") || key.hasPrefix("cron:") { return true }
        return row["spawnedBy"]?.text != nil || row["parentSessionKey"]?.text != nil
    }

    /// Starts a brand-new session (no admin needed) and switches to it.
    func createSession() {
        guard gateway.state.isConnected else {
            showToast("Not connected")
            return
        }
        Task {
            do {
                let result = try await gateway.request(
                    "sessions.create", ["idempotencyKey": .string(UUID().uuidString.lowercased())], timeout: 30)
                guard let key = result["key"]?.text ?? result["entry"]?["key"]?.text else {
                    showToast("The gateway didn't return a session")
                    return
                }
                onSwitchSession?(key)
                showToast("Started a new session")
                loadSessions()
            } catch {
                showToast("Couldn't start a session: \(error.localizedDescription)")
            }
        }
    }

    func switchSession(to key: String) {
        guard !Self.matches(key, sessionKey) else { return }
        onSwitchSession?(key)
    }

    /// Clears the current session in place (requires admin).
    func resetSession() {
        guard requireAdmin(for: "Reset session") else { return }
        Task {
            do {
                _ = try await gateway.request("sessions.reset", ["key": .string(sessionKey)], timeout: 30)
                items.removeAll()
                showToast("Session cleared")
                refreshSessionSettings()
            } catch {
                if Self.isMissingAdmin(error) { adminMissing("Reset session") } else {
                    showToast("Reset failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// OpenClaw only lets admin devices reset or compact a session.
    private func requireAdmin(for action: String) -> Bool {
        guard gateway.state.isConnected, !gateway.hasAdmin else { return true }
        adminMissing(action)
        return false
    }

    private func adminMissing(_ action: String) {
        if case .pending = gateway.adminAccess {
            showToast("\(action) needs admin access — approve it on your gateway")
        } else {
            showToast("\(action) needs admin access — see Settings › Gateway")
        }
        onNeedsAdmin?()
    }

    nonisolated static func isMissingAdmin(_ error: Error) -> Bool {
        guard let error = error as? GatewayError else { return false }
        if error.details?["missingScope"]?.string == GatewayClient.adminScope { return true }
        return error.code == "FORBIDDEN" && error.message.contains("operator.admin")
            || error.message.localizedCaseInsensitiveContains("missing scope: operator.admin")
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
        case "agent":
            handleAgent(payload)
        case "session.message":
            // A message was committed to the transcript; generated images arrive this way.
            let key = payload["sessionKey"]?.string ?? payload["key"]?.string ?? payload["session"]?["key"]?.string
            guard Self.matches(key, sessionKey), let message = payload["message"],
                  message["role"]?.string == "assistant"
            else { return }
            attachImages(from: message)
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
            sessionsReload?.cancel()
            sessionsReload = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                loadSessions()
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
            if activeRunId == nil { activeRunId = runId }
            if progress.startedAt == nil { progress.startedAt = Date() }
            progress.phase = Self.phaseText(p["phase"]?.string, retry: p["retry"])
            if activity != .streaming {
                activity = .thinking(phase: progress.headline)
            }
        case "delta":
            activeRunId = runId
            let delta = p["deltaText"]?.string ?? ""
            let snapshot = p["message"].flatMap(MessageText.extract)
            let snapshotImages = p["message"].map(MessageText.images) ?? []
            let replace = p["replace"]?.bool == true
            upsertAssistant(runId: runId) { item in
                // A supplied snapshot already includes deltaText; never append it twice.
                if let snapshot { item.text = snapshot }
                else if replace { item.text = delta }
                else { item.text += delta }
                if !snapshotImages.isEmpty { item.images = Self.uniqueImages(item.images + snapshotImages) }
            }
            if isUserLooking() { markSeen(runId: runId) }
            let wasStreaming = activity == .streaming
            activity = .streaming
            if !wasStreaming { onAssistantOutput?() }
        case "final":
            let alreadyFinal = finalizedRuns.contains(runId)
            rememberFinal(runId)
            let hadItem = items.contains { $0.role == .assistant && $0.runId == runId }
            let finalText = p["message"].flatMap { $0["openclawDisplayContent"].flatMap(MessageText.extract) ?? MessageText.extract($0) }
            let finalImages = p["message"].map { MessageText.images($0["openclawDisplayContent"] ?? .null) + MessageText.images($0) } ?? []
            // A second commit of the latest reply under another run id (e.g. a mirrored
            // transcript write) is not a new message: don't duplicate it or glow.
            if !hadItem, finalImages.isEmpty, let finalText,
               let latest = items.last(where: { $0.role == .assistant }), latest.text.trimmed == finalText.trimmed {
                Log.info("Ignoring duplicate final for run \(runId)")
                finishRun(runId)
                return
            }
            upsertAssistant(runId: runId) { item in
                if let finalText { item.text = finalText }
                if !finalImages.isEmpty { item.images = Self.uniqueImages(finalImages) }
                item.isStreaming = false
            }
            removeEmptyAssistant(runId: runId)
            finishRun(runId)
            let visible = items.contains { $0.role == .assistant && $0.runId == runId }
            if visible, !alreadyFinal {
                onAssistantOutput?()
                if isUserLooking() {
                    markSeen(runId: runId)
                } else if hasUnseenContent(runId: runId) {
                    raiseAttention(.reply, runId: runId)
                } else {
                    Log.info("Final for run \(runId) adds nothing unseen; no glow")
                }
            } else {
                Log.info("No glow for run \(runId): \(alreadyFinal ? "repeat final" : "silent run")")
            }
            reconcileAttachments()
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
            guard !finalizedRuns.contains(runId) else { return }
            rememberFinal(runId)
            appendError(p["errorMessage"]?.text ?? "The agent hit an error.")
            raiseAttention(.error, runId: runId)
        default:
            break
        }
    }

    private func finishRun(_ runId: String) {
        if activeRunId == nil || activeRunId == runId {
            activeRunId = nil
            activity = .idle
            progress = RunProgress()
        }
    }

    // MARK: Live progress

    /// `agent` events: tool calls, activity items, commentary, plans, and lifecycle.
    private func handleAgent(_ p: JSON) {
        if let key = p["sessionKey"]?.string {
            guard Self.matches(key, sessionKey) else { return }
        } else {
            // Unscoped events: only follow the run this session is showing.
            guard let runId = p["runId"]?.string, runId == activeRunId else { return }
        }
        guard let runId = p["runId"]?.text else { return }
        let data = p["data"] ?? .null
        let phase = data["phase"]?.string

        switch p["stream"]?.string {
        case "lifecycle":
            if phase == "start" {
                if activeRunId != runId { progress = RunProgress(startedAt: Date()) }
                activeRunId = runId
                if activity == .idle { activity = .thinking(phase: nil) }
            } else if phase == "end" || phase == "error" {
                progress.finishAll()
            }
            return
        case "item":
            if data["kind"]?.string == "preamble" {
                if let text = data["progressText"]?.text {
                    progress.note = Self.lastSentences(text)
                }
            } else {
                guard data["suppressChannelProgress"]?.bool != true, data["hideFromChannelProgress"]?.bool != true,
                      let id = data["toolCallId"]?.text ?? data["itemId"]?.text
                else { return }
                let status = data["status"]?.string?.lowercased()
                let title = data["title"]?.text
                    ?? data["name"]?.text.map { ToolTitles.title(name: $0, args: data["args"]) }
                progress.upsert(id: id, title: title, active: phase != "end",
                                error: status == "error" || status == "failed")
            }
        case "tool":
            guard let id = data["toolCallId"]?.text, let name = data["name"]?.text else { return }
            switch phase {
            case "start":
                // Activity items usually carry a nicer title; only fill in when absent.
                let exists = progress.steps.contains { $0.id == id }
                progress.upsert(id: id, title: exists ? nil : ToolTitles.title(name: name, args: data["args"]), active: true)
            case "result", "end":
                progress.upsert(id: id, title: nil, active: false, error: data["isError"]?.bool == true)
            default:
                break
            }
        case "plan":
            guard phase == "update" || phase == nil else { return }
            progress.plan = (data["steps"]?.array ?? []).compactMap { step in
                guard let text = step["step"]?.text ?? step["text"]?.text ?? step["title"]?.text else { return nil }
                return RunProgress.PlanItem(text: text, status: step["status"]?.string ?? "pending")
            }
        default:
            return
        }
        if progress.startedAt == nil { progress.startedAt = Date() }
        if case .thinking = activity { activity = .thinking(phase: progress.headline) }
    }

    /// Keeps commentary short enough for a single line or two.
    nonisolated static func lastSentences(_ text: String, limit: Int = 160) -> String {
        let trimmed = text.trimmed
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit - 1)).trimmed
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
        items.removeAll { $0.role == .assistant && $0.runId == runId && $0.text.trimmed.isEmpty && $0.images.isEmpty }
    }

    nonisolated static func uniqueImages(_ images: [ImageAttachment]) -> [ImageAttachment] {
        var seen = Set<String>()
        return images.filter { seen.insert($0.id).inserted }
    }

    // MARK: Images

    /// Starts loading an attachment's pixels if needed; views observe `images`.
    func loadImage(_ attachment: ImageAttachment) {
        guard images[attachment.id] == nil, !imageLoads.contains(attachment.id) else { return }
        if let inline = attachment.inlineBase64, let data = Data(base64Encoded: inline), let image = NSImage(data: data) {
            images[attachment.id] = image
            return
        }
        guard let artifactId = attachment.artifactId, gateway.state.isConnected else { return }
        imageLoads.insert(attachment.id)
        Task {
            defer { imageLoads.remove(attachment.id) }
            // Managed images return a short-lived ticket URL; if it expires mid-fetch, ask once more.
            for attempt in 0..<2 {
                do {
                    let result = try await gateway.request(
                        "artifacts.download",
                        ["sessionKey": .string(sessionKey), "artifactId": .string(artifactId)],
                        timeout: 30)
                    if let base64 = result["data"]?.string, let data = Data(base64Encoded: base64),
                       let image = NSImage(data: data) {
                        images[attachment.id] = image
                        return
                    }
                    guard let path = result["url"]?.text, let url = gateway.httpURL(forPath: path) else {
                        Log.error("artifacts.download returned no bytes or URL for \(artifactId)")
                        return
                    }
                    if let image = try await Self.fetchImage(url) {
                        images[attachment.id] = image
                        return
                    }
                } catch {
                    Log.error("Image load failed (attempt \(attempt + 1)): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Downloads a gateway media URL. The ticket in the URL is scoped to this one image.
    nonisolated static func fetchImage(_ url: URL) async throws -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else {
            throw GatewayError(code: "HTTP_\(http.statusCode)", message: "Image download returned HTTP \(http.statusCode)")
        }
        // OpenClaw's client guidance caps source images at 12 MiB.
        guard data.count <= 12 * 1024 * 1024 else {
            throw GatewayError(code: "TOO_LARGE", message: "Image is larger than 12 MB")
        }
        return NSImage(data: data)
    }

    /// Live terminal events can omit attachments: the image is committed to the transcript
    /// separately, sometimes after the run ends. Check the transcript a few times.
    func reconcileAttachments() {
        reconcileTask?.cancel()
        reconcileTask = Task {
            for delay in [0.6, 2.0, 4.0, 8.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard let result = try? await gateway.request(
                    "chat.history", ["sessionKey": .string(sessionKey), "limit": 8], timeout: 20)
                else { continue }
                var attachedAny = false
                for message in result["messages"]?.array ?? [] where message["role"]?.string == "assistant" {
                    if attachImages(from: message) { attachedAny = true }
                }
                // Once the latest reply has its images, stop polling.
                if attachedAny || items.last(where: { $0.role == .assistant })?.images.isEmpty == false { return }
            }
        }
    }

    /// Attaches a committed assistant message's images to the reply it belongs to.
    /// Returns true if it added images that weren't shown yet.
    @discardableResult
    func attachImages(from message: JSON) -> Bool {
        let found = MessageText.images(message)
        guard !found.isEmpty else { return false }
        // Already showing all of them?
        let shown = Set(items.flatMap(\.images).map(\.id))
        guard !found.allSatisfy({ shown.contains($0.id) }) else { return false }

        let runId = message["__openclaw"]?["runId"]?.string
        let text = MessageText.extract(message)?.trimmed ?? ""
        // 1) same run, 2) the live reply that contains this caption, 3) the latest reply.
        let index = items.lastIndex(where: { $0.role == .assistant && runId != nil && $0.runId == runId })
            ?? items.lastIndex(where: { $0.role == .assistant && !text.isEmpty && $0.text.trimmed.contains(text) })
            ?? (items.last?.role == .assistant ? items.indices.last : nil)
        if let index {
            items[index].images = Self.uniqueImages(items[index].images + found)
        } else {
            items.append(ChatItem(id: message["__openclaw"]?["id"]?.string ?? UUID().uuidString,
                                  role: .assistant, text: text, runId: runId, images: found))
        }
        Log.info("Attached \(found.count) image(s) from the transcript")
        return true
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

    private func raiseAttention(_ reason: AttentionReason, runId: String? = nil) {
        guard settings.glowOnReply || reason == .needsInput else { return }
        if isUserLooking(), reason != .needsInput { return }
        Log.info("Attention raised: \(reason) run=\(runId ?? "-")")
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

    /// Image content blocks (`type: "image"`) with an artifact id or inline base64 data.
    static func images(_ message: JSON) -> [ImageAttachment] {
        let blocks = message["content"]?.array ?? message.array ?? []
        return blocks.compactMap { block in
            guard block["type"]?.string == "image" || block["type"]?.string == "output_image" else { return nil }
            let artifactId = block["artifactId"]?.text
            let inline = block["data"]?.text ?? block["source"]?["data"]?.text ?? block["image_url"]?.text.flatMap(dataURLPayload)
            guard artifactId != nil || inline != nil else { return nil }
            return ImageAttachment(
                id: artifactId ?? String(inline!.suffix(48)),
                artifactId: artifactId,
                inlineBase64: inline,
                mimeType: block["mimeType"]?.text ?? block["source"]?["media_type"]?.text,
                alt: block["alt"]?.text ?? block["title"]?.text,
                width: block["width"]?.double,
                height: block["height"]?.double)
        }
    }

    private static func dataURLPayload(_ url: String) -> String? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return String(url[url.index(after: comma)...])
    }

    static func stripInstruction(_ text: String) -> String {
        guard let end = text.range(of: "</notchclaw-format>") else { return text }
        guard text.hasPrefix("<notchclaw-format>") else { return text }
        return String(text[end.upperBound...]).trimmed
    }
}
