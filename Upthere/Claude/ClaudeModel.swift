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
    /// The tool call running now, and the one a wait is about: while Claude
    /// waits on it, other calls (parallel, subagents) don't hide the wait.
    var currentToolUseID: String?
    var pendingToolUseID: String?
    /// PreCompact's trigger: a manual /compact ends the turn, auto goes on.
    var compactTrigger: String?
    /// You went to this session's window during a wait and came back: you
    /// probably answered there, so the wait stops calling for you.
    var waitVisited = false
    var waitSeen = false

    /// Waiting for you, and you haven't been to its window since.
    var needsYou: Bool { activity.needsUser && !waitSeen }

    var projectName: String {
        if let name = status?.sessionName, !name.isEmpty { return name }
        if let title = transcript.title, !title.isEmpty { return title }
        guard let cwd else { return "Claude" }
        return (cwd as NSString).lastPathComponent
    }

    var statusText: String {
        if waitSeen && activity.needsUser { return "Answered in terminal?" }
        return switch activity {
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

/// The confirmation shown for a moment after you answer in the notch.
struct AnswerEcho: Equatable {
    var text: String
    var symbol: String
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
    /// Requests the notch can answer, by session.
    private(set) var requests: [String: ClaudeRequest] = [:]
    /// What you just answered, shown for a moment, by session.
    private(set) var echoes: [String: AnswerEcho] = [:]
    /// Answer from the notch is on (its hooks are installed).
    var answersEnabled = false
    /// How long the notch keeps a request before the terminal asks.
    var answerWait: TimeInterval = 20
    /// Peek for a moment when a turn finishes.
    var peekOnDone = true
    /// The session that just finished, for that moment.
    private(set) var justFinished: String?

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
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var channels: [UUID: AnswerChannel] = [:]
    @ObservationIgnored private var handoverTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var echoTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var finishedTask: Task<Void, Never>?

    /// How long the ear peeks after a turn finishes.
    static let donePeek: Duration = .seconds(2.5)

    /// How long a finished turn stays visible.
    static let doneLinger: Duration = .seconds(10)

    #if DEBUG
    /// Demo recordings: show only staged `demo-…` sessions, so real Claude
    /// Code sessions running on the machine don't leak into the take.
    @ObservationIgnored var demoOnly = false {
        didSet {
            guard demoOnly else { return }
            for session in sessions where !session.id.hasPrefix("demo-") { remove(session.id) }
        }
    }
    #endif

    // MARK: Derived state

    var visibleSessions: [ClaudeSession] {
        sessions.filter { $0.activity != .idle }
    }

    var isLive: Bool { !visibleSessions.isEmpty }

    /// Sessions that need you (permission or input), longest waiting first.
    var waiting: [ClaudeSession] {
        sessions.filter(\.needsYou).sorted { $0.since < $1.since }
    }

    /// The session that has waited longest for you.
    var attention: ClaudeSession? { waiting.first }

    /// The session the collapsed notch represents.
    var primary: ClaudeSession? {
        attention ?? justFinishedSession ?? visibleSessions.first { $0.activity.isWorking } ?? visibleSessions.first
    }

    var justFinishedSession: ClaudeSession? {
        justFinished.flatMap { id in visibleSessions.first { $0.id == id && $0.activity == .done } }
    }

    // MARK: Lifecycle

    func start() {
        guard hub == nil else { return }
        let hub = ClaudeHub { message in
            Task { @MainActor [weak self] in
                switch message {
                case .hook(let event): self?.handle(event)
                case .statusLine(let info): self?.handle(info)
                case .answer(let event, let request, let channel): self?.handle(event, request: request, channel: channel)
                }
            }
        }
        do {
            try hub.start()
            self.hub = hub
        } catch {
            claudeLog.error("failed to start hook socket: \(error.localizedDescription)")
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { [weak self] in self?.appActivated(bundle) }
        }
    }

    /// Off clears everything, so nothing stale stays on screen and On
    /// starts fresh.
    func stop() {
        hub?.stop()
        hub = nil
        tailers.values.forEach { $0.stop() }
        tailers.removeAll()
        doneTimers.values.forEach { $0.cancel() }
        doneTimers.removeAll()
        for request in requests.values { dropRequest(request.id, reply: "") }
        sessions.removeAll()
        gcTask?.cancel()
        gcTask = nil
        weeklyTask?.cancel()
        weeklyTask = nil
        usageTask?.cancel()
        usageTask = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// The app a session runs in (the Claude app for its chats).
    nonisolated static func appBundleID(for session: ClaudeSession) -> String? {
        desktopURL(for: session) != nil ? "com.anthropic.claudefordesktop" : session.terminalBundleID
    }

    /// Going to a waiting session's app, then leaving it, softens the wait.
    private func appActivated(_ bundle: String?) {
        for index in sessions.indices where sessions[index].activity.needsUser && !sessions[index].waitSeen {
            if Self.appBundleID(for: sessions[index]) == bundle {
                sessions[index].waitVisited = true
            } else if sessions[index].waitVisited {
                sessions[index].waitSeen = true
            }
        }
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
        #if DEBUG
        if demoOnly && !event.sessionID.hasPrefix("demo-") { return }
        #endif
        var session = sessions.first { $0.id == event.sessionID } ?? ClaudeSession(id: event.sessionID)
        session.lastEvent = .now
        if let cwd = event.cwd { session.cwd = cwd }
        if let bundle = event.terminalBundleID { session.terminalBundleID = bundle }
        if let host = event.hostSessionID { session.hostSessionID = host }
        if let tty = event.tty { session.tty = tty }
        if let path = event.transcriptPath { session.transcriptPath = path }

        let previous = session.activity
        // While Claude waits on one call, other calls (run in parallel, or by
        // subagents) must not hide the wait.
        let waitingOn = previous.needsUser ? session.pendingToolUseID : nil
        switch event.kind {
        case .sessionStart:
            if event.source == "compact" {
                // A manual /compact ends the turn (no Stop follows); an
                // automatic one happens mid-turn and Claude carries on.
                session.activity = session.compactTrigger == "manual" ? .idle : .thinking
                session.compactTrigger = nil
            } else if !previous.isWorking {
                session.activity = .idle
            }
        case .userPromptSubmit:
            session.activity = .thinking
            session.turnStarted = .now
        case .preToolUse:
            guard waitingOn == nil else { break }
            if let tool = event.toolName, ClaudeActivity.inputTools.contains(tool) {
                session.activity = .input(prompt: event.question)
                session.pendingToolUseID = event.toolUseID
            } else {
                session.activity = .tool(name: event.toolName ?? "Tool", detail: event.toolDetail)
                if event.agentID == nil { session.currentToolUseID = event.toolUseID }
            }
        case .postToolUse, .postToolUseFailure, .subagentStop:
            if let waitingOn, event.toolUseID != waitingOn { break }
            if previous != .done && previous != .idle { session.activity = .thinking }
        case .permissionRequest:
            session.activity = Self.permissionActivity(previous: previous, message: event.message, tool: event.toolName)
        case .notification:
            switch event.notificationType {
            case "auth_success":
                break
            case "idle_prompt":
                // Claude has been waiting for a new prompt for a while: any
                // turn still shown as running was interrupted.
                if previous.isWorking || previous.needsUser { session.activity = .idle }
            case "elicitation_dialog":
                session.activity = .input(prompt: event.message)
            case "permission_prompt":
                session.activity = Self.permissionActivity(previous: previous, message: event.message, tool: nil)
            default:
                // Older Claude Code versions don't send notification_type.
                if event.notificationType == nil, event.message?.localizedCaseInsensitiveContains("permission") == true {
                    session.activity = Self.permissionActivity(previous: previous, message: event.message, tool: nil)
                }
            }
        case .preCompact:
            session.activity = .compacting
            session.compactTrigger = event.trigger
        case .stop, .stopFailure:
            session.activity = .done
            session.turnStarted = nil
            if previous != .done { announceFinished(session.id) }
            scheduleWeeklyRescan()
            scheduleUsageRefresh()
        case .sessionEnd:
            remove(event.sessionID)
            return
        }
        if session.activity != previous {
            enter(session.activity, from: previous, in: &session)
        }

        upsert(session)
        if !session.activity.needsUser, let request = requests[session.id] { dropRequest(request.id, reply: "") }
        if session.activity.isWorking || session.activity.needsUser { ensureTailer(for: session) }
        scheduleDoneFade(for: session)
        scheduleGC()
    }

    private func announceFinished(_ id: String) {
        guard peekOnDone else { return }
        justFinished = id
        finishedTask?.cancel()
        finishedTask = Task { [weak self] in
            try? await Task.sleep(for: Self.donePeek)
            guard !Task.isCancelled else { return }
            self?.justFinished = nil
        }
    }

    /// Bookkeeping shared by hook events and transcript signals.
    private func enter(_ activity: ClaudeActivity, from previous: ClaudeActivity, in session: inout ClaudeSession) {
        session.since = .now
        if session.turnStarted == nil && activity.isWorking { session.turnStarted = .now }
        if !activity.isWorking && !activity.needsUser && activity != .done { session.turnStarted = nil }
        if activity.needsUser && !previous.needsUser { session.pendingToolUseID = session.pendingToolUseID ?? session.currentToolUseID }
        if !activity.needsUser { session.pendingToolUseID = nil }
        session.waitVisited = false
        session.waitSeen = false
    }

    /// What the transcript says that hooks don't: Esc was pressed, or the
    /// call Claude was waiting on got its result (answered in the terminal).
    private func applyTranscript(_ info: TranscriptInfo, at index: Int) {
        var session = sessions[index]
        let old = session.transcript
        session.transcript = info
        let previous = session.activity
        if info.interrupts > old.interrupts, previous.isWorking || previous.needsUser {
            session.activity = .idle
        } else if previous.needsUser, let pending = session.pendingToolUseID,
            info.recentToolResults.contains(pending), !old.recentToolResults.contains(pending)
        {
            session.activity = .thinking
        }
        if session.activity != previous { enter(session.activity, from: previous, in: &session) }
        if sessions[index] != session { sessions[index] = session }
        if !session.activity.needsUser, let request = requests[session.id] { dropRequest(request.id, reply: "") }
    }

    // MARK: Answering from the notch

    private func handle(_ event: HookEvent, request: ClaudeRequest, channel: AnswerChannel) {
        // The plain hook reports the same event; handling it twice is harmless
        // and covers either arriving first.
        handle(event)
        guard answersEnabled, let session = sessions.first(where: { $0.id == request.sessionID }) else {
            return channel.reply("")
        }
        // Already in that session's window: the terminal asks straight away.
        if let bundle = Self.appBundleID(for: session),
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle
        {
            return channel.reply("")
        }
        if let old = requests[request.sessionID] { dropRequest(old.id, reply: "") }
        requests[request.sessionID] = request
        channels[request.id] = channel
        let id = request.id
        channel.whenClosed {
            Task { @MainActor [weak self] in self?.dropRequest(id, reply: nil) }
        }
        let wait = answerWait
        handoverTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.handOver(id)
        }
    }

    /// Sends your pick. Ignored if the request is gone, or arrived too
    /// recently to have been seen (an ear opening under the pointer).
    func answer(_ requestID: UUID, with answer: ClaudeAnswer) {
        guard let request = requests.values.first(where: { $0.id == requestID }), request.isAwake,
            let output = request.output(for: answer)
        else { return }
        dropRequest(requestID, reply: output)
        showEcho(request.echo(for: answer), for: request.sessionID)
        // Claude carries on at once; don't wait for the tool to finish (or
        // for the next event) to stop calling for you.
        guard let index = sessions.firstIndex(where: { $0.id == request.sessionID }) else { return }
        var session = sessions[index]
        let previous = session.activity
        session.activity = answer == .denyAndStop ? .idle : .thinking
        if session.activity != previous { enter(session.activity, from: previous, in: &session) }
        sessions[index] = session
        scheduleDoneFade(for: session)
    }

    /// "Answer in terminal", or the wait ran out: Claude Code asks there.
    func handOver(_ requestID: UUID) {
        dropRequest(requestID, reply: "")
    }

    private func dropRequest(_ id: UUID, reply: String?) {
        handoverTasks.removeValue(forKey: id)?.cancel()
        let channel = channels.removeValue(forKey: id)
        if let reply { channel?.reply(reply) }
        if let key = requests.first(where: { $0.value.id == id })?.key { requests.removeValue(forKey: key) }
    }

    private func showEcho(_ echo: (text: String, symbol: String), for sessionID: String) {
        echoes[sessionID] = AnswerEcho(text: echo.text, symbol: echo.symbol)
        echoTasks.removeValue(forKey: sessionID)?.cancel()
        echoTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.echoes.removeValue(forKey: sessionID)
        }
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
        if let request = requests[id] { dropRequest(request.id, reply: "") }
        sessions.removeAll { $0.id == id }
        tailers.removeValue(forKey: id)?.stop()
        doneTimers.removeValue(forKey: id)?.cancel()
    }

    private func ensureTailer(for session: ClaudeSession) {
        guard tailers[session.id] == nil, let path = session.transcriptPath else { return }
        let id = session.id
        let tailer = TranscriptTailer(url: URL(fileURLWithPath: path), queue: tailQueue) { info in
            Task { @MainActor [weak self] in
                guard let self, let index = self.sessions.firstIndex(where: { $0.id == id }),
                    self.sessions[index].transcript != info
                else { return }
                self.applyTranscript(info, at: index)
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
        // No app recorded: a tty still means a terminal; otherwise there's
        // nothing sensible to bring forward, so say so rather than guess.
        guard let bundleID = session.terminalBundleID ?? (session.tty != nil ? "com.apple.Terminal" : nil) else {
            NSSound.beep()
            return
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            // It quit since: open it again (the chat or tab is gone with it).
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSSound.beep()
            }
            return
        }
        if Self.editors.contains(bundleID), let cwd = session.cwd,
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            // Opening a folder that's already open focuses its window.
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: cwd, isDirectory: true)], withApplicationAt: app,
                configuration: NSWorkspace.OpenConfiguration())
            return
        }
        running.activate()
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
