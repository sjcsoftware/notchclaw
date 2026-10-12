<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="NotchClaw icon">
</p>

<h1 align="center">NotchClaw</h1>

<p align="center">
  <b>Talk to your <a href="https://github.com/openclaw/openclaw">OpenClaw</a> agent from the MacBook notch.</b><br>
  Hover to open, hold a key to speak, and watch replies stream in as rich Markdown, charts, and images.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-black">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white">
  <img alt="Dependencies" src="https://img.shields.io/badge/dependencies-0-brightgreen">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <img src="docs/images/home.png" alt="NotchClaw's home screen open under the notch" width="820">
</p>

## Features

- **Lives in the notch.** Minimized, it's just a black extension of the notch. Hover and it springs open, then folds away when you move on.
- **Hold to talk.** Hold <kbd>⌥ Space</kbd> anywhere: the notch opens, the agent's emoji ripples with your voice, and your words are transcribed live in a speech bubble. Release to send.
- **Voice controls.** Say "set effort to high", "switch model to sonnet", "compact the context", "new session", or "stop".
- **Rich replies.** Answers render as Markdown with tables, code blocks (with copy), quotes, and task lists. Data shows up as **native charts**, and generated **images** appear inline.
- **Neon glow.** When the agent replies or needs your approval while you're elsewhere, the notch glows with a Siri-style spectrum.
- **Session controls at a glance.** Model, reasoning effort, compaction (with a context-usage ring), and new session all sit next to the agent.
- **Codex usage meter.** If your agent uses a ChatGPT/Codex login, the header shows your 5-hour, daily, or weekly usage.
- **Exec approvals.** Approve or deny shell commands the agent wants to run, right from the notch.
- **Resilient.** It reconnects in under a second when Wi‑Fi returns or the Mac wakes, and shows a calm offline state in between.
- **Native and small.** Swift, SwiftUI, and AppKit with zero third-party dependencies, at about 2 MB.

<table>
  <tr>
    <td width="50%"><img src="docs/images/listening.png" alt="Listening: rings around the agent and live transcription"></td>
    <td width="50%"><img src="docs/images/thinking.png" alt="Thinking: orbiting rings while the agent works"></td>
  </tr>
  <tr>
    <td align="center"><sub>Hold <kbd>⌥ Space</kbd> to speak. Your words appear live.</sub></td>
    <td align="center"><sub>The agent's rings orbit while it thinks.</sub></td>
  </tr>
</table>

<p align="center">
  <img src="docs/images/chat.png" alt="Chat screen with a Markdown reply, a native line chart, and a table" width="820"><br>
  <sub>Replies land in the chat screen as Markdown, tables, and native charts.</sub>
</p>

<p align="center">
  <img src="docs/images/minimized-glow.png" alt="Minimized notch glowing after a reply" width="820"><br>
  <sub>Minimized, the notch glows when there's something new.</sub>
</p>

## Requirements

- A Mac with Apple Silicon running **macOS 14 Sonoma or later**. Notch Macs get the full effect; on other displays NotchClaw sits at the top center of the screen.
- A running **OpenClaw gateway** (protocol v4, OpenClaw 2026.8 or newer), either on this Mac or reachable over your LAN or tailnet.

## Install

