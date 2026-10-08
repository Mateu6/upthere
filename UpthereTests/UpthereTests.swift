import Foundation
import Testing

@testable import Upthere

struct AdapterParserTests {
    @Test func mergesDiffsIntoFullState() {
        let parser = AdapterStreamParser()
        let full = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","title":"Song","artist":"Artist","album":"Album","duration":200,"elapsedTime":10,"playing":true,"playbackRate":1,"timestamp":"2026-10-07T11:07:39Z"}}"#
        let diff = #"{"type":"data","diff":true,"payload":{"playing":false,"elapsedTime":42,"album":null}}"#
        let events = parser.feed(Data((full + "\n" + diff + "\n").utf8))

        let snapshots = events.compactMap { event -> PlaybackSnapshot?? in
            if case .snapshot(let s) = event { return s } else { return nil }
        }
        #expect(snapshots.count == 2)
        let last = snapshots.last!!
        #expect(last.title == "Song")
        #expect(last.isPlaying == false)
        #expect(last.elapsed == 42)
        #expect(last.album == "")
        #expect(last.duration == 200)
    }

    @Test func handlesLinesSplitAcrossReads() {
        let parser = AdapterStreamParser()
        let line = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"t","playing":true}}"# + "\n"
        let bytes = Array(line.utf8)
        #expect(parser.feed(Data(bytes[0..<20])).isEmpty)
        #expect(parser.feed(Data(bytes[20...])).count == 1)
    }

    @Test func emptyPayloadMeansNothingPlaying() {
        let parser = AdapterStreamParser()
        let events = parser.feed(Data((#"{"type":"data","diff":false,"payload":{}}"# + "\n").utf8))
        guard case .snapshot(let snapshot) = events.first else { Issue.record("no event"); return }
        #expect(snapshot == nil)
    }
}

struct PlayerFilterTests {
    @Test func excludesBrowsersAndTheirWebApps() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!)
        prefs.playerFilter = .excludeBrowsers
        #expect(prefs.allowsPlayer("com.spotify.client"))
        #expect(!prefs.allowsPlayer("com.apple.Safari"))
        #expect(!prefs.allowsPlayer("com.example.webapp", parent: "com.google.Chrome"))
        prefs.pinnedPlayer = "com.apple.Safari"
        #expect(prefs.allowsPlayer("com.apple.Safari"))
    }

    @Test func onlySelectedUsesAllowlist() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!)
        prefs.playerFilter = .onlySelected
        prefs.allowedPlayers = ["com.spotify.client"]
        #expect(prefs.allowsPlayer("com.spotify.client"))
        #expect(!prefs.allowsPlayer("com.apple.Music"))
    }
}

struct HookEventTests {
    private func event(_ json: String) -> HookEvent? { HookEvent.parse(Data(json.utf8)) }

    @Test func parsesEnvelope() throws {
        let e = try #require(
            event(
                #"{"v":1,"term":"ghostty","bundle":"com.mitchellh.ghostty","ppid":1,"payload":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/proj","tool_name":"Edit","tool_input":{"file_path":"/x/proj/Sources/App.swift"}}}"#
            ))
        #expect(e.kind == .preToolUse)
        #expect(e.toolDetail == "App.swift")
        #expect(e.terminalBundleID == "com.mitchellh.ghostty")
    }

    @Test func focusTargetsTheExactSession() throws {
        let e = try #require(
            event(
                #"{"v":1,"bundle":"com.anthropic.claudefordesktop","host":"local_d1a8-90d3","tty":null,"payload":{"hook_event_name":"Stop","session_id":"s1"}}"#
            ))
        #expect(e.hostSessionID == "local_d1a8-90d3")
        var session = ClaudeSession(id: "s1")
        session.hostSessionID = e.hostSessionID
        #expect(ClaudeModel.desktopURL(for: session)?.absoluteString == "claude://code/continue?session=local_d1a8-90d3")
        session.hostSessionID = "local_x&y=1"
        #expect(ClaudeModel.desktopURL(for: session) == nil)
        #expect(ClaudeModel.selectTabScript(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")?.contains("\"/dev/ttys004\"") == true)
        #expect(ClaudeModel.selectTabScript(bundleID: "com.apple.Terminal", tty: "/dev/ttys004\" & quit") == nil)
        #expect(ClaudeModel.selectTabScript(bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys004") == nil)
    }

    @Test func toolDetails() {
        #expect(ToolInfo.detail(tool: "Bash", input: ["command": "swift build\nswift test"]) == "swift build")
        #expect(ToolInfo.detail(tool: "Bash", input: ["command": "ls", "description": "List files"]) == "List files")
        #expect(ToolInfo.detail(tool: "WebFetch", input: ["url": "https://example.com/a"]) == "example.com")
        #expect(ToolInfo.displayName("mcp__github__create_issue") == "github · create issue")
    }
}

