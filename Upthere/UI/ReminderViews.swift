import SwiftUI

/// The ears' sizes for pinned reminders, shared by the views and the
/// width math in `NotchViewModel+Widths`, so the ear hugs what's drawn.
enum ReminderMetrics {
    /// A collapsed reminder's name, at most.
    static let collapsedText: CGFloat = 130
    /// A strip chip's text column.
    static let chipText: CGFloat = 110
    /// A hovered chip's two buttons (unpin, open).
    static let chipButtons: CGFloat = 48

    static func collapsedCheck(unit: CGFloat) -> CGFloat { (unit * 0.36).rounded() }
    static func chipCheck(unit: CGFloat) -> CGFloat { unit - 18 }
}

/// A pinned reminder in the collapsed ear: its circle in the list's colour
/// (red once overdue) and its name.
struct ReminderCollapsedItem: View {
    let item: ReminderItem
    let unit: CGFloat
    var mirrored = false

    var body: some View {
        let tone = item.isOverdue() ? Theme.danger : item.list.tone.color
        // A long name rolls within its cap rather than ending in "…".
        let width = min(TextWidth.of(item.title, Theme.TextStyle.label), ReminderMetrics.collapsedText)
        HStack(spacing: 4) {
            if mirrored { circle(tone) }
            MarqueeText(
                text: item.title, font: Theme.TextStyle.label.font, color: Theme.Ink.icon,
                alignment: mirrored ? .leading : .trailing
            )
            .frame(width: width)
            if !mirrored { circle(tone) }
        }
    }

    private func circle(_ tone: Color) -> some View {
        let size = ReminderMetrics.collapsedCheck(unit: unit)
        return Circle()
            .strokeBorder(tone, lineWidth: 1.5)
            // Overdue isn't told by colour alone.
            .overlay {
                if item.isOverdue() {
                    Image(systemName: "exclamationmark").font(.system(size: size * 0.6, weight: .heavy)).foregroundStyle(tone)
                        .transition(.blurReplace)
                }
            }
            .frame(width: size, height: size)
            .animation(.smooth(duration: 0.3), value: item.isOverdue())
    }
}

/// A pinned reminder in the hover strip: tick it done (a second tick in
/// the moment after undoes it), its name and when it's due. Hovered, it can
/// be unpinned or opened in Reminders; like a timer chip, those buttons open
/// on the side away from the notch so the chip itself stays put.
struct ReminderChip: View {
    let model: NotchViewModel
    let item: ReminderItem
    /// The notch is on the leading side (right ear).
    var mirrored = false
    /// Under the pointer, maybe just passing: a tint, no layout change.
    @State private var pointing = false

    var body: some View {
        let reminders = model.reminders
        let done = reminders.completing.contains(item.id)
        let overdue = item.isOverdue()
        let tone = overdue ? Theme.danger : item.list.tone.color
        let hovering = model.hoveredChip == .reminder(item.id)
        HStack(spacing: 6) {
            if hovering && !mirrored { buttons(reminders) }
            ReminderCheck(item: item, done: done, size: ReminderMetrics.chipCheck(unit: model.geometry.height)) {
                reminders.toggleComplete(item.id)
            }
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: item.title, font: Theme.TextStyle.label.font)
                    .opacity(done ? 0.5 : 1)
                Text(subtitle)
                    .font(Theme.TextStyle.body.font)
                    .foregroundStyle(item.due == nil ? Theme.secondary : tone)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            .frame(width: ReminderMetrics.chipText, alignment: .leading)
            if hovering && mirrored { buttons(reminders) }
        }
        .padding(.vertical, 2)
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(item.list.tone.color.opacity(hovering || pointing ? 0.2 : 0.12))
        }
        .onHover { inside in
            pointing = inside
            model.hoverChip(.reminder(item.id), inside: inside)
        }
        .animation(.easeOut(duration: 0.12), value: pointing)
        .onDisappear { model.chipGone(.reminder(item.id)) }
        .animation(.smooth(duration: 0.2), value: done)
        // Changed in Reminders (renamed, due moved, list or overdue colour).
        .animation(.smooth(duration: 0.3), value: subtitle)
        .animation(.smooth(duration: 0.3), value: overdue)
    }

    private func buttons(_ reminders: RemindersModel) -> some View {
        HStack(spacing: 0) {
            chipButton("pin.slash.fill", help: "Unpin") { reminders.unpin(item.id) }
            chipButton("arrow.up.forward.app", help: "Open in Reminders") { ReminderStore.reveal(item.id) }
        }
        .transition(.blurReplace)
    }

    /// When it's due, else its list.
    private var subtitle: String {
        if model.reminders.completing.contains(item.id) { return String(localized: "Done") }
        guard let due = item.due else { return item.list.title }
        return ReminderParser.describe(due)
    }

    private func chipButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Ink.icon)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }
}
