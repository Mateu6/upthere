# 01. Watch Claude work  ·  MAIN  ·  Status: mapped

Marks: `(code)` read from code · `(walked)` clicked through · `(tested)` has an E2E test · `(?)` inferred, needs Mateusz's confirmation.

- **User:** a developer with one or more Claude Code sessions (terminal, editor or the Claude app)
- **Goal:** know at a glance what Claude is doing, without switching windows
- **Preconditions:** "Show Claude Code activity" on · hooks connected (Settings → Claude)

## Starts
| # | Entry point | From | Where it lands | Source |
|---|---|---|---|---|
| S1 | You send a prompt | `UserPromptSubmit` hook → socket | step 1 | (walked) |
| S2 | A session starts | `SessionStart` (stays hidden while idle) | — | (code) |

## Steps
1. **Collapsed ears:** left = spark (working), right = tool symbol + count badge (`ClaudeBadge`) (walked)
2. **Hover/peek left:** project title, "+N", status line rolling (`ClaudeDetail`) (walked)
3. **Hover right:** what's happening now, timer, model, tokens (`ClaudeToolDetail`) (code)
4. **Click either ear:** expands; left adds ↗ and ‹ › (code)

## Decision points
| # | At step | What is decided | Condition | Where | → Branch |
|---|---|---|---|---|---|
| D1 | any | which session the ear shows | `selectedSessionID ?? attention ?? working ?? first` | `NotchViewModel.swift:578`, `ClaudeModel.swift:150` | see flow 05 |
| D2 | any | tool vs question | tool is `AskUserQuestion`/`ExitPlanMode` | `ClaudeModel.swift:250` | flow 03 |
| D3 | any | session dropped | quiet > 30 min (3 h while working) | `ClaudeModel.swift:345` | E3 |

## Endings
| # | Kind | What the user sees | Data afterwards | Where next | Status | Test |
|---|---|---|---|---|---|---|
| E1 | success | ✓ "Done" + Claude's last words, 10 s, then hides | activity `.idle` | flow 04 (jump to chat) | code | — |
| E2 | success | session closed → it vanishes | removed | — | walked | — |
| E3 | abandoned | terminal killed → stays until GC | removed after 30 min / 3 h | — | code | — |
| E4 | **missing** | **you press Esc / interrupt → spark keeps spinning up to 3 h** (no `Stop` hook on interrupt) | stuck `.thinking`/`.tool` | — | code | — |

## Open
- E4: see loose end L2.