1. Download the latest `NotchClaw-x.y.z.dmg` from [**Releases**](https://github.com/chaseungjoon/notchclaw/releases).
2. Open it and drag **NotchClaw** into **Applications**.
3. Launch it. Release builds are ad-hoc signed rather than notarized, so on first launch either:
   - right-click NotchClaw in Applications, choose **Open**, then **Open** again, **or**
   - go to **System Settings › Privacy & Security** and click **Open Anyway**, **or**
   - run `xattr -dr com.apple.quarantine /Applications/NotchClaw.app`.

### Build from source

You only need the Xcode **Command Line Tools**; the full Xcode app isn't required.

```bash
git clone https://github.com/chaseungjoon/notchclaw.git
cd notchclaw
scripts/build.sh            # → dist/NotchClaw.app and dist/NotchClaw-<version>.dmg
open dist/NotchClaw.app
```

## Set up

NotchClaw opens **Settings** on first launch. You can reopen it any time with <kbd>⌘ ,</kbd>, from the gear on the notch, or from the menu bar icon.

1. **Gateway URL.** For a gateway on this Mac, use `ws://127.0.0.1:18789`. For another machine, use something like `ws://192.168.1.20:18789` or `wss://claw.your-tailnet.ts.net`. `http(s)://` and bare `host:port` work too.
2. **Token.** This is your gateway's shared secret: the `gateway.auth.token` you chose during `openclaw onboard`, stored in `~/.openclaw/openclaw.json`. `openclaw config get` redacts secrets, so read it from that file or from wherever you keep it.
3. **Session.** Leave this as `main` to talk to your agent's main session, or enter any session key.
4. Click **Save & Connect**.

**Remote gateways need a one-time approval.** NotchClaw signs in with its own device identity, so the gateway asks you to approve it. The notch shows the exact command; run it on the gateway host:

```bash
openclaw devices list
openclaw devices approve <requestId>
```

NotchClaw connects by itself once you approve it. Connections from the same machine (loopback) are approved automatically.

**Voice permissions.** The first time you hold the shortcut, macOS asks for **Microphone** and **Speech Recognition** access. Allow both, then hold the shortcut again.

## Use

| Do this | To |
| --- | --- |
| Hover over the notch | Open the default screen (agent, controls, usage) |
| Hold <kbd>⌥ Space</kbd> (or click the agent) | Talk; release to send |
| Click **Chat** | Open the conversation and type (<kbd>↩</kbd> sends, <kbd>⌥ ↩</kbd> adds a new line) |
| Click the model name or **Model** | Switch models (from the gateway's catalog) |
| **Effort** | Set reasoning effort (off → xhigh) |
| **Compact** | Summarize old context; the ring shows how full the context window is |
| **New session** | Reset the session |
| Click the usage meter | Choose the 5h, daily, or weekly Codex window |
| <kbd>Esc</kbd> in chat | Clear the draft, or go back home |
| Move the pointer away or click elsewhere | Minimize (the 📌 pin in chat keeps it open) |

**Voice commands.** Short phrases are treated as controls instead of messages:

| Say | Effect |
| --- | --- |
| "set effort to high", "thinking max" | Reasoning effort |
| "switch model to sonnet", "use gpt five codex model" | Model (fuzzy-matched) |
| "compact the context" | Compaction |
| "new session", "start over" | Reset |
| "stop" | Abort the current reply |

Everything else is sent to your agent.

## Charts and images in replies

**Charts need no setup.** Each message sent from NotchClaw carries a short formatting note asking the agent to reply in Markdown. When numbers help, the note also asks for a fenced `chart` block, which NotchClaw draws with Swift Charts:

````markdown
```chart
{"type": "bar", "title": "Weekly signups", "x": "Week", "y": "Signups",
 "data": [{"x": "W1", "y": 120}, {"x": "W2", "y": 180}, {"x": "W3", "y": 240, "series": "optional"}]}
```
````

Supported types are `bar`, `line`, `area`, `point`, and `pie`. Add `series` for multiple lines or bars. If the JSON is malformed, the block is shown as code. You can turn the note off in **Settings › Agent**.

**Images use OpenClaw's `image_generate` tool.** It's available whenever an image provider is configured. If your agent signs in with **ChatGPT/Codex OAuth**, `openai/gpt-image-2` already works with no extra keys. Otherwise, set an `OPENAI_API_KEY` (or a Gemini or OpenRouter key) and optionally pick a default model:

```json5
// ~/.openclaw/openclaw.json
{ agents: { defaults: { mediaModels: { image: { primary: "openai/gpt-image-2" } } } } }
```

Generated images appear inline in the chat. Click one to open it in Preview, or right-click to copy or save it.

> **Where do standing instructions go?** In OpenClaw, `MEMORY.md` is for durable facts and decisions, not behaviour. If you want charts and images on every channel (Telegram, WhatsApp, and so on), add a line to your workspace's **`AGENTS.md`** instead, for example: *"When data is easier to grasp visually, include a chart; when a picture would help, use image_generate."* Inside NotchClaw you don't need this, because the per-message note already covers it.

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

## Privacy and security

- The gateway token and device key are stored in `~/Library/Application Support/NotchClaw/credentials.json` with `0600` permissions.
- Speech is transcribed by Apple's Speech framework, on-device when the model is available. Audio is only captured while you hold the shortcut.
- NotchClaw talks only to the gateway you configure. It has no analytics or telemetry.

## Development

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

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. The original product brief lives in [docs/IDEA.md](docs/IDEA.md).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "Approve this Mac on your gateway" | Run `openclaw devices approve <id>` on the gateway host |
| "Gateway token doesn't match" | Re-enter `gateway.auth.token` in Settings › Gateway |
| Holding <kbd>⌥ Space</kbd> does nothing | Another app may own that shortcut (Settings › Voice warns about this); pick a different one |
| "Turn on Dictation…" in the bubble | Enable **System Settings › Keyboard › Dictation**, or allow Speech Recognition |
| No usage meter | The gateway's model isn't using a Codex/ChatGPT login, or **Show Codex usage** is off |
| macOS asks for mic access again after an update | Expected with ad-hoc signed builds; each build is a new signature |

## Acknowledgments

- [OpenClaw](https://github.com/openclaw/openclaw), the personal agent and gateway this app drives.
- [boring.notch](https://github.com/TheBoredTeam/boring.notch), whose notch window and shape techniques inspired NotchClaw.

## License

[MIT](LICENSE) © 2026 chaseungjoon