@MainActor
struct ClaudeModelTests {
    private func send(_ model: ClaudeModel, _ name: String, extra: String = "") {
        let json = #"{"hook_event_name":"\#(name)","session_id":"s1","cwd":"/Users/me/proj"\#(extra)}"#
        model.handle(HookEvent.parse(Data(json.utf8))!)
    }

    @Test func turnLifecycle() {
        let model = ClaudeModel()
        send(model, "SessionStart")
        #expect(!model.isLive)
        send(model, "UserPromptSubmit")
        #expect(model.primary?.activity == .thinking)
        #expect(model.primary?.projectName == "proj")
        send(model, "PreToolUse", extra: #","tool_name":"Bash","tool_input":{"command":"make"}"#)
        #expect(model.primary?.activity == .tool(name: "Bash", detail: "make"))
        send(model, "Notification", extra: #","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)
        #expect(model.attention != nil)
        send(model, "PostToolUse", extra: #","tool_name":"Bash""#)
        #expect(model.primary?.activity == .thinking)
        send(model, "Stop")
        #expect(model.primary?.activity == .done)
        send(model, "Notification", extra: #","message":"Claude is waiting for your input","notification_type":"idle_prompt""#)
        #expect(model.primary?.activity == .done)
        send(model, "SessionEnd")
        #expect(model.sessions.isEmpty)
    }
}

struct TranscriptTests {
    @Test func extractsAssistantInfo() {
        var info = TranscriptInfo()
        let line = #"{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":""},{"type":"text","text":"\nAll tests pass now.\nMore detail"}],"usage":{"input_tokens":2,"cache_read_input_tokens":90000,"cache_creation_input_tokens":1000,"output_tokens":5}}}"#
        TranscriptTailer.apply(line: Data(line.utf8), to: &info)
        #expect(info.model == "claude-opus-5-5")
        #expect(info.contextTokens == 91002)
        #expect(info.lastText == "All tests pass now.")

        TranscriptTailer.apply(line: Data(#"{"type":"custom-title","customTitle":"Notch app","sessionId":"x"}"#.utf8), to: &info)
        #expect(info.title == "Notch app")

        TranscriptTailer.apply(line: Data(#"{"type":"user","message":{"content":"\"type\":\"assistant\""}}"#.utf8), to: &info)
        #expect(info.lastText == "All tests pass now.")
    }
}

struct HookInstallerTests {
    @Test func installIsIdempotentAndPreservesUserHooks() {
        let userHook: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "echo hi"]]]
        let settings: [String: Any] = ["model": "opus", "hooks": ["PreToolUse": [userHook]]]

        let once = HookInstaller.installing(into: settings, command: "\"/x/upthere-hook\"")
        let twice = HookInstaller.installing(into: once, command: "\"/x/upthere-hook\"")
        #expect(HookInstaller.isInstalled(in: twice))
        let pre = (twice["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        #expect(pre.count == 2)
        #expect(twice["model"] as? String == "opus")

        let removed = HookInstaller.removing(from: twice)
        #expect(!HookInstaller.isInstalled(in: removed))
        let left = (removed["hooks"] as! [String: Any])
        #expect(left.keys.sorted() == ["PreToolUse"])
    }
}

@MainActor
struct HoverRegionTests {
    @Test func sideComesFromCursorPosition() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!)
        prefs.claudeEnabled = true
        let claude = ClaudeModel()
        claude.handle(HookEvent.parse(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/p"}"#.utf8))!)
        // A 1512×982 screen with a 200pt notch, 32pt tall.
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchRect: CGRect(x: 656, y: 950, width: 200, height: 32), hasNotch: true)
        let model = NotchViewModel(
            nowPlaying: NowPlayingModel(prefs: prefs), claude: claude, prefs: prefs, geometry: geometry)
        // Collapsed Claude-only: both ears ~36pt + shoulder.
        #expect(model.regionUnderCursor(at: CGPoint(x: 640, y: 970)) == .left)
        #expect(model.regionUnderCursor(at: CGPoint(x: 870, y: 970)) == .right)
        #expect(model.regionUnderCursor(at: CGPoint(x: 756, y: 970)) == .center)
        #expect(model.regionUnderCursor(at: CGPoint(x: 400, y: 970)) == nil)
        #expect(model.regionUnderCursor(at: CGPoint(x: 870, y: 900)) == nil)
    }
}

struct StatusLineTests {
    static let json = #"{"session_id":"s1","session_name":"notch work","model":{"id":"claude-opus-5-5","display_name":"Opus"},"cost":{"total_cost_usd":1.234},"context_window":{"total_input_tokens":84000,"context_window_size":200000,"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":4102444800},"seven_day":{"used_percentage":81.2,"resets_at":4102444800}}}"#

    @Test func parsesStatusLineEnvelope() throws {
        let envelope = #"{"v":1,"kind":"statusline","payload":"# + Self.json + "}"
        guard case .statusLine(let info) = ClaudeMessage.parse(Data(envelope.utf8)) else {
            Issue.record("not a status line")
            return
        }
        #expect(info.sessionName == "notch work")
        #expect(info.modelName == "Opus")
        #expect(info.contextPercent == 42)
        #expect(info.fiveHour?.usedPercent == 23.5)
        #expect(info.sevenDay?.usedPercent == 81.2)
        #expect(info.costUSD == 1.234)
    }

    @Test func hookEnvelopesStillRouteToHooks() {
        let envelope = #"{"v":1,"kind":null,"payload":{"hook_event_name":"Stop","session_id":"s1"}}"#
        guard case .hook(let event) = ClaudeMessage.parse(Data(envelope.utf8)) else {
            Issue.record("not a hook")
            return
        }
        #expect(event.kind == .stop)
    }

    @Test func tokenFormatting() {
        #expect(TokenFormat.short(950) == "950")
        #expect(TokenFormat.short(12_300) == "12.3k")
        #expect(TokenFormat.short(84_000) == "84k")
        #expect(TokenFormat.short(250_000) == "250k")
        #expect(TokenFormat.short(4_560_000) == "4.6M")
        #expect(UsageInfo.shortModel("claude-opus-5-5") == "Opus 5.5")
    }

    @MainActor @Test func chipsFollowPreferences() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!)
        let info = StatusLineInfo(try! JSONSerialization.jsonObject(with: Data(Self.json.utf8)) as! [String: Any])!
        var session = ClaudeSession(id: "s1")
        session.status = info
        session.transcript.sessionTokens = 1_500_000
        let plan = PlanUsage(fiveHour: info.fiveHour, sevenDay: info.sevenDay, updated: .now)

        prefs.infoResetTimes = false
        var chips = UsageInfo.chips(for: session, plan: plan, weeklyTokens: 9_000_000, prefs: prefs)
        #expect(chips.map(\.text) == ["session 24%", "week 81%", "ctx 42%", "81.6k to compact"])
        #expect(chips[1].level ?? 0 > 0.8)

        prefs.infoSessionFormat = .amount
        prefs.infoWeekFormat = .amount
        prefs.infoContextFormat = .amount
        prefs.infoCost = true
        prefs.infoModel = true
        chips = UsageInfo.chips(for: session, plan: plan, weeklyTokens: 9_000_000, prefs: prefs)
        #expect(chips.map(\.text) == ["1.5M tok", "wk 9M", "ctx 84k", "81.6k to compact", "$1.23", "Opus"])
    }
}

struct StatusLineInstallerTests {
    @Test func wrapsExistingStatusLineAndRestoresIt() {
        let original: [String: Any] = ["type": "command", "command": "~/bin/my line.sh 'x'", "padding": 1]
        let settings: [String: Any] = ["statusLine": original]
        let (installed, saved) = HookInstaller.installingStatusLine(into: settings, helper: "\"/h/upthere-hook\"")
        let command = (installed["statusLine"] as! [String: Any])["command"] as! String
        #expect(command == #""/h/upthere-hook" statusline --then '~/bin/my line.sh '\''x'\'''"#)
        #expect((installed["statusLine"] as! [String: Any])["padding"] as? Int == 1)
        #expect(HookInstaller.isStatusLineInstalled(in: installed))

        // Installing twice doesn't wrap twice.
        let again = HookInstaller.installingStatusLine(into: installed, helper: "\"/h/upthere-hook\"")
        #expect((again.settings["statusLine"] as! [String: Any])["command"] as? String == command)

        let restored = HookInstaller.removingStatusLine(from: installed, original: saved)
        #expect((restored["statusLine"] as! [String: Any])["command"] as? String == original["command"] as? String)
    }

    @Test func removesWhenThereWasNone() {
        let (installed, saved) = HookInstaller.installingStatusLine(into: ["model": "opus"], helper: "/h/upthere-hook")
        #expect(saved == nil)
        let restored = HookInstaller.removingStatusLine(from: installed, original: saved)
        #expect(restored["statusLine"] == nil)
        #expect(restored["model"] as? String == "opus")
    }
}

struct UsageScannerTests {
    @Test func countsLastSevenDaysOncePerResponse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upthere-scan-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ id: String, _ req: String, _ date: Date, _ tokens: Int) -> String {
            #"{"type":"assistant","requestId":"\#(req)","timestamp":"\#(iso.string(from: date))","message":{"id":"\#(id)","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
        }
        let a = [
            line("m1", "r1", now.addingTimeInterval(-3600), 100),
            line("m1", "r1", now.addingTimeInterval(-3600), 100),  // second content block
            line("m2", "r2", now.addingTimeInterval(-8 * 86400), 1000),  // too old
            #"{"type":"user","message":{"content":"hi"}}"#,
        ].joined(separator: "\n") + "\n"
        let b = line("m1", "r1", now.addingTimeInterval(-3600), 100) + "\n"  // resumed copy
            + line("m3", "r3", now.addingTimeInterval(-86400), 50) + "\n"
        try a.write(to: dir.appendingPathComponent("p/a.jsonl"), atomically: true, encoding: .utf8)
        try b.write(to: dir.appendingPathComponent("p/b.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(root: dir)
        #expect(scanner.scanSync(now: now) == 150)

        // Appended lines are picked up incrementally.
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("p/a.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("m4", "r4", now, 7) + "\n").utf8))
        try handle.close()
        #expect(scanner.scanSync(now: now) == 157)
    }
}

@MainActor
struct PerEarTests {
    @Test func onlyTheTargetedEarOpens() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!)
        let claude = ClaudeModel()
        claude.handle(HookEvent.parse(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/p"}"#.utf8))!)
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchRect: CGRect(x: 656, y: 950, width: 200, height: 32), hasNotch: true)
        let model = NotchViewModel(nowPlaying: NowPlayingModel(prefs: prefs), claude: claude, prefs: prefs, geometry: geometry)

        #expect(model.content.left == .claudeGlyph && model.content.right == .claudeBadge)
        model.debugSet(left: .collapsed, right: .peek)
        #expect(model.content.left == .claudeGlyph)
        #expect(model.content.right == .claudeTool(expanded: false))
        model.debugSet(left: .expanded, right: .collapsed)
        #expect(model.content.left == .claudeDetail(expanded: true))
        #expect(model.content.right == .claudeBadge)
        model.collapseAll()
        #expect(!model.isAnyEarOpen)
    }
}

@MainActor
struct NotchlessTests {
    @Test func claudeAndTimersShareOneEarAndOnlyTheOuterPieceOpens() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!)
        let claude = ClaudeModel()
        claude.handle(HookEvent.parse(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/p"}"#.utf8))!)
        let timers = TimerModel(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!)
        _ = timers.start("tea 4m")
        // A 2560-wide external display: a zero-width virtual notch, 24pt tall.
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            notchRect: CGRect(x: 1280, y: 1416, width: 0, height: 24), hasNotch: false)
        let model = NotchViewModel(
            nowPlaying: NowPlayingModel(prefs: prefs), claude: claude, prefs: prefs, geometry: geometry, timers: timers)

        // [timers | Claude], centered as a whole.
        #expect(model.content.left == .claudePiece(timers: .collapsed))
        #expect(model.content.right == .none)
        #expect(model.restingCenterOffset == -(model.leftWidth / 2).rounded())
        // Over Claude's piece: nothing opens. Over the timers: the left ear.
        #expect(model.regionUnderCursor(at: CGPoint(x: 1280 - 100, y: 1430)) == .center)
        #expect(model.regionUnderCursor(at: CGPoint(x: 1280 - model.claudePieceWidth - 20, y: 1430)) == .left)
        model.debugSet(left: .peek, right: .collapsed)
        #expect(model.content.left == .claudePiece(timers: .strip))
        // Once open, moving back over Claude keeps it open.
        #expect(model.regionUnderCursor(at: CGPoint(x: 1280 - 100, y: 1430)) == .left)
    }
}

struct UpNextTests {
    @Test func pkceMatchesRFC7636() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.verifier()
        #expect(verifier.count == 64)
        #expect(PKCE.formEncode(["redirect_uri": "http://127.0.0.1:1/cb", "a": "b c"]) == "a=b%20c&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcb")
    }

    @Test func parsesLoopbackCallback() {
        let request = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:47863\r\n\r\n"
        #expect(LoopbackReceiver.parseCallback(request) == ["code": "abc123", "state": "xyz"])
        #expect(LoopbackReceiver.parseCallback("GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
    }

    @Test func parsesSpotifyQueue() {
        let json = #"{"currently_playing":{"name":"Now"},"queue":[{"name":"Next","artists":[{"name":"A"},{"name":"B"}],"uri":"spotify:track:1","album":{"images":[{"url":"https://i/640","width":640},{"url":"https://i/64","width":64}]}},{"name":"Episode","show":{"name":"Pod"},"images":[{"url":"https://i/e","width":300}]}]}"#
        let items = SpotifyAPI.parseQueue(Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].title == "Next" && items[0].artist == "A, B" && items[0].position == 0)
        #expect(items[0].artworkURL?.absoluteString == "https://i/64")
        #expect(items[1].artist == "Pod" && items[1].position == 1)
        #expect(items[0].uri == "spotify:track:1" && items[1].uri == nil)
    }

    @Test func jumpsWithinPlaylistsAndAlbumsOnly() {
        func player(_ type: String) -> [String: Any] { ["context": ["type": type, "uri": "spotify:\(type):x"]] }
        #expect(SpotifyAPI.jumpContext(player("playlist")) == "spotify:playlist:x")
        #expect(SpotifyAPI.jumpContext(player("album")) == "spotify:album:x")
        #expect(SpotifyAPI.jumpContext(player("artist")) == nil)
        #expect(SpotifyAPI.jumpContext([:]) == nil)
    }

    @Test func reportsSpotifysOwnReason() {
        func message(_ json: String) -> String? { SpotifyAPI.error(status: 403, body: Data(json.utf8)).errorDescription }
        #expect(message(#"{"error":{"status":403,"message":"Player command failed: Restriction violated","reason":"UNKNOWN"}}"#) == "Spotify: Restriction violated")
        #expect(message(#"{"error":{"status":403,"message":"x","reason":"PREMIUM_REQUIRED"}}"#) == "Spotify: Jumping to a song needs Spotify Premium")
    }

    @Test func parsesMusicQueue() {
        let items = MusicQueue.parse("One\tArtist 1\nTwo\tArtist 2\n")
        #expect(items.map(\.title) == ["One", "Two"])
        #expect(items[1].artist == "Artist 2" && items[1].position == 1)
    }
}

@MainActor
struct AttentionTests {
    private func send(_ model: ClaudeModel, _ name: String, extra: String = "") {
        let json = #"{"hook_event_name":"\#(name)","session_id":"s1","cwd":"/p"\#(extra)}"#
        model.handle(HookEvent.parse(Data(json.utf8))!)
    }

