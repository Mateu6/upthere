# Upthere

A tiny, native macOS notch app: **what's playing**, **what Claude Code is
doing** and **your timers**, right beside the notch. Hover to peek, click to
act. It never drops below the notch, so it just looks like the notch grew ears.

- **Now Playing:** Spotify, Music and (optionally) any other player, with artwork, controls and a seek bar you can always grab. Scroll sideways to seek and up/down for volume. Sound bars can follow the actual audio.
- **Up Next:** the upcoming songs beside the cover; click one to jump straight to it (Spotify via its Web API, Music via AppleScript).
- **Claude Code:** thinking / running `Edit · App.swift` / **needs permission** (amber) / **asking you something** (blue) / done, with the chat title, model, context and plan limits (session and weekly, like the Claude app). Click to open that exact chat; scroll to switch chats.
- **Timers:** count-ups to log what you're doing and countdowns for what you're waiting on, several at once. Press **⌥⌘T** anywhere, type `waiting for CI 15m`, and each finished timer can become a Calendar event.
- **Screens without a notch:** Claude, music and timers sit side by side as one centered pill, with your choice of center piece.
- **Themes:** Classic (black), Aurora (artwork-tinted) and Glass (native Liquid Glass).
- **Fast:** Swift + AppKit + SwiftUI, with no polling. Idle, it uses ~0% CPU; ear animations are Core Animation springs on the render server at your display's refresh rate.

## Install

```bash
brew install --cask mateu6/tap/upthere
```

Or download the DMG from [Releases](https://github.com/Mateu6/upthere/releases). Upthere updates itself (Sparkle).
It isn't notarized yet: if macOS blocks the first launch, use System Settings → Privacy & Security → Open Anyway.

Requires macOS 26 (Tahoe) or later. Right-click the notch for **Settings…**.

## Setup

### Claude Code

**Settings → Agents → Connect Claude Code** adds hooks for `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`,
`SubagentStop`, `PreCompact` and `SessionEnd` to `~/.claude/settings.json`
(with a backup at `~/.claude/settings.json.upthere-backup`). **Disconnect**
removes only Upthere's entries. Works with Claude Code in a terminal, in
editors and in the Claude app.

Plan limits (**Settings → Claude info**) come from one of:

- **Read plan limits from my Claude login** (opt-in): reads Claude Code's login from the Keychain, read-only, and asks `api.anthropic.com` for the same numbers the Claude app shows. It never refreshes or changes the login. macOS asks once to allow it.
- **Connect status line** (terminal sessions): Claude Code passes its limits to the status line, which forwards them and then runs your previous status line unchanged.

### Up Next with Spotify

Spotify's queue needs your own (free) Spotify app:

1. Create an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) with the redirect URI `http://127.0.0.1:47863/callback` and the Web API enabled.
2. Paste its **Client ID** in **Settings → Up Next** and click **Connect Spotify**.

Jumping to a song needs Spotify Premium. The login is stored in a file only
your account can read (`~/Library/Application Support/upthere/secrets`), and
can be revoked anytime on Spotify's Apps page.

### Timers

**⌥⌘T** (changeable in Settings) opens a field under the notch. A duration at
the end makes a countdown (`tea 4m`, `deploy 1h30m`); without one it counts up.
Up to six run at once, each color-coded; pin the ones you want to stay
visible. Stopping one can add a Calendar event (Settings → Timers).

### Permissions

macOS asks only when a feature needs it:

| Permission | When |
| --- | --- |
| Automation (Spotify, Music) | First time Upthere controls them, or reads Music's queue |
| Audio capture | Only if you turn on the live visualizer; audio is captured only while the sound bars are on screen |
| Calendars | Only if you turn on Calendar logging for timers |

No Accessibility, no Screen Recording.

## How it works

| Piece | Mechanism |
| --- | --- |
| Notch window | Two non-activating `NSPanel`s (one per ear) at the menu-bar level on all Spaces. Each frame hugs its ear, so the rest of the menu bar stays clickable; a Core Animation mask springs the ear open and closed. |
| Now Playing (all players) | [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter): one long-lived `/usr/bin/perl` child streams MediaRemote changes as JSON, needed because macOS 15.4+ restricts MediaRemote to entitled processes. |
| Spotify / Music | Distributed notifications for state; AppleScript (`osascript`) for commands. It never launches the apps. |
| Live visualizer | A Core Audio process tap on the player only, analysed with vDSP into four bands. |
| Claude Code | Hooks run `upthere-hook`, a Foundation-free CLI that sends one message to a Unix socket in about 1 ms and always exits 0. The app tails only active transcripts for title, model and last message. |
| Global shortcut | Carbon `RegisterEventHotKey` (no Accessibility needed). |
| Progress, rings & spinners | `CABasicAnimation`s: zero per-frame work in the app. |

## Build

Requirements: macOS 26+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), CMake.

```bash
brew install xcodegen cmake
git clone --recursive https://github.com/Mateu6/upthere.git && cd upthere
xcodegen generate
xcodebuild -scheme Upthere -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Upthere.app
```

Run the tests with `xcodebuild -scheme Upthere -derivedDataPath build/DerivedData test`.

Builds are ad-hoc signed by default. macOS ties Keychain approvals to the
signature, so for development use a stable identity in `Config/Local.xcconfig`
(gitignored). A self-signed code-signing certificate is enough:

```
CODE_SIGN_IDENTITY = Upthere Local
```

or your Developer ID:

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Developer ID Application
ENABLE_HARDENED_RUNTIME = YES
```

Releases are built by [`.github/workflows/release.yml`](.github/workflows/release.yml)
when a `v*` tag is pushed: DMG, signed Sparkle appcast and a Homebrew cask bump
([Mateu6/homebrew-tap](https://github.com/Mateu6/homebrew-tap)).

## Project layout

```
Upthere/App          entry point, preferences
Upthere/Notch        panels, geometry, layout and hover state
Upthere/UI           SwiftUI ear views + Core Animation layer views
Upthere/NowPlaying   adapter + native sources, artwork, visualizer, Up Next
Upthere/Claude       socket hub, hook events, sessions, transcripts, usage
Upthere/Timer        timers, parser, global shortcut, input field, Calendar
Upthere/Settings     settings window
Upthere/Updates      Sparkle
UpthereHook          the tiny Foundation-free hook CLI
Vendor/              mediaremote-adapter (git submodule)
```

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled components.
