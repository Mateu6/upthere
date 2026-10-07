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
        #expect(chips.map(\.text) == ["5h 24%", "wk 81%", "ctx 42%"])
        #expect(chips[1].level ?? 0 > 0.8)

        prefs.infoSessionFormat = .amount
        prefs.infoWeekFormat = .amount
        prefs.infoContextFormat = .amount
        prefs.infoCost = true
        prefs.infoModel = true
        chips = UsageInfo.chips(for: session, plan: plan, weeklyTokens: 9_000_000, prefs: prefs)
        #expect(chips.map(\.text) == ["1.5M tok", "wk 9M", "ctx 84k", "$1.23", "Opus"])
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
        let json = #"{"currently_playing":{"name":"Now"},"queue":[{"name":"Next","artists":[{"name":"A"},{"name":"B"}],"album":{"images":[{"url":"https://i/640","width":640},{"url":"https://i/64","width":64}]}},{"name":"Episode","show":{"name":"Pod"},"images":[{"url":"https://i/e","width":300}]}]}"#
        let items = SpotifyAPI.parseQueue(Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].title == "Next" && items[0].artist == "A, B" && items[0].position == 0)
        #expect(items[0].artworkURL?.absoluteString == "https://i/64")
        #expect(items[1].artist == "Pod" && items[1].position == 1)
    }

    @Test func parsesMusicQueue() {
        let items = MusicQueue.parse("One\tArtist 1\nTwo\tArtist 2\n")
        #expect(items.map(\.title) == ["One", "Two"])
        #expect(items[1].artist == "Artist 2" && items[1].position == 1)
    }
}
