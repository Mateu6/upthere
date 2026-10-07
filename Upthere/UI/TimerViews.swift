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

    var body: some View {
        ZStack {
            if timer.isCountdown {
                TimerRingView(timer: timer, color: color)
                if timer.isPaused {
                    Image(systemName: "pause.fill").font(.system(size: size * 0.32, weight: .bold))
                        .foregroundStyle(Color(nsColor: color))
                }
            } else {
                Image(systemName: timer.isPaused ? "pause.circle" : "stopwatch")
                    .font(.system(size: size * 0.78, weight: .medium))
                    .foregroundStyle(Color(nsColor: color))
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(alerting ? 1.12 : 1)
        .animation(alerting ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .smooth(duration: 0.3), value: alerting)
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
        track.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
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
    var font: Font = .system(size: 11.5, weight: .semibold)

    var body: some View {
        // Compact text changes at most every 15 s until the last minute.
        let fine = !compact || (timer.remaining().map { abs($0) < 70 } ?? (timer.elapsed() < 70))
        TimelineView(.periodic(from: .now, by: fine ? 1 : 15)) { context in
            Text(text(at: context.date))
                .font(font.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(timer.isPaused ? Theme.secondary : .white)
                .contentTransition(.numericText())
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

/// Hovered timer ear: a sideways strip with a chip per timer, Claude's
/// status when it's live, and + to add another.
struct TimerStrip: View {
    let model: NotchViewModel

    var body: some View {
        let timers = model.timers
        let h = model.geometry.height
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let session = model.claude.primary, model.prefs.claudeEnabled {
                        ClaudeChip(model: model, session: session, size: h - 16)
                    }
                    ForEach(timers.timers) { timer in
                        TimerChip(model: model, timer: timer, size: h - 14).id(timer.id)
                    }
                    if timers.timers.count < TimerModel.maxTimers {
                        Button(action: model.openTimerInput) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverButtonStyle())
                        .help("New timer")
                    }
                }
                .padding(.horizontal, 6)
            }
            .onAppear { if let id = timers.alertingID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: timers.alertingID) { _, id in
                if let id { withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

struct TimerChip: View {
    let model: NotchViewModel
    let timer: TrackedTimer
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        let timers = model.timers
        let alerting = timers.alertingID == timer.id
        let color = timers.color(of: timer)
        HStack(spacing: 6) {
            TimerGlyph(timer: timer, color: color, size: size, alerting: alerting)
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(
                    text: alerting ? "Time's up · \(timer.label)" : timer.label,
                    font: .system(size: 10.5, weight: .semibold),
                    color: alerting ? Color(nsColor: color) : .white)
                TimerTime(timer: timer, font: .system(size: 10, weight: .medium))
            }
            .frame(width: 92, alignment: .leading)
            if hovering {
                HStack(spacing: 0) {
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
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: color).opacity(alerting ? 0.25 : hovering ? 0.12 : 0.06)))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
    }

    private func chipButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
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
                MarqueeText(text: session.projectName, font: .system(size: 10.5, weight: .semibold))
                MarqueeText(text: session.statusText, font: .system(size: 10, weight: .medium), color: Theme.secondary)
            }
            .frame(width: 92, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: Theme.claude).opacity(0.08)))
        .onTapGesture { model.claude.focus(session) }
    }
}
