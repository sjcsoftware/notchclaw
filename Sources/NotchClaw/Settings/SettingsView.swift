import AVFoundation
import Carbon.HIToolbox
import Speech
import SwiftUI

struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            GatewaySettings(app: app)
                .tabItem { Label("Gateway", systemImage: "network") }
            AgentSettings(app: app)
                .tabItem { Label("Agent", systemImage: "face.smiling") }
            NotchSettings(app: app)
                .tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
            VoiceSettings(app: app)
                .tabItem { Label("Voice", systemImage: "mic") }
        }
        .frame(width: 520)
        .frame(minHeight: 430)
    }
}

// MARK: - Gateway

private struct GatewaySettings: View {
    let app: AppModel
    @State private var url = ""
    @State private var token = ""
    @State private var sessionKey = ""
    @State private var revealToken = false
    @State private var copiedDevice = false

    var body: some View {
        Form {
            Section {
                TextField("Gateway URL", text: $url, prompt: Text("ws://127.0.0.1:18789"))
                    .onSubmit(apply)
                HStack {
                    Group {
                        if revealToken {
                            TextField("Token", text: $token, prompt: Text("gateway.auth.token"))
                        } else {
                            SecureField("Token", text: $token, prompt: Text("gateway.auth.token"))
                        }
                    }
                    .onSubmit(apply)
                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealToken ? "Hide token" : "Show token")
                }
                TextField("Session", text: $sessionKey, prompt: Text("main"))
                    .onSubmit(apply)
            } header: {
                Text("Connection")
            } footer: {
                Text("Find these with `openclaw config get gateway` on the gateway host. Remote gateways ask you to approve this Mac once with `openclaw devices approve`.")
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(stateColor).frame(width: 8, height: 8)
                        Text(stateText).textSelection(.enabled)
                    }
                }
                if let version = app.gateway.serverVersion, app.gateway.state.isConnected {
                    LabeledContent("OpenClaw", value: version)
                }
                if case .pairingRequired(let requestId) = app.gateway.state {
                    LabeledContent("Approve with") {
                        Text("openclaw devices approve \(requestId ?? "--latest")")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Device ID") {
                    HStack {
                        Text(String(SecureStore.shared.identity.deviceId.prefix(16)) + "…")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button(copiedDevice ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SecureStore.shared.identity.deviceId, forType: .string)
                            copiedDevice = true
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reconnect") { app.gateway.reconnectNow(reason: "settings") }
                        .disabled(!isDirty && app.gateway.state == .idle)
                    Button("Save & Connect", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(GatewayClient.normalizedURL(url) == nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            url = app.settings.gatewayURL
            token = app.settings.gatewayToken
            sessionKey = app.settings.sessionKey
        }
    }

    private var isDirty: Bool {
        url != app.settings.gatewayURL || token != app.settings.gatewayToken || sessionKey != app.settings.sessionKey
    }

    private func apply() {
        let sessionChanged = sessionKey.trimmed != app.settings.sessionKey
        app.settings.gatewayURL = url.trimmed
        app.settings.gatewayToken = token.trimmed
        app.settings.sessionKey = sessionKey.trimmed
        app.applyConnectionSettings()
        if sessionChanged { app.session.sessionChanged() }
        if !app.gateway.state.isConnected { app.gateway.reconnectNow(reason: "settings saved") }
    }

    private var stateText: String {
        switch app.gateway.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .offline(let reason): return "Offline — \(reason)"
        case .pairingRequired: return "Waiting for approval on the gateway"
        case .authFailed(let message): return message
        case .idle: return "Not configured"
        }
    }

    private var stateColor: Color {
        switch app.gateway.state {
        case .connected: return .green
        case .connecting, .pairingRequired: return .orange
        case .idle: return .gray
        default: return .red
        }
    }
}

// MARK: - Agent

private struct AgentSettings: View {
    let app: AppModel
    @State private var customEmoji = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    private static let emojis = [
        "🦞", "🦀", "🐙", "🦑", "🐳", "🦊", "🐱", "🐶", "🐼", "🦉", "🐝", "🦄",
        "🤖", "👾", "🧠", "✨", "⚡️", "🔥", "🌙", "🪐", "🚀", "🛸", "🧙", "🥷",
        "🎩", "🍀", "🌵", "🍄", "🧊", "💎", "🎧", "🕹️",
    ]

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: Binding(get: { app.settings.agentName }, set: { app.settings.agentName = $0 }),
                          prompt: Text("OpenClaw"))
                LabeledContent("Emoji") {
                    HStack(spacing: 8) {
                        Text(app.settings.resolvedEmoji).font(.system(size: 26))
                        TextField("Custom", text: $customEmoji, prompt: Text("Type any emoji"))
                            .frame(width: 120)
                            .onChange(of: customEmoji) { _, value in
                                if let first = value.trimmed.first { app.settings.agentEmoji = String(first) }
                            }
                        Button {
                            NSApp.orderFrontCharacterPalette(nil)
                        } label: {
                            Image(systemName: "face.smiling")
                        }
                        .help("Open the emoji picker")
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 12), spacing: 6) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button {
                            app.settings.agentEmoji = emoji
                        } label: {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(app.settings.resolvedEmoji == emoji ? Color.accentColor.opacity(0.25) : .clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(emoji)")
                    }
                }
            }

