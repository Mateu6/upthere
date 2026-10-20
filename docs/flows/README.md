# Flows — Upthere (Claude features)

What it is: a native macOS notch app; the ears show Now Playing, Claude Code status and timers.
Who it's for: developers running Claude Code who don't want to leave what they're doing. Default path: glance and go on; pro controls in Settings.

Last run: 2026-10-19 · commit `74d62dd` + uncommitted fixes · scope: Claude features (flows 01–07)
Inventory: native app, no routes; Claude clickables audited by hand: 9 in the ears + Settings rows (see interactions.md)

Files: [01](01-watch-claude-work.md) · [02](02-claude-needs-permission.md) · [03](03-claude-asks-you.md) · [04](04-jump-to-chat.md) · [05](05-switch-sessions.md) · [06](06-usage-and-limits.md) · [07](07-connect-hooks.md) · [interactions.md](interactions.md) · [loose-ends.md](loose-ends.md)
Decision page: https://claude.ai/artifact/UCeTrZnaZMYiMGv4SyVnXa

## Coverage

| Flow | Status | Ending | Mapped | Walked | Tested |
|---|---|---|---|---|---|
| 01 Watch Claude work | fixed 2026-10-19 | E1 done (peeks 2.5 s) · E2 closed · E3 quiet · E4 Esc → idle | ✓ | E1, E2, E4 | `turnLifecycle`, `compactAndIdlePromptEndStuckTurns`, `TranscriptSignalTests` |
| 02 Needs permission | fixed | E1 allowed (terminal) · E2 denied · E3 Esc · E4 Allow/Deny/Always/Deny+stop in notch · E5 handed to terminal | ✓ | E4, E5 (3 themes, notchless) | `parallelCallsAndSubagentsDontHideAWait`, `ClaudeRequestTests` |
| 03 Asks you | fixed | E1 answered in terminal · E2 Esc · E3 options/plan in notch · E4 handed over | ✓ | E3, E4 | `ClaudeRequestTests` |
| 04 Jump to chat | fixed (code) | E1–E4 · E5 app quit → reopened · no app → beep | ✓ | ✗ (opens real apps) | ✗ |
| 05 Switch sessions | fixed | E1 reset · E2 notchless reset · E3 own colour + badge points back · new wait takes over | ✓ | E3 | `colourFollowsTheChatOnScreenButWaitsComeFirst`, `longestWaitingComesFirst` |
| 06 Usage | mapped | — | partly | ✗ | ✗ |
| 07 Connect hooks | fixed | E1 · E2 · E3 onboarding once · answer toggle on/off · upgrade at launch | ✓ | ✗ (would edit real settings.json) | `AnswerInstallerTests`, `HookInstallerTests` |

Shots: `shots/02-answer-*`, `03-answer-*`, `05-fixed-*`, `01-fixed-*` (Aurora, Glass, Classic; notchless via the debug switch, whose capture clips the top few points).
Live-tested 2026-10-20: real AskUserQuestion from Claude Code in Terminal, answered by clicking in the notch (works). Not walked: a real question from the Claude desktop app, real permission and plan requests, clicking chips by pointer (driven through DebugBridge `answer:*`), jump-to-chat endings.

## Decisions log
- 2026-10-19: answer from the notch: option questions, Allow/Deny, plan approval. Notch first, then the terminal after a timeout (default 20 s) or "Answer in terminal"; never waits when the session's window is in front.
- 2026-10-19: each session's colour comes from the status of the conversation on screen.
- 2026-10-19: all 17 loose ends picked Fix; L2 "fix differently": always prioritize the one that needs me.
- 2026-10-20: answer hook installed in ~/.claude/settings.json; live question test passed.
- 2026-10-20: questions and permissions share the Claude app's yellow; tint always follows the status.
