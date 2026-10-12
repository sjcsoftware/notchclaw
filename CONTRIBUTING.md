# Contributing to NotchClaw

Thanks for helping! NotchClaw is a small, dependency-free macOS app, and we'd like to keep it that way.

- [Development](#development)
- [How it works](#how-it-works)
- [Guidelines](#guidelines)
- [Commits and PRs](#commits-and-prs)
- [Privacy and security](#privacy-and-security)
- [Troubleshooting](#troubleshooting)

## Development

Only the Xcode Command Line Tools are needed. The build scripts select the macOS 26 SDK when it's present, because the macOS 27 SDK's SwiftUI macros ship only with full Xcode.

```bash
scripts/test.sh          # unit tests (Swift Testing; works with just the Command Line Tools)
scripts/build.sh         # release .app + DMG in dist/ (add --desktop to copy the DMG to ~/Desktop)
scripts/screenshots.sh   # regenerate README screenshots and the icon preview
```

**Develop without a real agent.** `tools/mock-gateway` is a fake gateway that checks every request against OpenClaw's published protocol schema and streams a canned reply with a chart and an image:

```bash
cd tools/mock-gateway && npm install && PORT=18799 npm start
# then set the gateway URL in NotchClaw to ws://127.0.0.1:18799
```

The original product brief lives in [docs/IDEA.md](docs/IDEA.md).

## How it works

NotchClaw is an operator client for the [OpenClaw Gateway WebSocket protocol](https://github.com/openclaw/openclaw/tree/main/docs/gateway/protocol) (v4).

```
Sources/NotchClaw/
├── App/        main, AppDelegate (menus, status item, settings window), AppModel (wiring)
├── Gateway/    GatewayClient (handshake, RPC, events, reconnect), DeviceIdentity (Ed25519), JSON
├── Agent/      AgentSession (chat stream, history, approvals, model/effort/compact, usage, images)
├── Notch/      NotchController (panel, hover, click-through), Home/Chat views, glow & animations
├── Markdown/   Block parser, renderer, Swift Charts blocks
├── Voice/      Carbon hold-to-talk hotkey, speech capture, voice-command parser
└── Settings/   Preferences and the Settings window
```

- **Handshake.** NotchClaw waits for `connect.challenge` and signs the challenge-bound payload with a per-install Ed25519 key. It then sends `connect` as an `operator` with `operator.read`, `operator.write`, and `operator.approvals`, and stores the device token the gateway issues.
- **Streaming.** It subscribes with `sessions.messages.subscribe` and renders `chat` events (`delta`, `final`, `error`), restoring history with `chat.history`.
- **Controls** call `sessions.patch` (model, `thinkingLevel`), `sessions.compact`, `sessions.reset`, `chat.abort`, `exec.approval.resolve`, `usage.status`, and `artifacts.download`.
- **Liveness.** A tick and ping watchdog, `NWPathMonitor`, and wake notifications trigger an immediate reconnect, with exponential backoff (up to 10 s) otherwise.
- **The notch** is a borderless, non-activating `NSPanel` above the menu bar. It's click-through everywhere except the visible notch, so it never blocks the apps underneath.

## Guidelines

- **No third-party dependencies.** Use Apple frameworks (SwiftUI, AppKit, Charts, Speech, CryptoKit, Network).
- **Match the surrounding code**: naming, comment density, `@MainActor @Observable` models, and small focused views.
- **Be a good Mac citizen**: support VoiceOver labels, keyboard access, and Reduce Motion for any new animation.
- **Protocol changes**: follow OpenClaw's [gateway protocol docs](https://github.com/openclaw/openclaw/tree/main/docs/gateway/protocol) and check new requests against the mock gateway, which validates them against the published schema.
- **Add tests** for parsing and protocol logic in `Tests/NotchClawTests`.
- **UI changes**: run `scripts/screenshots.sh` and include before/after images in your PR.

## Commits and PRs

- Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat(notch): …`, `fix(voice): …`).
- Keep PRs focused, and describe how you tested (real gateway, mock gateway, or both).

## Privacy and security

- The gateway token and device key are stored in `~/Library/Application Support/NotchClaw/credentials.json` with `0600` permissions.
- Speech is transcribed by **Apple's Speech framework**, on-device when the model is available. Audio is only captured while you hold the shortcut.
- NotchClaw talks only to the gateway you configure. It has no analytics or telemetry.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "Approve this Mac on your gateway" | Run `openclaw devices approve <id>` on the gateway host |
| "Gateway token doesn't match" | Re-enter `gateway.auth.token` in Settings › Gateway |
| Holding <kbd>⌥ Space</kbd> does nothing | Another app may own that shortcut (Settings › Voice warns about this); pick a different one |
| "Turn on Dictation…" in the bubble | Enable **System Settings › Keyboard › Dictation**, or allow Speech Recognition |
| No usage meter | The gateway's model isn't using a Codex/ChatGPT login, or **Show Codex usage** is off |
| macOS asks for mic access again after an update | Expected with ad-hoc signed builds; each build is a new signature |
