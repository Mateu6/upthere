import AppKit
import QuartzCore
import SwiftUI

/// A timer's mark: a ring that fills as a countdown runs (driven by a linear
/// Core Animation, so it costs nothing per frame), or a stopwatch glyph for
/// count-ups.
struct TimerGlyph: View {
    let timer: TrackedTimer
    let color: NSColor
    let size: CGFloat
    var alerting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if timer.isCountdown {
                TimerRingView(timer: timer, color: color)
                if timer.isPaused {
                    Image(systemName: "pause.fill").font(.system(size: size * 0.32, weight: .bold))
                        .foregroundStyle(Color(nsColor: color))
                        .transition(.blurReplace)
                }
            } else {
                Image(systemName: timer.isPaused ? "pause.circle" : "stopwatch")
                    .font(.system(size: size * 0.78, weight: .medium))
                    .foregroundStyle(Color(nsColor: color))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.24), value: timer.isPaused)
        // Time's up: a pulse, as a fade under Reduce Motion.
        .scaleEffect(alerting && !reduceMotion ? 1.12 : 1)
        .opacity(alerting && reduceMotion ? 0.45 : 1)
        .animation(
            alerting ? .easeInOut(duration: reduceMotion ? 0.8 : 0.5).repeatForever(autoreverses: true) : .smooth(duration: 0.3),
            value: alerting)
    }
}

struct TimerRingView: NSViewRepresentable {
    let timer: TrackedTimer
    let color: NSColor

    func makeNSView(context: Context) -> TimerRingNSView { TimerRingNSView() }
    func updateNSView(_ view: TimerRingNSView, context: Context) { view.update(timer: timer, color: color) }
}

final class TimerRingNSView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var timer: TrackedTimer?
    private var lastSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineCap = .round
            self.layer?.addSublayer(layer)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(Theme.Ink.trackOpacity).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        restart()
    }

    func update(timer: TrackedTimer, color: NSColor) {
        arc.strokeColor = color.cgColor
        guard timer != self.timer else { return }
        self.timer = timer
        restart()
    }

    private func restart() {
        guard let timer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let line = max(1.5, min(bounds.width, bounds.height) * 0.12)
        let rect = bounds.insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
        // Starts at 12 o'clock and runs clockwise.
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        let path = CGPath(
            ellipseIn: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height),
            transform: &transform)
        for layer in [track, arc] {
            layer.frame = bounds
            layer.path = path
            layer.lineWidth = line
        }
        arc.removeAnimation(forKey: "progress")
        let progress = timer.progress()
        arc.strokeEnd = progress
        if let remaining = timer.remaining(), remaining > 0, !timer.isPaused {
            let fill = CABasicAnimation(keyPath: "strokeEnd")
            fill.fromValue = progress
            fill.toValue = 1
            fill.duration = remaining
            fill.timingFunction = CAMediaTimingFunction(name: .linear)
            fill.fillMode = .forwards
            fill.isRemovedOnCompletion = false
            fill.preferredFrameRateRange = CAAnimation.slowFrameRate
            arc.add(fill, forKey: "progress")
        }
        CATransaction.commit()
    }
}

/// Time text for a timer: remaining for countdowns (then "+overtime"),
/// elapsed for count-ups. `compact` is for the collapsed notch.
struct TimerTime: View {
    let timer: TrackedTimer
    var compact = false
    var font: Font = Theme.TextStyle.readout.font
    var color: Color = .white

    var body: some View {
        // Compact text changes at most every 15 s until the last minute.
        let fine = !compact || (timer.remaining().map { abs($0) < 70 } ?? (timer.elapsed() < 70))
        TimelineView(.periodic(from: .now, by: fine ? 1 : 15)) { context in
            let text = text(at: context.date)
            Text(text)
                .font(font.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(timer.isPaused ? Theme.secondary : color)
                .contentTransition(.numericText(countsDown: timer.isCountdown))
                // The timeline ticks without a transaction: give each tick one.
                .animation(.smooth(duration: 0.3), value: text)
                .animation(.smooth(duration: 0.24), value: timer.isPaused)
        }
    }

    private func text(at date: Date) -> String {
        if let remaining = timer.remaining(at: date) {
            if remaining < 0 { return "+" + (compact ? TimerParser.compact(-remaining) : TimerParser.clock(-remaining)) }
            return compact ? TimerParser.compact(remaining) : TimerParser.clock(remaining)
        }
        return compact ? TimerParser.compact(timer.elapsed(at: date)) : TimerParser.clock(timer.elapsed(at: date))
    }
}

/// Hovered timer ear: a sideways strip with a chip per timer and pinned
/// reminder, Claude's status when it's live, and buttons to add more. It
/// keeps the collapsed ear's order reading out from the notch (timers,
/// reminders, Claude), so nothing changes places as it opens; the add
/// buttons sit at the far end.
struct TimerStrip: View {
    let model: NotchViewModel
    /// The ear's width, so chips sit against the notch when they fit.
    var stripWidth: CGFloat = 0
    /// Claude's chip (off where Claude has its own piece).
    var showsClaude = true
    /// The notch is on the leading side (right ear).
    var mirrored = false
    /// Under the pointer, maybe just passing: a tint, no layout change.
    @State private var pointing = false

