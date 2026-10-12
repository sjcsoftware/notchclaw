import SwiftUI

/// The default expanded screen: the agent front and center, controls around it,
/// and the user's live speech in a bubble underneath.
struct HomeView: View {
    let app: AppModel

    var body: some View {
        let notch = app.notch
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                AgentStatusLine(app: app)
                Spacer(minLength: notch.geometry.notchWidth + 12)
                UsageCluster(app: app)
            }
            .frame(height: notch.geometry.notchHeight)

            ConnectionBanner(app: app)
            ForEach(app.session.approvals) { approval in
                ApprovalCard(approval: approval) { decision in
                    app.session.resolveApproval(approval, decision: decision)
                }
            }

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .trailing, spacing: 7) {
                    modelButton
                    effortButton
                    compactButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                AgentStage(app: app)

                VStack(alignment: .leading, spacing: 7) {
                    HomeAction(icon: "bubble.left.and.text.bubble.right.fill", title: "Chat",
                               badge: app.session.items.isEmpty ? nil : "\(app.session.items.filter { $0.role == .assistant }.count)",
                               prominent: true) {
                        notch.showChat(focusComposer: true)
                    }
                    .help("Open the conversation")
                    HomeAction(icon: "square.and.pencil", title: "New session") { app.session.newSession() }
                        .help("Reset the session and start fresh")
                    HomeAction(icon: "gearshape.fill", title: "Settings") { app.openSettings() }
                        .help("NotchClaw settings (⌘,)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)

            SpeechBubble(app: app)
                .frame(minHeight: 34)
        }
        .padding(.horizontal, NotchLayout.openCorners.top + 12)
        .padding(.bottom, 12)
        .frame(width: NotchLayout.homeWidth)
        .overlay(alignment: .bottom) { ToastView(message: app.session.toast) }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.voice.phase)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.spokenText)
    }

    // MARK: Controls

    private var modelButton: some View {
        let session = app.session
        let current = session.sessionSettings.modelRef
        return HomeAction(icon: "cpu", title: current.map(AgentSession.shortModelName) ?? "Model", menu: true) {
            var entries: [PopupMenu.Entry] = [.item("Default model", checked: current == nil) { session.setModel(nil) }]
            let byProvider = Dictionary(grouping: session.models, by: \.provider)
            for provider in byProvider.keys.sorted() {
                entries.append(.separator)
                entries.append(.header(provider))
                for model in byProvider[provider] ?? [] {
                    entries.append(.item(model.name, checked: model.id == current) { session.setModel(model.id) })
                }
            }
            if session.models.isEmpty {
                entries.append(.item(app.gateway.state.isConnected ? "Loading models…" : "Connect to choose a model",
                                     enabled: false) {})
                session.loadModels()
            }
            PopupMenu.show(entries)
        }
        .help("Model")
        .accessibilityLabel("Model: \(current ?? "default")")
    }

    private var effortButton: some View {
        let session = app.session
        let settings = session.sessionSettings
        return HomeAction(icon: "brain.head.profile", title: settings.thinkingLevel?.capitalized ?? "Effort", menu: true) {
            var entries: [PopupMenu.Entry] = [
                .item("Default effort", checked: settings.thinkingLevel == nil) { session.setThinking(nil) },
                .separator,
            ]
            for level in settings.thinkingOptions {
                entries.append(.item(level.capitalized, checked: level == settings.thinkingLevel) { session.setThinking(level) })
            }
            PopupMenu.show(entries)
        }
        .help("Reasoning effort")
        .accessibilityLabel("Reasoning effort: \(settings.thinkingLevel ?? "default")")
    }

    private var compactButton: some View {
        let fraction = app.session.sessionSettings.contextFraction
        return HomeAction(icon: "rectangle.compress.vertical", title: "Compact", trailing: fraction.map { AnyView(ContextRing(fraction: $0)) }) {
            app.session.compact()
        }
        .disabled(app.session.activity.isBusy)
        .help(fraction.map { "Compact context (\(Int($0 * 100))% used)" } ?? "Compact context")
    }
}

