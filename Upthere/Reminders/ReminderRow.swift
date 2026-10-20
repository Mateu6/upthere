import SwiftUI

/// A reminder already in Reminders, under the field: tick it done, see
/// its list and date, pin it to the notch.
struct ReminderRow: View {
    let reminders: RemindersModel
    let item: ReminderItem
    var highlighted = false

    var body: some View {
        let pinned = reminders.isPinned(item.id)
        let done = reminders.completing.contains(item.id)
        HStack(spacing: 8) {
            ReminderCheck(item: item, done: done, size: 15) { reminders.toggleComplete(item.id) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                HStack(spacing: 4) {
                    Circle().fill(item.list.tone.color).frame(width: 6, height: 6)
                    Text(item.list.title)
                    if let due = item.due {
                        Text("·")
                        Text(ReminderParser.describe(due))
                            .foregroundStyle(item.isOverdue() ? Theme.danger : Color.secondary)
                    }
                    if item.priority != .none {
                        Text("·")
                        Text(item.priority.marks)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                reminders.togglePin(item)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? Color(nsColor: item.list.tone.nsColor) : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PanelIconButtonStyle())
            .help(pinned ? "Unpin from the notch" : "Pin to the notch")
            Button {
                ReminderStore.reveal(item.id)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("Open in Reminders")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(highlighted ? Theme.Ink.hoverOpacity : 0))
        }
        .animation(.spring(duration: 0.2, bounce: 0), value: highlighted)
        .animation(.smooth(duration: 0.2), value: done)
    }
}

/// Reminders' round checkbox, in the list's colour. Filled while ticked;
/// a second click within the moment before it's saved undoes it.
struct ReminderCheck: View {
    let item: ReminderItem
    let done: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        let tone = item.isOverdue() ? Theme.danger : item.list.tone.color
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(tone, lineWidth: max(1.2, size * 0.1))
                if done {
                    Circle().fill(tone).padding(size * 0.2).transition(.scale(scale: 0.5).combined(with: .opacity))
                } else if item.isOverdue() {
                    // Overdue isn't told by colour alone.
                    Image(systemName: "exclamationmark").font(.system(size: size * 0.55, weight: .heavy))
                        .foregroundStyle(tone).transition(.opacity)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(CheckButtonStyle())
        .help(done ? "Undo" : "Mark as done")
        .animation(.spring(duration: 0.2, bounce: 0), value: done)
    }
}

/// The checkbox grows a touch under the pointer and dips when pressed.
private struct CheckButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.88 : hovering ? 1.1 : 1)
                .opacity(hovering || configuration.isPressed ? 1 : 0.9)
                .onHover { hovering = $0 }
                .animation(.spring(duration: 0.12, bounce: 0), value: configuration.isPressed)
                .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
        }
    }
}