    var body: some View {
        let timers = model.timers
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if mirrored {
                        timerChips
                        reminderChips
                        claudeChip
                        addButtons
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                        addButtons
                        claudeChip
                        reminderChips
                        timerChips
                    }
                }
                .padding(.horizontal, 6)
                .frame(minWidth: stripWidth, alignment: mirrored ? .leading : .trailing)
                .animation(.smooth(duration: 0.25), value: model.reminders.pinned.map(\.id))
                .animation(.smooth(duration: 0.25), value: model.timers.timers.map(\.id))
                .animation(.smooth(duration: 0.25), value: model.claude.primary?.id)
                .animation(.smooth(duration: 0.25), value: model.reminders.isAuthorized)
            }
            .defaultScrollAnchor(mirrored ? .leading : .trailing)
            // Time's up on a chip out of sight: scroll just enough to show it.
            .onAppear { if let id = timers.alertingID { proxy.scrollTo(TrayChip.timer(id)) } }
            .onChange(of: timers.alertingID) { _, id in
                if let id { withAnimation(.smooth) { proxy.scrollTo(TrayChip.timer(id)) } }
            }
            // A chip cut off at the strip's far end would open its buttons
            // out of sight: scroll just enough to show them (no-op when the
            // chip is already whole, so the usual hover moves nothing).
            .onChange(of: model.hoveredChip) { _, chip in
                guard let chip else { return }
                Task { @MainActor in
                    withAnimation(Theme.earSpring(opening: true)) { proxy.scrollTo(chip) }
                }
            }
        }
    }

    /// Read outwards from the notch: the last one sits against it.
    private func outwards<T>(_ items: [T]) -> [T] { mirrored ? items.reversed() : items }

    private var timerChips: some View {
        ForEach(outwards(model.timers.timers)) { timer in
            TimerChip(model: model, timer: timer, size: model.geometry.height - 14, mirrored: mirrored)
                .id(TrayChip.timer(timer.id))
                .transition(.blurReplace)
        }
    }

    private var reminderChips: some View {
        ForEach(outwards(model.reminders.pinned)) { item in
            ReminderChip(model: model, item: item, mirrored: mirrored)
                .id(TrayChip.reminder(item.id))
                .transition(.blurReplace)
        }
    }

    @ViewBuilder private var claudeChip: some View {
        if showsClaude, let session = model.claude.primary, model.prefs.claudeEnabled {
            ClaudeChip(model: model, session: session, size: model.geometry.height - 16)
                .transition(.blurReplace)
        }
    }

    @ViewBuilder private var addButtons: some View {
        if model.reminders.isAuthorized {
            addButton("checklist", help: "New reminder", action: model.openReminderInput)
        }
        if model.timers.timers.count < TimerModel.maxTimers {
            addButton("plus", help: "New timer", action: model.openTimerInput)
        }
    }

    private func addButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Ink.icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
        .transition(.blurReplace)
    }
}

/// A timer in the strip: glyph, label and time. Hovered, its buttons open
/// on the side away from the notch, so the chip under the pointer stays
/// put and only what lies beyond it moves out, with the ear.
struct TimerChip: View {
    let model: NotchViewModel
    let timer: TrackedTimer
    let size: CGFloat
    /// The notch is on the leading side (right ear).
    var mirrored = false
    /// Under the pointer, maybe just passing: a tint, no layout change.
    @State private var pointing = false

