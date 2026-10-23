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
    /// The overdue "!" beside a collapsed name or icon, with its gap.
    static let overdueMark: CGFloat = 9

    static func chipCheck(unit: CGFloat) -> CGFloat { unit - 18 }
    static func collapsedIcon(unit: CGFloat) -> CGFloat { (unit * 0.42).rounded() }

    static func nameWidth(_ item: ReminderItem) -> CGFloat {
        min(TextWidth.of(item.title, Theme.TextStyle.label), collapsedText)
    }

    /// A collapsed reminder by name: the name, plus "!" once overdue.
    static func collapsedWidth(_ item: ReminderItem) -> CGFloat {
        nameWidth(item) + (item.isOverdue() ? overdueMark : 0)
    }

    /// All pinned reminders as one icon: the icon, a count past one, "!"
    /// when any is overdue.
    static func iconWidth(_ items: [ReminderItem], unit: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let count = items.count > 1 ? 3 + TextWidth.of("\(items.count)", Theme.TextStyle.label) : 0
        return collapsedIcon(unit: unit) + count + (items.contains { $0.isOverdue() } ? overdueMark + 1 : 0)
    }
}

/// "!" for overdue, so it isn't told by colour alone.
private struct OverdueMark: View {
    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.danger)
            .frame(width: ReminderMetrics.overdueMark - 2)
            .transition(.blurReplace)
    }
}

/// A pinned reminder in the collapsed ear: its name, in red with a "!" once
/// overdue. The list's colour tints the ear instead of a
/// ring, which looked tickable but only opened the strip.
struct ReminderCollapsedItem: View {
    let item: ReminderItem
    var mirrored = false

    var body: some View {
        let overdue = item.isOverdue()
        HStack(spacing: 2) {
            // The "!" leads the name (away from the notch), so it can't be
            // read as the next reminder's.
            if !mirrored && overdue { OverdueMark() }
            // A long name rolls within its cap rather than ending in "…".
            MarqueeText(
                text: item.title, font: Theme.TextStyle.label.font, color: overdue ? Theme.danger : Theme.Ink.icon,
                alignment: mirrored ? .leading : .trailing
            )
            .frame(width: ReminderMetrics.nameWidth(item))
            if mirrored && overdue { OverdueMark() }
        }
        .animation(.smooth(duration: 0.3), value: overdue)
    }
}

/// All pinned reminders as one checklist icon in the lead reminder's list
/// colour (red once any is overdue), with how many past one.
struct ReminderCollapsedIcon: View {
    let items: [ReminderItem]
    let unit: CGFloat
    var mirrored = false

    var body: some View {
        let overdue = items.contains { $0.isOverdue() }
        let tone = overdue ? Theme.danger : items.first.map { $0.list.tone.color } ?? Theme.Ink.icon
        HStack(spacing: 3) {
            if mirrored && overdue { OverdueMark() }
            if mirrored { icon(tone) }
            if items.count > 1 {
                Text("\(items.count)")
                    .font(Theme.TextStyle.label.font)
                    .foregroundStyle(Theme.Ink.icon)
                    .fixedSize()
                    .contentTransition(.numericText(value: Double(items.count)))
                    .transition(.blurReplace)
            }
            if !mirrored { icon(tone) }
            if !mirrored && overdue { OverdueMark() }
        }
        .animation(.smooth(duration: 0.3), value: overdue)
        .animation(.smooth(duration: 0.25), value: items.count)
    }

    private func icon(_ tone: Color) -> some View {
        let size = ReminderMetrics.collapsedIcon(unit: unit)
        return Image(systemName: "checklist")
            .font(.system(size: size * 0.8, weight: .semibold))
            .foregroundStyle(tone)
            .frame(width: size, height: size)
            .animation(.smooth(duration: 0.3), value: tone)
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
