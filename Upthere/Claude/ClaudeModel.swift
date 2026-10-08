import AppKit
import Observation
import os

nonisolated private let claudeLog = Logger(subsystem: "dev.upthere.app", category: "claude")

nonisolated enum ClaudeActivity: Equatable, Sendable {
    case idle
    case thinking
    case tool(name: String, detail: String?)
    /// Claude wants to run a tool and needs your approval.
    case permission(tool: String?, detail: String?)
    /// Claude is asking you something (a question, a plan to review, a form).
    case input(prompt: String?)
    case compacting
    case done

    var isWorking: Bool {
        switch self {
        case .thinking, .tool, .compacting: true
        default: false
        }
    }

    var needsUser: Bool {
        switch self {
        case .permission, .input: true
        default: false
        }
    }

    /// Tools that are really Claude asking you something.
    static let inputTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
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
    var hostSessionID: String?
    var tty: String?
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
        case .permission(let tool?, _): "Allow \(ToolInfo.displayName(tool))?"
        case .permission: "Needs permission"
        case .input: "Needs your input"
        case .compacting: "Compacting…"
        case .done: "Done"
        }
    }

    /// "Claude needs your permission to use Bash" → "Bash".
    static func toolName(fromPermissionMessage message: String?) -> String? {
        guard let message, let range = message.range(of: "permission to use ") else { return nil }
        let name = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return name.isEmpty ? nil : name
    }
}

/// Session state machine fed by hook events and transcript tails.
@Observable
final class ClaudeModel {
    private(set) var sessions: [ClaudeSession] = []
    /// Account-wide plan limits: from the Claude login (usage endpoint) or
    /// the newest status-line snapshot, whichever is newer.
    private(set) var planUsage: PlanUsage?
    /// "Pro", "Max", … when known from the Claude login.
    private(set) var planName: String?

    /// Poll the usage endpoint with the Claude login (opt-in).
    var accountUsageEnabled = false {
        didSet {
            guard accountUsageEnabled != oldValue else { return }
            if accountUsageEnabled { startUsagePolling() } else { usageTask?.cancel(); usageTask = nil }
        }
    }
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
    @ObservationIgnored private let usageClient = ClaudeUsageClient()
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var usageRefreshTask: Task<Void, Never>?
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

    /// A session that needs you: permission or input.
    var attention: ClaudeSession? {
        sessions.first { $0.activity.needsUser }
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
        usageTask?.cancel()
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

    private func startUsagePolling() {
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchAccountUsage()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    /// After a reply the numbers have moved; refresh soon (debounced).
    private func scheduleUsageRefresh() {
        guard accountUsageEnabled else { return }
        usageRefreshTask?.cancel()
        usageRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await self?.fetchAccountUsage()
        }
    }

    private func fetchAccountUsage() async {
        guard let result = try? await usageClient.fetch() else { return }
        if planUsage != result.usage { planUsage = result.usage }
        if let plan = result.plan, planName != plan { planName = plan }
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
        if let host = event.hostSessionID { session.hostSessionID = host }
        if let tty = event.tty { session.tty = tty }
        if let path = event.transcriptPath { session.transcriptPath = path }

        let previous = session.activity
        switch event.kind {
        case .sessionStart:
            if !previous.isWorking { session.activity = .idle }
        case .userPromptSubmit:
            session.activity = .thinking
            session.turnStarted = .now
        case .preToolUse:
            if let tool = event.toolName, ClaudeActivity.inputTools.contains(tool) {
                session.activity = .input(prompt: event.question)
            } else {
                session.activity = .tool(name: event.toolName ?? "Tool", detail: event.toolDetail)
            }
        case .postToolUse, .subagentStop:
            if previous != .done && previous != .idle { session.activity = .thinking }
        case .permissionRequest:
            session.activity = Self.permissionActivity(previous: previous, message: event.message, tool: event.toolName)
        case .notification:
            switch event.notificationType {
            case "idle_prompt", "auth_success":
                break
            case "elicitation_dialog":
                session.activity = .input(prompt: event.message)
            case "permission_prompt":
                session.activity = Self.permissionActivity(previous: previous, message: event.message, tool: nil)
            default:
                // Older Claude Code versions don't send notification_type.
                if event.message?.localizedCaseInsensitiveContains("permission") == true {
                    session.activity = Self.permissionActivity(previous: previous, message: event.message, tool: nil)
                }
            }
        case .preCompact:
            session.activity = .compacting
        case .stop:
            session.activity = .done
            session.turnStarted = nil
            scheduleWeeklyRescan()
            scheduleUsageRefresh()
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

    /// A permission prompt for one of Claude's question tools is really a
    /// request for input; otherwise it's about the tool that was running.
    private static func permissionActivity(previous: ClaudeActivity, message: String?, tool: String?) -> ClaudeActivity {
        switch previous {
        case .input:
            return previous
        case .tool(let name, let detail):
            if ClaudeActivity.inputTools.contains(name) { return .input(prompt: detail) }
            return .permission(tool: tool ?? name, detail: detail)
        default:
            return .permission(tool: tool ?? ClaudeSession.toolName(fromPermissionMessage: message), detail: nil)
        }
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

    /// Brings the session forward: its chat in the Claude app, its tab in
    /// Terminal or iTerm2, its project window in VS Code-like editors, or
    /// otherwise just the app it runs in.
    func focus(_ session: ClaudeSession) {
        if let url = Self.desktopURL(for: session) {
            NSWorkspace.shared.open(url)
            return
        }
        let bundleID = session.terminalBundleID ?? "com.apple.Terminal"
        if Self.editors.contains(bundleID), let cwd = session.cwd,
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            // Opening a folder that's already open focuses its window.
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: cwd, isDirectory: true)], withApplicationAt: app,
                configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        if let script = Self.selectTabScript(bundleID: bundleID, tty: session.tty) {
            Task { _ = await ScriptRunner.run(script) }
        }
    }

    nonisolated static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "com.vscodium",
    ]

    /// `claude://code/continue?session=local_…` opens that session in the
    /// Claude desktop app.
    nonisolated static func desktopURL(for session: ClaudeSession) -> URL? {
        guard let id = session.hostSessionID, id.wholeMatch(of: /local_[A-Za-z0-9-]{1,64}/) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(id)")
    }

    /// AppleScript that selects the tab running on `tty`.
    nonisolated static func selectTabScript(bundleID: String, tty: String?) -> String? {
        guard let tty, tty.wholeMatch(of: /\/dev\/tty[a-z]*[0-9]+/) != nil else { return nil }
        switch bundleID {
        case "com.apple.Terminal":
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected of t to true
                                set index of w to 1
                                return
                            end if
                        end repeat
                    end repeat
                end tell
                """
        case "com.googlecode.iterm2":
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """
        default:
            return nil
        }
    }
}
