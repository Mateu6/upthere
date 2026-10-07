import SwiftUI

/// One figure in the agent ear, e.g. "5h 23%" or "ctx 85k".
struct UsageChip: Identifiable, Equatable {
    let id: String
    let text: String
    /// 0…1 when the figure is a fraction of a limit; drives the warning color.
    var level: Double?
}

enum UsageInfo {
    static let defaultContextSize = 200_000

    /// The chips the user picked, for one session, skipping figures that
    /// aren't available (e.g. plan limits without the status-line bridge).
    static func chips(
        for session: ClaudeSession?, plan: PlanUsage?, weeklyTokens: Int?, prefs: Preferences, now: Date = .now
    ) -> [UsageChip] {
        var chips: [UsageChip] = []
        let plan = plan?.current(at: now)

        if prefs.infoSession {
            switch prefs.infoSessionFormat {
            case .percent:
                if let window = plan?.fiveHour {
                    chips.append(limitChip("session", label: "session", window: window, prefs: prefs, now: now))
                }
            case .amount:
                if let tokens = session?.transcript.sessionTokens, tokens > 0 {
                    chips.append(UsageChip(id: "session", text: "\(TokenFormat.short(tokens)) tok"))
                }
            }
        }
        if prefs.infoWeek {
            switch prefs.infoWeekFormat {
            case .percent:
                if let window = plan?.sevenDay {
                    chips.append(limitChip("week", label: "week", window: window, prefs: prefs, now: now))
                }
            case .amount:
                if let weeklyTokens {
                    chips.append(UsageChip(id: "week", text: "wk \(TokenFormat.short(weeklyTokens))"))
                }
            }
        }
        if prefs.infoContext, let session {
            let tokens = session.status?.contextTokens ?? session.transcript.contextTokens
            switch prefs.infoContextFormat {
            case .percent:
                if let percent = contextFraction(session, prefs: prefs) {
                    chips.append(UsageChip(id: "context", text: "ctx \(Int((percent * 100).rounded()))%", level: percent))
                }
            case .amount:
                if let tokens { chips.append(UsageChip(id: "context", text: "ctx \(TokenFormat.short(tokens))")) }
            }
        }
        if prefs.infoAutoCompact, let session, let tokens = session.status?.contextTokens ?? session.transcript.contextTokens {
            let left = max(0, autoCompactThreshold(contextSize(session, prefs: prefs)) - tokens)
            let fraction = Double(tokens) / Double(max(1, autoCompactThreshold(contextSize(session, prefs: prefs))))
            chips.append(UsageChip(id: "compact", text: "\(TokenFormat.short(left)) to compact", level: fraction))
        }
        if prefs.infoCost, let cost = session?.status?.costUSD {
            chips.append(UsageChip(id: "cost", text: cost < 10 ? String(format: "$%.2f", cost) : String(format: "$%.0f", cost)))
        }
        if prefs.infoModel, let model = session?.status?.modelName ?? session?.transcript.model.map(shortModel) {
            chips.append(UsageChip(id: "model", text: model))
        }
        return chips
    }

    /// Fraction for the ring around Claude's icon.
    static func ringValue(for session: ClaudeSession?, plan: PlanUsage?, prefs: Preferences, now: Date = .now) -> Double? {
        let plan = plan?.current(at: now)
        switch prefs.usageRing {
        case .none: return nil
        case .session: return plan?.fiveHour.map { $0.usedPercent / 100 }
        case .week: return plan?.sevenDay.map { $0.usedPercent / 100 }
        case .context: return session.flatMap { contextFraction($0, prefs: prefs) }
        }
    }

    static func contextFraction(_ session: ClaudeSession, prefs: Preferences) -> Double? {
        if let percent = session.status?.contextPercent { return percent / 100 }
        guard let tokens = session.transcript.contextTokens else { return nil }
        return Double(tokens) / Double(contextSize(session, prefs: prefs))
    }

    /// The session's context window: from the status line, the setting, or
    /// inferred (more than 200k in use means a 1M window).
    static func contextSize(_ session: ClaudeSession, prefs: Preferences) -> Int {
        if let size = session.status?.contextSize { return size }
        if let size = prefs.contextWindow.tokens { return size }
        return (session.transcript.contextTokens ?? 0) > defaultContextSize ? 1_000_000 : defaultContextSize
    }

    /// Claude Code compacts about 34k tokens before the window is full
    /// (e.g. 965.6k of 1M, 166k of 200k).
    static func autoCompactThreshold(_ size: Int) -> Int { size - 34_400 }

    private static func limitChip(_ id: String, label: String, window: LimitWindow, prefs: Preferences, now: Date) -> UsageChip {
        var text = "\(label) \(Int(window.usedPercent.rounded()))%"
        if prefs.infoResetTimes { text += " ↻" + remaining(until: window.resetsAt, now: now) }
        return UsageChip(id: id, text: text, level: window.usedPercent / 100)
    }

    /// Like the Claude app: "45m", "4h 50m", then the weekday ("Mon").
    static func remaining(until date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 24 * 3600 {
            let minutes = Int(seconds / 60)
            return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
        }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    static func shortModel(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    static func color(for level: Double?) -> Color {
        guard let level else { return Theme.secondary }
        if level >= 0.9 { return Color(nsColor: NSColor(srgbRed: 1, green: 0.42, blue: 0.38, alpha: 1)) }
        if level >= 0.75 { return Color(nsColor: Theme.amber) }
        return Theme.secondary
    }
}

/// A row of usage figures separated by dots.
struct UsageChipsView: View {
    let chips: [UsageChip]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                if index > 0 { Text("·").foregroundStyle(Theme.secondary) }
                Text(chip.text)
                    .foregroundStyle(UsageInfo.color(for: chip.level))
                    .fixedSize()
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .animation(.smooth(duration: 0.25), value: chips)
    }
}

/// A thin progress ring drawn around Claude's icon.
struct UsageRingView: View {
    let value: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: min(1, max(0.02, value)))
                .stroke(UsageInfo.color(for: value).opacity(value < 0.75 ? 0 : 1), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .overlay {
                    Circle()
                        .trim(from: 0, to: min(1, max(0.02, value)))
                        .stroke(Color(nsColor: Theme.claude).opacity(value < 0.75 ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.4), value: value)
    }
}

/// The agent ear with no active session: just your plan usage.
struct UsageSummary: View {
    let model: NotchViewModel

    var body: some View {
        let chips = model.usageChips(for: nil)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(model.claude.planName.map { "Claude \($0)" } ?? "Claude")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                UsageChipsView(chips: chips)
            }
            .lineLimit(1)
        }
    }
}
