# Contributing to NotchClaw

Thanks for helping! NotchClaw is a small, dependency-free macOS app, and we'd like to keep it that way.

## Getting started

```bash
scripts/test.sh     # run the test suite
scripts/build.sh    # build dist/NotchClaw.app and a DMG
```

Only the Xcode Command Line Tools are needed. The build scripts select the macOS 26 SDK when it's present, because the macOS 27 SDK's SwiftUI macros ship only with full Xcode.

To work on gateway features without a real agent, run the schema-validating mock in `tools/mock-gateway` (see the README).

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
