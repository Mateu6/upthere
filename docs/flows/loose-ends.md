# Loose ends — Claude features

Run 2026-10-19 · commit 74d62dd · decision page: https://claude.ai/artifact/UCeTrZnaZMYiMGv4SyVnXa (private)

Severity: broken · dead (dead end) · missing (branch) · friction. Full wording, evidence and fixes are on the decision page.

| ID | Severity | Flow | Finding | Decision | Outcome |
|---|---|---|---|---|---|
| L1 | missing | 02, 03 | Answer Claude from the notch | fix | fixed, walked |
| L2 | broken | 05 | Ear colour follows the wrong session | fix differently: \"yes but always prioritize the one that needs me\" | fixed, walked |
| L3 | missing | 05 | A hidden session waiting for you isn't signalled | fix | fixed, walked |
| L4 | broken | 01, 02, 03 | Stuck 'working' or 'waiting' after Esc or /compact | fix | fixed, walked |
| L5 | broken | 02, 03 | Subagents and parallel tools erase 'needs you' | fix | fixed, unit-tested |
| L6 | dead | 02, 04 | With timers running, the waiting ear can't open | fix | fixed, walked |
| L7 | broken | 07 | Turning Claude off and on breaks cleanup | fix | fixed, unit-tested |
| L8 | missing | 01, 02 | Missing hooks: permission requests and failed tools | fix | fixed, unit-tested |
| L9 | friction | 02 | Stays amber while an allowed tool runs | fix | fixed (code) |
| L10 | friction | 02, 03 | Several waiting: the newest session shows, not the oldest request | fix | fixed, unit-tested |
| L11 | friction | 02, 04 | 'Open chat' needs a click to expand first | fix | fixed, walked |
| L12 | friction | 01, 02 | Right ear tells questions from work by colour only | fix | fixed (code) |
| L13 | friction | 01 | 'Done' is easy to miss | fix | fixed, walked |
| L14 | friction | 01 | Timer strip chip ignores status colour | fix | fixed (code) |
| L15 | friction | 01 | Idle sessions get their transcript read | fix | fixed (code) |
| L16 | friction | 04 | Open chat can bring the wrong app, or nothing | fix | fixed (code) |
| L17 | missing | 07 | Hooks never connected: no hint outside Settings | fix | fixed (code) |

## Notes from applying (2026-10-19)
- L2: tint follows the chat on screen; a chat that *starts* waiting after you picked another takes over (his note: "always prioritize the one that needs me").
- L4: Esc is read from Claude Code's transcript line "[Request interrupted by user"; the idle-prompt notification is the backup; manual /compact ends the turn.
- L5: while waiting, other tool calls are ignored; a matching PostToolUse, a transcript tool result for that call, Esc, Stop or a new prompt end the wait.
- L8: existing installs get the new events at launch (`HookInstaller.upgradeIfNeeded`), still only Upthere's entries.
- L9: answering in the notch clears the wait at once. For terminal answers: going to the session's window and leaving it softens the wait to "Answered in terminal?" (grey, no peek, ✋ kept).
- L16: no app recorded and no tty → a beep instead of guessing Terminal; an app that quit is reopened.
- L17: first launch with ~/.claude present and no hooks opens Settings → Claude once.
- 2026-10-20 (Mateusz, from a screenshot): "the background here is not matching the status" and "the question to me should have yellow color just like claude yellow dot in the app". Now: questions use the same yellow as permissions (marks ✋ / ? tell them apart); the tint always follows the status; the L9 "Answered in terminal?" softening only applies to terminal sessions (being in the Claude app doesn't mean you saw that chat) and no longer changes colours.
