import AppKit
import SwiftUI

/// The reminder field under the notch (⌥⌘R): add a reminder to any list,
/// and pin reminders, new or existing, to the notch.
final class ReminderInputController {
    private let panel: NotchFieldPanel
    private let reminders: RemindersModel
    private let prefs: Preferences

    init(reminders: RemindersModel, prefs: Preferences, geometry: @escaping () -> NotchGeometry?) {
        self.reminders = reminders
        self.prefs = prefs
        panel = NotchFieldPanel(geometry: geometry)
    }

    var isOpen: Bool { panel.isOpen }

    func toggle() { isOpen ? close() : show() }

    func show() {
        reminders.refresh()
        // First use: the system asks right away (its prompt says what for),
        // and the field opens once allowed.
        if !reminders.isAuthorized, !reminders.isDenied {
            Task {
                await reminders.requestAccess()
                if reminders.isAuthorized { show() }
            }
            return
        }
        panel.show(ReminderInputView(reminders: reminders, prefs: prefs, close: { [weak self] in self?.close() }))
    }

    func close() { panel.close() }
}

struct ReminderInputView: View {
    let reminders: RemindersModel
    @Bindable var prefs: Preferences
    let close: () -> Void

    @State private var composer = ReminderComposer()
    @State private var existing: [ReminderItem] = []
    @State private var highlighted: Int?
    @State private var added: ReminderList?
    @State private var error: String?
    @FocusState private var focused: Bool

    /// Rows shown under the field at most.
    private static let rowLimit = 7

    private var resolved: ReminderComposer.Resolved {
        composer.resolve(lists: reminders.lists, defaultListID: prefs.reminderListID ?? reminders.defaultListID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if reminders.isAuthorized {
                field
                if added == nil {
                    ReminderFieldChips(
                        reminders: reminders, composer: $composer, resolved: resolved, pin: $prefs.reminderPin)
                    if let error { ErrorText(message: error) }
                    if !rows.isEmpty {
                        Divider()
                        rowList
                    }
                }
            } else {
                AccessPrompt(reminders: reminders, close: close)
            }
        }
        .padding(16)
        .frame(width: 460)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.smooth(duration: 0.24), value: rows.map(\.id))
        .animation(.smooth(duration: 0.24), value: added)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .task(id: reminders.revision) { existing = await reminders.incomplete() }
        .onChange(of: composer.text) { highlighted = nil }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: added != nil ? "checkmark.circle.fill" : "checklist")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(added.map { $0.tone.color } ?? Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            if let added {
                Text("Added to \(added.title)")
                    .font(.system(size: 16))
                    .transition(.blurReplace)
            } else {
                TextField("Remind me to…  e.g. “call mom tomorrow 5pm #family”", text: $composer.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { submit(pin: prefs.reminderPin) }
            }
            Spacer(minLength: 0)
            // ⌘↵ flips the pin for this one reminder.
            Button("") { submit(pin: !prefs.reminderPin) }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Existing reminders

    /// Typing: reminders whose title matches, to pin instead of adding a
    /// duplicate. Empty: what's pinned, then the most pressing.
    private var rows: [ReminderItem] {
        let query = composer.text.trimmingCharacters(in: .whitespaces)
        let pinned = reminders.pinned
        let open = existing.filter { item in !pinned.contains { $0.id == item.id } }
        if query.isEmpty {
            let dated = open.filter { $0.due != nil }.sorted { $0.due!.date < $1.due!.date }
            return Array((pinned + dated).prefix(Self.rowLimit))
        }
        let words = resolved.title.split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        let matches = (pinned + open).filter { item in words.allSatisfy { item.title.localizedCaseInsensitiveContains($0) } }
        return Array(matches.prefix(Self.rowLimit))
    }

    private var rowList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(composer.text.trimmingCharacters(in: .whitespaces).isEmpty ? "Pinned and coming up" : "Already in Reminders")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                ReminderRow(reminders: reminders, item: item, highlighted: highlighted == index)
                    .transition(.blurReplace)
            }
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        highlighted = max(0, min((highlighted ?? (step > 0 ? -1 : rows.count)) + step, rows.count - 1))
        return .handled
    }

    // MARK: Saving

    private func submit(pin: Bool) {
        // A highlighted row: ↵ pins or unpins it instead of adding.
        if let highlighted, rows.indices.contains(highlighted) {
            reminders.togglePin(rows[highlighted])
            return
        }
        guard
            let draft = composer.draft(
                lists: reminders.lists, defaultListID: prefs.reminderListID ?? reminders.defaultListID)
        else { return }
        do {
            try reminders.add(draft, pin: pin)
            error = nil
            added = resolved.list ?? ReminderList(id: "", title: "Reminders", hue: 235)
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                close()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// No access yet: say what it's for and ask; refused before, point to
/// System Settings.
private struct AccessPrompt: View {
    let reminders: RemindersModel
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                Text("Add to Reminders from anywhere")
                    .font(.system(size: 14, weight: .semibold))
                Text(
                    reminders.isDenied
                        ? "Reminders access is off for Upthere. Turn it on in System Settings, then press ⌥⌘R again."
                        : "Upthere needs access to Reminders to add reminders and keep pinned ones in the notch."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if reminders.isDenied {
                        Button("Open Privacy Settings…") {
                            PrivacySettings.open("Privacy_Reminders")
                            close()
                        }
                    } else {
                        Button("Allow Access") { Task { await reminders.requestAccess() } }
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("Not Now", action: close)
                }
                .controlSize(.small)
            }
        }
        .onExitCommand(perform: close)
    }
}
