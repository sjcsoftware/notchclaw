import SwiftUI

/// Live "what the agent is doing" card shown in the chat while a run is in flight.
struct RunProgressView: View {
    let progress: RunProgress
    /// Compact form used under streaming text: just the active step.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ThinkingDots()
                ShimmerText(text: progress.headline ?? "Thinking…", size: 11.5)
                    .lineLimit(1)
                Spacer(minLength: 6)
                ElapsedTime(since: progress.startedAt)
            }
            if !compact {
                if let note = progress.note, note != progress.headline {
                    Text(note)
                        .font(.system(size: 11.5))
                        .italic()
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                if !progress.plan.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(progress.plan.enumerated()), id: \.offset) { _, item in
                            PlanRow(item: item)
                        }
                    }
                    .padding(.leading, 2)
                }
                if !progress.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if progress.steps.count > 5 {
                            Text("\(progress.steps.count - 5) earlier steps")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        ForEach(progress.steps.suffix(5)) { step in
                            StepRow(step: step)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .padding(.vertical, compact ? 2 : 6)
        .padding(.horizontal, compact ? 0 : 10)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.045))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: progress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working: \(progress.headline ?? "thinking")")
    }
}

private struct StepRow: View {
    let step: RunProgress.Step

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if step.isActive {
                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                } else if step.isError {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(NotchPalette.usageColor(0))
                }
            }
            .font(.system(size: 10.5))
            .frame(width: 14, height: 14)
            Text(step.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(step.isActive ? 0.9 : 0.55))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct PlanRow: View {
    let item: RunProgress.PlanItem

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(item.text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(item.status == "completed" ? 0.45 : 0.85))
                .strikethrough(item.status == "completed", color: .white.opacity(0.3))
                .lineLimit(1)
        }
    }

    private var icon: String {
        switch item.status {
        case "completed": return "checkmark.square.fill"
        case "in_progress": return "arrow.right.square.fill"
        default: return "square"
        }
    }

    private var color: Color {
        switch item.status {
        case "completed": return NotchPalette.usageColor(0)
        case "in_progress": return NotchPalette.siri[2]
        default: return .white.opacity(0.35)
        }
    }
}

/// "12s", "1m 05s": how long the current run has been going.
struct ElapsedTime: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.format(context.date.timeIntervalSince(since)))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }
}
