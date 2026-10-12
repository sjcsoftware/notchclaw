import SwiftUI

/// Top-level overlay view. Lives in a transparent panel pinned to the top of the screen.
struct NotchRootView: View {
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notch = app.notch
        let expanded = notch.isExpanded
        let corners = expanded ? NotchLayout.openCorners : NotchLayout.closedCorners
        let shape = NotchShape(topCornerRadius: corners.top, bottomCornerRadius: corners.bottom)
        let glowing = app.session.attention != nil && !expanded

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if expanded {
                    ExpandedNotchView(app: app)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
                                removal: .opacity.animation(.easeIn(duration: 0.08))))
                } else {
                    ClosedNotchView(app: app)
                        .frame(width: notch.closedSize.width, height: notch.closedSize.height)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
            .background(.black)
            .clipShape(shape)
            .background {
                if glowing {
                    SiriGlow(shape: shape, intensity: app.session.attention == .needsInput ? 1 : 0.85)
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 22, y: 8)
            .contentShape(shape)
            .onTapGesture {
                if !expanded { app.notch.expand(); app.session.clearAttention() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("NotchClaw")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.82), value: expanded)
        .animation(.easeInOut(duration: 0.35), value: glowing)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Closed

struct ClosedNotchView: View {
    let app: AppModel

    var body: some View {
        let session = app.session
        let gateway = app.gateway
        HStack(spacing: 0) {
            AgentAvatar(
                emoji: app.settings.resolvedEmoji, size: 14,
                thinking: session.activity.isBusy || app.voice.isActive,
                dimmed: !gateway.state.isConnected)
                .frame(width: NotchLayout.earWidth)
            Spacer(minLength: app.notch.geometry.notchWidth)
            rightEar
                .frame(width: NotchLayout.earWidth)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var rightEar: some View {
        let session = app.session
        switch app.gateway.state {
        case .connected:
            if session.attention == .needsInput {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchPalette.accentGradient)
                    .symbolEffect(.pulse)
                    .accessibilityLabel("Agent needs your input")
            } else if session.attention == .reply {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchPalette.accentGradient)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("New reply")
            } else if app.settings.showUsage, let window = session.usage?.bestWindow(for: app.settings.usageWindow) {
                VStack(spacing: 2.5) {
                    UsageBar(percent: window.usedPercent, width: 24, height: 4)
                    Text(window.label)
                        .font(.system(size: 7.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                .help("\(session.usage?.providerName ?? "Codex") \(window.label): \(Int(window.usedPercent))% used")
            }
        case .connecting:
            ConnectingSpinner(size: 11)
        case .offline:
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.35))
                .symbolEffect(.pulse)
                .accessibilityLabel("Disconnected")
        case .pairingRequired:
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .accessibilityLabel("Waiting for device approval")
        case .authFailed:
            Image(systemName: "exclamationmark.lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .accessibilityLabel("Authentication failed")
        case .idle:
            Image(systemName: "gearshape.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .accessibilityLabel("Not configured")
        }
    }
}

struct ConnectingSpinner: View {
    var size: CGFloat
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.75)
            .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
            .accessibilityLabel("Connecting")
    }
}
