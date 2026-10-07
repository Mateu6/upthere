import AppKit
import Observation
import os

nonisolated private let claudeLog = Logger(subsystem: "dev.upthere.app", category: "claude")

nonisolated enum ClaudeActivity: Equatable, Sendable {
    case idle
    case thinking
    case tool(name: String, detail: String?)
    case waiting(message: String?)
    case compacting
    case done

    var isWorking: Bool {
        switch self {
        case .thinking, .tool, .compacting: true
        default: false
        }
    }
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    var cwd: String?
    var activity: ClaudeActivity = .idle
    /// When the current activity (or the current turn, while working) began.
    var since: Date = .now
    var turnStarted: Date?
    var lastEvent: Date = .now
    var transcript = TranscriptInfo()
    var terminalBundleID: String?
    var transcriptPath: String?
    /// Latest status-line snapshot (needs the status-line bridge).
    var status: StatusLineInfo?

    var projectName: String {
        if let name = status?.sessionName, !name.isEmpty { return name }
        if let title = transcript.title, !title.isEmpty { return title }
        guard let cwd else { return "Claude" }
        return (cwd as NSString).lastPathComponent
    }

    var statusText: String {
        switch activity {
        case .idle: "Idle"
        case .thinking: "Thinking…"
        case .tool(let name, _): ToolInfo.displayName(name)
        case .waiting(let message): Self.shortWaitingText(message)
        case .compacting: "Compacting…"
        case .done: "Done"
        }
    }

    static func shortWaitingText(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "Needs you" }
        if message.localizedCaseInsensitiveContains("permission") { return "Needs permission" }
        if message.localizedCaseInsensitiveContains("waiting for your input") { return "Waiting for input" }
        return message
    }
}

/// Session state machine fed by hook events and transcript tails.
@Observable
final class ClaudeModel {
    private(set) var sessions: [ClaudeSession] = []
    /// Account-wide plan limits, from the newest status-line snapshot.
    private(set) var planUsage: PlanUsage?
    /// Tokens over the last 7 days from local transcripts (when enabled).
    private(set) var weeklyTokens: Int?

    /// Turn the background weekly scan on only when it's displayed.
    var weeklyScanEnabled = false {
        didSet {
            guard weeklyScanEnabled != oldValue else { return }
            if weeklyScanEnabled { startWeeklyScans() } else { weeklyTask?.cancel(); weeklyTask = nil }
        }
    }

    @ObservationIgnored private var hub: ClaudeHub?
    @ObservationIgnored private let scanner = UsageScanner()
    @ObservationIgnored private var weeklyTask: Task<Void, Never>?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var tailers: [String: TranscriptTailer] = [:]
    @ObservationIgnored private var tailQueue = DispatchQueue(label: "dev.upthere.transcripts", qos: .utility)
    @ObservationIgnored private var doneTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var gcTask: Task<Void, Never>?

    /// How long a finished turn stays visible.
    static let doneLinger: Duration = .seconds(10)

    // MARK: Derived state

    var visibleSessions: [ClaudeSession] {
        sessions.filter { $0.activity != .idle }
    }

    var isLive: Bool { !visibleSessions.isEmpty }

    var attention: ClaudeSession? {
        sessions.first { if case .waiting = $0.activity { true } else { false } }
    }

    /// The session the collapsed notch represents.
    var primary: ClaudeSession? {
        attention ?? visibleSessions.first { $0.activity.isWorking } ?? visibleSessions.first
    }

    // MARK: Lifecycle

    func start() {
        guard hub == nil else { return }
        let hub = ClaudeHub { message in
            Task { @MainActor [weak self] in
                switch message {
                case .hook(let event): self?.handle(event)
                case .statusLine(let info): self?.handle(info)
                }
            }
        }
        do {
            try hub.start()
            self.hub = hub
        } catch {
            claudeLog.error("failed to start hook socket: \(error.localizedDescription)")
        }
    }

    func stop() {
        hub?.stop()
        hub = nil
        tailers.values.forEach { $0.stop() }
        tailers.removeAll()
        gcTask?.cancel()
        weeklyTask?.cancel()
    }

    // MARK: Usage

    func handle(_ info: StatusLineInfo) {
        if info.fiveHour != nil || info.sevenDay != nil {
            let usage = PlanUsage(fiveHour: info.fiveHour, sevenDay: info.sevenDay, updated: .now)
            if planUsage != usage { planUsage = usage }
        }
        // Only enrich sessions the hooks know about; a status line alone
        // doesn't make a session visible.
        guard let index = sessions.firstIndex(where: { $0.id == info.sessionID }) else { return }
        if sessions[index].status != info { sessions[index].status = info }
    }

