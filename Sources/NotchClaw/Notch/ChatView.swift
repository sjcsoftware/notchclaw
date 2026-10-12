import SwiftUI

/// The chat page: conversation transcript plus composer.
struct ChatView: View {
    let app: AppModel

    var body: some View {
        let notch = app.notch
        let maxSize = notch.maxExpandedSize(settings: app.settings)
        let width = wantsWide ? maxSize.width : min(NotchLayout.baseExpandedWidth, maxSize.width)
        let chrome: CGFloat = NotchLayout.headerTopPadding + 26 + 96
        let conversationMax = max(90, maxSize.height - chrome - bannerAllowance)

        VStack(spacing: 10) {
            NotchHeader(app: app, showsBack: true)
                .padding(.top, NotchLayout.headerTopPadding)
                .padding(.horizontal, NotchLayout.headerInset)
            ConnectionBanner(app: app)
            ForEach(app.session.approvals) { approval in
                ApprovalCard(approval: approval) { decision in
                    app.session.resolveApproval(approval, decision: decision)
                }
            }
            if app.voice.phase != .idle {
                ListeningCard(voice: app.voice)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ConversationView(app: app, maxHeight: conversationMax)
            Composer(app: app)
        }
        .padding(.horizontal, NotchLayout.contentInset)
        .padding(.bottom, 18)
        .frame(width: width)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: wantsWide)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.voice.phase)
    }

    private var bannerAllowance: CGFloat {
        var h: CGFloat = 0
        if !app.gateway.state.isConnected { h += 64 }
        h += CGFloat(app.session.approvals.count) * 96
        if app.voice.phase != .idle { h += 56 }
        return h
    }

    /// Long or structured replies get the wide layout.
    private var wantsWide: Bool {
        guard let text = app.session.latestAssistantText else { return false }
        return text.count > 650 || text.contains("```") || text.contains("\n|") || text.hasPrefix("|")
    }
}

// MARK: - Header

/// Shared header: `Name  model ··· (notch) ···  n%  ▬▬▬`.
struct NotchHeader: View {
    let app: AppModel
    var showsBack = false

