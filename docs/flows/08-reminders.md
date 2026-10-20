# 08 · Reminders: add from anywhere, pin to the notch

Who: someone mid-task who remembers something and wants it out of their head without leaving the app they're in.

## Main flow: quick add
1. ⌥⌘R anywhere → the field opens under the notch, focused, without activating Upthere.
   - First time: the system asks for Reminders access first, then the field opens.
   - Refused before: the field says so and offers "Open Privacy Settings…" (no dead end).
2. Type: `call mom tomorrow 5pm !! #family @home`. The chips under the field show what was read: list, date, priority, flag, tags, pin.
3. ↵ adds it (⌘↵ adds with the pin flipped). The icon turns into a check with "Added to <list>", then the field closes.

## Adjusting by click
- List chip → any list. Date chip → quick picks (Today, This evening, Tomorrow, Tomorrow morning, This weekend, Next week), "Pick a date and time…", "No date" (keeps a date-like phrase in the title), "Use the date in the text".
- Priority chip → none / ! / !! / !!!. Flag toggle. # chip → recent tags. Notch chip → pin new reminders (remembered).
- A value picked by click wins over what the text says.

## Pin an existing reminder
- Empty field: pinned ones, then the soonest-due open reminders. Typing: open reminders whose title matches, so you pin one instead of adding a duplicate.
- Each row: tick done · pin/unpin · open in Reminders. ↑/↓ highlights a row; ↵ then pins/unpins it.

## In the notch
- Collapsed left ear: up to 2 pinned reminders by name (overdue first, then soonest), ring in the list's colour, red with "!" once overdue; "+N" for the rest. Timers stay next to the notch. A name longer than the ear's cap rolls instead of ending in "…".
- With the tray up, the music ear shows the cover (with bars, or the paused title) rather than bars alone.
- Hover: the strip keeps the collapsed order out from the notch (timers, reminders, Claude), with the checklist (new reminder) and + (new timer) buttons at the far end. A chip per pinned reminder: tick done (1.6 s to tick again and undo), title, due date or list.
- Resting on a chip ~180 ms opens its buttons (reminder: unpin, open in Reminders) on the side away from the notch, so the chip itself stays put. A fast sweep only tints the chips it passes; moving the rest to another chip swaps them in one spring. A cut-off chip at the strip's far end scrolls just enough to show its buttons.
- Done, deleted or changed in Reminders (or on another device): the notch follows (EventKit change notification, no polling).

## Limits (Apple's)
- Tags: EventKit and Reminders' scripting have no tags API. Tags are saved as `#hashtags` in the notes (searchable in Reminders) and remembered for the # menu.
- Flag: set through Reminders' AppleScript, so the first flag asks for Automation access to Reminders.
