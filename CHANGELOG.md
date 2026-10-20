# Changelog

## 0.7.0
- **LaTeX math in replies.** Equations are typeset instead of showing raw TeX. Inline math (`\(…\)`, `$…$`) sits on the text baseline. Display math (`\[…\]`, `$$…$$`, or a bare `\begin{align}`) is centered and scrolls sideways when it's wider than the chat. Supported: fractions, roots, sub- and superscripts, sums and integrals with limits, `\left…\right` delimiters, matrices, `cases`, `aligned`, accents, `\boxed`, `\text`, Greek, `\mathbb`/`\mathcal`/`\mathbf`, and the usual operators and arrows. Math is set in the STIX Two Math font that ships with macOS, with no new dependencies. Prices like "$5 and $10" stay plain text. Right-click an equation to copy its LaTeX.

## 0.6.6
- Fix: you can scroll all the way back through a conversation. NotchClaw used to load only the last 40 transcript rows, and tool calls and results count as rows, so tool-heavy chats showed just a handful of messages. It now loads 150 rows up front and automatically fetches earlier pages when you reach the top (keeping your place), skipping past pages that contain only tool activity. An "Earlier messages" control at the top also loads more on click.

## 0.6.5
- Fix: scrolling in the chat. The panel no longer re-applies its click-through flag on every pointer update (which could cut trackpad scroll gestures off), and scrolls over the open notch that macOS delivers elsewhere are applied to the chat.
- A slim, trackless scrollbar that blends into the notch (thin translucent capsule; brightens on hover; draggable) replaces the hidden one.
- Fix: generated images now appear on live replies. Images committed to the transcript after the reply (under an internal run id) are attached as they arrive via `session.message`, matched by run, caption, or latest reply, with a short transcript re-check as a backstop.

## 0.6.4
- Fix: scrolling works again in the chat. 0.6.3 hid the scrollbar with `.scrollIndicators(.never)`, which on macOS removes the scroller and with it wheel/trackpad scrolling; the scrollbar is now hidden with an invisible overlay scroller instead.
- A **↓ button** appears at the bottom of the chat whenever you've scrolled up; click it to jump to the latest message.
- Auto-scroll is sticky: new reply text only pulls you down if you're already at the bottom, so you can read earlier messages while the agent is replying.

## 0.6.3
- Removed the scrollbar from the chat (and from wide code blocks and tables), including when macOS is set to always show scroll bars.

## 0.6.2
- **Live progress while the agent works.** Instead of sitting on "Waking the model", NotchClaw shows what the agent is doing right now: tool steps as they start and finish (with spinners and checkmarks), the agent's own commentary ("I'll check the logs first…"), its plan, and elapsed time. It's a card in the chat, a one-line caption under the agent on the home screen, and a running-tool line under a streaming reply. NotchClaw now subscribes to OpenClaw's tool-event stream to get this.

## 0.6.1
- Fix: the minimized notch no longer glows when there's no new message. Repeated terminal events for a run, the same reply committed under a second run id, silent runs, and replies you already read now leave the notch dark (and no longer duplicate the reply in chat).
- Fix: a streamed snapshot frame could repeat its last chunk of text.

## 0.6.0
- **Session picker.** The home screen's session tile shows the current session; click it to start a **New session** (no admin needed), jump to a recent session, or reset the current one (admin).
- The usage meter in the header now reads **OpenAI mark · percent · bar**.
- Session lists skip sub-agent and cron sessions and use parameters older gateways accept.

## 0.5.2
- Fix: opening Chat from the home screen no longer shows a black panel until you scroll.
- New session and Compact need OpenClaw's `operator.admin` scope. **Settings › Gateway › Admin access** can now request it, shows the exact `openclaw devices approve` command to run on the gateway host, keeps NotchClaw working on its current access while approval is pending, and switches over automatically once approved. Without admin, those buttons explain what's needed instead of failing.

## 0.5.1
- Syntax highlighting in code blocks: keywords, strings, numbers, comments, types, functions, built-ins, and decorators, for Python, Swift, JavaScript/TypeScript, shell, JSON, Go, Rust, C-family, Java/Kotlin, Ruby, SQL, YAML, CSS, PHP, and Lua. Unknown languages stay plain.

## 0.5.0
- The minimized notch opens only when the pointer is actually inside it (edges included), not when it passes nearby.
- New **Settings › Notch › Minimized notch size** tuner: adjust width and height with sliders or steppers and watch the notch resize live, outlined in blue, to match your Mac's hardware notch.
- The minimized notch's visible body now defaults to the detected hardware notch size.

## 0.4.1
- Fix: agent-generated images now display. Managed images arrive as short-lived media-ticket URLs, which NotchClaw now fetches from the gateway origin (renewing an expired ticket once); attachments missing from live events are recovered from the transcript.
- Relicensed under GPL-3.0 (previously MIT).
- README: table of contents.

## 0.4.0
- New app icon: a graphite squircle with a lit notch and spectrum claw marks.
- Native charts in replies via ```chart blocks, rendered with Swift Charts (bar, line, area, point, pie).
- Inline images generated by the agent (`image_generate`), loaded with `artifacts.download`; click to open, right-click to copy or save.
- README, screenshots, license, contributing guide, CI, and a schema-validating mock gateway.

## 0.3.2
- Hold-to-talk always opens the default screen; recognition falls back from on-device to server, and errors show in the speech bubble.
- Settings warn when the shortcut is already taken by another app.

## 0.3.1
- More natural side margins; removed the ring around the agent emoji.

## 0.3.0
- Header redesigned as "Name · model ··· n% usage"; polished controls.

## 0.2.0
- New default screen with the agent in the middle and controls around it; chat opens on demand.
- Minimized notch is a plain black box; replies glow and open in chat.
- Fixed the panel collapsing while reaching for buttons.

## 0.1.0
- First version: gateway client, notch overlay, chat, voice, usage, settings.