            Section("Replies") {
                Toggle("Ask for rich replies (Markdown, charts, images)", isOn: Binding(
                    get: { app.settings.injectMarkdownInstruction }, set: { app.settings.injectMarkdownInstruction = $0 }))
                Text("Adds a short instruction to each message sent from NotchClaw so replies use Markdown, ```chart blocks for data, and the agent's image tool when a picture helps. Slash commands are sent untouched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do { try LaunchAtLogin.set(value); launchError = nil }
                        catch { launchError = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                    }
                if let launchError { Text(launchError).font(.callout).foregroundStyle(.red) }
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { app.settings.showMenuBarIcon }, set: { app.settings.showMenuBarIcon = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notch

private struct NotchSettings: View {
    let app: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Show Codex usage", isOn: Binding(get: { app.settings.showUsage }, set: { app.settings.showUsage = $0 }))
                Picker("Usage window", selection: Binding(get: { app.settings.usageWindow }, set: { app.settings.usageWindow = $0 })) {
                    ForEach(UsageWindowChoice.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!app.settings.showUsage)
                if let usage = app.session.usage {
                    LabeledContent("Current") {
                        Text(usage.windows.map { "\($0.label) \(Int($0.usedPercent))%" }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("Shown when the gateway's model uses a Codex (ChatGPT) login. Data comes from the gateway's usage status.")
                    .foregroundStyle(.secondary)
            }

            Section("Expanded size limit") {
                LabeledContent("Max height") {
                    HStack {
                        Slider(value: Binding(get: { app.settings.maxHeightFraction }, set: { app.settings.maxHeightFraction = $0 }),
                               in: 0.3...0.9, step: 0.05)
                        Text("\(Int(app.settings.maxHeightFraction * 100))% of screen")
                            .monospacedDigit()
                            .frame(width: 110, alignment: .trailing)
                    }
                }
                LabeledContent("Max width") {
                    HStack {
                        Slider(value: Binding(get: { app.settings.maxWidthFraction }, set: { app.settings.maxWidthFraction = $0 }),
                               in: 0.3...0.8, step: 0.05)
                        Text("\(Int(app.settings.maxWidthFraction * 100))% of screen")
                            .monospacedDigit()
                            .frame(width: 110, alignment: .trailing)
                    }
                }
            }

            Section("Feedback") {
                Toggle("Glow when the agent replies or needs you", isOn: Binding(
                    get: { app.settings.glowOnReply }, set: { app.settings.glowOnReply = $0 }))
                Toggle("Haptic tap when the notch opens", isOn: Binding(
                    get: { app.settings.hapticFeedback }, set: { app.settings.hapticFeedback = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Voice

private struct VoiceSettings: View {
    let app: AppModel
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()

    var body: some View {
        Form {
            Section {
                Toggle("Hold-to-talk shortcut", isOn: Binding(
                    get: { app.settings.pushToTalkEnabled },
                    set: { app.settings.pushToTalkEnabled = $0; app.applyHotKey() }))
                LabeledContent("Shortcut") {
                    ShortcutRecorder(app: app)
                }
                .disabled(!app.settings.pushToTalkEnabled)
                if let error = app.hotKeyError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Toggle("Send automatically when released", isOn: Binding(
                    get: { app.settings.autoSendVoice }, set: { app.settings.autoSendVoice = $0 }))
                Picker("Language", selection: Binding(get: { app.settings.speechLocale }, set: { app.settings.speechLocale = $0 })) {
                    Text("System (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "default"))").tag("")
                    ForEach(Self.locales, id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                    }
                }
            } header: {
                Text("Push to talk")
            } footer: {
                Text("Hold the shortcut anywhere, speak, and release. Say things like “set effort to high”, “switch model to sonnet”, “compact the context”, “new session”, or “stop” to control the agent.")
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Microphone") { permission(micStatus == .authorized) }
                LabeledContent("Speech recognition") { permission(speechStatus == .authorized) }
                HStack {
                    Spacer()
                    Button("Request Access") {
                        Task {
                            _ = await VoiceController.ensurePermissions()
                            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                            speechStatus = SFSpeechRecognizer.authorizationStatus()
                        }
                    }
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var locales: [String] {
        SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
    }

    private func permission(_ granted: Bool) -> some View {
        Label(granted ? "Allowed" : "Not allowed", systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(granted ? .green : .secondary)
    }
}

/// Click, then press a key combination. Esc cancels.
private struct ShortcutRecorder: View {
    let app: AppModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press shortcut…" : app.settings.pushToTalk.display)
                    .frame(minWidth: 120)
            }
            .help("Click and press a new shortcut")
            if app.settings.pushToTalk != .defaultPushToTalk {
                Button("Reset") { app.settings.pushToTalk = .defaultPushToTalk; app.applyHotKey() }
                    .controlSize(.small)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        app.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            let isFunctionKey = (Int(kVK_F1)...Int(kVK_F20)).contains(Int(event.keyCode))
                || [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19].contains(Int(event.keyCode))
            guard carbon != 0 || isFunctionKey else {
                NSSound.beep()
                return nil
            }
            app.settings.pushToTalk = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon)
            stop()
            app.applyHotKey()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        app.isRecordingShortcut = false
    }
}