/// A pill button used around the agent on the home screen.
struct HomeAction: View {
    let icon: String
    let title: String
    var badge: String? = nil
    var menu = false
    var prominent = false
    var trailing: AnyView? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let trailing { trailing }
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
                if menu {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.5)
                }
            }
            .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.4))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .frame(maxWidth: 150)
            .background {
                Capsule().fill(
                    prominent
                        ? AnyShapeStyle(NotchPalette.accentGradient.opacity(hovering ? 0.75 : 0.5))
                        : AnyShapeStyle(.white.opacity(hovering ? 0.16 : 0.09)))
            }
            .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.18 : 0.06)))
            .contentShape(Capsule())
            .scaleEffect(hovering && isEnabled ? 1.03 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Agent stage

/// The big emoji. Ripples with your voice while listening, orbits while thinking,
/// floats gently when idle. Click it to talk.
struct AgentStage: View {
    let app: AppModel
    @State private var floating = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = app.voice.phase == .listening
        let finishing = app.voice.phase == .finishing
        let thinking = app.session.activity.isBusy
        let connected = app.gateway.state.isConnected
        let level = CGFloat(app.voice.level)

        ZStack {
            if listening || finishing {
                ListeningRings(level: app.voice.level)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if thinking {
                ThinkingHalo()
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else if hovering {
                Circle()
                    .fill(RadialGradient(colors: [NotchPalette.siri[1].opacity(0.35), .clear],
                                         center: .center, startRadius: 4, endRadius: 52))
                    .transition(.opacity)
            }

            Text(app.settings.resolvedEmoji)
                .font(.system(size: 46))
                .grayscale(connected ? 0 : 1)
                .opacity(connected ? 1 : 0.55)
                .scaleEffect(listening ? 1 + level * 0.25 : (hovering ? 1.06 : 1))
                .offset(y: floating && !listening && !reduceMotion ? -2.5 : 2.5)
                .animation(.easeOut(duration: 0.09), value: level)
                .shadow(color: listening ? NotchPalette.siri[0].opacity(0.6) : .clear, radius: 10 * level)

            if !connected {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(Color(red: 0.9, green: 0.3, blue: 0.25)))
                    .offset(x: 26, y: 24)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 108, height: 108)
        .contentShape(Circle())
        .onTapGesture { app.toggleListening() }
        .onHover { hovering = $0 }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { floating = true }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: listening)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: thinking)
        .animation(.easeOut(duration: 0.2), value: hovering)
        .help(app.settings.pushToTalkEnabled
              ? "Click or hold \(app.settings.pushToTalk.display) to talk"
              : "Click to talk")
        .accessibilityElement()
        .accessibilityLabel(listening ? "Listening" : (thinking ? "\(app.settings.resolvedName) is thinking" : app.settings.resolvedName))
        .accessibilityHint("Activate to start or stop talking")
        .accessibilityAddTraits(.isButton)
    }
}

/// Spectrum rings that radiate outward, driven by microphone level.
private struct ListeningRings: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let l = CGFloat(level)
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [NotchPalette.siri[1].opacity(0.25 + 0.35 * l), NotchPalette.siri[3].opacity(0.05), .clear],
                        center: .center, startRadius: 6, endRadius: 54))
                    .scaleEffect(0.85 + l * 0.3)
                ForEach(0..<3, id: \.self) { i in
                    let phase = reduceMotion ? 0.5 : ((t * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                    Circle()
                        .stroke(
                            AngularGradient(colors: NotchPalette.siri, center: .center,
                                            angle: .degrees(reduceMotion ? 0 : t * 120)),
                            lineWidth: 1.5 + l * 2.5)
                        .scaleEffect(0.55 + phase * (0.45 + l * 0.25))
                        .opacity((1 - phase) * (0.5 + 0.5 * Double(l)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Counter-rotating spectrum arcs shown while the agent works.
private struct ThinkingHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(AngularGradient(colors: NotchPalette.siri, center: .center),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees((t * 220).truncatingRemainder(dividingBy: 360)))
                    .frame(width: 84, height: 84)
                    .shadow(color: NotchPalette.siri[1].opacity(0.8), radius: 6)
                Circle()
                    .trim(from: 0, to: 0.35)
                    .stroke(AngularGradient(colors: NotchPalette.siri.reversed(), center: .center),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-(t * 160).truncatingRemainder(dividingBy: 360)))
                    .frame(width: 70, height: 70)
                    .opacity(0.8)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Speech bubble

/// The user's words, transcribed live, in a bubble pointing up at the agent.
private struct SpeechBubble: View {
    let app: AppModel

    var body: some View {
        let voice = app.voice
        ZStack {
            if let content {
                VStack(spacing: 0) {
                    BubbleTail()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 14, height: 7)
                    HStack(spacing: 8) {
                        if voice.phase == .listening {
                            VoiceWaveform(level: voice.level, bars: 4)
                                .frame(width: 22)
                        } else if case .failed = voice.phase {
                            Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                        } else if app.session.activity.isBusy {
                            ThinkingDots().scaleEffect(0.75)
                        }
                        Text(content.text)
                            .font(.system(size: 12.5, weight: content.placeholder ? .regular : .medium))
                            .foregroundStyle(.white.opacity(content.placeholder ? 0.5 : 0.95))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .contentTransition(.opacity)
                            .animation(.easeOut(duration: 0.1), value: content.text)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.12)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                AngularGradient(colors: NotchPalette.siri, center: .center).opacity(voice.phase == .listening ? 0.9 : 0.3),
                                lineWidth: 1))
                }
                .frame(maxWidth: 400)
                .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You said: \(content.text)")
            } else {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.35))
                    .transition(.opacity)
            }
        }
    }

    private var content: (text: String, placeholder: Bool)? {
        let voice = app.voice
        switch voice.phase {
        case .listening:
            return voice.transcript.isEmpty ? ("Listening…", true) : (voice.transcript, false)
        case .finishing:
            return voice.transcript.isEmpty ? ("…", true) : (voice.transcript, false)
        case .failed(let message):
            return (message, true)
        case .idle:
            return app.spokenText.map { ($0, false) }
        }
    }

    private var hint: String {
        app.settings.pushToTalkEnabled
            ? "Hold \(app.settings.pushToTalk.display) or click \(app.settings.resolvedEmoji) to talk"
            : "Click \(app.settings.resolvedEmoji) to talk"
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
