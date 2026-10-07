import AppKit
import Observation

/// One running (or paused) timer. All times are derived from timestamps,
/// so nothing ticks while it runs.
nonisolated struct TrackedTimer: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var label: String
    var colorIndex: Int
    /// nil = count-up (work log); otherwise the countdown length.
    var countdown: TimeInterval?
    var startedAt: Date
    var pausedTotal: TimeInterval = 0
    var pausedAt: Date?
    /// The countdown's "time's up" has fired.
    var alerted = false

    var isPaused: Bool { pausedAt != nil }
    var isCountdown: Bool { countdown != nil }

    func elapsed(at now: Date = .now) -> TimeInterval {
        max(0, (pausedAt ?? now).timeIntervalSince(startedAt) - pausedTotal)
    }

    /// Negative once the countdown is over (overtime).
    func remaining(at now: Date = .now) -> TimeInterval? {
        countdown.map { $0 - elapsed(at: now) }
    }

    /// When a running countdown reaches zero.
    var endDate: Date? {
        guard let countdown, pausedAt == nil else { return nil }
        return startedAt.addingTimeInterval(pausedTotal + countdown)
    }

    func progress(at now: Date = .now) -> Double {
        guard let countdown, countdown > 0 else { return 0 }
        return min(1, elapsed(at: now) / countdown)
    }
}

/// A finished timer, ready to log.
nonisolated struct TimerEntry: Equatable, Sendable {
    var label: String
    var start: Date
    var end: Date
    var countdown: TimeInterval?
    var activeTime: TimeInterval
}

/// Several timers at once: count-ups for "what I'm doing", countdowns for
/// "what I'm waiting for". Persisted, so they survive a relaunch. A single
/// task wakes for the next countdown end; nothing polls.
@Observable
final class TimerModel {
    static let maxTimers = 6
    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.78, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.3, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.9, blue: 0.5, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.45, blue: 0.75, alpha: 1),
        NSColor(srgbRed: 0.75, green: 0.6, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.85, blue: 0.35, alpha: 1),
    ]

    private(set) var timers: [TrackedTimer] = []
    private(set) var recentLabels: [String] = []
    /// A countdown that just ended (the notch shows "Time's up").
    private(set) var alertingID: UUID?

    @ObservationIgnored var onFinish: ((TimerEntry) -> Void)?
    @ObservationIgnored var onAlert: ((TrackedTimer) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var alarmTask: Task<Void, Never>?
    @ObservationIgnored private var alertClearTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "timers"),
            let saved = try? JSONDecoder().decode([TrackedTimer].self, from: data)
        {
            timers = saved
        }
        recentLabels = defaults.stringArray(forKey: "timerRecentLabels") ?? []
        armAlarm()
    }

    var isEmpty: Bool { timers.isEmpty }

    /// The timer the collapsed notch shows: a countdown that's over, then
    /// the countdown closest to its end, then the newest running count-up.
    var urgent: TrackedTimer? {
        let now = Date.now
        let countdowns = timers.filter { $0.isCountdown && !$0.isPaused }
            .sorted { ($0.remaining(at: now) ?? 0) < ($1.remaining(at: now) ?? 0) }
        if let first = countdowns.first { return first }
        if let running = timers.filter({ !$0.isPaused }).max(by: { $0.startedAt < $1.startedAt }) { return running }
        return timers.last
    }

    func color(of timer: TrackedTimer) -> NSColor { Self.palette[timer.colorIndex % Self.palette.count] }

    // MARK: Actions

    @discardableResult
    func start(_ input: String, now: Date = .now) -> TrackedTimer? {
        let parsed = TimerParser.parse(input)
        guard !parsed.label.isEmpty else { return nil }
        return start(label: parsed.label, countdown: parsed.duration, now: now)
    }

    @discardableResult
    func start(label: String, countdown: TimeInterval?, now: Date = .now) -> TrackedTimer? {
        guard timers.count < Self.maxTimers else { return nil }
        let used = Set(timers.map(\.colorIndex))
        let color = (0..<Self.palette.count).first { !used.contains($0) } ?? timers.count
        let timer = TrackedTimer(label: label, colorIndex: color, countdown: countdown, startedAt: now)
        timers.append(timer)
        recentLabels.removeAll { $0.caseInsensitiveCompare(label) == .orderedSame }
        recentLabels.insert(label, at: 0)
        recentLabels = Array(recentLabels.prefix(12))
        changed()
        return timer
    }

    func pause(_ id: UUID, now: Date = .now) {
        update(id) { if $0.pausedAt == nil { $0.pausedAt = now } }
    }

    func resume(_ id: UUID, now: Date = .now) {
        update(id) { timer in
            guard let pausedAt = timer.pausedAt else { return }
            timer.pausedTotal += now.timeIntervalSince(pausedAt)
            timer.pausedAt = nil
        }
    }

    func togglePause(_ id: UUID) {
        guard let timer = timers.first(where: { $0.id == id }) else { return }
        timer.isPaused ? resume(id) : pause(id)
    }

    /// Adds time to a countdown (e.g. +5 min); an alerted one starts over.
    func extend(_ id: UUID, by seconds: TimeInterval = 300, now: Date = .now) {
        update(id) { timer in
            guard let countdown = timer.countdown else { return }
            // If it's in overtime, extend from now rather than from zero.
            let overtime = max(0, -(timer.remaining(at: now) ?? 0))
            timer.countdown = countdown + overtime + seconds
            timer.alerted = false
        }
        if alertingID == id { alertingID = nil }
    }

    func stop(_ id: UUID, now: Date = .now) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        let timer = timers.remove(at: index)
        if alertingID == id { alertingID = nil }
        changed()
        let end = timer.pausedAt ?? now
        onFinish?(
            TimerEntry(
                label: timer.label, start: timer.startedAt, end: end, countdown: timer.countdown,
                activeTime: timer.elapsed(at: now)))
    }

    func stopAll(now: Date = .now) {
        for timer in timers { stop(timer.id, now: now) }
    }

    func dismissAlert() {
        alertingID = nil
    }

    // MARK: Internals

    private func update(_ id: UUID, _ change: (inout TrackedTimer) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        change(&timers[index])
        changed()
    }

    private func changed() {
        if let data = try? JSONEncoder().encode(timers) { defaults.set(data, forKey: "timers") }
        defaults.set(recentLabels, forKey: "timerRecentLabels")
        armAlarm()
    }

    /// One task for the next countdown to end, re-armed on every change.
    private func armAlarm() {
        alarmTask?.cancel()
        let pending = timers.filter { !$0.alerted }.compactMap { timer in timer.endDate.map { (timer.id, $0) } }
        guard let (id, date) = pending.min(by: { $0.1 < $1.1 }) else { return }
        alarmTask = Task { [weak self] in
            let wait = date.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.fire(id)
        }
    }

    private func fire(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].alerted = true
        alertingID = id
        onAlert?(timers[index])
        changed()
        // The alert pulses for a while, then settles into overtime.
        alertClearTask?.cancel()
        alertClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, self?.alertingID == id else { return }
            self?.alertingID = nil
        }
    }
}
