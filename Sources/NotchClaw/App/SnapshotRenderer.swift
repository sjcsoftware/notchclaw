#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders notch states to PNGs for visual review.
/// Run: NOTCHCLAW_SNAPSHOT_DIR=/tmp/shots .build/debug/NotchClaw
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["NOTCHCLAW_SNAPSHOT_DIR"] else { return false }
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let model = AppModel()
        model.notch.geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956), notchWidth: 185, notchHeight: 32, hasNotch: true)
        model.session.loadPreviewContent()

        render(model, page: nil, name: "closed", url: url)
        model.notch.expand(page: .home)
        render(model, page: .home, name: "home", url: url)
        model.voice.previewListening("Hey, what's on my calendar tomorrow and can you summarize it")
        render(model, page: .home, name: "home-listening", url: url)
        model.voice.previewListening(nil)
        render(model, page: .chat, name: "chat", url: url)
        let markdown = MarkdownView(model.session.items.last?.text ?? "")
            .padding(20).frame(width: 560).background(.black).environment(\.colorScheme, .dark)
        save(ImageRenderer(content: markdown), name: "markdown", url: url)
        return true
    }

    private static func render(_ model: AppModel, page: NotchViewModel.Page?, name: String, url: URL) {
        if let page { model.notch.page = page }
        let view = NotchRootView(app: model)
            .frame(width: 900, height: page == .chat ? 620 : 330)
            .background(Color(white: 0.55))
        save(ImageRenderer(content: view), name: name, url: url)
    }

    private static func save<V: View>(_ renderer: ImageRenderer<V>, name: String, url: URL) {
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url.appendingPathComponent("\(name).png"))
    }
}

extension AgentSession {
    func loadPreviewContent() {
        items = [
            ChatItem(id: "1", role: .user, text: "Compare the two deploy options for the API"),
            ChatItem(id: "2", role: .assistant, text: """
            ## Deploy options

            | Option | Cost | Cold start |
            |:--|--:|:--:|
            | **Fly.io** | $12/mo | ~300 ms |
            | **Railway** | $20/mo | none |

            1. Fly is cheaper for bursty traffic.
            2. Railway keeps a warm instance.

            ```bash
            fly deploy --remote-only
            ```

            > Recommendation: start on Fly, revisit at 10k req/day.
            """),
        ]
        usage = UsageInfo(providerName: "Codex", plan: "plus", windows: [
            UsageWindowInfo(label: "5h", usedPercent: 42, resetAt: Date().addingTimeInterval(7200)),
            UsageWindowInfo(label: "Week", usedPercent: 71, resetAt: nil),
        ])
        sessionSettings = SessionSettings(model: "openai-codex/gpt-5.1-codex", thinkingLevel: "high",
                                          totalTokens: 52_000, contextTokens: 200_000)
    }
}

extension VoiceController {
    func previewListening(_ text: String?) {
        if let text {
            phase = .listening
            transcript = text
            level = 0.6
        } else {
            phase = .idle
            transcript = ""
        }
    }
}
#endif

#if DEBUG
/// Debug-only: `NOTCHCLAW_AUTOSEND="text"` sends a message after connecting and prints state.
@MainActor
enum DebugHooks {
    static func install(_ model: AppModel) {
        guard let text = ProcessInfo.processInfo.environment["NOTCHCLAW_AUTOSEND"] else { return }
        Task {
            while !model.gateway.state.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1))
            model.session.send(text)
            try? await Task.sleep(for: .seconds(3))
            let s = model.session
            print("STATE \(model.gateway.state) page=\(model.notch.page) expanded=\(model.notch.isExpanded) pending=\(model.notch.chatPending)")
            print("ITEMS \(s.items.map { "\($0.role):\($0.text.prefix(40))" })")
            print("USAGE \(String(describing: s.usage?.windows.map { "\($0.label)=\($0.usedPercent)" }))")
            print("MODELS \(s.models.map(\.id)) SETTINGS \(s.sessionSettings.modelRef ?? "-") \(s.sessionSettings.thinkingLevel ?? "-")")
            print("ATTENTION \(String(describing: s.attention)) ACTIVITY \(s.activity)")
            fflush(stdout)
            exit(0)
        }
    }
}
#endif
