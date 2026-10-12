import AppKit
import SwiftUI

struct ConversationView: View {
    let app: AppModel
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let session = app.session
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.items.isEmpty {
                        EmptyConversation(app: app)
                    }
                    ForEach(session.items) { item in
                        MessageRow(item: item, emoji: app.settings.resolvedEmoji)
                            .id(item.id)
                    }
                    if showsPendingThinking {
                        ThinkingRow(phase: phaseText)
                            .id("thinking")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.bottom)
            .frame(height: min(max(contentHeight, 44), maxHeight))
            .overlay(alignment: .bottom) { ToastView(message: session.toast) }
            .mask(fadeMask)
            .onChange(of: session.items.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showsPendingThinking)
    }

    private var showsPendingThinking: Bool {
        guard case .thinking = app.session.activity else { return false }
        return app.session.items.last?.role != .assistant || app.session.items.last?.text.isEmpty == true
    }

    private var phaseText: String? {
        if case .thinking(let phase) = app.session.activity { return phase }
        return nil
    }

    private var fadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
            Rectangle().fill(.black)
        }
    }
}

private struct EmptyConversation: View {
    let app: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(app.settings.resolvedEmoji).font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text("What can \(app.settings.resolvedName) do for you?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.vertical, 6)
    }

    private var hint: String {
        if app.settings.pushToTalkEnabled {
            return "Type below, or hold \(app.settings.pushToTalk.display) and speak."
        }
        return "Type a message below."
    }
}

private struct MessageRow: View {
    let item: ChatItem
    let emoji: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(LinearGradient(
                                colors: [NotchPalette.siri[1].opacity(0.45), NotchPalette.siri[2].opacity(0.4)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                if item.text.isEmpty {
                    ThinkingRow(phase: nil)
                } else {
                    MarkdownView(item.text)
                }
                if !item.isStreaming && !item.text.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.text, forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.45))
                        Text(item.date, style: .time)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .opacity(hovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: hovering)
                }
            }
            .onHover { hovering = $0 }
        case .notice:
            Text(item.text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
        case .error:
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(item.text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct ThinkingRow: View {
    let phase: String?

    var body: some View {
        HStack(spacing: 10) {
            ThinkingDots()
            ShimmerText(text: phase ?? "Thinking", size: 11.5)
        }
        .padding(.vertical, 4)
    }
}

private struct ToastView: View {
    let message: String?

    var body: some View {
        ZStack {
            if let message {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(white: 0.16)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: message)
    }
}

// MARK: - Controls

struct ControlsRow: View {
    let app: AppModel

    var body: some View {
        let session = app.session
        let settings = session.sessionSettings
        HStack(spacing: 6) {
            Menu {
                Button("Default model") { session.setModel(nil) }
                let providers = Dictionary(grouping: session.models, by: \.provider)
                ForEach(providers.keys.sorted(), id: \.self) { provider in
                    Section(provider) {
                        ForEach(providers[provider] ?? []) { model in
                            Button {
                                session.setModel(model.id)
                            } label: {
                                if model.id == settings.modelRef { Label(model.name, systemImage: "checkmark") }
                                else { Text(model.name) }
                            }
                        }
                    }
                }
                if session.models.isEmpty { Text("No models reported by the gateway") }
            } label: {
                chip(icon: "cpu", text: settings.modelRef.map(AgentSession.shortModelName) ?? "Model")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model")
            .accessibilityLabel("Model")

            Menu {
                Button("Default effort") { session.setThinking(nil) }
                Divider()
                ForEach(settings.thinkingOptions, id: \.self) { level in
                    Button {
                        session.setThinking(level)
                    } label: {
                        if level == settings.thinkingLevel { Label(level.capitalized, systemImage: "checkmark") }
                        else { Text(level.capitalized) }
                    }
                }
            } label: {
                chip(icon: "brain", text: settings.thinkingLevel?.capitalized ?? "Effort")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reasoning effort")
            .accessibilityLabel("Reasoning effort")

            Button {
                session.compact()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.compress.vertical")
                    Text("Compact")
                    if let fraction = settings.contextFraction {
                        ContextRing(fraction: fraction)
                    }
                }
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(session.activity.isBusy)
            .help(settings.contextFraction.map { "Compact context (\(Int($0 * 100))% used)" } ?? "Compact context")

            Spacer(minLength: 4)

            if session.activity.isBusy && session.activity != .compacting {
                Button { session.abort() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(IconButtonStyle(active: true))
                    .help("Stop")
                    .accessibilityLabel("Stop reply")
                    .transition(.scale.combined(with: .opacity))
            }
            Button { session.newSession() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(IconButtonStyle())
                .help("New session")
                .accessibilityLabel("New session")
            Button { app.notch.isPinned.toggle() } label: {
                Image(systemName: app.notch.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(IconButtonStyle(active: app.notch.isPinned))
            .help(app.notch.isPinned ? "Unpin (collapse when the pointer leaves)" : "Keep open")
            .accessibilityLabel(app.notch.isPinned ? "Unpin notch" : "Pin notch open")
            Button { app.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle())
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
        .animation(.snappy, value: session.activity.isBusy)
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.5)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.1)))
        .frame(maxWidth: 170)
    }
}

private struct ContextRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(NotchPalette.usageColor(fraction * 100), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 10, height: 10)
    }
}

// MARK: - Composer

struct Composer: View {
    let app: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        let notch = app.notch
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Message \(app.settings.resolvedName)…",
                text: Binding(get: { notch.composerText }, set: { notch.composerText = $0 }),
                axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 8)
                .padding(.leading, 12)
                .accessibilityLabel("Message")

            Button {
                if app.voice.isActive { app.voice.end() }
                else { app.voice.begin(localeIdentifier: app.settings.speechLocale) }
            } label: {
                Image(systemName: app.voice.isActive ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: app.voice.isActive)
            }
            .buttonStyle(IconButtonStyle(active: app.voice.isActive))
            .padding(.bottom, 4)
            .help(app.settings.pushToTalkEnabled ? "Dictate (or hold \(app.settings.pushToTalk.display))" : "Dictate")
            .accessibilityLabel(app.voice.isActive ? "Stop dictation" : "Dictate")

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(canSend ? AnyShapeStyle(NotchPalette.accentGradient) : AnyShapeStyle(.white.opacity(0.12))))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.bottom, 3)
            .padding(.trailing, 4)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? AnyShapeStyle(NotchPalette.accentGradient.opacity(0.7)) : AnyShapeStyle(.white.opacity(0.1)), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: focused)
        .onChange(of: focused) { _, value in notch.composerFocused = value }
        .onChange(of: notch.focusRequest) { _, _ in
            notch.requestKeyWindow()
            focused = true
        }
        .onKeyPress(.escape) {
            if !notch.composerText.isEmpty { notch.composerText = ""; return .handled }
            notch.collapse()
            return .handled
        }
    }

    private var canSend: Bool { !app.notch.composerText.trimmed.isEmpty && app.gateway.state.isConnected }

    private func send() {
        let text = app.notch.composerText
        guard !text.trimmed.isEmpty else { return }
        guard app.gateway.state.isConnected else {
            app.session.showToast("Offline — reconnecting first")
            return
        }
        app.notch.composerText = ""
        app.session.send(text)
    }
}
