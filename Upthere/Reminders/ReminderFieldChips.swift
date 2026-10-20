import SwiftUI

/// What the reminder will be, as buttons under the field: list, date,
/// priority, flag, tags and pin. Each shows what the text set and changes
/// it with a click; a value picked here wins over the text.
struct ReminderFieldChips: View {
    let reminders: RemindersModel
    @Binding var composer: ReminderComposer
    let resolved: ReminderComposer.Resolved
    @Binding var pin: Bool
    @State private var pickingDate = false
    @State private var pickedDate = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                listMenu
                dateMenu
                priorityMenu
                FieldChip(symbol: composer.flagged ? "flag.fill" : "flag", title: nil, active: composer.flagged, tint: .orange) {
                    composer.flagged.toggle()
                }
                .help(composer.flagged ? "Flagged" : "Flag")
                tagMenu
                Spacer(minLength: 4)
                FieldChip(symbol: pin ? "pin.fill" : "pin", title: "Notch", active: pin) { pin.toggle() }
                    .help(pin ? "New reminders are pinned to the notch" : "Pin new reminders to the notch")
            }
            if pickingDate {
                HStack(spacing: 8) {
                    DatePicker("", selection: $pickedDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Button("Set") {
                        composer.dueChoice = .picked(.init(date: pickedDate, hasTime: true))
                        pickingDate = false
                    }
                    .controlSize(.small)
                    Button("Cancel") { pickingDate = false }.controlSize(.small)
                }
                .transition(.blurReplace)
            }
            hint
        }
        .animation(.smooth(duration: 0.2), value: pickingDate)
    }

    // MARK: Chips

    private var listMenu: some View {
        Menu {
            ForEach(reminders.lists) { list in
                Toggle(isOn: Binding(get: { resolved.list?.id == list.id }, set: { _ in composer.listID = list.id })) {
                    Text(list.title)
                }
            }
        } label: {
            ChipLabel(dot: resolved.list?.tone.color, symbol: nil, title: resolved.list?.title ?? "List", active: true)
        }
        .menuStyle(.button)
        .buttonStyle(FieldChipStyle(active: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(resolved.listFromText ? "List from “@” in the text" : "List")
    }

    private var dateMenu: some View {
        Menu {
            ForEach(ReminderComposer.quickDates(), id: \.title) { pick in
                Button(pick.title) { composer.dueChoice = .picked(pick.due) }
            }
            Button("Pick a date and time…") {
                pickedDate = resolved.due?.date ?? Date.now.addingTimeInterval(3600)
                pickingDate = true
            }
            if resolved.due != nil || composer.dueChoice != .fromText {
                Divider()
                if composer.dueChoice != .fromText {
                    Button("Use the date in the text") { composer.dueChoice = .fromText }
                }
                if resolved.due != nil { Button("No date") { composer.dueChoice = .none } }
            }
        } label: {
            ChipLabel(
                dot: nil, symbol: "calendar", title: resolved.due.map { ReminderParser.describe($0) } ?? "Date",
                active: resolved.due != nil)
        }
        .menuStyle(.button)
        .buttonStyle(FieldChipStyle(active: resolved.due != nil))
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var priorityMenu: some View {
        Menu {
            ForEach([ReminderParser.Priority.none, .low, .medium, .high], id: \.self) { level in
                Toggle(isOn: Binding(get: { resolved.priority == level }, set: { _ in composer.priority = level })) {
                    Text(level == .none ? level.title : "\(level.marks)  \(level.title)")
                }
            }
        } label: {
            ChipLabel(
                dot: nil, symbol: resolved.priority == .none ? "exclamationmark" : nil,
                title: resolved.priority == .none ? nil : resolved.priority.marks, active: resolved.priority != .none)
        }
        .menuStyle(.button)
        .buttonStyle(FieldChipStyle(active: resolved.priority != .none))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Priority: \(resolved.priority.title)")
    }

    /// Tags typed with "#", plus recent ones to add with a click.
    private var tagMenu: some View {
        Menu {
            let unused = reminders.recentTags.filter { tag in
                !resolved.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            }
            if unused.isEmpty {
                Text("Type #tag in the text")
            } else {
                ForEach(unused, id: \.self) { tag in
                    Button("#\(tag)") { appendToText("#\(tag)") }
                }
            }
        } label: {
            ChipLabel(
                dot: nil, symbol: "number", title: resolved.tags.isEmpty ? nil : resolved.tags.joined(separator: " #"),
                active: !resolved.tags.isEmpty)
        }
        .menuStyle(.button)
        .buttonStyle(FieldChipStyle(active: !resolved.tags.isEmpty))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tags (saved as #hashtags in the notes)")
    }

    private var hint: some View {
        HStack(spacing: 0) {
            Text(resolved.title.isEmpty ? "@list  #tag  !!  and a date, or pick them above" : "“\(resolved.title)”")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !resolved.title.isEmpty {
                Text(pin ? "↵ add and pin   ⌘↵ add" : "↵ add   ⌘↵ add and pin")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func appendToText(_ word: String) {
        let text = composer.text
        composer.text = text.isEmpty || text.hasSuffix(" ") ? text + word + " " : text + " " + word + " "
    }
}

/// A chip's face: a list dot or a symbol, then the value.
private struct ChipLabel: View {
    let dot: Color?
    let symbol: String?
    let title: String?
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            if let title {
                Text(title).lineLimit(1).contentTransition(.interpolate)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(active ? Color.primary : Color.secondary)
    }
}

/// A toggle-like chip (flag, pin).
private struct FieldChip: View {
    let symbol: String
    let title: String?
    let active: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(active ? tint : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                if let title { Text(title).font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .buttonStyle(FieldChipStyle(active: active))
    }
}

/// Chips: a soft capsule that lights on hover and dips when pressed; a set
/// value keeps a faint fill so what's chosen reads at a glance.
struct FieldChipStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, active: active)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    Capsule().fill(.primary.opacity(pressed ? 0.2 : hovering ? 0.13 : active ? 0.08 : 0.04))
                }
                .contentShape(Capsule())
                .scaleEffect(pressed ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(.spring(duration: 0.12, bounce: 0), value: pressed)
                .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
                .animation(.smooth(duration: 0.2), value: active)
        }
    }
}
