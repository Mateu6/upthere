import AppKit

/// How wide each ear is: every piece hugs what it draws.
extension NotchViewModel {
    /// Ear widths, without the shoulder flare.
    var leftWidth: CGFloat {
        let content = content.left
        let limit: CGFloat? =
            switch content {
            case .timerStrip: timerStripLimit
            case .claudePiece: timerStripLimit + 340
            case .claudeDetail where answerShown: Self.answerLimit
            default: nil
            }
        return nudged(clamp(width(content), room: geometry.leftRoom, limit: limit), .left)
    }
    var rightWidth: CGFloat {
        let content = content.right
        let limit: CGFloat? = if case .musicWithTimers = content { timerStripLimit + 260 } else { nil }
        return nudged(clamp(width(content), room: geometry.rightRoom, limit: limit), .right)
    }

    /// The widest an ear can get on this screen (including the hover nudge).
    func maxEarWidth(room: CGFloat) -> CGFloat {
        // Without a notch, a piece can sit inside a timer strip's ear.
        let widest = max(CGFloat(prefs.maxEarWidth), timerStripLimit) + (geometry.hasNotch ? 0 : 340)
        return min(widest, max(0, room - 8 - Theme.shoulderRadius)) + 6
    }

    var unit: CGFloat { geometry.height }

    /// Collapsed ears swell slightly under the cursor before peeking:
    /// immediate feedback that the notch noticed you.
    func nudged(_ width: CGFloat, _ side: NotchSide) -> CGFloat {
        width > 0 && nudgedSide == side && !isOpen(side) ? width + 6 : width
    }

    func width(_ content: LeftContent) -> CGFloat {
        switch content {
        case .none: 0
        case .musicArt, .claudeGlyph: unit + 4
        case .musicInfo(let expanded): expanded ? 280 : 230
        case .queue: 360
        case .timer: timerCollapsedWidth
        case .timerStrip: timerStripWidth
        case .claudeDetail(let expanded): claudeDetailWidth(expanded: expanded)
        case .claudePiece(let part): claudePieceWidth + width(part)
        }
    }

    func width(_ part: TimerPart) -> CGFloat {
        switch part {
        case .none: 0
        case .collapsed: timerCollapsedWidth(spark: false)
        case .strip: timerStripWidth(claudeChip: false)
        }
    }

    /// Claude's piece hugs its project name (the status rolls beneath it),
    /// widening on hover to fit time and usage. It may grow larger when it
    /// shares the screen with music only, as it has more to say.
    var claudePieceWidth: CGFloat { claudePieceWidth(hovered: claudePieceHovered) }

    func claudePieceWidth(hovered: Bool) -> CGFloat {
        if let answer = answerRowWidth { return answer }
        let cap: CGFloat = nowPlaying.isLive && timers.isEmpty ? 360 : 320
        let session = selectedSession
        // The name as drawn, plus 22 for a "+N" badge.
        var text = TextWidth.of(session?.projectName ?? "", Theme.TextStyle.title)
        if claude.visibleSessions.count > 1 { text += waitingElsewhere != nil ? 32 : 22 }
        if hovered, let session {
            // Hovered: time beside the title, usage after the description.
            let status = min(TextWidth.of(session.statusLine, Theme.TextStyle.body), 140)
            text = max(text + 36, status + usageLineWidth(for: session) - 30)
        }
        let chrome = unit + 4 + 12 + 10  // + the scrolling text's edge fade
        return (chrome + min(max(text, 96), cap - chrome)).rounded()
    }

    /// Claude's detail hugs its text too: the name when peeking; time,
    /// usage and the buttons when expanded.
    func claudeDetailWidth(expanded: Bool) -> CGFloat {
        if let answer = answerRowWidth { return answer }
        // Waiting for you, the peek also has the open-chat button.
        let open: CGFloat = selectedSession?.needsYou == true ? 28 : 0
        guard expanded else { return min(claudePieceWidth(hovered: false), 240) + open }
        guard let session = selectedSession else { return 240 }
        // Title + time on top; status (at least 120, it rolls) + usage below.
        let title = TextWidth.of(session.projectName, Theme.TextStyle.title) + 40
        let chips = usageChips(for: session)
        let usage = chips.isEmpty ? 0 : 12 + chips.reduce(0) { $0 + TextWidth.of($1.text, Theme.TextStyle.chip) + 6 }
        let status = min(TextWidth.of(session.statusLine, Theme.TextStyle.body), 160) + usage
        let buttons: CGFloat = 28 + (claude.visibleSessions.count > 1 ? 48 : 0)
        return min(unit + 4 + 22 + max(title, status, 120) + buttons, 420).rounded()
    }

    /// Elapsed time plus usage chips, as drawn.
    func usageLineWidth(for session: ClaudeSession) -> CGFloat {
        let chips = usageChips(for: session)
        return 30 + (chips.isEmpty ? 0 : 12 + chips.reduce(0) { $0 + TextWidth.of($1.text, Theme.TextStyle.chip) + 6 })
    }

    /// Music in the middle keeps a fixed width so the timers beside it
    /// never shift.
    var musicPieceWidth: CGFloat { 250 }

