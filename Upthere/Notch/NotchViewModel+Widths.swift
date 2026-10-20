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
            // The pref caps the rolling text, never the controls beside it;
            // the ceiling caps everything.
            case .claudeDetail(let expanded):
                min(max(CGFloat(prefs.maxEarWidth), claudeDetailMinimum(expanded: expanded)), claudeEarCeiling)
            default: nil
            }
        return nudged(clamp(width(content), room: geometry.leftRoom, limit: limit), .left)
    }
    var rightWidth: CGFloat {
        let content = content.right
        let limit: CGFloat? =
            switch content {
            case .musicWithTimers: timerStripLimit + 260
            case .claudeTool: min(max(CGFloat(prefs.maxEarWidth), claudeToolMinimum), claudeEarCeiling)
            default: nil
            }
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
        let cap = claudePieceCap
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

    var claudePieceCap: CGFloat { nowPlaying.isLive && trayIsEmpty ? 360 : 320 }

    /// The hovered piece's figures that fit beside a little rolling status.
    func pieceChips(for session: ClaudeSession) -> [UsageChip] {
        let room = claudePieceCap - (unit + 4 + 12 + 10) - 60
        return fitting(usageChips(for: session), room: room - 8 - TextWidth.of("·", Theme.TextStyle.body))
    }

    /// Claude's detail hugs its text too: the name when peeking; time,
    /// usage and the buttons when expanded. With no chat, it's the plan
    /// usage, the same size hovered or clicked (there is nothing more).
    func claudeDetailWidth(expanded: Bool) -> CGFloat {
        if let answer = answerRowWidth { return answer }
        guard let session = selectedSession else { return usageSummaryWidth }
        let edges = 8 + unit + 4
        guard expanded else {
            // Waiting for you, the peek also has the open-chat button.
            let open = session.needsYou ? Self.detailButtons(1) : 0
            return min(claudePieceWidth(hovered: false), 240) + open
        }
        // Title + time on top; status (it rolls, so capped) + usage below.
        let top = TextWidth.of(session.projectName, Theme.TextStyle.title) + 4 + elapsedWidth(session)
        let bottom = min(TextWidth.of(session.statusLine, Theme.TextStyle.body), 160) + usageTailWidth(for: session)
        let text = max(top, bottom, 120)
        return min(edges + detailButtonsWidth + text, claudeEarCeiling).rounded(.up)
    }

    /// The widest a Claude ear gets, however much it has to say. Usage
    /// figures that don't fit drop from the end rather than widen it.
    var claudeEarCeiling: CGFloat { max(CGFloat(prefs.maxEarWidth), 420) }

    /// The figures after the detail's status line: as many as fit beside
    /// its buttons and a little rolling status.
    func detailChips(for session: ClaudeSession) -> [UsageChip] {
        let room = claudeEarCeiling - (8 + unit + 4 + detailButtonsWidth + 60)
        return fitting(usageChips(for: session), room: room - 8 - TextWidth.of("·", Theme.TextStyle.body))
    }

    /// The right ear's figures that fit beside its time.
    func toolChips(for session: ClaudeSession) -> [UsageChip] {
        let room = claudeEarCeiling - claudeToolChrome(session) - elapsedWidth(session)
        return fitting(claudeEarChips(for: session), room: room - 8 - TextWidth.of("·", Theme.TextStyle.body))
    }

    /// The leading chips that fit in `room`; the last ones go first.
    func fitting(_ chips: [UsageChip], room: CGFloat) -> [UsageChip] {
        var chips = chips
        while !chips.isEmpty && chipsWidth(chips) > room { chips.removeLast() }
        return chips
    }

    /// The least the detail can be: its buttons, time and usage figures
    /// whole, and a little of the rolling name and status beside them.
    func claudeDetailMinimum(expanded: Bool) -> CGFloat {
        guard let session = selectedSession else { return usageSummaryWidth }
        guard expanded else { return 0 }
        let figures = max(elapsedWidth(session) + 4, usageTailWidth(for: session))
        return (8 + unit + 4 + detailButtonsWidth + figures + 60).rounded(.up)
    }

    /// Open chat, plus the chat pager when there are several: 20 pt
    /// buttons 8 apart, and the spacing either side of the spacer.
    var detailButtonsWidth: CGFloat { Self.detailButtons(claude.visibleSessions.count > 1 ? 3 : 1) }

    static func detailButtons(_ count: Int) -> CGFloat { CGFloat(count) * 28 + 8 }

    /// No chat, just the plan: "Claude Pro" over its limits.
    var usageSummaryWidth: CGFloat {
        let title = TextWidth.of(claude.planName.map { "Claude \($0)" } ?? "Claude", Theme.TextStyle.title)
        let chips = chipsWidth(usageChips(for: nil))
        return (8 + max(title, chips) + 4 + unit + 4).rounded(.up)
    }

    /// The turn's elapsed time as drawn; sized for its digit count so the
    /// ear doesn't twitch every second.
    func elapsedWidth(_ session: ClaudeSession) -> CGFloat {
        let elapsed = Date.now.timeIntervalSince(session.turnStarted ?? session.since)
        return TextWidth.of(elapsed >= 3600 ? "0:00:00" : "00:00", Theme.TextStyle.figure)
    }

    /// " · 5h 12% · week 40%" after a status line, or nothing.
    func usageTailWidth(for session: ClaudeSession) -> CGFloat {
        let chips = detailChips(for: session)
        return chips.isEmpty ? 0 : 8 + TextWidth.of("·", Theme.TextStyle.body) + chipsWidth(chips)
    }

    /// A row of usage chips as `UsageChipsView` draws it.
    func chipsWidth(_ chips: [UsageChip]) -> CGFloat {
        guard !chips.isEmpty else { return 0 }
        let dots = CGFloat(chips.count - 1) * (8 + TextWidth.of("·", Theme.TextStyle.chip))
        return chips.reduce(dots) { $0 + TextWidth.of($1.text, Theme.TextStyle.chip) }
    }

    /// Elapsed time plus usage chips, as drawn.
    func usageLineWidth(for session: ClaudeSession) -> CGFloat {
        let chips = pieceChips(for: session)
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
            + reminders.collapsedReminders.map { item in
                ReminderMetrics.collapsedCheck(unit: unit) + 4
                    + min(TextWidth.of(item.title, Theme.TextStyle.label), ReminderMetrics.collapsedText)
            }
        let hidden = timers.hiddenCount + reminders.hiddenCount
        let badge: CGFloat = hidden > 0 ? 10 + CGFloat("+\(hidden)".count) * 7 : 0
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
        let add: CGFloat = (timers.timers.count < TimerModel.maxTimers ? 30 : 0) + (reminders.isAuthorized ? 30 : 0)
        // A hovered chip shows its buttons (pin, pause, +5, stop); the
        // strip grows to fit them rather than keeping room spare.
        let buttons = chipButtonsWidth(hoveredChip)
        // Reminder chips: check, text column, padding.
        let reminderChip = 7 + ReminderMetrics.chipCheck(unit: unit) + 6 + ReminderMetrics.chipText + 6
        let reminderChips = CGFloat(reminders.pinned.count) * (reminderChip + 6)
        return 12 + claudeChip + reminderChips + CGFloat(timers.timers.count) * (chip + 6) + add + buttons + 8
    }

    /// The room a hovered chip's buttons take in the strip.
    func chipButtonsWidth(_ chip: TrayChip?) -> CGFloat {
        switch chip {
        case .timer(let id): timers.timers.first { $0.id == id }.map { $0.isCountdown ? 84 : 64 } ?? 0
        case .reminder(let id): reminders.pinned.contains { $0.id == id } ? ReminderMetrics.chipButtons : 0
        case nil: 0
        }
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
        let cap: CGFloat = expanded ? 420 : 340
        let text = max(min(line + 10, cap - 60), claudeToolFigures(session), 120)
        return min(claudeToolChrome(session) + text, max(cap, claudeToolMinimum), claudeEarCeiling).rounded(.up)
    }

    /// The least the right ear can be: its figures whole.
    var claudeToolMinimum: CGFloat {
        guard let session = selectedSession else { return 0 }
        return (claudeToolChrome(session) + claudeToolFigures(session)).rounded(.up)
    }

    /// Padding, plus the state's symbol when there is one.
    func claudeToolChrome(_ session: ClaudeSession) -> CGFloat {
        8 + (session.activity.symbol != nil ? 18 : 0) + 12
    }

    /// Time · model · tokens, as drawn.
    private func claudeToolFigures(_ session: ClaudeSession) -> CGFloat {
        let chips = toolChips(for: session)
        let tail = chips.isEmpty ? 0 : 8 + TextWidth.of("·", Theme.TextStyle.body) + chipsWidth(chips)
        return elapsedWidth(session) + tail
    }
}
