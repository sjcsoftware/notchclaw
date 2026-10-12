#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders notch states onto a mock desktop for the README and visual review.
/// Run: `NOTCHCLAW_SNAPSHOT_DIR=docs/images .build/debug/NotchClaw` (or `scripts/screenshots.sh`).
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["NOTCHCLAW_SNAPSHOT_DIR"] else { return false }
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Minimized, glowing because a reply arrived.
        scene(url, "minimized-glow", height: 120) { app in
            app.session.attention = .reply
        }
        // Fine-tuning the minimized size in Settings (outlined).
        scene(url, "minimized-tuning", height: 120) { app in
            app.notch.isTuningSize = true
            app.notch.sizeAdjust = CGSize(width: 24, height: 4)
        }
        // Default (home) screen.
        scene(url, "home", height: 250) { app in
            app.notch.expand(page: .home)
        }
        // Hold-to-talk: rings + live transcription bubble.
        scene(url, "listening", height: 270) { app in
            app.notch.expand(page: .home)
            app.voice.previewListening("What's on my calendar tomorrow? Summarize it in a table", level: 0.65)
        }
        // Sent, agent thinking.
        scene(url, "thinking", height: 270) { app in
            app.notch.expand(page: .home)
            app.spokenText = "Compare my last three months of cloud spend"
            app.session.activity = .thinking(phase: "Gathering context")
        }
        // Chat with a syntax-highlighted code reply.
        scene(url, "code", height: 470) { app in
            app.notch.expand(page: .chat)
            app.session.items = [
                ChatItem(id: "1", role: .user, text: "Write a quick Python function that inverts a binary tree."),
                ChatItem(id: "2", role: .assistant, text: """
                ### Invert a Binary Tree

                ```python
                from typing import Optional

                @dataclass
                class Node:
                    value: int
                    left: Optional["Node"] = None
                    right: Optional["Node"] = None

                def inverse(root: Optional[Node]) -> Optional[Node]:
                    \"\"\"Swap left/right children at every node.\"\"\"
                    if root is None:
                        return None  # empty subtree
                    root.left, root.right = inverse(root.right), inverse(root.left)
                    return root
                ```
                """),
            ]
        }
        // Chat with a rich Markdown reply and a native chart.
        scene(url, "chat", height: 580) { app in
            app.notch.expand(page: .chat)
            app.session.loadPreviewConversation()
        }
        return true
    }

    private static func scene(_ dir: URL, _ name: String, height: CGFloat, configure: (AppModel) -> Void) {
        let app = AppModel()
        app.gateway.simulateConnected(version: "2026.10.2")
        app.notch.geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 185, notchHeight: 32, hasNotch: true)
        app.session.loadPreviewDefaults()
        configure(app)
        let view = MockDesktop(height: height) { NotchRootView(app: app) }
            .environment(\.notchSnapshot, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let data = ImageExport.pngData(image) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

/// A slice of a macOS desktop: wallpaper, menu bar, and the hardware notch.
private struct MockDesktop<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.13, blue: 0.32), Color(red: 0.36, green: 0.2, blue: 0.48),
                         Color(red: 0.86, green: 0.45, blue: 0.4)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.4, green: 0.6, blue: 1).opacity(0.45), .clear],
                           center: .init(x: 0.2, y: 0.9), startRadius: 10, endRadius: 600)
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                Text("Finder").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) {
                    Text($0).font(.system(size: 13))
                }
                Spacer()
                Image(systemName: "wifi").font(.system(size: 13))
                Image(systemName: "battery.75percent").font(.system(size: 15))
                Text("Mon 9:41 AM").font(.system(size: 13))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(.black.opacity(0.12))
            content
        }
        .frame(width: 1100, height: height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

extension AgentSession {
    func loadPreviewDefaults() {
        usage = UsageInfo(providerName: "Codex", plan: "plus", windows: [
            UsageWindowInfo(label: "5h", usedPercent: 42, resetAt: Date().addingTimeInterval(7200)),
            UsageWindowInfo(label: "Week", usedPercent: 71, resetAt: nil),
        ])
        sessionSettings = SessionSettings(model: "openai-codex/gpt-5.1-codex", thinkingLevel: "high",
                                          totalTokens: 52_000, contextTokens: 200_000)
        items = [ChatItem(id: "0", role: .assistant, text: "Ready.")]
    }

    func loadPreviewConversation() {
        items = [
            ChatItem(id: "1", role: .user, text: "How did our API latency change this week? Keep it short."),
            ChatItem(id: "2", role: .assistant, text: """
            ## API latency this week

            p95 dropped **38%** after Tuesday's cache rollout.

            ```chart
            {"type":"line","title":"p95 latency (ms)","x":"Day","y":"ms","data":[
              {"x":"Mon","y":412,"series":"p95"},{"x":"Tue","y":398,"series":"p95"},{"x":"Wed","y":281,"series":"p95"},
              {"x":"Thu","y":262,"series":"p95"},{"x":"Fri","y":255,"series":"p95"},
              {"x":"Mon","y":180,"series":"p50"},{"x":"Tue","y":176,"series":"p50"},{"x":"Wed","y":121,"series":"p50"},
              {"x":"Thu","y":118,"series":"p50"},{"x":"Fri","y":115,"series":"p50"}]}
            ```

            | Endpoint | Before | After |
            |:--|--:|--:|
            | `GET /feed` | 520 ms | **240 ms** |
            | `POST /search` | 610 ms | **455 ms** |

            > Next: warm the cache on deploy so Monday mornings stay fast.
            """),
        ]
    }
}

extension VoiceController {
    func previewListening(_ text: String?, level: Float = 0.6) {
        if let text {
            phase = .listening
            transcript = text
            self.level = level
        } else {
            phase = .idle
            transcript = ""
        }
    }
}

/// Debug-only: `NOTCHCLAW_AUTOSEND="text"` sends a message after connecting and prints state.
@MainActor
enum DebugHooks {
    static func install(_ model: AppModel) {
        if ProcessInfo.processInfo.environment["NOTCHCLAW_SCROLL_TEST"] != nil {
            // Hosts the chat in a real window and drives it with scroll-wheel events.
            Task {
                model.session.items = (0..<30).map { i in
                    ChatItem(id: "\(i)", role: i.isMultiple(of: 2) ? .user : .assistant,
                             text: "Message \(i): " + String(repeating: "lorem ipsum ", count: 12))
                }
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 360),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: ConversationView(app: model, maxHeight: 320)
                    .frame(width: 540).background(.black).environment(\.colorScheme, .dark))
                window.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))
                func find(_ view: NSView) -> NSScrollView? {
                    if let s = view as? NSScrollView { return s }
                    for sub in view.subviews { if let s = find(sub) { return s } }
                    return nil
                }
                guard let scroll = find(window.contentView!) else { print("NO SCROLLVIEW"); exit(1) }
                print("SCROLLER style=\(scroll.scrollerStyle == .overlay ? "overlay" : "legacy") vertical=\(scroll.verticalScroller.map { String(describing: type(of: $0)) } ?? "none") hasVertical=\(scroll.hasVerticalScroller)")
                let before = scroll.contentView.bounds.origin.y
                // Trackpad-like gesture: continuous pixel deltas with began/changed/ended phases.
                let phases: [Int64] = [1, 2, 2, 2, 2, 2, 4]
                for phase in phases {
                    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                     wheel1: phase == 4 ? 0 : 40, wheel2: 0, wheel3: 0)!
                    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                    if let event = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: event) }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                // Programmatic scroll to the top (like a user reading history).
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .milliseconds(800))
                let after = scroll.contentView.bounds.origin.y
                print("SCROLL offset before=\(Int(before)) after=\(Int(after)) moved=\(abs(after - before) > 1)")
                if let dir = ProcessInfo.processInfo.environment["NOTCHCLAW_SCROLL_PNG"],
                   let rep = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
                    window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir))
                }
                fflush(stdout)
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["NOTCHCLAW_PROGRESS_TEST"] != nil {
            // Samples the live progress while the mock gateway narrates a run.
            Task {
                while !model.gateway.state.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                model.notch.expand(page: .chat)
                model.session.send("what's my day tomorrow?")
                for at in [0.3, 0.7, 1.2, 2.4, 3.8, 5.0, 6.0] {
                    try? await Task.sleep(until: .now + .seconds(at == 0.3 ? 0.3 : 0), clock: .continuous)
                    try? await Task.sleep(for: .seconds(at == 0.3 ? 0 : 0.6))
                    let p = model.session.progress
                    print("t+\(at)s activity=\(model.session.activity) headline=\(p.headline ?? "-") steps=\(p.steps.map { ($0.isActive ? "▶︎" : "✓") + $0.title }) plan=\(p.plan.map { "\($0.status):\($0.text)" })")
                    if at == 2.4, let dir = ProcessInfo.processInfo.environment["NOTCHCLAW_PROGRESS_PNG"] {
                        for (name, page) in [("progress-chat", NotchViewModel.Page.chat), ("progress-home", .home)] {
                            model.notch.page = page
                            let view = NotchRootView(app: model).frame(width: 760, height: page == .chat ? 520 : 330)
                                .background(Color(white: 0.3)).environment(\.notchSnapshot, true)
                            let renderer = ImageRenderer(content: view)
                            renderer.scale = 2
                            if let image = renderer.nsImage, let data = ImageExport.pngData(image) {
                                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                            }
                        }
                        model.notch.page = .chat
                    }
                }
                fflush(stdout)
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["NOTCHCLAW_GLOW_TEST"] != nil {
            // Reply while minimized must glow; replays after the user has looked must not.
            Task {
                while !model.gateway.state.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                model.session.send("hello")
                try? await Task.sleep(for: .seconds(2))
                print("AFTER-REPLY attention=\(String(describing: model.session.attention)) items=\(model.session.items.count)")
                // The user opens the notch, reads the chat, and minimizes it again.
                model.notch.expand(page: .chat)
                model.session.clearAttention()
                try? await Task.sleep(for: .milliseconds(300))
                model.notch.collapse()
                try? await Task.sleep(for: .seconds(3.5))
                print("AFTER-REPLAYS attention=\(String(describing: model.session.attention)) items=\(model.session.items.count) assistants=\(model.session.items.filter { $0.role == .assistant }.map { $0.text.prefix(12) })")
                fflush(stdout)
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["NOTCHCLAW_SESSIONS_TEST"] != nil {
            // Exercises list → create → switch back against the mock gateway.
            Task {
                while !model.gateway.state.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                print("START key=\(model.settings.resolvedSessionKey) title=\(model.session.currentSessionTitle) list=\(model.session.sessions.map(\.title))")
                model.session.createSession()
                try? await Task.sleep(for: .seconds(2))
                print("CREATED key=\(model.settings.resolvedSessionKey) title=\(model.session.currentSessionTitle) list=\(model.session.sessions.map(\.title)) toast=\(model.session.toast ?? "-")")
                model.session.switchSession(to: "agent:main:main")
                try? await Task.sleep(for: .seconds(1.5))
                print("SWITCHED key=\(model.settings.resolvedSessionKey) title=\(model.session.currentSessionTitle) items=\(model.session.items.count)")
                model.settings.sessionKey = "main"
                fflush(stdout)
                exit(0)
            }
            return
        }
        if let method = ProcessInfo.processInfo.environment["NOTCHCLAW_DEBUG_RPC"] {
            // Calls one RPC and writes the raw result (for checking payload shapes).
            Task {
                while !model.gateway.state.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
                let params = ProcessInfo.processInfo.environment["NOTCHCLAW_DEBUG_PARAMS"]
                    .flatMap { try? JSON.decode(Data($0.utf8)) } ?? .object([:])
                let out = ProcessInfo.processInfo.environment["NOTCHCLAW_DEBUG_OUT"] ?? "/dev/stdout"
                do {
                    let result = try await model.gateway.request(method, params, timeout: 30)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(result).write(to: URL(fileURLWithPath: out))
                    print("RPC OK \(out)")
                } catch {
                    print("RPC ERROR \(error)")
                }
                fflush(stdout)
                exit(0)
            }
            return
        }
        if let approvalFile = ProcessInfo.processInfo.environment["NOTCHCLAW_ADMIN_TEST"] {
            // Walks the admin-upgrade flow against the mock gateway and prints each state.
            Task {
                var last = ""
                @MainActor func report(_ tag: String) {
                    let line = "\(model.gateway.state) admin=\(model.gateway.adminAccess) hasAdmin=\(model.gateway.hasAdmin)"
                    if line != last { print("\(tag) \(line)"); last = line }
                }
                model.session.resetSession()  // before approval: should be refused politely
                for tick in 0..<80 {
                    try? await Task.sleep(for: .milliseconds(500))
                    report("T\(tick)")
                    if tick == 6 {
                        model.session.resetSession()
                        print("TOAST \(model.session.toast ?? "-")")
                    }
                    if tick == 10 { FileManager.default.createFile(atPath: approvalFile, contents: Data()); print("APPROVED") }
                    if model.gateway.hasAdmin, model.gateway.state.isConnected {
                        model.session.resetSession()
                        try? await Task.sleep(for: .seconds(1.5))
                        print("TOAST \(model.session.toast ?? "-")")
                        break
                    }
                }
                fflush(stdout)
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["NOTCHCLAW_CHECK_IMAGES"] != nil {
            // Loads history the normal way and reports which agent images actually decode.
            Task {
                while !model.session.historyLoaded { try? await Task.sleep(for: .milliseconds(200)) }
                let attachments = model.session.items.flatMap(\.images)
                print("ATTACHMENTS \(attachments.count)")
                attachments.forEach(model.session.loadImage)
                for _ in 0..<60 where model.session.images.count < attachments.count {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                for attachment in attachments {
                    let size = model.session.images[attachment.id]?.size
                    print("IMAGE \(attachment.id.prefix(48)) -> \(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "NOT LOADED")")
                }
                if let out = ProcessInfo.processInfo.environment["NOTCHCLAW_CHECK_IMAGES_PNG"] {
                    model.notch.expand(page: .chat)
                    model.session.items = Array(model.session.items.suffix(2))
                    let view = NotchRootView(app: model).frame(width: 760, height: 640)
                        .background(Color(white: 0.3)).environment(\.notchSnapshot, true)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    if let image = renderer.nsImage, let data = ImageExport.pngData(image) {
                        try? data.write(to: URL(fileURLWithPath: out))
                    }
                }
                fflush(stdout)
                exit(0)
            }
            return
        }
        if let path = ProcessInfo.processInfo.environment["NOTCHCLAW_DUMP_HISTORY"] {
            // Writes the raw chat.history payload for inspecting message/attachment shapes.
            Task {
                while !model.gateway.state.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
                let result = try? await model.gateway.request(
                    "chat.history", ["sessionKey": .string(model.session.sessionKey), "limit": 8], timeout: 30)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try? encoder.encode(result ?? .null).write(to: URL(fileURLWithPath: path))
                print("DUMPED \(path)")
                fflush(stdout)
                exit(0)
            }
            return
        }
        guard let text = ProcessInfo.processInfo.environment["NOTCHCLAW_AUTOSEND"] else { return }
        Task {
            while !model.gateway.state.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1))
            model.session.send(text)
            try? await Task.sleep(for: .seconds(2.5))
            for item in model.session.items { item.images.forEach(model.session.loadImage) }
            try? await Task.sleep(for: .seconds(1))
            let s = model.session
            print("STATE \(model.gateway.state) page=\(model.notch.page) expanded=\(model.notch.isExpanded) pending=\(model.notch.chatPending)")
            print("ITEMS \(s.items.map { "\($0.role):\($0.text.prefix(40)) images=\($0.images.count)" })")
            print("USAGE \(String(describing: s.usage?.windows.map { "\($0.label)=\($0.usedPercent)" }))")
            print("MODELS \(s.models.map(\.id)) SETTINGS \(s.sessionSettings.modelRef ?? "-") \(s.sessionSettings.thinkingLevel ?? "-")")
            print("IMAGES loaded=\(s.images.count)")
            print("ATTENTION \(String(describing: s.attention)) ACTIVITY \(s.activity)")
            fflush(stdout)
            exit(0)
        }
    }
}
#endif
