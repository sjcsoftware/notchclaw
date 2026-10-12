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
                    Group {
                        switch notch.page {
                        case .home:
                            HomeView(app: app)
                                .transition(.blurReplace)
                        case .chat:
                            ChatView(app: app)
                                .transition(.blurReplace)
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))))
                } else {
                    // Minimized: a plain black extension of the notch, nothing inside.
                    Color.black
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
            .overlay {
                // While fine-tuning in Settings, outline the minimized notch so it can be lined up
                // with the hardware cutout.
                if notch.isTuningSize && !expanded {
                    shape.stroke(Color(red: 0.35, green: 0.75, blue: 1), lineWidth: 1.5)
                        .shadow(color: Color(red: 0.35, green: 0.75, blue: 1).opacity(0.8), radius: 4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 22, y: 8)
            .contentShape(shape)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { notch.contentFrame = $0 }
            .onHover { notch.viewHovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("NotchClaw")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.82), value: expanded)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: notch.page)
        .animation(.easeInOut(duration: 0.35), value: glowing)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: notch.sizeAdjust)
        .animation(.easeInOut(duration: 0.2), value: notch.isTuningSize)
        .environment(\.colorScheme, .dark)
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
