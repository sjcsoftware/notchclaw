import AppKit
import Observation

/// Root object wiring settings, the gateway connection, the agent session,
/// push-to-talk, and the notch UI state together.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let gateway: GatewayClient
    let session: AgentSession
    let voice: VoiceController
    let notch: NotchViewModel
    @ObservationIgnored let hotKey: HotKey
    @ObservationIgnored var openSettings: () -> Void = {}

    /// Set while the user is recording a new shortcut, so the hotkey doesn't fire.
    var isRecordingShortcut = false {
        didSet { applyHotKey() }
    }

    init() {
        settings = AppSettings()
        gateway = GatewayClient()
        session = AgentSession(gateway: gateway, settings: settings)
        voice = VoiceController()
        notch = NotchViewModel()
        hotKey = HotKey()

        session.isUserLooking = { [weak self] in self?.notch.isExpanded ?? false }
        session.onAssistantOutput = { [weak self] in self?.assistantProduced() }
        voice.onFinished = { [weak self] text in self?.handleTranscript(text) }
        hotKey.onPress = { [weak self] in self?.pushToTalkPressed() }
        hotKey.onRelease = { [weak self] in self?.pushToTalkReleased() }
    }

    func start() {
        applyConnectionSettings()
        applyHotKey()
    }

    func applyConnectionSettings() {
        gateway.configure(urlString: settings.gatewayURL, token: settings.gatewayToken)
    }

    func applyHotKey() {
        hotKey.register(settings.pushToTalkEnabled && !isRecordingShortcut ? settings.pushToTalk : nil)
    }

    // MARK: Push-to-talk

    /// The last thing the user said, shown in the speech bubble under the agent until it replies.
    private(set) var spokenText: String?
    @ObservationIgnored private var expandedForVoice = false
    @ObservationIgnored private var bubbleTask: Task<Void, Never>?

    func toggleListening() {
        if voice.isActive { pushToTalkReleased() } else { pushToTalkPressed() }
    }

    private func pushToTalkPressed() {
        expandedForVoice = !notch.isExpanded
        notch.expand()
        session.clearAttention()
        bubbleTask?.cancel()
        spokenText = nil
        voice.begin(localeIdentifier: settings.speechLocale)
    }

    private func pushToTalkReleased() {
        voice.end()
    }

    private func handleTranscript(_ text: String) {
        guard !text.isEmpty else {
            if expandedForVoice, !notch.isHovering { notch.collapse() }
            return
        }
        spokenText = text
        if let command = VoiceCommand.parse(text) {
            perform(command)
            clearBubble(after: 2.5, collapse: true)
        } else if settings.autoSendVoice {
            session.send(text)
            // Stay open on the home screen while the agent thinks; the reply opens chat.
        } else {
            spokenText = nil
            notch.composerText = text
            notch.showChat(focusComposer: true)
        }
    }

    private func clearBubble(after delay: TimeInterval, collapse: Bool) {
        bubbleTask?.cancel()
        bubbleTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            spokenText = nil
            if collapse, expandedForVoice, !notch.isHovering, notch.page == .home, !voice.isActive {
                notch.collapse()
            }
        }
    }

    /// Replies always land in the chat screen: switch now if open, otherwise on next open.
    private func assistantProduced() {
        bubbleTask?.cancel()
        spokenText = nil
        if notch.isExpanded {
            notch.showChat(focusComposer: false)
        } else {
            notch.chatPending = true
        }
    }

    func perform(_ command: VoiceCommand) {
        switch command {
        case .stop:
            session.abort()
        case .compact:
            session.compact()
        case .newSession:
            session.newSession()
        case .setEffort(let level):
            session.setThinking(level)
        case .setModel(let query):
            if ["default", "the default", "auto"].contains(query) {
                session.setModel(nil)
            } else if let model = VoiceCommand.matchModel(query, in: session.models) {
                session.setModel(model.id)
            } else {
                session.showToast("No model matching “\(query)”")
            }
        }
    }
}
