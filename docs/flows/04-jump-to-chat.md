# 04. Jump to the chat  ·  secondary  ·  Status: mapped

## Starts
| # | Entry point | Where | Source |
|---|---|---|---|
| S1 | ↗ button, left ear **expanded only** | `ClaudeViews.swift:75` | (code) |
| S2 | click the notchless Claude piece | `ClaudeViews.swift:172` | (code) |

## Decision points (`ClaudeModel.focus`, `ClaudeModel.swift:370`)
| # | Condition | → |
|---|---|---|
| D1 | `hostSessionID` is `local_…` | `claude://code/continue?session=…` → E1 |
| D2 | bundle is VS Code/Cursor/Windsurf/Zed/VSCodium and cwd known | open folder in that editor → E2 |
| D3 | Terminal / iTerm2 with a tty | activate + AppleScript selects the tab → E3 (asks Automation once) |
| D4 | anything else | just activate the app → E4 |

## Endings
| # | Kind | What the user sees | Status |
|---|---|---|---|
| E1 | success | that chat in the Claude app | code |
| E2 | success | the project window | code |
| E3 | success | the exact tab | code |
| E4 | partial | the app, not the tab (Ghostty, Warp, Kitty…) | code |
| E5 | failure | app no longer running → nothing happens, no feedback | code |
