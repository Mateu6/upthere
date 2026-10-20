# Clickables register — Claude area

States: N normal · H hover · P pressed · D disabled · L busy (✓ present · ✗ missing · – not relevant). Verdict: ok · fix · suggest · broken.

## Left ear, Claude (`UI/ClaudeViews.swift` ClaudeDetail) · flows 01, 02, 03, 05

| Clickable | Does | N | H | P | D | L | Works | Verdict | Suggestion |
|---|---|---|---|---|---|---|---|---|---|
| Ear body (peek) | `set: left expanded` (`NotchViewModel.tap`) | ✓ | ✓ opens | – haptic only | – | – | yes | ok | — |
| ↗ open chat | `ext: focus(session)` | ✓ | ✓ | ✓ | – | – | yes | suggest | only reachable after expanding; while Claude waits, the jump is the main action (L7) |
| ‹ › pager | `set: selectedSessionID` | ✓ | ✓ | ✓ | – | – | yes | ok | — |
| Scroll over ear | switch session / scrub status | – | – | – | – | – | yes | ok | — |
| "+N" badge | nothing | ✓ | – | – | – | – | – | suggest | doesn't say whether another session needs you; make it amber/violet + click jumps to the waiting one (L4) |
| Status line "Allow Bash? · …" | nothing | ✓ | – | – | – | – | – | fix | reads as a question with no answer to click (L1, agreed) |

## Right ear, Claude (`ClaudeToolDetail`, `ClaudeBadge`) · flows 01–03

| Clickable | Does | N | H | P | D | L | Works | Verdict | Suggestion |
|---|---|---|---|---|---|---|---|---|---|
| Badge / ear body | `set: right expanded` | ✓ | ✓ | – | – | – | yes | suggest | expanding only widens the text; no actions live here (home for the answer row) |

## Notchless Claude piece (`ClaudePiece`) · flows 01, 04

| Clickable | Does | N | H | P | D | L | Works | Verdict | Suggestion |
|---|---|---|---|---|---|---|---|---|---|
| Piece | `ext: focus(session)` | ✓ | ✓ | ✓ | – | – | yes | ok | when waiting, click should open the answer row (plan) |

## Settings → Claude (`Settings/ClaudeSettings.swift`) · flows 06, 07

| Clickable | Does | N | H | P | D | L | Works | Verdict | Suggestion |
|---|---|---|---|---|---|---|---|---|---|
| Show Claude Code activity | `set: claudeEnabled` | system | | | | | yes | ok | — |
| Connect / Disconnect Claude Code | `submit: HookInstaller` | system | | | | | yes | ok | — |
| Status line connect | `submit` | system | | | | | yes | ok | — |
| Usage toggles / pickers | `set` | system | | | | | yes | ok | — |

## Serves no flow
None found in the Claude area.
