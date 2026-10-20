import AppKit
import SwiftUI

/// The small field under the notch for starting timers (and seeing the
/// running ones). Opened with the global shortcut or the notch's + button.
final class TimerInputController {
    private let panel: NotchFieldPanel
    private let timers: TimerModel

    init(timers: TimerModel, geometry: @escaping () -> NotchGeometry?) {
        self.timers = timers
        panel = NotchFieldPanel(geometry: geometry)
    }

    var isOpen: Bool { panel.isOpen }

    func toggle() { isOpen ? close() : show() }

    func show() {
        panel.show(TimerInputView(timers: timers, close: { [weak self] in self?.close() }))
    }

    func close() { panel.close() }
}

struct TimerInputView: View {
    let timers: TimerModel
    let close: () -> Void

    @State private var text = ""
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    private var parsed: TimerParser.Parsed { TimerParser.parse(text) }

    private var suggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespaces)
        return timers.recentLabels
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .filter { $0.caseInsensitiveCompare(query) != .orderedSame }
            .prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: parsed.duration == nil ? "stopwatch" : "timer")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                TextField("Track something…  e.g. “waiting for CI 15m”", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(start)
            }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(preview)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, label in
                        Button {
                            text = label
                        } label: {
                            Label(label, systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle(highlighted: highlighted == index, tint: .primary))
                    }
                }
            }
            if !timers.timers.isEmpty {
                Divider()
                runningList
            }
        }
        .padding(16)
        .frame(width: 420)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { focused = true }
        .onExitCommand(perform: close)
        .onKeyPress(.downArrow) {
            highlighted = min((highlighted ?? -1) + 1, suggestions.count - 1)
            if let highlighted, suggestions.indices.contains(highlighted) { text = suggestions[highlighted] }
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max((highlighted ?? 1) - 1, 0)
            if let highlighted, suggestions.indices.contains(highlighted) { text = suggestions[highlighted] }
            return .handled
        }
    }

    private var preview: String {
        guard timers.timers.count < TimerModel.maxTimers else { return "\(TimerModel.maxTimers) timers running. Stop one to add another." }
        if let duration = parsed.duration {
            return "Countdown \(TimerParser.clock(duration)) · \(parsed.label)  ↵"
        }
        return "Count-up · \(parsed.label)  ↵"
    }

    private var runningList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(timers.timers.enumerated()), id: \.element.id) { index, timer in
                HStack(spacing: 8) {
                    Capsule().fill(Color(nsColor: timers.color(of: timer))).frame(width: 4, height: 16)
                    Text(timer.label).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timeText(timer, at: context.date))
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(timer.isPaused ? Color.secondary : Color(nsColor: timers.color(of: timer)))
                    }
                    Button {
                        timers.togglePin(timer.id)
                    } label: {
                        Image(systemName: timer.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(PanelIconButtonStyle())
                    .help(timer.isPinned ? "Unpin" : "Keep visible in the notch")
                    Button {
                        timers.togglePause(timer.id)
                    } label: {
                        Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(PanelIconButtonStyle())
                    Button {
                        timers.stop(timer.id)
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(PanelIconButtonStyle())
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .help("Stop and log (⌘\(index + 1))")
                }
            }
            if timers.timers.count > 1 {
                Button("Stop all and log") { timers.stopAll() }
                    .buttonStyle(PanelIconButtonStyle())
                    .font(.system(size: 11.5))
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }

    private func timeText(_ timer: TrackedTimer, at date: Date) -> String {
        if let remaining = timer.remaining(at: date) {
            return remaining >= 0 ? TimerParser.clock(remaining) : "+" + TimerParser.clock(-remaining)
        }
        return TimerParser.clock(timer.elapsed(at: date))
    }

    private func start() {
        guard !parsed.label.isEmpty, timers.start(text) != nil else { return }
        close()
    }
}
