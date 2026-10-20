import AppKit
import Observation

/// The notch's state: which ear is open, what it shows and how wide it is.
/// The logic lives in the extensions beside this file (`+Layout`, `+Widths`,
/// `+Sessions`, `+Answer`, `+Palette`, `+Hover`, `+Scroll`); stored state
/// stays here, as Swift requires.
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
    var nudgedSide: NotchSide?
    /// The seek bar is grown (hovered 150 ms, dragged or scroll-seeking);
    /// the music ear's content moves up to make room.
    var seekBarActive = false
    /// Where a drag or scroll would seek to, shown in the bar itself.
    var seekPreview: TimeInterval?
    var hud: HUD?
    var hudSide: NotchSide = .right

    @ObservationIgnored var openTasks: [NotchSide: Task<Void, Never>] = [:]
    @ObservationIgnored var closeTasks: [NotchSide: Task<Void, Never>] = [:]
    @ObservationIgnored var outsideClickMonitor: Any?
    @ObservationIgnored var pointerMonitor: Any?
    @ObservationIgnored var scrollAxis: ScrollAxis?
    @ObservationIgnored var lastScroll = Date.distantPast
    @ObservationIgnored var seekTask: Task<Void, Never>?
    @ObservationIgnored var hudTask: Task<Void, Never>?
    @ObservationIgnored var seekHoverTask: Task<Void, Never>?
    @ObservationIgnored var seekBarHovered = false
    @ObservationIgnored var seekReleaseTask: Task<Void, Never>?

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
        // Every skip restarts the countdown, even while the ear is still
        // open from the last one; only the pointer resting on it keeps it.
        let open = mode(side) == .peek && regionUnderCursor() != side
        guard mode(side) == .collapsed || open else { return }
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
        let claudeCalls = prefs.claudeEnabled && (claude.attention != nil || claude.justFinishedSession != nil)
        return leftMode == .collapsed && (claudeCalls || timers.alertingID != nil) ? .peek : leftMode
    }

    var isAnyEarOpen: Bool { effectiveLeftMode != .collapsed || rightMode != .collapsed }

    var content: (left: LeftContent, right: RightContent) { content(left: effectiveLeftMode, right: rightMode) }

    /// The theme for the screen the notch is on (screens without a notch
    /// can have their own).
    var appearance: Appearance { prefs.appearance(hasNotch: geometry.hasNotch) }

    /// Notchless screens have room to spare: the music ear rests showing
    /// title, artist and controls instead of just the bars.
    var musicRestsOpen: Bool { !geometry.hasNotch }

    /// Whether `side` shows its open layout (hovered, or resting open).
    func isOpen(_ side: NotchSide) -> Bool {
        mode(side) != .collapsed || (side == .right && musicRestsOpen && showsMusic(.right))
    }

    // MARK: State used by the extensions

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

    /// When a chat was last picked by hand (buttons, scrolling, the badge).
    @ObservationIgnored var selectedAt = Date.distantPast

    var answerDraft = AnswerDraft()

    @ObservationIgnored var lastHoverRegion: NotchSide?? = .none

    /// Sideways scrolls over Claude's rolling description (left ear, and the
    /// right ear's tool line).
    @ObservationIgnored let leftStatusScrub = MarqueeScrubber()
    @ObservationIgnored let rightStatusScrub = MarqueeScrubber()

    @ObservationIgnored var sessionScroll: CGFloat = 0
    /// One gesture switches at most once: locked after a switch until the
    /// fingers lift (trackpad) or the wheel rests for a moment.
    @ObservationIgnored var sessionScrollLocked = false
    @ObservationIgnored var lastSessionScroll = Date.distantPast
    @ObservationIgnored var selectionResetTask: Task<Void, Never>?

    #if DEBUG
    /// Debug commands hold their state: the real pointer is elsewhere, and
    /// its hover events would otherwise close what was opened.
    @ObservationIgnored var debugHold = false
    #endif

    // MARK: Changing modes

    func setMode(_ side: NotchSide, _ new: EarMode) {
        switch side {
        case .left: if leftMode != new { leftMode = new }
        case .right: if rightMode != new { rightMode = new }
        case .center: return
        }
        updateOutsideClickMonitor()
        updatePointerMonitor()
        if side == .left && showsQueue { queue.refresh(for: nowPlaying.current) }
    }
}
