# Plan: Allow / Deny from the notch

**Status:** built 2026-10-19 (flowcheck L1), widened to option questions and plan approval. What shipped
differs from this plan: one `upthere-hook answer` mode serves `PreToolUse` (AskUserQuestion|ExitPlanMode) and
`PermissionRequest`; the app decides the wait ("notch first, then the terminal after N s or ↗", never when the
session's window is in front). The spike below wasn't needed: the docs say a `PreToolUse` hook runs before any
dialog, so the terminal stays silent while the hook waits. See `docs/flows/02-…` and `03-…`.

## Why

When Claude needs permission, the notch turns amber and you go to the terminal or the Claude app to answer.
That trip is the main reason to leave Upthere today ("no reason to look elsewhere"). The notch should
answer the request itself: show exactly what's being asked, then **Allow** or **Deny** in one click.

## What Claude Code gives us

The `PermissionRequest` hook (docs: code.claude.com/docs/en/hooks):

- It fires when Claude Code is about to ask for permission. Input: `tool_name`, `tool_input`, `mcp_server`
  for MCP tools, and an optional `permission_suggestions` (the "always allow" rule Claude would add).
- The output decides it:
  ```json
  {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
    "decision":{"behavior":"allow"}}}
  ```
  - `behavior`: `allow` or `deny`.
  - `updatedPermissions`: `allow` only. Pass `permission_suggestions` back for "Always allow".
  - `message`: `deny` only. Tells Claude why.
  - `interrupt`: `deny` only. Stops Claude.
- Exit 0 with no output means no decision, and the normal dialog runs. **So silence is always safe.**
- Default hook timeout is 600 s. Timed-out output is discarded, which is again safe.
- In non-interactive sessions with no decision, the call is denied. That's existing behaviour, and we don't change it.

**Unknown, so spike first:** the docs don't say whether the terminal or app dialog shows *while* the hook is
still running, or only after it returns. Everything below depends on this.

## Step 0: spike (~30 min)

Add a temporary hook to `~/.claude/settings.json` that runs `sleep 30` on `PermissionRequest`. Trigger a Bash
permission in (a) the terminal and (b) the Claude desktop app, then check three things:

1. Does the dialog appear immediately, or after 30 s?
2. If it appears immediately and you answer it, is the hook killed, or does it keep running?
3. If the hook prints an `allow` after you've already answered, is it ignored? (It must be.)

Possible results:

- **A: the dialog shows in parallel** (like the `canUseTool` host race, "whichever decides first applies").
  The hook can wait the whole time, and the notch and the terminal both answer. This is the best case.
- **B: the dialog waits for the hook.** The hook may wait only a short, adjustable time (default 8 s) before
  falling back to the dialog. Upthere has to show the request instantly, and it skips waiting entirely when
  the session's own terminal or app is frontmost, because you're already there.

## Design

### Opt-in

- New Settings row under Agents: **Answer permission requests from the notch**, off by default.
  This follows principle 3 (ask for as little as possible) and principle 4 (be a good guest). Turning it on
  installs one more hook group. Turning it off, or Disconnect, removes only that group.
- In result B, an extra row: **Wait for the notch for … s** (a stepper, 3–30 s). It's folded under the toggle,
  because it's a pro control.

### Hook (`UpthereHook/main.swift`)

New mode `upthere-hook permission`. It stays Foundation-free.

1. Read stdin. If `tool_name` is `AskUserQuestion` or `ExitPlanMode`, exit at once with no output. Those are
   questions, not yes/no.
2. Connect to the socket. If the app isn't listening, exit 0 silently, exactly as today.
3. Send the envelope with `"kind":"permission"` and a random request id. Keep the socket open
   (today the client closes after writing).
4. Wait for one reply line with `poll()`, until the deadline (result A: just under the hook timeout;
   result B: the pref). The app sends one of `allow`, `allow-always`, `deny`, `deny-stop` or `none`.
5. Print the matching decision JSON. For `allow-always`, echo `permission_suggestions` back as
   `updatedPermissions`; the hook copies the raw bytes, so no JSON parser is needed. On EOF, timeout or `none`,
   print nothing.

`HookInstaller` adds `PermissionRequest` with `matcher: "*"`, the `permission` argument and its own
`timeout`. `isInstalled` keeps checking only the base events, so the toggle is reported on its own.

### App

- **`ClaudeHub`**: for `kind == "permission"`, don't close on read. Keep the fd in `pending[requestID]` and
  hand the event over with a reply closure. Its read source sees EOF when the hook dies (timed out, or the
  user answered elsewhere and the hook was killed), and that resolves the request as gone.
- **`ClaudeModel`**: `session.pendingPermission = PermissionRequest(id, tool, detail, fullInput,
  suggestion?, receivedAt)`. It resolves (sending `none` if still open) when any of these arrives for that
  session: `PostToolUse`, `UserPromptSubmit`, `Stop`, `SessionEnd`, or a newer request. That's how we know
  the user answered in the terminal or the app. Several sessions can be waiting at once, so the first one
  in arrival order is shown and the rest count in the existing `+N` badge.
- **`HookEvent`**: parse `permission_suggestions` (just its presence, plus a short summary such as
  "Always allow `npm run lint`") and keep the full `tool_input.command` or `file_path` for display.

### UI (most important first, everything else layered)

The Claude ear already **peeks on its own** for a permission prompt (see the `claude_permission` demo scene).
The new row lives in that peek, so nothing new moves on screen. It shows:

```
[✋]  Bash · rm -rf node_modules                 Deny   [ Allow ]
```

- **Allow** is the primary button: filled in the amber status tone, with dark text.
  **Deny** is plain text with a faint hover wash, so it's the less prominent option, as the principles want.
  Both get the normal, hover and pressed states from `RowButtonStyle` / `LiftButtonStyle`.
- **The exact command, never a paraphrase.** For Bash, show the command itself, which rolls with
  `MarqueeText` and can be scrubbed. The description goes in `.help`. For Edit or Write, show the file name
  and its folder.
- **Folded away:** Allow has a small chevron menu with **Always allow** (shown only when a suggestion exists,
  with the rule spelled out) and **Deny and stop Claude**. ⌥-click on Allow means Always allow. ⌥-click on
  Deny means deny and stop.
- **Never approve by accident:**
  - The buttons accept clicks only after they've been on screen for 350 ms, so an ear opening under the cursor
    can't take a click meant for the menu bar.
  - Each button is bound to the request id it was drawn for, so a request swapping underneath you does nothing.
  - No keyboard shortcut in v1, because the panel never takes focus.
- **After a click:** the row turns into a short confirmation ("Allowed" ✓ in green, or "Denied" with the
  hand icon) for 1.2 s, then the ear goes back to the tool line. The undo story is honest: a permission can't
  be taken back once Claude has it, which is exactly why the 350 ms guard and the visible command exist.
- **Left ear and notchless piece:** the spark gets the existing `hand.raised.fill` overlay (see quick fix 1),
  and a click on the piece opens the right ear's request instead of jumping to the chat.
- **Answered elsewhere:** the row cross-fades (`.blurReplace`) to whatever Claude does next. No error, no toast.
- **Themes and screens:** check Classic, Aurora and Glass, with a notch and without. Use the
  `scripts/debug-notch.swift` modes and add a `permission:<tool>:<detail>` mode.

## Edge cases

| Case | Behaviour |
| --- | --- |
| Upthere not running, or the toggle is off | The hook exits instantly with no output, so the normal dialog runs |
| Upthere quits while a hook waits | EOF, so the hook prints nothing and the normal dialog runs |
| Answered in the terminal or app first | A later PostToolUse or Stop event clears the request. Our late reply is ignored by Claude Code (confirm in the spike) |
| Two sessions waiting | One shown, `+1` badge, and the second appears after the first resolves |
| Subagent asks | Same flow. The chat title shows the parent session |
| `AskUserQuestion`, `ExitPlanMode` | Not handled: the hook returns immediately |
| Headless / `-p` sessions | Unchanged. We never auto-allow |
| A Claude Code version without PermissionRequest | The hook never fires, and Notification `permission_prompt` keeps the amber state as today |

## Tests

- `HookInstallerTests`: adding the permission group, removing it alone, leaving other entries untouched.
- `HookEventTests`: parsing `permission_suggestions` and the full command.
- A hook decision test: run the built `upthere-hook permission` against a test socket (`UPTHERE_SOCKET`)
  and check the stdout JSON for each reply, plus silence on EOF and timeout.
- `ClaudeModel`: the pending request lifecycle (resolved by PostToolUse, Stop and EOF).

## Order of work

1. The spike, then choose result A or B. *(blocking)*
2. Hook mode and installer, with tests.
3. Hub, model and event changes, with tests.
4. Ear UI, Settings row, debug mode, snapshots in 3 themes × 2 layouts.
5. README feature line and CLAUDE.md note ("the permission hook may wait; every other hook still never blocks").