    var body: some View {
        let timers = model.timers
        let alerting = timers.alertingID == timer.id
        let color = timers.color(of: timer)
        let hovering = model.hoveredChip == .timer(timer.id)
        HStack(spacing: 6) {
            if hovering && !mirrored { buttons(timers) }
            TimerGlyph(timer: timer, color: color, size: size, alerting: alerting)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    if timer.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(Color(nsColor: color))
                            .transition(.blurReplace)
                    }
                    MarqueeText(
                        text: alerting ? "Time's up · \(timer.label)" : timer.label,
                        font: Theme.TextStyle.label.font)
                    .id(alerting)
                    .transition(.blurReplace)
                }
                TimerTime(timer: timer, font: Theme.TextStyle.figure.font, color: Color(nsColor: color))
            }
            .frame(width: 92, alignment: .leading)
            if hovering && mirrored { buttons(timers) }
        }
        .padding(.vertical, 2)
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .background {
            // Color-coded: a tinted fill and a bar in the timer's color.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: color).opacity(alerting ? 0.34 : hovering || pointing ? 0.26 : 0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color(nsColor: color)).frame(width: 3).padding(.vertical, 4).padding(.leading, 2)
                }
        }
        .onHover { inside in
            pointing = inside
            model.hoverChip(.timer(timer.id), inside: inside)
        }
        .animation(.easeOut(duration: 0.12), value: pointing)
        .animation(.smooth(duration: 0.24), value: timer.isPinned)
        .animation(Theme.contentSwap, value: alerting)
        .onDisappear { model.chipGone(.timer(timer.id)) }
    }

    private func buttons(_ timers: TimerModel) -> some View {
        HStack(spacing: 0) {
            chipButton(timer.isPinned ? "pin.slash.fill" : "pin.fill", help: timer.isPinned ? "Unpin" : "Keep visible") {
                timers.togglePin(timer.id)
            }
            chipButton(timer.isPaused ? "play.fill" : "pause.fill", help: timer.isPaused ? "Resume" : "Pause") {
                timers.togglePause(timer.id)
            }
            if timer.isCountdown {
                chipButton("goforward.5", help: "+5 minutes") { timers.extend(timer.id) }
            }
            chipButton("stop.fill", help: "Stop and log") { timers.stop(timer.id) }
        }
        .transition(.blurReplace)
    }

    private func chipButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Ink.icon)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .animation(.smooth(duration: 0.2), value: symbol)
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }
}

/// Collapsed timer ear: each pinned timer (or the urgent one) as its time
/// in its color plus its glyph, right next to the notch; pinned reminders
/// by name beyond them; "+N" for the rest and a small spark while Claude
/// works.
struct TimerCollapsed: View {
    let model: NotchViewModel
    /// Claude's spark (off where Claude has its own piece).
    var showsClaude = true
    /// The notch is on the leading side (right ear): read outwards from it.
    var mirrored = false

    var body: some View {
        let timers = model.timers
        let h = model.geometry.height
        let shown = mirrored ? Array(timers.collapsedTimers.reversed()) : timers.collapsedTimers
        let reminders = model.reminders.collapsedReminders
        HStack(spacing: 8) {
            if !mirrored {
                Spacer(minLength: 0)
                extras(timers: timers)
                reminderItems(reminders, h: h)
            }
            ForEach(shown) { timer in
                let color = timers.color(of: timer)
                HStack(spacing: 4) {
                    if mirrored { glyph(timer, color: color, h: h) }
                    TimerTime(timer: timer, compact: true, color: Color(nsColor: color))
                    if !mirrored { glyph(timer, color: color, h: h) }
                }
                .transition(.blurReplace)
            }
            if mirrored {
                reminderItems(reminders.reversed(), h: h)
                extras(timers: timers)
                Spacer(minLength: 0)
            }
        }
        .animation(.smooth(duration: 0.25), value: timers.collapsedTimers.map(\.id))
        .animation(.smooth(duration: 0.25), value: reminders.map(\.id))
        .animation(.smooth(duration: 0.25), value: timers.hiddenCount + model.reminders.hiddenCount)
        .animation(.smooth(duration: 0.25), value: model.claude.primary?.activity.isWorking == true)
    }

    private func reminderItems(_ items: [ReminderItem], h: CGFloat) -> some View {
        ForEach(items) { item in
            ReminderCollapsedItem(item: item, unit: h, mirrored: mirrored).transition(.blurReplace)
        }
    }

    private func glyph(_ timer: TrackedTimer, color: NSColor, h: CGFloat) -> some View {
        TimerGlyph(timer: timer, color: color, size: h * 0.5, alerting: model.timers.alertingID == timer.id)
    }

    /// Claude's spark and the "+N" badge, at the far end from the notch.
    @ViewBuilder private func extras(timers: TimerModel) -> some View {
        if showsClaude, model.prefs.claudeEnabled, model.claude.primary?.activity.isWorking == true {
            ClaudeSparkView(style: .working, color: Theme.claude).frame(width: 9, height: 9)
                .transition(.blurReplace)
        }
        let hidden = timers.hiddenCount + model.reminders.hiddenCount
        if hidden > 0 {
            Text("+\(hidden)")
                .font(Theme.TextStyle.badge.font)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText(value: Double(hidden)))
                .transition(.blurReplace)
        }
    }
}

/// Claude's status as a chip in the timer strip.
struct ClaudeChip: View {
    let model: NotchViewModel
    let session: ClaudeSession
    let size: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            ClaudeGlyph(session: session, size: size * 0.7, ring: model.usageRing)
                .frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: session.projectName, font: Theme.TextStyle.label.font)
                MarqueeText(text: session.statusText, font: Theme.TextStyle.body.font, color: session.statusColor)
            }
            .frame(width: 92, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: Theme.claude).opacity(0.08)))
        .liftButton(scale: 1.02) { model.claude.focus(session) }
    }
}
