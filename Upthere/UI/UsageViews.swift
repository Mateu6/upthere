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
                    chips.append(limitChip("session", label: "5h", window: window, prefs: prefs, now: now))
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
                    chips.append(limitChip("week", label: "wk", window: window, prefs: prefs, now: now))
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
                if let percent = contextFraction(session) {
                    chips.append(UsageChip(id: "context", text: "ctx \(Int((percent * 100).rounded()))%", level: percent))
                }
            case .amount:
                if let tokens { chips.append(UsageChip(id: "context", text: "ctx \(TokenFormat.short(tokens))")) }
            }
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
        case .context: return session.flatMap(contextFraction)
        }
    }

    static func contextFraction(_ session: ClaudeSession) -> Double? {
        if let percent = session.status?.contextPercent { return percent / 100 }
        guard let tokens = session.transcript.contextTokens else { return nil }
        return Double(tokens) / Double(session.status?.contextSize ?? defaultContextSize)
    }

    private static func limitChip(_ id: String, label: String, window: LimitWindow, prefs: Preferences, now: Date) -> UsageChip {
        var text = "\(label) \(Int(window.usedPercent.rounded()))%"
        if prefs.infoResetTimes { text += " ↻" + remaining(until: window.resetsAt, now: now) }
        return UsageChip(id: id, text: text, level: window.usedPercent / 100)
    }

    /// "45m", "3h", "2d".
    static func remaining(until date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 48 * 3600 { return "\(Int((seconds / 3600).rounded()))h" }
        return "\(Int((seconds / 86400).rounded()))d"
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
