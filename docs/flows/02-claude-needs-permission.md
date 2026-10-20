# 02. Claude needs permission  ·  MAIN  ·  Status: mapped

- **User:** developer away from the session's window
- **Goal:** notice the request and answer it fast
- **Preconditions:** hooks connected

## Starts
| # | Entry point | From | Where it lands | Source |
|---|---|---|---|---|
| S1 | `PermissionRequest` hook | **not installed** (`HookInstaller.swift:11`) — never fires today | step 1 | (code) |
| S2 | `Notification` `permission_prompt` | socket | step 1 | (walked) |

## Steps
1. **Left ear auto-peeks** (`effectiveLeftMode`, `NotchViewModel.swift:158`): amber spark + ✋ mark, "Allow Bash? · Clean installs" in amber, ear tinted amber (walked)
2. **Right ear:** ✋ symbol (code)
3. **Today:** you click ↗ (after expanding) to jump to the terminal/app and answer there (code)

## Decision points
| # | At step | What is decided | Condition | Where | → Branch |
|---|---|---|---|---|---|
| D1 | 1 | permission or question | previous was a question tool | `ClaudeModel.swift:300` | flow 03 |
| D2 | 1 | which waiting session shows | first in `sessions` (newest session, not oldest request) | `ClaudeModel.swift:145` | L6 |

## Endings
| # | Kind | What the user sees | Data afterwards | Where next | Status | Test |
|---|---|---|---|---|---|---|
| E1 | success | Allowed in terminal → amber stays **until the tool finishes** (`PostToolUse`), then "Thinking…" | `.thinking` | flow 01 | code | — |
| E2 | success | Denied, Claude continues → next tool / Done | next state | flow 01 | code | — |
| E3 | **missing** | Denied with "tell Claude what to do" / Esc → **amber + peek stay up to 30 min** | stuck `.permission` | — | code | — |
| E4 | **new (agreed)** | Allow / Deny from the notch | — | — | not built | — |

## Decisions log
- 2026-10-19: answer from the notch; notch first, then the terminal after a timeout or "Answer in terminal"; never wait when the session's window is in front.

## After fixes (2026-10-19)
| E4 | success | **built:** Allow / Deny in the notch; ⋯ → Always allow `rule` / Deny and stop; ↗ hands over | thinking at once | flow 01 | walked | `ClaudeRequestTests` |
| E5 | handed over | no click within the wait, or ↗ → terminal asks | still waiting | terminal | walked | — |
