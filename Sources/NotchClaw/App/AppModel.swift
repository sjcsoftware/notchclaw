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

    private var expandedForVoice = false

    private func pushToTalkPressed() {
        expandedForVoice = !notch.isExpanded
        notch.expand()
        session.clearAttention()
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
        if let command = VoiceCommand.parse(text) {
            perform(command)
        } else if settings.autoSendVoice {
            session.send(text)
        } else {
            notch.composerText = text
            notch.focusRequest += 1
            return
        }
        // Keep the notch open briefly so the user sees the result, then let hover rules take over.
        if expandedForVoice {
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                if !notch.isHovering, notch.canAutoCollapse, !voice.isActive { notch.collapse() }
            }
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
