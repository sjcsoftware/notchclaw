import AppKit
import SwiftUI

struct ConversationView: View {
    let app: AppModel
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0
    /// Height of the visible scroll area and where the bottom of the transcript sits in it.
    @State private var viewportHeight: CGFloat = 0
    @State private var bottomEdge: CGFloat = 0
    /// Whether the newest message is in view (drives sticky auto-scroll and the jump button).
    private var isAtBottom: Bool { viewportHeight == 0 || bottomEdge <= viewportHeight + 24 }
    @Environment(\.notchSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(app.session.items) { MessageRow(item: $0, session: app.session) }
                progressRows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            scrolling
        }
    }

    private var scrolling: some View {
        let session = app.session
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // A plain VStack: a lazy stack leaves freshly revealed rows blank when the
                // scroll view grows to its measured height on appear.
                VStack(alignment: .leading, spacing: 14) {
                    if session.items.isEmpty {
                        EmptyConversation(app: app)
                    }
                    ForEach(session.items) { item in
                        MessageRow(item: item, session: session)
                            .id(item.id)
                    }
                    progressRows
                    Color.clear.frame(height: 1).id("bottom")
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("chatScroll")).minY } action: {
                            bottomEdge = $0
                        }
                }
                .padding(.vertical, 4)
                .background(ScrollerHider())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    contentHeight = height
                    app.notch.chatContentHeight = height
                }
            }
            .coordinateSpace(name: "chatScroll")
            .defaultScrollAnchor(.bottom)
            .frame(height: min(max(contentHeight, 44), maxHeight))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .overlay(alignment: .bottom) { ToastView(message: session.toast) }
            .mask(fadeMask)
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    JumpToBottomButton {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .padding(.bottom, 8)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isAtBottom)
            // Sticky auto-scroll: follow new text only if the reader is already at the bottom.
            .onChange(of: session.items.last?.text) { _, _ in
                if isAtBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.items.count) { _, _ in
                // Your own new message always brings you down to it.
                guard isAtBottom || session.items.last?.role == .user else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: contentHeight) { _, _ in
                if isAtBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                // Start at the last known height so the first frame is already full size.
                if contentHeight == 0 { contentHeight = app.notch.chatContentHeight }
                proxy.scrollTo("bottom", anchor: .bottom)
                Task { @MainActor in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showsPendingThinking)
    }

    /// Live run progress: a full card before reply text arrives, then a one-line
    /// "currently doing" row under the streaming reply whenever a tool is running.
    @ViewBuilder
    private var progressRows: some View {
        let session = app.session
        if showsPendingThinking {
            RunProgressView(progress: session.progress)
                .id("thinking")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if session.activity == .streaming, session.progress.activeStep != nil {
            RunProgressView(progress: session.progress, compact: true)
                .id("thinking")
                .transition(.opacity)
        }
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
    let session: AgentSession
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
                if item.text.isEmpty && item.images.isEmpty {
                    ThinkingRow(phase: nil)
                } else if !item.text.isEmpty {
                    MarkdownView(item.text)
                }
                if !item.images.isEmpty {
                    AgentImagesView(attachments: item.images, session: session)
                        .padding(.top, item.text.isEmpty ? 0 : 6)
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

struct ToastView: View {
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

struct ContextRing: View {
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
    @Environment(\.notchSnapshot) private var snapshot

    var body: some View {
        let notch = app.notch
        HStack(alignment: .bottom, spacing: 8) {
            if snapshot {
                Text("Message \(app.settings.resolvedName)…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.leading, 12)
            } else {
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
            }

            if app.session.activity.isBusy && app.session.activity != .compacting {
                Button { app.session.abort() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(IconButtonStyle(active: true))
                    .padding(.bottom, 4)
                    .help("Stop the reply")
                    .accessibilityLabel("Stop reply")
                    .transition(.scale.combined(with: .opacity))
            }

            Button {
                app.toggleListening()
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
        .animation(.snappy, value: app.session.activity.isBusy)

        .onChange(of: focused) { _, value in notch.composerFocused = value }
        .onChange(of: notch.wantsComposerFocus) { _, _ in takeFocusIfRequested() }
        .onAppear(perform: takeFocusIfRequested)
        .onKeyPress(.escape) {
            if !notch.composerText.isEmpty { notch.composerText = ""; return .handled }
            notch.page = .home
            return .handled
        }
    }

    private func takeFocusIfRequested() {
        guard app.notch.wantsComposerFocus else { return }
        app.notch.wantsComposerFocus = false
        app.notch.requestKeyWindow()
        Task { @MainActor in focused = true }
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

// MARK: - Images

/// Images the agent generated, loaded on demand through `artifacts.download`.
struct AgentImagesView: View {
    let attachments: [ImageAttachment]
    let session: AgentSession

    var body: some View {
        let columns = attachments.count == 1
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                AgentImageTile(attachment: attachment, session: session, single: attachments.count == 1)
            }
        }
        .frame(maxWidth: attachments.count == 1 ? 400 : .infinity, alignment: .leading)
    }
}

private struct AgentImageTile: View {
    let attachment: ImageAttachment
    let session: AgentSession
    let single: Bool
    @State private var hovering = false

    var body: some View {
        let image = session.images[attachment.id]
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: single ? .fit : .fill)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo").font(.system(size: 18))
                            Text(attachment.artifactId == nil ? "Image unavailable" : "Loading image…")
                                .font(.system(size: 10.5))
                        }
                        .foregroundStyle(.white.opacity(0.4))
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: single ? nil : 150)
        .aspectRatio(single ? (image.map { $0.size.width / max($0.size.height, 1) } ?? attachment.aspectRatio ?? 1.5) : nil,
                     contentMode: .fit)
        .frame(maxHeight: single ? 300 : 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.25 : 0.08)))
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .onHover { hovering = $0 }
        .onAppear { session.loadImage(attachment) }
        .onTapGesture { if let image { ImageExport.open(image, name: attachment.id) } }
        .contextMenu {
            if let image {
                Button("Open in Preview") { ImageExport.open(image, name: attachment.id) }
                Button("Copy Image") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                Button("Save to Downloads") { ImageExport.saveToDownloads(image, name: attachment.id) }
            }
        }
        .help(attachment.alt ?? "Generated image — click to open")
        .accessibilityLabel(attachment.alt ?? "Generated image")
    }
}

enum ImageExport {
    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func open(_ image: NSImage, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchclaw-\(safe(name)).png")
        guard let data = pngData(image), (try? data.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }

    static func saveToDownloads(_ image: NSImage, name: String) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let data = pngData(image) else { return }
        let url = downloads.appendingPathComponent("NotchClaw \(safe(name)).png")
        if (try? data.write(to: url)) != nil { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private static func safe(_ name: String) -> String {
        String(name.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40))
    }
}

/// Floating "jump to latest" control shown when the newest message is out of view.
private struct JumpToBottomButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(white: hovering ? 0.26 : 0.18)))
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                .contentShape(Circle())
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Jump to the latest message")
        .accessibilityLabel("Jump to latest message")
    }
}
