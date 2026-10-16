import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @Bindable var prefs: Preferences
    @Bindable var updater: Updater
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                        }
                        refreshLoginItem()
                    }
                if loginItemStatus == .requiresApproval {
                    FixRow(message: "Allow Upthere in Login Items to start it at login.", button: "Open Login Items…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } else if let launchError {
                    ErrorText(message: launchError)
                }
                Picker("Display", selection: $prefs.display) {
                    ForEach(DisplayChoice.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Ears") {
                LabeledContent("Keep ear open after leaving") {
                    Slider(value: $prefs.earCloseDelay, in: 0...2, step: 0.1)
                        .frame(width: 180)
                    Text(String(format: "%.1f s", prefs.earCloseDelay)).monospacedDigit().frame(width: 50, alignment: .trailing)
                }
                LabeledContent("Max ear width") {
                    Slider(value: $prefs.maxEarWidth, in: 180...480, step: 10)
                        .frame(width: 180)
                    Text("\(Int(prefs.maxEarWidth)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                LabeledContent("Version \(updater.currentVersion)") {
                    Button("Check Now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                }
            }

            Section("About") {
                Link("github.com/Mateu6/upthere", destination: URL(string: "https://github.com/Mateu6/upthere")!)
            }
        }
        .settingsTab()
        // Coming back from System Settings: pick up what was allowed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
    }

    private func refreshLoginItem() {
        loginItemStatus = SMAppService.mainApp.status
        launchAtLogin = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }
}
