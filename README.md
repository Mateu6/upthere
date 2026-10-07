# Upthere

A tiny, native macOS notch app: **what's playing** on the right of the notch,
**what Claude Code is doing** on the left. Hover to peek, click to expand.
It never drops below the notch, so it just looks like the notch grew ears.

- **Now Playing:** Spotify, Music, and (optionally) any other player. Includes artwork, transport controls, a seek bar and a live progress line.
- **Player filter:** exclude browsers, or allow only chosen apps, plus a *pinned player*. Play/pause goes to Spotify even while a YouTube tab is playing.
- **Claude Code:** thinking / running `Edit · App.swift` / **needs permission** (auto-peeks, amber) / done. Also shows the session title, model, context size and the last message.
- **Fast:** Swift + AppKit + SwiftUI, with no polling anywhere.
  - Collapsed with music playing, it uses **0.0% CPU** and about 17 MB.
  - Animations run as Core Animation layer animations on the render server.

## How it works

| Piece | Mechanism |
| --- | --- |
| Notch window | Two non-activating `NSPanel`s (one per ear). They stay at the menu-bar level on all Spaces, and each frame hugs its ear so the rest of the menu bar stays clickable. |
| Now Playing (all players) | [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter): one long-lived `/usr/bin/perl` child streams MediaRemote changes as JSON. This is needed because macOS 15.4+ restricts MediaRemote to entitled processes. |
| Spotify / Music | Distributed notifications for state; AppleScript (`osascript`) for commands. It never launches the apps. |
| Claude Code | Hooks in `~/.claude/settings.json` run `upthere-hook`, which sends one message to a Unix socket in about 1 ms and always exits 0. The app also tails only the active session transcripts for title, model and last message. |
| Progress & spinners | `CABasicAnimation`s: zero per-frame work in the app. |

## Build

Requirements: macOS 26+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), CMake.

```bash
brew install xcodegen cmake
git clone --recursive https://github.com/Mateu6/upthere.git && cd upthere
xcodegen generate
xcodebuild -scheme Upthere -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Upthere.app
```

Builds are ad-hoc signed by default. To sign with your own team, create `Config/Local.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Developer ID Application
```

Run the tests with `xcodebuild -scheme Upthere -derivedDataPath build/DerivedData test`.

### Connect Claude Code

Right-click the notch → **Settings… → Connect Claude Code**. This adds hooks
for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`Notification`, `Stop`, `SubagentStop`, `PreCompact` and `SessionEnd`, and
saves a backup as `~/.claude/settings.json.upthere-backup`. **Disconnect**
removes only Upthere's entries.

### Permissions

The first time Upthere controls Spotify or Music, macOS asks for
**Automation** permission. Nothing else is required: no Accessibility, no
Screen Recording.

## Project layout

```
Upthere/App          entry point, preferences
Upthere/Notch        panels, geometry, layout/hover state
Upthere/UI           SwiftUI ear views + Core Animation layer views
Upthere/NowPlaying   adapter + native sources, arbiter, artwork
Upthere/Claude       socket hub, hook events, session state, transcript tailer, hook installer
UpthereHook          the tiny Foundation-free hook CLI
Vendor/              mediaremote-adapter (git submodule)
```

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled components.