    /// Music at the outer end hugs its title, keeping it close to the controls.
    /// Hugs "Title · Artist", capped so a long title truncates.
    func pausedWidth(art: Bool) -> CGFloat {
        guard let snapshot = nowPlaying.current else { return unit + 4 }
        var text = TextWidth.of(snapshot.title, Theme.TextStyle.title)
        if !snapshot.artist.isEmpty { text += TextWidth.of(" · \(snapshot.artist)", Theme.TextStyle.title) }
        return ((art ? unit + 2 : 10) + min(text + 2, 170) + 10).rounded(.up)
    }

    var musicHugWidth: CGFloat {
        guard let snapshot = nowPlaying.current else { return 250 }
        let text = max(
            TextWidth.of(snapshot.title, Theme.TextStyle.title),
            TextWidth.of(snapshot.artist, Theme.TextStyle.body))
        // +10: the scrolling text's edge fade.
        return (unit + 4 + min(max(text + 10, 60), 200) + 8 + 76 + 10).rounded(.up)
    }

    func width(_ content: RightContent) -> CGFloat {
        switch content {
        case .none: 0
        case .musicBars, .claudeBadge: unit + 4
        case .musicCompact: unit * 2
        case .musicPaused(let art): pausedWidth(art: art)
        case .musicControls: 300
        case .musicFull(let expanded): geometry.hasNotch ? (expanded ? 340 : 300) : musicHugWidth
        case .claudeTool(let expanded): claudeToolWidth(expanded: expanded)
        case .musicWithTimers(let strip): musicPieceWidth + width(strip ? TimerPart.strip : .collapsed)
        }
    }

    /// Collapsed timers hug their content: glyph + time per shown timer,
    /// plus the "+N" badge and Claude's spark when present.
    var timerCollapsedWidth: CGFloat { timerCollapsedWidth(spark: true) }

    func timerCollapsedWidth(spark showsSpark: Bool) -> CGFloat {
        let now = Date.now
        // ~7.4 pt per character of the 11.5 pt semibold monospaced digits.
        let items = timers.collapsedTimers.map { timer -> CGFloat in
            let text: String
            if let remaining = timer.remaining(at: now) {
                text = (remaining < 0 ? "+" : "") + TimerParser.compact(remaining)
            } else {
                text = TimerParser.compact(timer.elapsed(at: now))
            }
            return unit * 0.5 + 4 + CGFloat(text.count) * 7.4
        }
        let badge: CGFloat = timers.hiddenCount > 0 ? 10 + CGFloat("+\(timers.hiddenCount)".count) * 7 : 0
        let spark: CGFloat = showsSpark && prefs.claudeEnabled && claude.primary?.activity.isWorking == true ? 17 : 0
        let spacing = CGFloat(max(0, items.count - 1)) * 8
        // Padding on both sides plus a little slack for a longer time.
        return 14 + items.reduce(0, +) + spacing + badge + spark + 6
    }

    /// The hover strip hugs its chips (Claude, each timer, +), with room
    /// for a hovered chip's buttons; it scrolls beyond the max width.
    var timerStripWidth: CGFloat { timerStripWidth(claudeChip: true) }

    func timerStripWidth(claudeChip showsClaude: Bool) -> CGFloat {
        let chip = unit + 92
        let claudeChip: CGFloat = showsClaude && prefs.claudeEnabled && claude.primary != nil ? chip + 6 : 0
        let add: CGFloat = timers.timers.count < TimerModel.maxTimers ? 30 : 0
        // A hovered chip shows its buttons (pin, pause, +5, stop); the
        // strip grows to fit them rather than keeping room spare.
        let buttons: CGFloat = hoveredTimerID.flatMap { id in timers.timers.first { $0.id == id } }
            .map { $0.isCountdown ? 84 : 64 } ?? 0
        return 12 + claudeChip + CGFloat(timers.timers.count) * (chip + 6) + add + buttons + 8
    }

    /// Timer strips may grow past the max ear width (they hug their chips),
    /// up to the room beside the notch; past that they scroll.
    var timerStripLimit: CGFloat { max(CGFloat(prefs.maxEarWidth), 600) }

    func clamp(_ width: CGFloat, room: CGFloat, limit: CGFloat? = nil) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(width, limit ?? CGFloat(prefs.maxEarWidth), max(0, room - 8 - Theme.shoulderRadius))
    }

    /// The Claude right ear hugs its two lines: what's happening now, and
    /// time · model · tokens beneath it.
    func claudeToolWidth(expanded: Bool) -> CGFloat {
        guard let session = selectedSession else { return 190 }
        let line = TextWidth.of(ClaudeToolDetail.primaryLine(session), Theme.TextStyle.title)
        let chips = claudeEarChips(for: session)
        let figures = 34 + chips.reduce(0) { $0 + TextWidth.of($1.text, Theme.TextStyle.chip) + 12 }
        let icon: CGFloat = session.activity.symbol != nil ? 18 : 0
        let cap: CGFloat = expanded ? 420 : 340
        return min(8 + icon + max(min(line + 10, cap - 60), figures, 120) + 12, cap).rounded(.up)
    }
}
