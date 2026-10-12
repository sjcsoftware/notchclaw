import SwiftUI

enum NotchPalette {
    /// Siri-like neon spectrum used for the attention glow and accents.
    static let siri: [Color] = [
        Color(red: 1.00, green: 0.18, blue: 0.58),  // hot pink
        Color(red: 0.66, green: 0.33, blue: 0.97),  // violet
        Color(red: 0.23, green: 0.51, blue: 0.96),  // blue
        Color(red: 0.13, green: 0.83, blue: 0.93),  // cyan
        Color(red: 1.00, green: 0.62, blue: 0.04),  // amber
        Color(red: 1.00, green: 0.18, blue: 0.58),  // back to pink to close the loop
    ]

    static let accentGradient = LinearGradient(
        colors: [siri[0], siri[1], siri[2], siri[3]], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return Color(red: 0.25, green: 0.86, blue: 0.62)
        case ..<85: return Color(red: 1.0, green: 0.72, blue: 0.2)
        default: return Color(red: 1.0, green: 0.33, blue: 0.36)
        }
    }
}

/// The notch silhouette: concave "ears" at the top corners flowing into
/// rounded bottom corners, so the shape reads as an extension of the hardware notch.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = topCornerRadius
        let b = min(bottomCornerRadius, (rect.height - t) / 1, rect.width / 2 - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Neon edge glow that slowly rotates its spectrum around the notch outline.
struct SiriGlow: View {
    let shape: NotchShape
    var intensity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let gradient = AngularGradient(
                colors: NotchPalette.siri, center: .center,
                angle: .degrees(reduceMotion ? 0 : (t * 70).truncatingRemainder(dividingBy: 360)))
            let breathe = reduceMotion ? 1 : 0.78 + 0.22 * sin(t * 2.2)
            ZStack {
                shape.stroke(gradient, lineWidth: 16).blur(radius: 18).opacity(0.75)
                shape.stroke(gradient, lineWidth: 6).blur(radius: 6).opacity(0.9)
                shape.stroke(gradient, lineWidth: 1.6)
            }
            .opacity(breathe * intensity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The agent's emoji, with a spinning spectrum ring while it is thinking.
struct AgentAvatar: View {
    let emoji: String
    var size: CGFloat = 16
    var thinking: Bool
    var dimmed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if thinking {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(
                            AngularGradient(colors: NotchPalette.siri, center: .center),
                            style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? 0 : (t * 300).truncatingRemainder(dividingBy: 360)))
                        .frame(width: size * 1.45, height: size * 1.45)
                        .shadow(color: NotchPalette.siri[1].opacity(0.8), radius: 3)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Text(emoji)
                .font(.system(size: size))
                .grayscale(dimmed ? 1 : 0)
                .opacity(dimmed ? 0.55 : 1)
                .phaseAnimator([false, true], trigger: thinking) { view, phase in
                    view.scaleEffect(thinking && phase && !reduceMotion ? 1.08 : 1)
                } animation: { _ in .easeInOut(duration: 0.6) }
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: thinking)
        .accessibilityLabel(thinking ? "Agent is thinking" : "Agent")
    }
}

/// Three dots that ripple through the spectrum: the in-conversation thinking indicator.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = reduceMotion ? 0 : sin(t * 5 - Double(i) * 0.7)
                    Circle()
                        .fill(NotchPalette.siri[i + 1])
                        .frame(width: 6, height: 6)
                        .offset(y: -3 * max(0, phase))
                        .opacity(0.55 + 0.45 * max(0, phase))
                        .shadow(color: NotchPalette.siri[i + 1].opacity(0.7), radius: 3)
                }
            }
        }
        .accessibilityLabel("Thinking")
    }
}

/// Text with a light sweep passing across it.
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let x = (t * 0.8).truncatingRemainder(dividingBy: 1.6) - 0.3
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: x - 0.25),
                                .init(color: .white, location: x),
                                .init(color: .clear, location: x + 0.25),
                            ], startPoint: .leading, endPoint: .trailing)
                    }
                    .mask(Text(text).font(.system(size: size, weight: .medium)))
                }
            }
    }
}

/// Compact usage meter: a capsule track that fills and changes color with usage.
struct UsageBar: View {
    let percent: Double
    var width: CGFloat = 30
    var height: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.14))
            Capsule()
                .fill(NotchPalette.usageColor(percent).gradient)
                .frame(width: max(height, width * percent / 100))
                .shadow(color: NotchPalette.usageColor(percent).opacity(0.6), radius: 2)
        }
        .frame(width: width, height: height)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: percent)
        .accessibilityElement()
        .accessibilityLabel("Usage")
        .accessibilityValue("\(Int(percent)) percent")
    }
}

/// Animated audio level bars for push-to-talk.
struct VoiceWaveform: View {
    let level: Float
    var bars = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = reduceMotion ? 0.5 : (sin(t * 9 + Double(i) * 1.3) + 1) / 2
                    let h = 4 + CGFloat(level) * 18 * (0.45 + 0.55 * wobble)
                    Capsule()
                        .fill(NotchPalette.siri[i % 5])
                        .frame(width: 3, height: h)
                }
            }
            .frame(height: 24)
            .animation(.easeOut(duration: 0.08), value: level)
        }
        .accessibilityLabel("Listening")
    }
}
