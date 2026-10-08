import AppKit
import Observation

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
    /// Timers own the left ear while any run: the urgent one collapsed,
    /// all of them (plus Claude) as a strip when open.
    case timer
    case timerStrip
    case claudeGlyph
    case claudeDetail(expanded: Bool)
    /// Screens without a notch: Claude's piece next to the notch, with the
    /// timers (if any) further out.
    case claudePiece(timers: TimerPart)
}

/// The timers' share of a combined ear on a screen without a notch.
enum TimerPart: Hashable {
    case none, collapsed, strip
}

enum RightContent: Hashable {
    case none
    case musicBars
    case musicCompact
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
    var checkForUpdates: () -> Void
    var quit: () -> Void
}

@Observable
final class NotchViewModel {
    let nowPlaying: NowPlayingModel
    let claude: ClaudeModel
    let prefs: Preferences
    let queue: QueueModel
    let timers: TimerModel
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var openTimerInput: () -> Void = {}

    var geometry: NotchGeometry
    private(set) var leftMode: EarMode = .collapsed
    private(set) var rightMode: EarMode = .collapsed
    var selectedSessionID: String?

    /// A collapsed ear under the cursor swells slightly before it peeks.
    private(set) var nudgedSide: NotchSide?
    /// The seek bar is grown (hovered 150 ms, dragged or scroll-seeking);
    /// the music ear's content moves up to make room.
    private(set) var seekBarActive = false
    /// Where a drag or scroll would seek to, shown in the bar itself.
    private(set) var seekPreview: TimeInterval?
    private(set) var hud: HUD?
    private(set) var hudSide: NotchSide = .right

    @ObservationIgnored private var openTasks: [NotchSide: Task<Void, Never>] = [:]
    @ObservationIgnored private var closeTasks: [NotchSide: Task<Void, Never>] = [:]
    @ObservationIgnored private var outsideClickMonitor: Any?
    @ObservationIgnored private var scrollAxis: ScrollAxis?
    @ObservationIgnored private var lastScroll = Date.distantPast
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var seekHoverTask: Task<Void, Never>?
    @ObservationIgnored private var seekBarHovered = false
    @ObservationIgnored private var seekReleaseTask: Task<Void, Never>?

    init(
        nowPlaying: NowPlayingModel, claude: ClaudeModel, prefs: Preferences, geometry: NotchGeometry,
        queue: QueueModel? = nil, timers: TimerModel? = nil
    ) {
        self.nowPlaying = nowPlaying
        self.claude = claude
        self.prefs = prefs
        self.queue = queue ?? QueueModel(prefs: prefs)
        self.timers = timers ?? TimerModel(defaults: UserDefaults(suiteName: "upthere.preview") ?? .standard)
        self.geometry = geometry
        observeTrack()
    }

    // MARK: Track announcements

    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var tracksObserved = false

