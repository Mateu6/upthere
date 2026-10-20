# 07. Connect / disconnect Claude Code  ·  secondary  ·  Status: mapped

## Steps
1. Settings → Claude → "Connect Claude Code" (`ClaudeSettings.swift:18`) → `HookInstaller.install` backs up and edits `~/.claude/settings.json` (code)
2. Disconnect removes only Upthere's entries (code)

## Endings
| # | Kind | What the user sees | Status |
|---|---|---|---|
| E1 | success | Connected | code |
| E2 | failure | error text under the row | code |
| E3 | **missing** | toggle on, hooks never connected → notch shows nothing, no hint anywhere outside Settings | code |

## Open
- Answering from the notch adds a second, opt-in hook group (see `docs/allow-deny-from-notch.md`).
