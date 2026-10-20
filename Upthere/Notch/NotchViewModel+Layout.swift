import AppKit

/// What each ear shows for the current state (`layout(left:right:)`), and
/// what that content is.
extension NotchViewModel {
    /// How far the virtual notch of a notchless screen moves left of the
    /// screen's center so the resting ears sit centered together.
    var restingCenterOffset: CGFloat {
        guard !geometry.hasNotch else { return 0 }
        let rest = content(left: .collapsed, right: .collapsed)
        let offset: CGFloat
        switch (rest.left, rest.right) {
        // Three pieces: the center piece sits in the middle of the screen.
        case (.claudePiece(.collapsed), .musicFull): offset = -claudePieceWidth(hovered: false) / 2
        case (_, .musicWithTimers): offset = musicPieceWidth / 2
        // Otherwise the resting ears are centered together.
        default:
            let left: CGFloat =
                switch rest.left {
                case .timerStrip: 0
                case .claudePiece(let part): claudePieceWidth(hovered: false) + width(part)
                default: width(rest.left)
                }
            offset = (width(rest.right) - left) / 2
        }
        let half = geometry.screenFrame.width / 2 - 40
        return min(max(offset, -half), half).rounded()
    }

    func content(left l: EarMode, right r: EarMode) -> (left: LeftContent, right: RightContent) {
        var c = layout(left: l, right: r)
        // Paused, the bars would just sit still: say what's paused instead.
        if nowPlaying.current?.isPlaying == false {
            if c.right == .musicBars { c.right = .musicPaused(art: false) }
            if c.right == .musicCompact { c.right = .musicPaused(art: true) }
        }
        return c
    }

    func layout(left l: EarMode, right r: EarMode) -> (left: LeftContent, right: RightContent) {
        // The music ear's mode, counting resting open as peeked.
        let rm: EarMode = r == .collapsed && musicRestsOpen ? .peek : r
        let sessionsLive = prefs.claudeEnabled && claude.isLive
        // With "show usage when idle", the Claude ear stays (ring + limits).
        let usageOnly = !sessionsLive && prefs.claudeEnabled && prefs.showUsageWhenIdle
            && claude.planUsage.map { $0.current().fiveHour != nil || $0.current().sevenDay != nil } == true
        let agents = sessionsLive || usageOnly
        // An open music ear keeps showing a paused/pinned player, but only
        // while music owns the ears: when Claude does, hovering its ear shows
        // Claude, never a player that has gone quiet.
        let musicEarOpen = !agents && (l != .collapsed || r != .collapsed)
        let music = nowPlaying.isLive || (musicEarOpen && nowPlaying.current != nil)

        let claudeLeft: LeftContent = l == .collapsed ? .claudeGlyph : .claudeDetail(expanded: l == .expanded)

        // Screens without a notch have room for Claude, music and timers
        // side by side: [timers | Claude ‖ music], or with music as the
        // center piece [Claude ‖ music | timers]. Only the outer piece of an
        // ear opens on hover, so the pieces next to the notch never move.
        if !geometry.hasNotch, sessionsLive {
            let musicNow = nowPlaying.isLive
            // Claude needing you shows in its piece rather than opening the ear.
            let lo: EarMode = l == .collapsed ? .collapsed : leftMode
            if musicNow && !timers.isEmpty && prefs.centerPiece == .music {
                let left: LeftContent = lo == .collapsed ? .claudePiece(timers: .none) : .claudeDetail(expanded: true)
                return (left, .musicWithTimers(strip: r != .collapsed))
            }
            let left: LeftContent =
                timers.isEmpty
                ? (lo == .collapsed ? .claudePiece(timers: .none) : .claudeDetail(expanded: true))
                : .claudePiece(timers: lo == .collapsed ? .collapsed : .strip)
            if musicNow { return (left, .musicFull(expanded: false)) }
            if !timers.isEmpty { return (left, .none) }
            return (left, r == .collapsed ? .claudeBadge : .claudeTool(expanded: r == .expanded))
        }

        // Timers take the left ear (Claude needing you still overrides).
        // Music then lives entirely in the right ear; Claude without music
        // keeps the right ear, and appears as a chip in the timer strip.
        if !timers.isEmpty {
            let left: LeftContent =
                claude.attention != nil && prefs.claudeEnabled
                ? .claudeDetail(expanded: l == .expanded) : l == .collapsed ? .timer : .timerStrip
            let musicNow = nowPlaying.isLive || (!sessionsLive && r != .collapsed && nowPlaying.current != nil)
            let right: RightContent
            switch (musicNow, sessionsLive) {
            case (true, false): right = rm == .collapsed ? .musicBars : .musicControls(expanded: rm == .expanded)
            case (true, true): right = rm == .collapsed ? .musicCompact : .musicFull(expanded: rm == .expanded)
            case (false, true): right = r == .collapsed ? .claudeBadge : .claudeTool(expanded: r == .expanded)
            case (false, false): right = .none
            }
            return (left, right)
        }

        switch (music, agents) {
        case (false, false):
            return (.none, .none)
        case (true, false):
            return (
                // Left: cover, opening to Up Next. Right: bars, opening to
                // title, artist and controls.
                l == .collapsed ? .musicArt : prefs.showQueue ? .queue : .musicInfo(expanded: l == .expanded),
                rm == .collapsed ? .musicBars : .musicControls(expanded: rm == .expanded)
            )
        case (false, true):
            if usageOnly { return (claudeLeft, .none) }
            return (claudeLeft, r == .collapsed ? .claudeBadge : .claudeTool(expanded: r == .expanded))
        case (true, true):
            return (claudeLeft, rm == .collapsed ? .musicCompact : .musicFull(expanded: rm == .expanded))
        }
    }

    /// Up Next: the right ear of a music-only notch, when open.
    var showsQueue: Bool { content.left == .queue }

    /// The seek/volume overlay needs a widened music ear.
    func showsHUD(on side: NotchSide) -> Bool {
        guard hud != nil, hudSide == side, isOpen(side) else { return false }
        let c = content
        switch side {
        case .left:
            if case .musicInfo = c.left { return true }
            if c.left == .queue { return true }
        case .right:
            switch c.right {
            case .musicControls, .musicFull, .musicWithTimers: return true
            default: break
            }
        case .center: break
        }
        return false
    }

    func showsMusic(_ side: NotchSide) -> Bool {
        let c = content
        switch side {
        case .left:
            if case .musicInfo = c.left { return true }
            return c.left == .musicArt || c.left == .queue
        case .right:
            switch c.right {
            case .musicBars, .musicCompact, .musicPaused, .musicControls, .musicFull, .musicWithTimers: return true
            default: return false
            }
        case .center: return false
        }
    }

    var claudeShown: Bool {
        switch content.left {
        case .claudeGlyph, .claudeDetail, .claudePiece: true
        default: false
        }
    }
}
