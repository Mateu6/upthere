import AppKit
import SwiftUI

/// A panel that can take keyboard focus without activating Upthere, so
/// typing a timer doesn't pull you out of the app you're in.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The small field under the notch for starting timers (and seeing the
/// running ones). Opened with the global shortcut or the notch's + button.
final class TimerInputController: NSObject, NSWindowDelegate {
    private let panel: KeyPanel
    private let timers: TimerModel
    private let geometry: () -> NotchGeometry?

    init(timers: TimerModel, geometry: @escaping () -> NotchGeometry?) {
        self.timers = timers
        self.geometry = geometry
        panel = KeyPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
    }

    var isOpen: Bool { panel.isVisible }

    func toggle() { isOpen ? close() : show() }

    func show() {
        let host = NSHostingController(rootView: TimerInputView(timers: timers, close: { [weak self] in self?.close() }))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        position()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    /// Centered under the notch, top-anchored as its height changes.
    private func position() {
        guard let g = geometry() else { return }
        let size = panel.contentViewController?.preferredContentSize ?? NSSize(width: 400, height: 80)
        let origin = NSPoint(
            x: g.notchRect.midX - size.width / 2,
            y: g.screenFrame.maxY - g.height - 10 - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        // Keep the top edge just under the notch.
        guard let g = geometry() else { return }
        var frame = panel.frame
        let top = g.screenFrame.maxY - g.height - 10
        if abs(frame.maxY - top) > 0.5 {
            frame.origin.y = top - frame.height
            panel.setFrameOrigin(frame.origin)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
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

/// Small icon buttons in the timer field: a soft rounded highlight fades in
/// under the pointer.
private struct PanelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .buttonStyle(.plain)
            .modifier(RowHover(pressed: configuration.isPressed))
    }

    private struct RowHover: ViewModifier {
        let pressed: Bool
        @State private var hovering = false

        func body(content: Content) -> some View {
            content
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.primary.opacity(pressed ? 0.16 : hovering ? 0.1 : 0))
                }
                .scaleEffect(pressed ? 0.94 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.spring(duration: 0.2, bounce: 0), value: pressed)
                .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
        }
    }
}