    private func startWeeklyScans() {
        weeklyTask?.cancel()
        weeklyTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.rescanWeekly()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    /// Debounced: bursts of Stop events trigger one scan.
    private func scheduleWeeklyRescan() {
        guard weeklyScanEnabled else { return }
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.rescanWeekly()
        }
    }

    private func rescanWeekly() {
        scanner.scan { tokens in
            Task { @MainActor [weak self] in
                if self?.weeklyTokens != tokens { self?.weeklyTokens = tokens }
            }
        }
    }

    // MARK: Events

    func handle(_ event: HookEvent) {
        var session = sessions.first { $0.id == event.sessionID } ?? ClaudeSession(id: event.sessionID)
        session.lastEvent = .now
        if let cwd = event.cwd { session.cwd = cwd }
        if let bundle = event.terminalBundleID { session.terminalBundleID = bundle }
        if let path = event.transcriptPath { session.transcriptPath = path }

        let previous = session.activity
        switch event.kind {
        case .sessionStart:
            if !previous.isWorking { session.activity = .idle }
        case .userPromptSubmit:
            session.activity = .thinking
            session.turnStarted = .now
        case .preToolUse:
            session.activity = .tool(name: event.toolName ?? "Tool", detail: event.toolDetail)
        case .postToolUse, .subagentStop:
            if previous != .done && previous != .idle { session.activity = .thinking }
        case .permissionRequest:
            session.activity = .waiting(message: "Needs permission")
        case .notification:
            switch event.notificationType {
            case "idle_prompt", "auth_success":
                break
            case "permission_prompt", "elicitation_dialog":
                session.activity = .waiting(message: event.message)
            default:
                // Older Claude Code versions don't send notification_type.
                if event.message?.localizedCaseInsensitiveContains("permission") == true {
                    session.activity = .waiting(message: event.message)
                }
            }
        case .preCompact:
            session.activity = .compacting
        case .stop:
            session.activity = .done
            session.turnStarted = nil
            scheduleWeeklyRescan()
        case .sessionEnd:
            remove(event.sessionID)
            return
        }
        if session.activity != previous {
            session.since = .now
            if session.turnStarted == nil && session.activity.isWorking { session.turnStarted = .now }
        }

        upsert(session)
        ensureTailer(for: session)
        scheduleDoneFade(for: session)
        scheduleGC()
    }

    private func upsert(_ session: ClaudeSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            if sessions[index] != session { sessions[index] = session }
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
        tailers.removeValue(forKey: id)?.stop()
        doneTimers.removeValue(forKey: id)?.cancel()
    }

    private func ensureTailer(for session: ClaudeSession) {
        guard tailers[session.id] == nil, let path = session.transcriptPath else { return }
        let id = session.id
        let tailer = TranscriptTailer(url: URL(fileURLWithPath: path), queue: tailQueue) { info in
            Task { @MainActor [weak self] in
                guard let self, let index = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                if self.sessions[index].transcript != info { self.sessions[index].transcript = info }
            }
        }
        tailers[id] = tailer
        tailer.start()
    }

    private func scheduleDoneFade(for session: ClaudeSession) {
        doneTimers.removeValue(forKey: session.id)?.cancel()
        guard session.activity == .done else { return }
        let id = session.id
        doneTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.doneLinger)
            guard !Task.isCancelled, let self,
                let index = self.sessions.firstIndex(where: { $0.id == id }),
                self.sessions[index].activity == .done
            else { return }
            self.sessions[index].activity = .idle
            self.tailers.removeValue(forKey: id)?.stop()
        }
    }

    /// Drops sessions that went quiet without a SessionEnd (e.g. a killed
    /// terminal). Runs only while sessions exist.
    private func scheduleGC() {
        guard gcTask == nil else { return }
        gcTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard let self else { return }
                let now = Date.now
                for session in self.sessions {
                    let quiet = now.timeIntervalSince(session.lastEvent)
                    let limit: TimeInterval = session.activity.isWorking ? 3 * 3600 : 30 * 60
                    if quiet > limit { self.remove(session.id) }
                }
                if self.sessions.isEmpty {
                    self.gcTask = nil
                    return
                }
            }
        }
    }

    // MARK: Actions

    func focus(_ session: ClaudeSession) {
        let bundleID = session.terminalBundleID ?? "com.apple.Terminal"
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }
}
