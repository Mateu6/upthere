import Foundation

nonisolated enum NotchSide: Equatable, Sendable { case left, center, right }

/// Each ear opens on its own: only the ear under the pointer peeks, and a
/// click expands just that ear.
enum EarMode: Equatable {
    case collapsed
    case peek
    case expanded
}

/// What each ear shows. Left = agents, right = music; a single live activity
/// spans both ears.
enum LeftContent: Hashable {
    case none
    case musicArt
    case musicInfo(expanded: Bool)
    /// Up Next (music-only): upcoming songs beside the cover.
    case queue
    /// Timers and pinned reminders (the tray) own the left ear while there
    /// are any: the urgent ones collapsed, all of them (plus Claude) as a
    /// strip when open.
    case timer
    case timerStrip
    case claudeGlyph
    case claudeDetail(expanded: Bool)
    /// Screens without a notch: Claude's piece next to the notch, with the
    /// timers (if any) further out.
    case claudePiece(timers: TimerPart)
}

/// A chip in the timer strip that can show its buttons.
enum TrayChip: Hashable {
    case timer(UUID)
    case reminder(String)
}

/// The timers' share of a combined ear on a screen without a notch.
enum TimerPart: Hashable {
    case none, collapsed, strip
}

enum RightContent: Hashable {
    case none
    case musicBars
    case musicCompact
    /// Collapsed and paused: "Title · Artist" instead of still bars, after
    /// the cover when the left ear is Claude's.
    case musicPaused(art: Bool)
    case musicControls(expanded: Bool)
    case musicFull(expanded: Bool)
    case claudeBadge
    case claudeTool(expanded: Bool)
    /// Screens without a notch, music in the middle: music next to the
    /// notch, the timers further out.
    case musicWithTimers(strip: Bool)
}

struct NotchActions {
    var openSettings: () -> Void
    var openTimerInput: () -> Void
    var openReminderInput: () -> Void
    var checkForUpdates: () -> Void
    var quit: () -> Void
}
