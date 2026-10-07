import AppKit
import Observation

nonisolated enum NotchSide: Equatable, Sendable { case left, center, right }

enum NotchMode: Equatable {
    case collapsed
    case peek(NotchSide)
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
    private(set) var mode: NotchMode = .collapsed
    var selectedSessionID: String?

    /// Collapsed + under the cursor (before the peek kicks in).
    private(set) var hoverNudge = false
    private(set) var hud: HUD?
    private(set) var hudSide: NotchSide = .right

    @ObservationIgnored private var hovered: Set<NotchSide> = []
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
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
    }

    // MARK: Presentation

    /// Claude asking for permission auto-peeks the agent ear.
    var effectiveMode: NotchMode {
        if mode == .collapsed && claude.attention != nil { return .peek(.left) }
        return mode
    }

    var content: (left: LeftContent, right: RightContent) {
        let mode = effectiveMode
        let collapsed = mode == .collapsed
        // Hovering reveals a paused/pinned player even after it stopped being "live".
        let music = nowPlaying.isLive || (!collapsed && nowPlaying.current != nil)
        let agents = prefs.claudeEnabled && claude.isLive

        switch (music, agents) {
        case (false, false):
            return (.none, .none)
        case (true, false):
            switch mode {
            case .collapsed: return (.musicArt, .musicBars)
            case .peek: return (.musicInfo(expanded: false), .musicControls(expanded: false))
            case .expanded: return (.musicInfo(expanded: true), .musicControls(expanded: true))
            }
        case (false, true):
            switch mode {
            case .collapsed: return (.claudeGlyph, .claudeBadge)
            case .peek: return (.claudeDetail(expanded: false), .claudeTool(expanded: false))
            case .expanded: return (.claudeDetail(expanded: true), .claudeTool(expanded: true))
            }
        case (true, true):
            switch mode {
            case .collapsed: return (.claudeGlyph, .musicCompact)
            case .peek(.left): return (.claudeDetail(expanded: false), .musicCompact)
            case .peek: return (.claudeGlyph, .musicFull(expanded: false))
            case .expanded: return (.claudeDetail(expanded: true), .musicFull(expanded: true))
            }
        }
    }

    /// Ear widths, without the shoulder flare.
    var leftWidth: CGFloat { nudged(clamp(width(content.left), room: geometry.leftRoom)) }
    var rightWidth: CGFloat { nudged(clamp(width(content.right), room: geometry.rightRoom)) }

    /// Window extents beside the notch: ear plus shoulder.
    var leftExtent: CGFloat { leftWidth > 0 ? leftWidth + Theme.shoulderRadius : 0 }
    var rightExtent: CGFloat { rightWidth > 0 ? rightWidth + Theme.shoulderRadius : 0 }

    private var unit: CGFloat { geometry.height }

    /// Collapsed ears swell slightly under the cursor before peeking:
    /// immediate feedback that the notch noticed you.
    private func nudged(_ width: CGFloat) -> CGFloat {
        width > 0 && hoverNudge && mode == .collapsed ? width + 6 : width
    }

    private func width(_ content: LeftContent) -> CGFloat {
        switch content {
        case .none: 0
        case .musicArt, .claudeGlyph: unit + 4
        case .musicInfo(let expanded): expanded ? 280 : 230
        case .claudeDetail(let expanded): expanded ? 300 : 240
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
        guard hud != nil, hudSide == side, mode != .collapsed else { return false }
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

    func cycleSession(by offset: Int) {
        let sessions = claude.visibleSessions
        guard sessions.count > 1 else { return }
        let current = sessions.firstIndex { $0.id == selectedSession?.id } ?? 0
        selectedSessionID = sessions[(current + offset + sessions.count) % sessions.count].id
    }

    // MARK: Interaction

    func hover(_ side: NotchSide, inside: Bool) {
        if inside { hovered.insert(side) } else { hovered.remove(side) }
        hoverTask?.cancel()

        let side: NotchSide? =
            hovered.isEmpty ? nil : hovered.contains(.left) ? .left : hovered.contains(.right) ? .right : .center
        if let side {
            if mode == .collapsed && !hoverNudge { hoverNudge = true }
            guard mode != .expanded, mode != .peek(side) else { return }
            // Hover intent: ignore the cursor just passing through the menu bar.
            let delay: Duration = mode == .collapsed ? .milliseconds(120) : .milliseconds(70)
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.setMode(.peek(side))
            }
        } else {
            if hoverNudge { hoverNudge = false }
            guard mode != .collapsed else { return }
            let delay: Duration = mode == .expanded ? .milliseconds(700) : .milliseconds(300)
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    #if DEBUG
    func debugSetMode(_ mode: NotchMode) {
        hoverTask?.cancel()
        setMode(mode)
    }

    func debugShowHUD(_ value: HUD, side: NotchSide) {
        setMode(.peek(side))
        showHUD(value, side: side, hold: .seconds(3))
    }
    #endif

    func tap() {
        hoverTask?.cancel()
        if mode == .expanded {
            if hovered.isEmpty { collapse() } else { setMode(.peek(.center)) }
        } else {
            setMode(.expanded)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func collapse() {
        hoverTask?.cancel()
        hudTask?.cancel()
        hud = nil
        hoverNudge = false
        selectedSessionID = nil
        setMode(.collapsed)
    }

    private func setMode(_ new: NotchMode) {
        guard new != mode else { return }
        mode = new
        updateOutsideClickMonitor()
    }

    /// While expanded, a click anywhere else collapses the notch. The global
    /// monitor only exists in that state, so it costs nothing otherwise.
    private func updateOutsideClickMonitor() {
        if mode == .expanded, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.collapse() }
            }
        } else if mode != .expanded, let monitor = outsideClickMonitor {
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
        if mode == .collapsed { setMode(.peek(side)) }

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