    /// When the track changes, briefly open the ear that shows the title.
    private func observeTrack() {
        let key = withObservationTracking {
            nowPlaying.current?.trackKey
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeTrack() } }
        }
        defer {
            lastTrackKey = key
            tracksObserved = true
            if showsQueue { queue.refresh(for: nowPlaying.current) }
        }
        // Not on launch, not when playback merely stops, and not where the
        // title is always showing anyway.
        guard tracksObserved, !musicRestsOpen, prefs.announceTracks, let key, key != lastTrackKey,
            nowPlaying.current?.isPlaying == true
        else { return }
        let side: NotchSide = .right  // the title lives in the right ear
        guard mode(side) == .collapsed else { return }
        setMode(side, .peek)
        closeTasks.removeValue(forKey: side)?.cancel()
        closeTasks[side] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, let self else { return }
            self.closeTasks[side] = nil
            if self.regionUnderCursor() != side { self.collapse(side) }
        }
    }

    // MARK: Presentation

    func mode(_ side: NotchSide) -> EarMode {
        switch side {
        case .left: leftMode
        case .right: rightMode
        case .center: .collapsed
        }
    }

    /// Claude needing you, or a countdown ending, auto-peeks the left ear.
    var effectiveLeftMode: EarMode {
        leftMode == .collapsed && (claude.attention != nil || timers.alertingID != nil) ? .peek : leftMode
    }

    var isAnyEarOpen: Bool { effectiveLeftMode != .collapsed || rightMode != .collapsed }

    var content: (left: LeftContent, right: RightContent) { content(left: effectiveLeftMode, right: rightMode) }

    /// Notchless screens have room to spare: the music ear rests showing
    /// title, artist and controls instead of just the bars.
    var musicRestsOpen: Bool { !geometry.hasNotch }

    /// Whether `side` shows its open layout (hovered, or resting open).
    func isOpen(_ side: NotchSide) -> Bool {
        mode(side) != .collapsed || (side == .right && musicRestsOpen && showsMusic(.right))
    }

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

    private func content(left l: EarMode, right r: EarMode) -> (left: LeftContent, right: RightContent) {
        // The music ear's mode, counting resting open as peeked.
        let rm: EarMode = r == .collapsed && musicRestsOpen ? .peek : r
        let sessionsLive = prefs.claudeEnabled && claude.isLive
        // With "show usage when idle", the Claude ear stays (ring + limits).
        let usageOnly = !sessionsLive && prefs.claudeEnabled && prefs.showUsageWhenIdle
            && claude.planUsage.map { $0.current().fiveHour != nil || $0.current().sevenDay != nil } == true
        let agents = sessionsLive || usageOnly
        // An open music ear keeps showing a paused/pinned player.
        let musicEarOpen = agents ? r != .collapsed : (l != .collapsed || r != .collapsed)
        let music = nowPlaying.isLive || (musicEarOpen && nowPlaying.current != nil)

        let claudeLeft: LeftContent = l == .collapsed ? .claudeGlyph : .claudeDetail(expanded: l == .expanded)

        // Screens without a notch have room for Claude, music and timers
        // side by side: [timers | Claude ‖ music], or with music as the
        // center piece [Claude ‖ music | timers]. Only the outer piece of an
        // ear opens on hover, so the pieces next to the notch never move.
        if !geometry.hasNotch, sessionsLive {
            let musicNow = nowPlaying.isLive || (r != .collapsed && nowPlaying.current != nil)
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
                ? .claudeDetail(expanded: false) : l == .collapsed ? .timer : .timerStrip
            let musicNow = nowPlaying.isLive || (r != .collapsed && nowPlaying.current != nil)
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

    /// Ear widths, without the shoulder flare.
    var leftWidth: CGFloat {
        let content = content.left
        let limit: CGFloat? =
            switch content {
            case .timerStrip: timerStripLimit
            case .claudePiece: timerStripLimit + 340
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

    private var unit: CGFloat { geometry.height }

    /// Collapsed ears swell slightly under the cursor before peeking:
    /// immediate feedback that the notch noticed you.
    private func nudged(_ width: CGFloat, _ side: NotchSide) -> CGFloat {
        width > 0 && nudgedSide == side && !isOpen(side) ? width + 6 : width
    }

    private func width(_ content: LeftContent) -> CGFloat {
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

    private func width(_ part: TimerPart) -> CGFloat {
        switch part {
        case .none: 0
        case .collapsed: timerCollapsedWidth(spark: false)
        case .strip: timerStripWidth(claudeChip: false)
        }
    }

    // MARK: Pieces (screens without a notch)

    /// The timer chip under the pointer, which shows its buttons.
    var hoveredTimerID: UUID?

    /// The pointer is on Claude's piece: it widens to fit time and usage.
    /// A chat picked by scrolling goes back to the most active one a little
    /// after the pointer leaves.
    var claudePieceHovered = false {
        didSet {
            guard claudePieceHovered != oldValue else { return }
            selectionResetTask?.cancel()
            guard !claudePieceHovered, selectedSessionID != nil else { return }
            let delay = prefs.earCloseDelay + 1.5
            selectionResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, !self.claudePieceHovered else { return }
                self.selectedSessionID = nil
            }
        }
    }

    /// Claude's piece hugs its project name (the status rolls beneath it),
    /// widening on hover to fit time and usage. It may grow larger when it
    /// shares the screen with music only, as it has more to say.
    var claudePieceWidth: CGFloat { claudePieceWidth(hovered: claudePieceHovered) }

    func claudePieceWidth(hovered: Bool) -> CGFloat {
        let cap: CGFloat = nowPlaying.isLive && timers.isEmpty ? 360 : 320
        let session = selectedSession
        // The name as drawn, plus 22 for a "+N" badge.
        var text = TextWidth.of(session?.projectName ?? "", size: 12, weight: .semibold)
        if claude.visibleSessions.count > 1 { text += 22 }
        if hovered, let session { text = max(text, usageLineWidth(for: session)) }
        let chrome = unit + 4 + 12 + 10  // + the scrolling text's edge fade
        return (chrome + min(max(text, 96), cap - chrome)).rounded()
    }

    /// Claude's detail hugs its text too: the name when peeking; time,
    /// usage and the buttons when expanded.
    private func claudeDetailWidth(expanded: Bool) -> CGFloat {
        guard expanded else { return min(claudePieceWidth(hovered: false), 240) }
        guard let session = selectedSession else { return 240 }
        // Title + time on top; status (at least 120, it rolls) + usage below.
        let title = TextWidth.of(session.projectName, size: 12, weight: .semibold) + 40
        let chips = usageChips(for: session)
        let usage = chips.isEmpty ? 0 : 12 + chips.reduce(0) { $0 + TextWidth.of($1.text, size: 10, weight: .medium) + 6 }
        let status = min(TextWidth.of(session.statusLine, size: 10.5, weight: .medium), 160) + usage
        let buttons: CGFloat = 28 + (claude.visibleSessions.count > 1 ? 48 : 0)
        return min(unit + 4 + 22 + max(title, status, 120) + buttons, 420).rounded()
    }

    /// Elapsed time plus usage chips, at ~5.6 pt per character.
    private func usageLineWidth(for session: ClaudeSession) -> CGFloat {
        let chips = usageChips(for: session)
        let characters = chips.reduce(0) { $0 + $1.text.count }
        return 30 + (chips.isEmpty ? 0 : 12 + CGFloat(characters) * 5.6 + CGFloat(chips.count) * 6)
    }

    /// Music in the middle keeps a fixed width so the timers beside it
    /// never shift.
    var musicPieceWidth: CGFloat { 250 }

    /// Music at the outer end hugs its title, keeping it close to the controls.
    private var musicHugWidth: CGFloat {
        guard let snapshot = nowPlaying.current else { return 250 }
        let text = max(
            TextWidth.of(snapshot.title, size: 12, weight: .semibold),
            TextWidth.of(snapshot.artist, size: 10.5, weight: .medium))
        // +10: the scrolling text's edge fade.
        return (unit + 4 + min(max(text + 10, 60), 200) + 8 + 76 + 10).rounded(.up)
    }

    /// Width of the piece next to the notch that stays as it is while the
    /// rest of the ear opens.
    private func innerPieceWidth(_ side: NotchSide) -> CGFloat? {
        let c = content
        switch side {
        case .left:
            if case .claudePiece(let part) = c.left, part != .none { return claudePieceWidth }
        case .right:
            if case .musicWithTimers = c.right { return musicPieceWidth }
        case .center: break
        }
        return nil
    }

    /// A closed ear's inner piece counts as the notch for hovering: only the
    /// outer piece opens the ear.
    private func overInnerPiece(_ side: NotchSide, distance: CGFloat) -> Bool {
        mode(side) == .collapsed && innerPieceWidth(side).map { distance < $0 } == true
    }

    private func width(_ content: RightContent) -> CGFloat {
        switch content {
        case .none: 0
        case .musicBars, .claudeBadge: unit + 4
        case .musicCompact: unit * 2
        case .musicControls: 300
        case .musicFull(let expanded): geometry.hasNotch ? (expanded ? 340 : 300) : musicHugWidth
        case .claudeTool(let expanded): expanded ? 300 : 190
        case .musicWithTimers(let strip): musicPieceWidth + width(strip ? TimerPart.strip : .collapsed)
        }
    }

    /// Collapsed timers hug their content: glyph + time per shown timer,
    /// plus the "+N" badge and Claude's spark when present.
    private var timerCollapsedWidth: CGFloat { timerCollapsedWidth(spark: true) }

    private func timerCollapsedWidth(spark showsSpark: Bool) -> CGFloat {
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
    private var timerStripWidth: CGFloat { timerStripWidth(claudeChip: true) }

    private func timerStripWidth(claudeChip showsClaude: Bool) -> CGFloat {
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
    private var timerStripLimit: CGFloat { max(CGFloat(prefs.maxEarWidth), 600) }

    private func clamp(_ width: CGFloat, room: CGFloat, limit: CGFloat? = nil) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(width, limit ?? CGFloat(prefs.maxEarWidth), max(0, room - 8 - Theme.shoulderRadius))
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
            case .musicBars, .musicCompact, .musicControls, .musicFull, .musicWithTimers: return true
            default: return false
            }
        case .center: return false
        }
    }

    // MARK: Colors

    static let claudePalette = [
        Theme.claude, NSColor(srgbRed: 0.96, green: 0.42, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.66, blue: 0.32, alpha: 1),
    ]
    static let attentionPalette = [
        Theme.amber, NSColor(srgbRed: 1.0, green: 0.55, blue: 0.2, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.86, blue: 0.4, alpha: 1),
    ]
    static let inputPalette = [
        Theme.input, NSColor(srgbRed: 0.55, green: 0.5, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.4, green: 0.82, blue: 1.0, alpha: 1),
    ]
    static let neutralPalette = [NSColor(white: 0.9, alpha: 1), NSColor(white: 0.75, alpha: 1), NSColor(white: 0.6, alpha: 1)]

    var musicPalette: [NSColor] { nowPlaying.artwork?.palette ?? Self.neutralPalette }

    /// The colors an ear is tinted with: the cover's for music, Claude's
    /// own for agents (amber while it needs you).
    func palette(for side: NotchSide) -> [NSColor] {
        let music = showsMusic(side) || (side == .left && !claudeShown && showsMusic(.right))
            || (side == .right && !claudeShown && showsMusic(.left))
        if music { return musicPalette }
        switch claude.attention?.activity {
        case .permission: return Self.attentionPalette
        case .input: return Self.inputPalette
        default: return Self.claudePalette
        }
    }

    private var claudeShown: Bool {
        switch content.left {
        case .claudeGlyph, .claudeDetail, .claudePiece: true
        default: false
        }
    }

    /// The session shown in the agent ear.
    var selectedSession: ClaudeSession? {
        if let id = selectedSessionID, let session = claude.visibleSessions.first(where: { $0.id == id }) {
            return session
        }
        return claude.primary
    }

    func usageChips(for session: ClaudeSession?) -> [UsageChip] {
        UsageInfo.chips(for: session, plan: claude.planUsage, weeklyTokens: claude.weeklyTokens, prefs: prefs)
    }

    var usageRing: Double? {
        UsageInfo.ringValue(for: selectedSession, plan: claude.planUsage, prefs: prefs)
    }

    func cycleSession(by offset: Int) {
        let sessions = claude.visibleSessions
        guard sessions.count > 1 else { return }
        let current = sessions.firstIndex { $0.id == selectedSession?.id } ?? 0
        selectedSessionID = sessions[(current + offset + sessions.count) % sessions.count].id
    }

    // MARK: Interaction

    /// Hover enter/exit events only say "something changed": what is hovered
    /// is read from the cursor's actual position (events from two panels can
    /// arrive in any order). Only the ear under the pointer opens; the notch
    /// itself opens nothing. An ear the pointer left stays open for the
    /// user's chosen delay.
    func hover(_ region: NotchSide, inside: Bool) {
        #if DEBUG
        if debugHold { return }
        #endif
        let region = regionUnderCursor()
        // Pointer moves only matter when they cross into another region.
        if inside, region == lastHoverRegion { return }
        lastHoverRegion = region
        for side in [NotchSide.left, .right] {
            if region == side {
                closeTasks.removeValue(forKey: side)?.cancel()
                guard mode(side) == .collapsed, openTasks[side] == nil else { continue }
                if nudgedSide != side { nudgedSide = side }
                // Hover intent: ignore the cursor just passing through the menu bar.
                openTasks[side] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled, let self else { return }
                    self.openTasks[side] = nil
                    if self.regionUnderCursor() == side { self.setMode(side, .peek) }
                }
            } else {
                openTasks.removeValue(forKey: side)?.cancel()
                if nudgedSide == side { nudgedSide = nil }
                guard mode(side) != .collapsed, closeTasks[side] == nil else { continue }
                let delay = mode(side) == .expanded ? max(prefs.earCloseDelay, 0.6) : prefs.earCloseDelay
                closeTasks[side] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    self.closeTasks[side] = nil
                    if self.regionUnderCursor() != side { self.collapse(side) }
                }
            }
        }
    }

    @ObservationIgnored private var lastHoverRegion: NotchSide?? = .none

    /// Which part of the notch is under the cursor: an ear (with its
    /// shoulder), the notch itself, or nothing.
    func regionUnderCursor(at point: CGPoint? = nil) -> NotchSide? {
        let p = point ?? NSEvent.mouseLocation
        let g = geometry
        guard p.y >= g.screenFrame.maxY - g.height - 1, p.y <= g.screenFrame.maxY + 1 else { return nil }
        let left = leftWidth > 0 ? leftWidth + Theme.shoulderRadius : 0
        let right = rightWidth > 0 ? rightWidth + Theme.shoulderRadius : 0
        if p.x >= g.notchRect.minX && p.x <= g.notchRect.maxX { return g.hasNotch || left + right > 0 ? .center : nil }
        if p.x < g.notchRect.minX && p.x >= g.notchRect.minX - left {
            return overInnerPiece(.left, distance: g.notchRect.minX - p.x) ? .center : .left
        }
        if p.x > g.notchRect.maxX && p.x <= g.notchRect.maxX + right {
            return overInnerPiece(.right, distance: p.x - g.notchRect.maxX) ? .center : .right
        }
        return nil
    }

    #if DEBUG
    /// Debug commands hold their state: the real pointer is elsewhere, and
    /// its hover events would otherwise close what was opened.
    @ObservationIgnored private var debugHold = false

    func debugSet(left: EarMode, right: EarMode) {
        debugHold = left != .collapsed || right != .collapsed
        setMode(.left, left)
        setMode(.right, right)
    }

    func debugShowHUD(_ value: HUD, side: NotchSide) {
        setMode(side, .peek)
        showHUD(value, side: side, hold: .seconds(3))
    }
    #endif

    /// Click on an ear: expand it, or back to a peek if it's expanded.
    /// Music ears don't expand: everything (seek bar included) is already
    /// there on hover.
    func tap(_ side: NotchSide) {
        guard side != .center, !showsMusic(side) else { return }
        openTasks.removeValue(forKey: side)?.cancel()
        if mode(side) == .expanded {
            setMode(side, .peek)
        } else {
            setMode(side, .expanded)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func collapse(_ side: NotchSide) {
        guard side != .center else { return }
        openTasks.removeValue(forKey: side)?.cancel()
        closeTasks.removeValue(forKey: side)?.cancel()
        if hudSide == side {
            hudTask?.cancel()
            hud = nil
        }
        if nudgedSide == side { nudgedSide = nil }
        if side == .left { selectedSessionID = nil }
        setMode(side, .collapsed)
    }

    func collapseAll() {
        collapse(.left)
        collapse(.right)
    }

    private func setMode(_ side: NotchSide, _ new: EarMode) {
        switch side {
        case .left: if leftMode != new { leftMode = new }
        case .right: if rightMode != new { rightMode = new }
        case .center: return
        }
        updateOutsideClickMonitor()
        if side == .left && showsQueue { queue.refresh(for: nowPlaying.current) }
    }

    /// While an ear is expanded, a click anywhere else collapses it. The
    /// global monitor only exists in that state, so it costs nothing otherwise.
    private func updateOutsideClickMonitor() {
        let expanded = leftMode == .expanded || rightMode == .expanded
        if expanded, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for side in [NotchSide.left, .right] where self.mode(side) == .expanded { self.collapse(side) }
                }
            }
        } else if !expanded, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: Scrolling (seek / volume)

    enum HUD: Equatable {
        case volume(Float)
    }

    private enum ScrollAxis { case horizontal, vertical }

    /// Horizontal scroll over the music ear seeks; vertical changes the
    /// system volume. The axis is locked per gesture so diagonal swipes don't
    /// do both. Returns whether the event was consumed.
    func scroll(_ event: NSEvent, side: NotchSide) -> Bool {
        if side == .left, cursorOverClaude() { return scrollSessions(event) }
        guard showsMusic(side), let current = nowPlaying.current else { return false }
        if !event.momentumPhase.isEmpty { return true }

        let now = Date.now
        if event.phase.contains(.began) || now.timeIntervalSince(lastScroll) > 0.35 { scrollAxis = nil }
        lastScroll = now

        // Device direction: positive = fingers right / up, regardless of natural scrolling.
        let inverted = event.isDirectionInvertedFromDevice
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
        if scrollAxis == nil {
            guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return true }
            scrollAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
        }
        let precise = event.hasPreciseScrollingDeltas
        // Sideways over Up Next scrolls the list, not the track.
        if scrollAxis == .horizontal && side == .left && showsQueue { return false }
        if mode(side) == .collapsed && regionUnderCursor() == side { setMode(side, .peek) }

        switch scrollAxis {
        case .horizontal where prefs.scrollToSeek:
            guard let duration = current.duration, duration > 0 else { return true }
            let base = seekPreview ?? current.position()
            let target = min(duration, max(0, base + Double(dx) * (precise ? 0.35 : 4)))
            previewSeek(target)
            let delay = event.phase.contains(.ended) ? 0 : 280
            seekTask?.cancel()
            seekTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.endSeek(at: target, after: .milliseconds(700))
            }
        case .vertical where prefs.scrollForVolume:
            let base: Float
            if case .volume(let v) = hud { base = v } else { base = SystemVolume.volume ?? 0.5 }
            guard let value = SystemVolume.set(base + Float(dy) * (precise ? 0.004 : 0.04)) else { return true }
            showHUD(.volume(value), side: side, hold: .milliseconds(1100))
        default:
            return false
        }
        return true
    }

    // MARK: Switching chats

    @ObservationIgnored private var sessionScroll: CGFloat = 0
    /// One gesture switches at most once: locked after a switch until the
    /// fingers lift (trackpad) or the wheel rests for a moment.
    @ObservationIgnored private var sessionScrollLocked = false
    @ObservationIgnored private var lastSessionScroll = Date.distantPast
    @ObservationIgnored private var selectionResetTask: Task<Void, Never>?

    /// Whether the pointer is over Claude's part of the left ear.
    private func cursorOverClaude() -> Bool {
        switch content.left {
        case .claudeGlyph, .claudeDetail: return true
        case .claudePiece: return geometry.notchRect.minX - NSEvent.mouseLocation.x < claudePieceWidth
        default: return false
        }
    }

    /// Scrolling over Claude switches to the next or previous chat: one
    /// switch per gesture, after ~60 pt of trackpad travel or a wheel notch.
    private func scrollSessions(_ event: NSEvent) -> Bool {
        guard claude.visibleSessions.count > 1 else { return false }
        let now = Date.now
        // A new gesture: fingers down, or the wheel resting for 0.45 s.
        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty
            && now.timeIntervalSince(lastSessionScroll) > 0.45)
        {
            sessionScroll = 0
            sessionScrollLocked = false
        }
        lastSessionScroll = now
        // Momentum belongs to the gesture that already switched (or didn't).
        guard event.momentumPhase.isEmpty, !sessionScrollLocked else { return true }
        let inverted = event.isDirectionInvertedFromDevice
        let dy = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let delta = abs(dy) >= abs(dx) ? dy : dx
        let step: Int
        if event.hasPreciseScrollingDeltas {
            sessionScroll += delta
            guard abs(sessionScroll) >= 60 else { return true }
            step = sessionScroll > 0 ? 1 : -1
        } else {
            guard abs(delta) >= 1 else { return true }
            step = delta > 0 ? 1 : -1
        }
        sessionScrollLocked = true
        sessionScroll = 0
        cycleSession(by: step)
        if mode(.left) == .collapsed, case .claudeGlyph = content.left { setMode(.left, .peek) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return true
    }

    // MARK: Seek bar

    func seekBarHover(_ inside: Bool) {
        seekBarHovered = inside
        seekHoverTask?.cancel()
        if inside {
            seekHoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.seekBarHovered else { return }
                self.seekBarActive = true
            }
        } else if seekPreview == nil {
            seekBarActive = false
        }
    }

    /// While dragging or scrolling: grow the bar and show the target in it.
    func previewSeek(_ seconds: TimeInterval) {
        seekReleaseTask?.cancel()
        seekPreview = seconds
        if !seekBarActive { seekBarActive = true }
    }

    /// Seeks (if `commit`) and lets the preview go shortly after, so the bar
    /// doesn't snap back before the player catches up.
    func endSeek(at seconds: TimeInterval?, after delay: Duration = .milliseconds(450)) {
        if let seconds { nowPlaying.send(.seek(seconds)) }
        seekReleaseTask?.cancel()
        seekReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.seekPreview = nil
            if !self.seekBarHovered { self.seekBarActive = false }
        }
    }

    private func showHUD(_ value: HUD, side: NotchSide, hold: Duration) {
        hudSide = side
        hud = value
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }
}

/// Measures text as the ears draw it (system font), so ears can hug their
/// content. Cached: titles and names change rarely.
enum TextWidth {
    private static var cache: [String: CGFloat] = [:]

    static func of(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let key = "\(size)|\(weight.rawValue)|\(text)"
        if let width = cache[key] { return width }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        if cache.count > 200 { cache.removeAll() }
        cache[key] = width
        return width
    }
}
