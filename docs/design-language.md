# Upthere design language

Status: **direction chosen, being rolled out** (2026-10-16). The icon is
parked (see `parked.md`).

## Decisions (round 1)

- **Ears: direction B, Instrument.** Titles 12 Medium (−0.005em), secondary
  10.5 Regular at 56%, numbers in SF Mono 10, and only three sizes
  (12 · 10.5 · 9). Glass is thick: a dark base for legibility, strong blur and
  saturation, a rim on three edges and a soft shadow. Motion: open 0.26 s,
  close 0.19 s, zero bounce, content slides 8 px out with the shape, and an
  interrupted ear keeps its velocity.
  *Why:* it matches "rigid" and "polished". It reads as a precise tool rather
  than a toy.
- **Settings: five tabs** (General · Appearance · Music · Claude · Timers),
  using the standard macOS toolbar tabs, with the setting people change most
  first in each tab. MediaRemote adapter and Pinned player go under Advanced
  in the Music tab.
- **Icon: parked.** Neither round 1 nor round 2 was chosen. See `parked.md`.

## Tokens (as built)

**Type** (`Upthere/UI/Typography.swift`, `Theme.TextStyle`):

| Token | Font | Used for |
|---|---|---|
| `title` | SF 12 Medium | project, track, plan name, one-line rows |
| `body` | SF 10.5 Regular | status line, artist, hints |
| `label` | SF 10.5 Medium | timer labels, Up Next titles |
| `caption` | SF 9 Regular | Up Next artist |
| `badge` | SF 9 Bold | "+2" counts |
| `figure` | SF Mono 10 Medium | times, seek position, HUD value |
| `readout` | SF Mono 12 Medium | a running timer's main readout |
| `chip` | SF 10.5 Regular, tabular digits | usage chips ("12.6M tok · ctx 27%") |

Secondary text is white at 56% (`Theme.secondary`). The −0.005em title
tracking from the mock was left out: at 12 pt it's 0.06 pt and invisible.

**Motion** (`Theme` in `UI/EarRootView.swift`, `UI/EarMotion.swift`):
- Ear open 0.26 s, close 0.19 s, zero bounce. The CA mask and the SwiftUI
  widths (`.earSpring(value:)`) pick the same spring by direction.
- Velocity: `EarWindow` solves the spring in closed form (`EarMotion`) and
  passes the current speed to the next spring as `initialVelocity`.
- Content: `.earContent(side)` blurs in and slides 8 pt out from the notch,
  and leaves with a plain blur. Swaps run on `Theme.contentSwap` (0.24 s), so
  the shape leads and the content follows.

**Glass** (`GlassFill`): native `.clear` glass (the strongest lensing) over a
smoky base (`Theme.glassBase`, 24% black), with a cover-colour wash of 0.45
and a glass tint of 0.35. The mock's drop shadow was left out: the panel
hugs the ear, so a shadow would be clipped.

**Settings:** `NSTabViewController` with toolbar tabs and one SwiftUI file
per tab in `Upthere/Settings/`. Each tab is as tall as its content, up to
720 pt, and the window title follows the tab. The labels are unchanged. Two
long footers were split between the sections they describe.

## Dos and don'ts

- Do take ear text from `Theme.TextStyle`, and measure it with the same style.
- Do keep mono for figures that tick (times). Words with numbers (chips) use
  tabular SF, because mono was too wide and crowded the status line.
- Don't add bounce to ear layout. Liveliness comes from speed, asymmetry and
  choreography.
- Don't put the Claude spark or other UI glyphs in the app icon (see
  `parked.md`).

## Brief

**Feels:** natural to the system · polished · rigid (precise, nothing wobbly
or loose) · in service of the content.

**Must not feel:** gaming · gimmicky · bolted onto the computer.

**Who and where:** a pro Mac user at a desk (developers using Claude Code,
people who keep music on while they work). They see it hundreds of times a
day out of the corner of their eye, so it has to be calm and readable at a
glance and never ask for attention it doesn't need.

**Reference:** macOS 26 Liquid Glass icons, Maps especially: a few flat,
clearly separated layers stacked with real depth, where the glass does the
rendering and the drawing stays simple.

**Stays:**
- the name Upthere
- the notch-with-ears shape, in the app and as the icon's motif
- the dusk colours (violet → pink → warm orange) and the current palette
- the three themes (Classic, Aurora, Glass) and the notch/notchless layouts
- Claude's brand colour as the Claude *status* colour inside the ears

**Changes (scope):**
1. **App icon:** rebuilt as a layered Icon Composer `.icon` (Liquid Glass,
   with light, dark, tinted and clear versions), drawn by Mateusz in Figma.
   The Claude-like spark leaves the icon.
2. **Ears, light refresh:** type weights and hierarchy, and a more intense
   Glass theme.
3. **Motion:** the ear open and close should feel more lively and natural.
   ⚠️ This touches the CLAUDE.md rule "no bounce on layout". See the open
   question below.
4. **Settings:** clearer, split into tabs. (This changes how people find a
   setting, which is a small navigation change and not only a visual one.)

**Decided:**
- *Lively ears:* bounce stays at zero (the CLAUDE.md rule stands). The
  liveliness comes from speed (a faster open and a shorter close), from
  content timing (the shape leads and the content follows) and from keeping
  velocity when the ear is interrupted.
