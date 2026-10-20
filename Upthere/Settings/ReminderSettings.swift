import AppKit
import SwiftUI

struct ReminderSettings: View {
    @Bindable var prefs: Preferences
    let reminders: RemindersModel

    var body: some View {
        Form {
            Section {
                Picker("Add a reminder with", selection: $prefs.reminderHotKey) {
                    ForEach(HotKey.ReminderPreset.allCases) { Text($0.title).tag($0) }
                }
                if reminders.isAuthorized {
                    Picker("New reminders go to", selection: $prefs.reminderListID) {
                        Text("Default list").tag(String?.none)
                        ForEach(reminders.lists) { list in
                            Label {
                                Text(list.title)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(list.tone.color)
                            }
                            .tag(Optional(list.id))
                        }
                    }
                    Toggle("Pin new reminders to the notch", isOn: $prefs.reminderPin)
                } else if reminders.isDenied {
                    FixRow(
                        message: "Reminders access is off for Upthere. Turn it on in System Settings, then come back.",
                        button: "Open Privacy Settings…"
                    ) { PrivacySettings.open("Privacy_Reminders") }
                } else {
                    LabeledContent("Reminders") {
                        Button("Allow Access") { Task { await reminders.requestAccess() } }
                    }
                }
            } footer: {
                SettingsFooter(
                    text: "Type “call mom tomorrow 5pm !! #family @home”: a date, !/!!/!!! for priority, #tags and @list, or pick them with the buttons. ⌘↵ adds with the pin flipped."
                )
            }

            if reminders.isAuthorized {
                Section {
                    if reminders.pinned.isEmpty {
                        Text("Nothing pinned. Pin a reminder from the field to keep it beside the notch.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(reminders.pinned) { item in
                            HStack {
                                Circle().fill(item.list.tone.color).frame(width: 8, height: 8)
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Button("Unpin") { reminders.unpin(item.id) }.controlSize(.small)
                            }
                        }
                    }
                } header: {
                    Text("Pinned to the notch")
                } footer: {
                    SettingsFooter(
                        text: "Tick one in the notch to complete it. Done or deleted in Reminders, it leaves the notch too. Tags are saved as #hashtags in the notes: Apple doesn’t let other apps set real Reminders tags."
                    )
                }
            }
        }
        .settingsTab()
        .onAppear { reminders.refresh() }
        // Coming back from System Settings: pick up what was allowed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reminders.refresh()
        }
    }
}
