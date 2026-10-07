import AppKit
import Observation

enum NotchSide: Equatable { case left, center, right }

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

    @ObservationIgnored private var hovered: Set<NotchSide> = []
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

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

    var leftWidth: CGFloat { clamp(width(content.left), room: geometry.leftRoom) }
    var rightWidth: CGFloat { clamp(width(content.right), room: geometry.rightRoom) }

    private var unit: CGFloat { geometry.height }

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
        case .musicControls(let expanded): expanded ? 230 : 140
        case .musicFull(let expanded): expanded ? 340 : 300
        case .claudeTool(let expanded): expanded ? 300 : 190
        }
    }

    private func clamp(_ width: CGFloat, room: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(width, CGFloat(prefs.maxEarWidth), max(0, room - 8))
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
            guard mode != .expanded, mode != .peek(side) else { return }
            // Hover intent: ignore the cursor just passing through the menu bar.
            let delay: Duration = mode == .collapsed ? .milliseconds(110) : .milliseconds(70)
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.mode = .peek(side)
            }
        } else if mode != .collapsed {
            let delay: Duration = mode == .expanded ? .milliseconds(650) : .milliseconds(350)
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.mode = .collapsed
                self.selectedSessionID = nil
            }
        }
    }

    #if DEBUG
    func debugSetMode(_ mode: NotchMode) {
        hoverTask?.cancel()
        self.mode = mode
    }
    #endif

    func tap() {
        hoverTask?.cancel()
        if mode == .expanded {
            mode = hovered.isEmpty ? .collapsed : .peek(.center)
        } else {
            mode = .expanded
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}