    var body: some View {
        HStack(spacing: 8) {
            if showsBack {
                Button {
                    app.notch.page = .home
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back to \(app.settings.resolvedName)")
                .accessibilityLabel("Back")
            }
            Text(app.settings.resolvedName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            ModelTag(app: app)
            Spacer(minLength: app.notch.geometry.notchWidth + 16)
            UsageCluster(app: app)
                .fixedSize()
                .layoutPriority(2)
        }
        .frame(height: 26)
    }
}

/// Connection dot + current model (or connection/run state). Click to switch models.
struct ModelTag: View {
    let app: AppModel
    @State private var hovering = false

    var body: some View {
        Button {
            ModelMenus.showModels(app)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: dotColor.opacity(0.8), radius: 3)
                Group {
                    if case .thinking = app.session.activity {
                        ShimmerText(text: label, size: 11)
                    } else if app.session.activity == .streaming {
                        ShimmerText(text: label, size: 11)
                    } else {
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.6))
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(.white.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Model — click to switch")
        .accessibilityLabel("Model: \(label)")
    }

    private var label: String {
        switch app.gateway.state {
        case .connected:
            switch app.session.activity {
            case .thinking(let phase): return phase ?? "Thinking…"
            case .streaming: return "Replying…"
            case .compacting: return "Compacting…"
            case .idle: return app.session.sessionSettings.modelRef.map(AgentSession.shortModelName) ?? "Default model"
            }
        case .connecting: return "Connecting…"
        case .offline: return "Offline"
        case .pairingRequired: return "Awaiting approval"
        case .authFailed: return "Sign-in failed"
        case .idle: return "Not set up"
        }
    }

    private var dotColor: Color {
        switch app.gateway.state {
        case .connected: return Color(red: 0.3, green: 0.9, blue: 0.55)
        case .connecting, .pairingRequired: return .orange
        case .idle: return .gray
        default: return Color(red: 1, green: 0.4, blue: 0.4)
        }
    }
}

/// Native menus for model and effort selection, shared by the header and home controls.
@MainActor
enum ModelMenus {
    static func showModels(_ app: AppModel) {
        let session = app.session
        let current = session.sessionSettings.modelRef
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

    static func showEffort(_ app: AppModel) {
        let session = app.session
        let settings = session.sessionSettings
        var entries: [PopupMenu.Entry] = [
            .item("Default effort", checked: settings.thinkingLevel == nil) { session.setThinking(nil) },
            .separator,
        ]
        for level in settings.thinkingOptions {
            entries.append(.item(level.capitalized, checked: level == settings.thinkingLevel) { session.setThinking(level) })
        }
        PopupMenu.show(entries)
    }
}

struct UsageCluster: View {
    let app: AppModel

    var body: some View {
        if app.settings.showUsage, let usage = app.session.usage, !usage.windows.isEmpty {
            Button {
                var entries: [PopupMenu.Entry] = [.header("\(usage.providerName) usage")]
                for choice in UsageWindowChoice.allCases {
                    let window = usage.window(for: choice)
                    let title = window.map { "\(choice.title) — \(Int($0.usedPercent))% used" } ?? "\(choice.title) — unavailable"
                    entries.append(.item(title, checked: app.settings.usageWindow == choice, enabled: window != nil) {
                        app.settings.usageWindow = choice
                    })
                }
                if let plan = usage.plan {
                    entries.append(.separator)
                    entries.append(.item("Plan: \(plan.capitalized)", enabled: false) {})
                }
                PopupMenu.show(entries)
            } label: {
                label(usage: usage)
            }
            .buttonStyle(.plain)
        }
    }

    private func label(usage: UsageInfo) -> some View {
        let window = usage.bestWindow(for: app.settings.usageWindow)
        let percent = window?.usedPercent ?? 0
        return HStack(spacing: 7) {
            OpenAIMark(size: 12)
                .foregroundStyle(.white.opacity(0.85))
            Text("\(Int(percent))%")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText(value: percent))
                .lineLimit(1)
                .fixedSize()
            UsageBar(percent: percent, width: 58, height: 5)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(helpText(usage: usage, window: window))
        .animation(.snappy, value: percent)
    }

    private func helpText(usage: UsageInfo, window: UsageWindowInfo?) -> String {
        guard let window else { return "\(usage.providerName) usage" }
        var text = "\(usage.providerName) · \(window.label) window · \(Int(window.usedPercent))% used"
        if let reset = window.resetAt, reset > Date() {
            text += " · resets \(reset.formatted(.relative(presentation: .named)))"
        }
        return text + "\nClick to choose 5h / daily / weekly"
    }
}

// MARK: - Banners & cards

struct ConnectionBanner: View {
    let app: AppModel
    @State private var copied = false

    var body: some View {
        switch app.gateway.state {
        case .connected:
            EmptyView()
        case .connecting(let attempt):
            banner(icon: "antenna.radiowaves.left.and.right", tint: .orange,
                   title: attempt > 0 ? "Reconnecting…" : "Connecting…", subtitle: host, action: nil)
        case .offline(let reason):
            banner(icon: "wifi.slash", tint: Color(red: 1, green: 0.45, blue: 0.35),
                   title: app.gateway.networkAvailable ? "Disconnected" : "No network",
                   subtitle: app.gateway.networkAvailable ? "\(reason) · retrying automatically" : "Will reconnect when you're back online",
                   action: ("Retry", { app.gateway.reconnectNow(reason: "user") }))
        case .pairingRequired(let requestId):
            VStack(alignment: .leading, spacing: 6) {
                banner(icon: "person.badge.key.fill", tint: .orange, title: "Approve this Mac on your gateway",
                       subtitle: "Run this on the gateway host, then NotchClaw connects automatically.", action: nil)
                let command = "openclaw devices approve \(requestId ?? "--latest")"
                HStack {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                .padding(8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        case .authFailed(let message):
            banner(icon: "exclamationmark.lock.fill", tint: .red, title: "Couldn't sign in", subtitle: message,
                   action: ("Settings…", { app.openSettings() }))
        case .idle:
            banner(icon: "link", tint: .blue, title: "Connect to your OpenClaw gateway",
                   subtitle: "Add the gateway URL and token in Settings.", action: ("Set Up…", { app.openSettings() }))
        }
    }

    private var host: String? { GatewayClient.normalizedURL(app.settings.gatewayURL)?.host }

    private func banner(icon: String, tint: Color, title: String, subtitle: String?, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                }
            }
            Spacer()
            if let action {
                Button(action.0, action: action.1).buttonStyle(ChipButtonStyle())
            }
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

struct ApprovalCard: View {
    let approval: PendingApproval
    let resolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(NotchPalette.accentGradient)
                Text("Approval needed").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if let expires = approval.expiresAt, expires > Date() {
                    Text(expires, style: .timer).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                }
            }
            Text(approval.title)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(4)
                .textSelection(.enabled)
            if let detail = approval.detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
            }
            HStack {
                ForEach(approval.decisions, id: \.self) { decision in
                    Button(Self.title(decision)) { resolve(decision) }
                        .buttonStyle(ChipButtonStyle(prominent: decision == "allow-once", destructive: decision == "deny"))
                }
            }
        }
        .padding(11)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AngularGradient(colors: NotchPalette.siri, center: .center).opacity(0.6), lineWidth: 1))
    }

    static func title(_ decision: String) -> String {
        switch decision {
        case "allow-once": return "Allow once"
        case "allow-always": return "Always allow"
        case "deny": return "Deny"
        default: return decision.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

struct ListeningCard: View {
    let voice: VoiceController

    var body: some View {
        HStack(spacing: 12) {
            if case .failed(let message) = voice.phase {
                Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
            } else {
                VoiceWaveform(level: voice.level)
                Text(voice.transcript.isEmpty ? (voice.phase == .finishing ? "Finishing…" : "Listening…") : voice.transcript)
                    .font(.system(size: 13, weight: voice.transcript.isEmpty ? .regular : .medium))
                    .foregroundStyle(.white.opacity(voice.transcript.isEmpty ? 0.5 : 0.95))
                    .lineLimit(3)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: voice.transcript)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AngularGradient(colors: NotchPalette.siri, center: .center), lineWidth: 1.2))
    }
}

// MARK: - Buttons

struct ChipButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(destructive ? Color(red: 1, green: 0.5, blue: 0.5) : .white.opacity(prominent ? 1 : 0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(NotchPalette.accentGradient.opacity(0.55)) : AnyShapeStyle(.white.opacity(0.1)))
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(NotchPalette.accentGradient) : AnyShapeStyle(.white.opacity(0.7)))
            .frame(width: 26, height: 24)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
