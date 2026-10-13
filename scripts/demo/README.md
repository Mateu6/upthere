# Demo recordings

Scripted scenes on the real notch, one full-screen take each, cut into:

| Output | Size | For |
| --- | --- | --- |
| `<scene>.gif` | 1000 px wide, menu-bar strip | GitHub README |
| `<scene>-reel.mp4` | 1080×1920, camera push-ins, caption | Reels, TikTok, Shorts |
| `<scene>-wide.mp4` | 1920×1080, camera push-ins, caption | X, LinkedIn, YouTube |
| `<scene>-square.mp4` | 1080×1080, camera push-ins, caption | X, LinkedIn feed |

Claude Code activity is staged: `demo.py` sends hook events to the app's
socket and writes a fake transcript (title, model, context, last message).
While recording, the app shows only `demo-…` sessions, so real Claude Code
sessions on the machine don't leak in. Music is your real Spotify.

## Setup (once)

```bash
brew install ffmpeg gifski
xcodebuild -scheme Upthere -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Upthere.app
```

The app that runs `demo.py` (Terminal, Claude, …) needs **Screen Recording**
permission, and **Automation → Spotify** for the music scenes.

## Before each take

Every output is just the menu-bar strip of the take (the ears never go below
it) on an indigo backdrop, so windows and the desktop never show. The menu
bar itself does: keep status items you don't want public out of it, and
start Spotify on a track with good artwork (or pass `--track spotify:track:…`).

## Commands

```bash
scripts/demo/demo.py list                      # scenes and their length
scripts/demo/demo.py run hero                  # rehearse, nothing recorded
scripts/demo/demo.py record hero music-hover   # raw takes → build/demo/raw
scripts/demo/demo.py render hero               # → build/demo/out
scripts/demo/demo.py render hero --formats gif
scripts/demo/demo.py showreel reel short           # the ~30 s cut, intro + outro cards
scripts/demo/demo.py showreel wide hero@0.5-15.4 music-hover   # any scenes, trimmed or not
```

## Adding a scene

Scenes are plain functions in `demo.py`, decorated with `@scene(caption, subtitle)`.
Use `d.wait(s)` for timing, `d.notch(mode)` for any DebugBridge mode
(`peek-left`, `expanded`, `theme-aurora`, `timer:tea for 4`, …),
`d.start_music()` / `d.spotify("pause")`, and `d.session(title=…)` for a Claude
session (`prompt`, `tool`, `ask_permission`, `ask`, `say`, `stop`).
`d.camera("left" | "right" | "wide" | "timers")` eases the reel's camera onto
that part of the notch (presets in `CAMERAS`); `@scene(camera=…)` sets where it
starts. `gif_width` sets how much of the menu bar the GIF shows, in points around the notch.

## Showreels

`showreel <reel|wide|square>` cross-fades scenes between an intro and an
outro card (`--no-cards` to skip them). `scene@in-out` trims a scene to
seconds from its start; named cuts live in `CUTS`, card text in `CARDS`.
