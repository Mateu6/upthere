# 03. Claude asks you something  ·  MAIN  ·  Status: mapped

- **Goal:** answer Claude's question (options), approve a plan, or fill an MCP form
- **Preconditions:** hooks connected

## Starts
| # | Entry point | Source |
|---|---|---|
| S1 | `PreToolUse` `AskUserQuestion` → `.input(prompt: first question)` | (walked via demo) |
| S2 | `PreToolUse` `ExitPlanMode` → "Plan ready for review" | (code) |
| S3 | `Notification` `elicitation_dialog` | (code) |

## Steps
1. Left ear auto-peeks: violet spark + "?" mark, the question rolling (code)
2. Right ear: "?" bubble, the question as the main line (code)
3. **Today: nothing to click.** Only the first question is kept; options, header and multi-select are dropped in `HookEvent.question` (`HookEvent.swift:43`).

## Endings
| # | Kind | What the user sees | Where next | Status |
|---|---|---|---|---|
| E1 | success | answered in terminal → `PostToolUse` → "Thinking…" | flow 01 | code |
| E2 | missing | Esc on the question → stays violet up to 30 min | — | code |
| E3 | **new (agreed)** | pick option(s) / approve plan in the notch | flow 01 | not built |

## Facts for building E3 (Claude Code hooks docs, checked 2026-10-19)
- `PreToolUse` may return `permissionDecision: "allow"` + `updatedInput` = original `questions` + `answers: {"<question>": "<label>"}`; multi-select joins labels with commas. `"allow"` alone is not enough.
- `ExitPlanMode`: input carries injected `plan` and `planFilePath`; approve with `allow` (+ echoed input), keep planning with `deny` + reason.
- While a `PreToolUse` hook waits, the terminal shows nothing; returning no output falls back to the normal dialog.

## After fixes (2026-10-19)
| E4 | success | **built:** options one question at a time (multi-select + Done), plan Approve / Keep planning | flow 01 | walked |
| E5 | handed over | wait ran out, or ↗ | terminal | walked |

- 2026-10-20: **live-tested** with real Claude Code in Terminal (2 questions); Mateusz picked both in the notch and Claude Code received them ("User answered Claude's questions → Circle"). Shot: `shots/03-live-1-real-question.png`.
