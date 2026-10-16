import AppKit
import SwiftUI

struct TimerSettings: View {
    @Bindable var prefs: Preferences
    let calendar: CalendarLogger
    @State private var calendars: [(id: String, title: String)] = []
    @State private var calendarAuthorized = false
    @State private var calendarDenied = false
    @State private var calendarError: String?

    var body: some View {
        Form {
            Section {
                Picker("Start a timer with", selection: $prefs.timerHotKey) {
                    ForEach(HotKey.Preset.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Sound when a countdown ends", isOn: $prefs.timerSound)
            } footer: {
                SettingsFooter(
                    text: "Type “review PR” to count up, or “waiting for CI 15m” to count down. Up to \(TimerModel.maxTimers) at once."
                )
            }

            Section {
                Toggle("Add finished timers to Calendar", isOn: $prefs.timerCalendar)
                    .onChange(of: prefs.timerCalendar) { _, on in if on { requestCalendar() } }
                if prefs.timerCalendar {
                    if calendarAuthorized {
                        Picker("Calendar", selection: $prefs.timerCalendarID) {
                            Text("Default calendar").tag(String?.none)
                            ForEach(calendars, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                        }
                        if !calendars.contains(where: { $0.title == "Upthere" }) {
                            Button("Create “Upthere” calendar") { createCalendar() }
                        }
                    } else if calendarDenied {
                        FixRow(
                            message: "Calendar access is off for Upthere. Turn it on in System Settings, then come back.",
                            button: "Open Privacy Settings…"
                        ) { PrivacySettings.open("Privacy_Calendars") }
                    } else {
                        Button("Allow Calendar access") { requestCalendar() }
                    }
                    if let calendarError { ErrorText(message: calendarError) }
                }
                Toggle("Keep entries shorter than a minute", isOn: $prefs.timerKeepShort)
            } header: {
                Text("Calendar")
            } footer: {
                SettingsFooter(text: "Each timer becomes its own calendar event when you stop it.")
            }
        }
        .settingsTab()
        .onAppear { reloadCalendars() }
        // Coming back from System Settings: pick up what was allowed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadCalendars()
        }
    }

    private func reloadCalendars() {
        calendarAuthorized = calendar.isAuthorized
        calendarDenied = calendar.isDenied
        calendars = calendar.calendars().map { ($0.calendarIdentifier, $0.title) }
    }

    private func requestCalendar() {
        Task {
            _ = await calendar.requestAccess()
            reloadCalendars()
        }
    }

    private func createCalendar() {
        do {
            let created = try calendar.createUpthereCalendar()
            prefs.timerCalendarID = created.calendarIdentifier
            calendarError = nil
        } catch {
            calendarError = error.localizedDescription
        }
        reloadCalendars()
    }
}
