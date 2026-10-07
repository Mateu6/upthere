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
    case claudeGlyph
    case claudeDetail(expanded: Bool)
}

enum RightContent: Hashable {
    case none
    case musicBars
    case musicCompact
    case musicControls(expanded: Bool)
    case musicFull(expanded: Bool)
    case claudeBadge
    case claudeTool(expanded: Bool)
}

struct NotchActions {
    var openSettings: () -> Void
    var checkForUpdates: () -> Void
    var quit: () -> Void
}

@Observable
final class NotchViewModel {
    let nowPlaying: NowPlayingModel
    let claude: ClaudeModel
    let prefs: Preferences

    var geometry: NotchGeometry
    private(set) var leftMode: EarMode = .collapsed
    private(set) var rightMode: EarMode = .collapsed
    var selectedSessionID: String?

    /// A collapsed ear under the cursor swells slightly before it peeks.
    private(set) var nudgedSide: NotchSide?
    private(set) var hud: HUD?
    private(set) var hudSide: NotchSide = .right

    @ObservationIgnored private var openTasks: [NotchSide: Task<Void, Never>] = [:]
    @ObservationIgnored private var closeTasks: [NotchSide: Task<Void, Never>] = [:]
    @ObservationIgnored private var outsideClickMonitor: Any?
    @ObservationIgnored private var scrollAxis: ScrollAxis?
    @ObservationIgnored private var lastScroll = Date.distantPast
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?

    init(nowPlaying: NowPlayingModel, claude: ClaudeModel, prefs: Preferences, geometry: NotchGeometry) {
        self.nowPlaying = nowPlaying
        self.claude = claude
        self.prefs = prefs
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
        }
        // Not on launch, and not when playback merely stops.
        guard tracksObserved, prefs.announceTracks, let key, key != lastTrackKey,
            nowPlaying.current?.isPlaying == true
        else { return }
        let side: NotchSide = prefs.claudeEnabled && claude.isLive ? .right : .left
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

    /// Claude asking for permission auto-peeks the agent ear.
    var effectiveLeftMode: EarMode {
        leftMode == .collapsed && claude.attention != nil ? .peek : leftMode
    }

    var isAnyEarOpen: Bool { effectiveLeftMode != .collapsed || rightMode != .collapsed }

    var content: (left: LeftContent, right: RightContent) {
        let l = effectiveLeftMode
        let r = rightMode
        let agents = prefs.claudeEnabled && claude.isLive
        // An open music ear keeps showing a paused/pinned player.
        let musicEarOpen = agents ? r != .collapsed : (l != .collapsed || r != .collapsed)
        let music = nowPlaying.isLive || (musicEarOpen && nowPlaying.current != nil)

        let claudeLeft: LeftContent = l == .collapsed ? .claudeGlyph : .claudeDetail(expanded: l == .expanded)
        switch (music, agents) {
        case (false, false):
            return (.none, .none)
        case (true, false):
            return (
                l == .collapsed ? .musicArt : .musicInfo(expanded: l == .expanded),
                r == .collapsed ? .musicBars : .musicControls(expanded: r == .expanded)
            )
        case (false, true):
            return (claudeLeft, r == .collapsed ? .claudeBadge : .claudeTool(expanded: r == .expanded))
        case (true, true):
            return (claudeLeft, r == .collapsed ? .musicCompact : .musicFull(expanded: r == .expanded))
        }
    }

    /// Ear widths, without the shoulder flare.
    var leftWidth: CGFloat { nudged(clamp(width(content.left), room: geometry.leftRoom), .left) }
    var rightWidth: CGFloat { nudged(clamp(width(content.right), room: geometry.rightRoom), .right) }

    /// The widest an ear can get on this screen (including the hover nudge).
    func maxEarWidth(room: CGFloat) -> CGFloat {
        min(CGFloat(prefs.maxEarWidth), max(0, room - 8 - Theme.shoulderRadius)) + 6
    }

    private var unit: CGFloat { geometry.height }

    /// Collapsed ears swell slightly under the cursor before peeking:
    /// immediate feedback that the notch noticed you.
    private func nudged(_ width: CGFloat, _ side: NotchSide) -> CGFloat {
        width > 0 && nudgedSide == side && mode(side) == .collapsed ? width + 6 : width
    }

    private func width(_ content: LeftContent) -> CGFloat {
        switch content {
        case .none: 0
        case .musicArt, .claudeGlyph: unit + 4
        case .musicInfo(let expanded): expanded ? 280 : 230
        case .claudeDetail(let expanded): expanded ? 340 : 240
        }
    }

