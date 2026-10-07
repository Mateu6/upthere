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