    @Test func permissionAndInputAreDistinct() {
        let model = ClaudeModel()
        send(model, "UserPromptSubmit")
        send(model, "PreToolUse", extra: #","tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#)
        send(model, "Notification", extra: #","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)
        #expect(model.primary?.activity == .permission(tool: "Bash", detail: "rm -rf build"))
        #expect(model.primary?.statusText == "Allow Bash?")

        send(model, "PostToolUse", extra: #","tool_name":"Bash""#)
        send(model, "PreToolUse", extra: #","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which theme?"}]}"#)
        #expect(model.primary?.activity == .input(prompt: "Which theme?"))
        // A permission prompt for the question tool stays an input request.
        send(model, "Notification", extra: #","message":"Claude needs your permission to use AskUserQuestion","notification_type":"permission_prompt""#)
        #expect(model.primary?.activity == .input(prompt: "Which theme?"))
        #expect(model.attention != nil)

        send(model, "Notification", extra: #","message":"Claude has a question","notification_type":"elicitation_dialog""#)
        #expect(model.primary?.activity == .input(prompt: "Which theme?") || model.primary?.activity == .input(prompt: "Claude has a question"))
    }

    @Test func parsesUsageEndpoint() {
        let json = #"{"five_hour":{"utilization":15.0,"resets_at":"2099-01-01T10:00:00.000+00:00"},"seven_day":{"utilization":28.0,"resets_at":"2099-01-05T06:00:00+00:00"},"seven_day_opus":null}"#
        let usage = ClaudeUsageClient.parse(Data(json.utf8))
        #expect(usage?.fiveHour?.usedPercent == 15)
        #expect(usage?.sevenDay?.usedPercent == 28)
        #expect(ClaudeUsageClient.parse(Data("{}".utf8)) == nil)
    }

    @Test func contextSizeInferenceAndAutoCompact() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!)
        var session = ClaudeSession(id: "s")
        session.transcript.contextTokens = 755_600
        #expect(UsageInfo.contextSize(session, prefs: prefs) == 1_000_000)
        prefs.infoResetTimes = false
        let chips = UsageInfo.chips(for: session, plan: nil, weeklyTokens: nil, prefs: prefs)
        #expect(chips.map(\.text) == ["ctx 76%", "210k to compact"])
    }
}

struct TimerParserTests {
    @Test func parsesDurations() {
        #expect(TimerParser.parse("review PR") == .init(label: "review PR", duration: nil))
        #expect(TimerParser.parse("waiting for CI 15m") == .init(label: "waiting for CI", duration: 900))
        #expect(TimerParser.parse("deploy 1h30m") == .init(label: "deploy", duration: 5400))
        #expect(TimerParser.parse("deploy 1h 30m") == .init(label: "deploy", duration: 5400))
        #expect(TimerParser.parse("tea 90s") == .init(label: "tea", duration: 90))
        #expect(TimerParser.parse("tea for 4") == .init(label: "tea", duration: 240))
        #expect(TimerParser.parse("tea for 4m") == .init(label: "tea", duration: 240))
        #expect(TimerParser.parse("focus 1.5h") == .init(label: "focus", duration: 5400))
        // Numbers that belong to the label stay there.
        #expect(TimerParser.parse("PR 42") == .init(label: "PR 42", duration: nil))
        #expect(TimerParser.parse("25m") == .init(label: "Timer", duration: 1500))
    }

    @Test func formats() {
        #expect(TimerParser.clock(905) == "15:05")
        #expect(TimerParser.clock(3725) == "1:02:05")
        #expect(TimerParser.compact(45) == "45s")
        #expect(TimerParser.compact(14 * 60 + 1) == "15m")
        #expect(TimerParser.compact(3900) == "1h05")
    }
}

@MainActor
struct TimerModelTests {
    private func model() -> TimerModel { TimerModel(defaults: UserDefaults(suiteName: "upthere.tests.\(UUID())")!) }

    @Test func pauseAccountingAndOvertime() throws {
        let timers = model()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let timer = try #require(timers.start("tea 4m", now: t0))
        timers.pause(timer.id, now: t0.addingTimeInterval(60))
        timers.resume(timer.id, now: t0.addingTimeInterval(160))  // paused 100 s
        let current = try #require(timers.timers.first)
        #expect(current.elapsed(at: t0.addingTimeInterval(200)) == 100)
        #expect(current.remaining(at: t0.addingTimeInterval(400)) == -60)  // 1 min overtime
        #expect(current.endDate == t0.addingTimeInterval(340))
    }

    @Test func severalTimersIndependently() throws {
        let timers = model()
        var entries: [TimerEntry] = []
        timers.onFinish = { entries.append($0) }
        let now = Date()
        let work = try #require(timers.start("review PR", now: now.addingTimeInterval(-600)))
        _ = timers.start("waiting for CI 15m", now: now.addingTimeInterval(-60))
        _ = timers.start("tea 4m", now: now.addingTimeInterval(-60))
        #expect(timers.timers.count == 3)
        #expect(Set(timers.timers.map(\.colorIndex)).count == 3)
        #expect(timers.urgent?.label == "tea")  // the countdown closest to its end

        timers.pause(work.id)
        #expect(timers.timers.first { $0.id == work.id }?.isPaused == true)
        #expect(timers.timers.filter(\.isPaused).count == 1)

        timers.stopAll()
        #expect(timers.isEmpty)
        #expect(entries.map(\.label).sorted() == ["review PR", "tea", "waiting for CI"])
    }

    @Test func extendFromOvertime() throws {
        let timers = model()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let timer = try #require(timers.start("x 1m", now: t0))
        timers.extend(timer.id, by: 300, now: t0.addingTimeInterval(120))  // 1 min over, +5
        #expect(timers.timers.first?.remaining(at: t0.addingTimeInterval(120)) == 300)
    }

    @Test func persistsAcrossLaunches() {
        let suite = "upthere.tests.\(UUID())"
        let first = TimerModel(defaults: UserDefaults(suiteName: suite)!)
        first.start("review PR")
        let second = TimerModel(defaults: UserDefaults(suiteName: suite)!)
        #expect(second.timers.map(\.label) == ["review PR"])
        #expect(second.recentLabels.first == "review PR")
    }

    @Test func calendarFields() {
        let start = Date(timeIntervalSince1970: 3_000_000)
        let entry = TimerEntry(label: "waiting for CI", start: start, end: start.addingTimeInterval(1500), countdown: 900, activeTime: 1200)
        let fields = CalendarLogger.fields(for: entry)
        #expect(fields.title == "waiting for CI")
        #expect(fields.start == start && fields.end == start.addingTimeInterval(1500))
        #expect(fields.notes == "Countdown 15m (+5m over) · 5m paused · logged by Upthere")
    }
}
