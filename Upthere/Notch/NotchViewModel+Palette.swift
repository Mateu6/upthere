import AppKit

/// The colours each ear is tinted with.
extension NotchViewModel {
    static let claudePalette = [Theme.claude] + Theme.gradient(from: Theme.claudeTone).dropFirst()
    static let attentionPalette = Theme.gradient(from: Theme.permissionTone)
    static let inputPalette = Theme.gradient(from: Theme.inputTone)
    static let neutralPalette = Theme.metalPalette

    var musicPalette: [NSColor] { nowPlaying.artwork?.palette ?? Self.neutralPalette }

    /// The colors an ear is tinted with: the cover's for music, Claude's
    /// own for agents (amber while it needs you), the lead item's for the tray.
    func palette(for side: NotchSide) -> [NSColor] {
        if side == .left, content.left == .timer || content.left == .timerStrip { return trayPalette }
        let music = showsMusic(side) || (side == .left && !claudeShown && showsMusic(.right))
            || (side == .right && !claudeShown && showsMusic(.left))
        if music { return musicPalette }
        // Each chat has its own colour: the one on screen sets the tint.
        // The tint always says what the status says.
        guard let session = selectedSession, session.activity.needsUser else { return Self.claudePalette }
        switch session.activity {
        case .permission: return Self.attentionPalette
        case .input: return Self.inputPalette
        default: return Self.claudePalette
        }
    }

    /// The tray takes the colour of what leads it: a timer that just ended,
    /// else the one next to the notch, else the first reminder (red once
    /// overdue, otherwise its list's colour).
    var trayPalette: [NSColor] {
        let timer = timers.timers.first { $0.id == timers.alertingID } ?? timers.collapsedTimers.first
        if let timer { return Theme.gradient(from: Theme.timerTones[timer.colorIndex % Theme.timerTones.count]) }
        guard let reminder = reminders.collapsedReminders.first else { return Self.neutralPalette }
        return Theme.gradient(from: reminder.isOverdue() ? Theme.dangerTone : reminder.list.tone)
    }
}
