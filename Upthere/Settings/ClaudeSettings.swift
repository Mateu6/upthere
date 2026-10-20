import SwiftUI

struct ClaudeSettings: View {
    @Bindable var prefs: Preferences
    let claude: ClaudeModel
    @State private var hooksInstalled = HookInstaller.isInstalled
    @State private var hookError: String?
    @State private var answersInstalled = HookInstaller.isAnswerInstalled
    @State private var statusLineInstalled = HookInstaller.isStatusLineInstalled
    @State private var statusLineError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show Claude Code activity", isOn: $prefs.claudeEnabled)
                    .onChange(of: prefs.claudeEnabled) { _, enabled in
                        if enabled { claude.start() } else { claude.stop() }
                    }
                Toggle("Peek when Claude finishes", isOn: $prefs.peekOnDone)
                    .disabled(!prefs.claudeEnabled)
                ConnectionRow(
                    title: "Claude Code hooks", connected: hooksInstalled, connect: "Connect Claude Code",
                    onConnect: { runHooks(HookInstaller.install) }, onDisconnect: { runHooks(HookInstaller.uninstall) })
                if let hookError { ErrorText(message: hookError) }
            } footer: {
                SettingsFooter(
                    text: "Adds hooks to ~/.claude/settings.json (a backup is saved next to it). The hook only forwards events to Upthere over a local socket and never blocks Claude."
                )
            }

            Section {
                Toggle("Answer Claude from the notch", isOn: answersBinding)
                    .disabled(!hooksInstalled)
                if answersInstalled {
                    Stepper(value: $prefs.answerWait, in: 5...90, step: 5) {
                        LabeledContent("Then ask in the terminal after", value: "\(Int(prefs.answerWait)) s")
                    }
                }
            } footer: {
                SettingsFooter(
                    text: hooksInstalled
                        ? "Pick Claude's options, allow or deny a command, and approve plans right in the notch. While a question waits there, the terminal shows it after this long or when you click Terminal. It never waits when that session's window is already in front."
                        : "Connect Claude Code first."
                )
            }

            Section {
                Toggle("Read plan limits from my Claude login", isOn: $prefs.accountUsage)
                    .help("Reads the Claude Code login from your Keychain (macOS asks once) and asks api.anthropic.com for your usage, like the Claude app. Never changes the login.")
                ConnectionRow(
                    title: "Status line (terminal only)", connected: statusLineInstalled, connect: "Connect status line",
                    onConnect: { runStatusLine(HookInstaller.installStatusLine) },
                    onDisconnect: { runStatusLine(HookInstaller.uninstallStatusLine) })
                if let statusLineError { ErrorText(message: statusLineError) }
                Picker("Ring around Claude icon", selection: $prefs.usageRing) {
                    ForEach(UsageRing.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show when limits reset", isOn: $prefs.infoResetTimes)
                Toggle("Keep showing usage when Claude is idle", isOn: $prefs.showUsageWhenIdle)
            } header: {
                Text("Plan limits")
            } footer: {
                SettingsFooter(
                    text: "Plan limits come from your Claude login (same numbers as the Claude app; the endpoint is undocumented and may change) or, for Claude Code in a terminal, its status line."
                )
            }

            Section {
                UsageRow(title: "Session", isOn: $prefs.infoSession, format: $prefs.infoSessionFormat,
                         percent: "% of 5-hour limit", amount: "Tokens this session")
                UsageRow(title: "Week", isOn: $prefs.infoWeek, format: $prefs.infoWeekFormat,
                         percent: "% of weekly limit", amount: "Tokens, last 7 days")
                UsageRow(title: "Context window", isOn: $prefs.infoContext, format: $prefs.infoContextFormat,
                         percent: "% used", amount: "Tokens")
                Toggle("Tokens until auto-compact", isOn: $prefs.infoAutoCompact)
                Picker("Context window size", selection: $prefs.contextWindow) {
                    ForEach(ContextWindowSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Session cost", isOn: $prefs.infoCost)
                Toggle("Model", isOn: $prefs.infoModel)
            } header: {
                Text("Claude info")
            } footer: {
                SettingsFooter(text: "Token amounts are counted from local transcripts.")
            }
        }
        .settingsTab()
    }

    private var answersBinding: Binding<Bool> {
        Binding(
            get: { answersInstalled },
            set: { on in runHooks { try HookInstaller.setAnswers(on) } }
        )
    }

    private func runHooks(_ action: () throws -> Void) {
        do {
            try action()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        hooksInstalled = HookInstaller.isInstalled
        answersInstalled = hooksInstalled && HookInstaller.isAnswerInstalled
        claude.answersEnabled = answersInstalled
    }

    private func runStatusLine(_ action: () throws -> Void) {
        do {
            try action()
            statusLineError = nil
        } catch {
            statusLineError = error.localizedDescription
        }
        statusLineInstalled = HookInstaller.isStatusLineInstalled
    }
}

/// A figure shown in the notch, as a percentage or an amount.
private struct UsageRow: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var format: UsageFormat
    let percent: String
    let amount: String

    var body: some View {
        HStack {
            Toggle(title, isOn: $isOn)
            Spacer()
            Picker(title, selection: $format) {
                Text(percent).tag(UsageFormat.percent)
                Text(amount).tag(UsageFormat.amount)
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn)
        }
    }
}