    private func width(_ content: RightContent) -> CGFloat {
        switch content {
        case .none: 0
        case .musicBars, .claudeBadge: unit + 4
        case .musicCompact: unit * 2
        case .musicControls(let expanded): expanded ? 230 : 150
        case .musicFull(let expanded): expanded ? 340 : 300
        case .claudeTool(let expanded): expanded ? 300 : 190
        }
    }

    private func clamp(_ width: CGFloat, room: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(width, CGFloat(prefs.maxEarWidth), max(0, room - 8 - Theme.shoulderRadius))
    }

    /// The seek/volume overlay needs a widened music ear.
    func showsHUD(on side: NotchSide) -> Bool {
        guard hud != nil, hudSide == side, mode(side) != .collapsed else { return false }
        let c = content
        switch side {
        case .left: if case .musicInfo = c.left { return true }
        case .right:
            switch c.right {
            case .musicControls, .musicFull: return true
            default: break
            }
        case .center: break
        }
        return false
    }

    func showsMusic(_ side: NotchSide) -> Bool {
        let c = content
        switch side {
        case .left: return c.left == .musicArt || { if case .musicInfo = c.left { true } else { false } }()
        case .right:
            switch c.right {
            case .musicBars, .musicCompact, .musicControls, .musicFull: return true
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
    static let neutralPalette = [NSColor(white: 0.9, alpha: 1), NSColor(white: 0.75, alpha: 1), NSColor(white: 0.6, alpha: 1)]

    var musicPalette: [NSColor] { nowPlaying.artwork?.palette ?? Self.neutralPalette }

    /// The colors an ear is tinted with: the cover's for music, Claude's
    /// own for agents (amber while it needs you).
    func palette(for side: NotchSide) -> [NSColor] {
        let music = showsMusic(side) || (side == .left && !claudeShown && showsMusic(.right))
            || (side == .right && !claudeShown && showsMusic(.left))
        if music { return musicPalette }
        return claude.attention != nil ? Self.attentionPalette : Self.claudePalette
    }

    private var claudeShown: Bool {
        switch content.left {
        case .claudeGlyph, .claudeDetail: true
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
        let region = regionUnderCursor()
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

    /// Which part of the notch is under the cursor: an ear (with its
    /// shoulder), the notch itself, or nothing.
    func regionUnderCursor(at point: CGPoint? = nil) -> NotchSide? {
        let p = point ?? NSEvent.mouseLocation
        let g = geometry
        guard p.y >= g.screenFrame.maxY - g.height - 1, p.y <= g.screenFrame.maxY + 1 else { return nil }
        let left = leftWidth > 0 ? leftWidth + Theme.shoulderRadius : 0
        let right = rightWidth > 0 ? rightWidth + Theme.shoulderRadius : 0
        if p.x >= g.notchRect.minX && p.x <= g.notchRect.maxX { return g.hasNotch || left + right > 0 ? .center : nil }
        if p.x < g.notchRect.minX && p.x >= g.notchRect.minX - left { return .left }
        if p.x > g.notchRect.maxX && p.x <= g.notchRect.maxX + right { return .right }
        return nil
    }

    #if DEBUG
    func debugSet(left: EarMode, right: EarMode) {
        setMode(.left, left)
        setMode(.right, right)
    }

    func debugShowHUD(_ value: HUD, side: NotchSide) {
        setMode(side, .peek)
        showHUD(value, side: side, hold: .seconds(3))
    }
    #endif

    /// Click on an ear: expand it, or back to a peek if it's expanded.
    func tap(_ side: NotchSide) {
        guard side != .center else { return }
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
        case seek(TimeInterval)
        case volume(Float)
    }

    private enum ScrollAxis { case horizontal, vertical }

    /// Horizontal scroll over the music ear seeks; vertical changes the
    /// system volume. The axis is locked per gesture so diagonal swipes don't
    /// do both. Returns whether the event was consumed.
    func scroll(_ event: NSEvent, side: NotchSide) -> Bool {
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
        if mode(side) == .collapsed { setMode(side, .peek) }

        switch scrollAxis {
        case .horizontal where prefs.scrollToSeek:
            guard let duration = current.duration, duration > 0 else { return true }
            let base: TimeInterval
            if case .seek(let t) = hud { base = t } else { base = current.position() }
            let target = min(duration, max(0, base + Double(dx) * (precise ? 0.35 : 4)))
            showHUD(.seek(target), side: side, hold: .milliseconds(900))
            let delay = event.phase.contains(.ended) ? 0 : 280
            seekTask?.cancel()
            seekTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.nowPlaying.send(.seek(target))
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
