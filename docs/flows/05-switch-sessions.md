# 05. Switch between sessions  ·  MAIN  ·  Status: mapped

- **Goal:** with several sessions, look at each one and see its own state
- **Preconditions:** 2+ visible sessions

## Starts
| # | Entry point | Where | Source |
|---|---|---|---|
| S1 | ‹ › in the expanded left ear | `ClaudeViews.swift:78` | (code) |
| S2 | scroll over the Claude ear (one switch per gesture) | `NotchViewModel.swift:890` | (code) |
| S3 | debug `claude-next` | `DebugBridge.swift` | (walked) |

## Steps
1. "+N" badge next to the title says how many others exist (walked)
2. Switch → title, status, spark, right-ear symbol follow the picked session (walked)
3. **Ear tint does not follow** — it follows `claude.attention` (any session needing you), `NotchViewModel.swift:563` (walked: `shots/05-switch-*-2-working-shown.png`)

## Endings
| # | Kind | What the user sees | Status |
|---|---|---|---|
| E1 | success | collapse → selection resets to the most urgent session | code |
| E2 | success | notchless: pointer leaves → resets after close delay + 1.5 s | code |
| E3 | **broken** | picked a working session while another waits → both ears stay amber | walked |

## Decisions log
- 2026-10-19: Mateusz: each session gets its own colour from the status of the conversation on screen.
