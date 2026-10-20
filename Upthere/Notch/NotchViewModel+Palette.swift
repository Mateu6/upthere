import AppKit

/// The colours each ear is tinted with.
extension NotchViewModel {
    static let claudePalette = [Theme.claude] + Theme.gradient(from: Theme.claudeTone).dropFirst()
    static let attentionPalette = Theme.gradient(from: Theme.permissionTone)
    static let inputPalette = Theme.gradient(from: Theme.inputTone)
    static let neutralPalette = [0.93, 0.8, 0.67].map { OKLCH($0, 0, 0).nsColor }

    var musicPalette: [NSColor] { nowPlaying.artwork?.palette ?? Self.neutralPalette }

    /// The colors an ear is tinted with: the cover's for music, Claude's
    /// own for agents (amber while it needs you).
    func palette(for side: NotchSide) -> [NSColor] {
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
}
