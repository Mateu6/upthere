import SwiftUI

struct ClaudeGlyph: View {
    let session: ClaudeSession?
    let size: CGFloat
    /// Optional usage ring (0…1) around the icon.
    var ring: Double? = nil

    var body: some View {
        icon
            .overlay {
                if let ring {
                    UsageRingView(value: ring, size: size + 9)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: ring != nil)
    }

    private var icon: some View {
        Group {
            switch session?.activity {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.95, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .transition(.scale.combined(with: .opacity))
            case .permission:
                ClaudeSparkView(style: .waiting, color: Theme.amber)
            case .input:
                ClaudeSparkView(style: .waiting, color: Theme.input)
            case .some(let activity) where activity.isWorking:
                ClaudeSparkView(style: .working, color: Theme.claude)
            default:
                ClaudeSparkView(style: .idle, color: Theme.claude.withAlphaComponent(0.6))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Left ear when hovered/expanded: who is working and on what.
struct ClaudeDetail: View {
    let model: NotchViewModel
    let session: ClaudeSession
    let expanded: Bool

    var body: some View {
        let count = model.claude.visibleSessions.count
        // The spark is the ear's anchor next to the notch (LeftEarContent);
        // text reads outwards from it, buttons sit at the outer end.
        HStack(spacing: 8) {
            if expanded {
                pagerButton("arrow.up.forward.app") { model.claude.focus(session) }
                    .help(session.hostSessionID != nil ? "Open this chat in Claude" : "Show terminal")
                if count > 1 {
                    pagerButton("chevron.left") { model.cycleSession(by: -1) }
                    pagerButton("chevron.right") { model.cycleSession(by: 1) }
                }
            }
            Spacer(minLength: 0)
            // The chat's title always leads, so switching chats (buttons or
            // scrolling) shows which one you're on.
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if count > 1 && !expanded {
                        Text("+\(count - 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Theme.Ink.badge))
                    }
                    MarqueeText(
                        text: session.projectName, font: .system(size: 12, weight: .semibold), alignment: .trailing,
                        hugs: true)
                    if expanded {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Theme.time(context.date.timeIntervalSince(session.turnStarted ?? session.since)))
                                .monospacedDigit()
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    MarqueeText(
                        text: statusLine, font: .system(size: 10.5, weight: .medium), color: statusColor,
                        alignment: .trailing, scrubber: model.leftStatusScrub)
                    if expanded {
                        let chips = model.usageChips(for: session)
                        if !chips.isEmpty {
                            Text("·").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            UsageChipsView(chips: chips).fixedSize()
                        }
                    }
                }
            }
            .lineLimit(1)
            .id(session.id)
            .transition(.blurReplace)
        }
        .animation(.smooth(duration: 0.25), value: session.id)
    }

    private var statusLine: String { session.statusLine }
    private var statusColor: Color { session.statusColor }

    private func pagerButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Ink.icon)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
    }
}

extension ClaudeSession {
    /// What it's doing, with the tool's target or the question asked.
    var statusLine: String {
        switch activity {
        case .tool(_, let detail?), .permission(_, let detail?): return "\(statusText) · \(detail)"
        case .input(let prompt?): return prompt
        default: return statusText
        }
    }

    var statusColor: Color {
        switch activity {
        case .permission: Color(nsColor: Theme.amber)
        case .input: Color(nsColor: Theme.input)
        default: Theme.secondary
        }
    }
}

/// Claude's piece on screens without a notch: project and status, reading
/// outwards from the spark. Hovering swaps the status for time and usage;
/// clicking opens the chat.
struct ClaudePiece: View {
    let model: NotchViewModel
    let session: ClaudeSession

    var body: some View {
        let count = model.claude.visibleSessions.count
        let hovering = model.claudePieceHovered
        Button { model.claude.focus(session) } label: {
            label(count: count, hovering: hovering)
        }
        .buttonStyle(PieceButtonStyle(hovering: hovering))
        .onHover { model.claudePieceHovered = $0 }
        .onDisappear { model.claudePieceHovered = false }
        .animation(.smooth(duration: 0.22), value: hovering)
        .help(session.hostSessionID != nil ? "Open this chat in Claude" : "Show terminal")
    }

    private func label(count: Int, hovering: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if count > 1 {
                    Text("+\(count - 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Theme.Ink.badge))
                }
                MarqueeText(
                    text: session.projectName, font: .system(size: 12, weight: .semibold), alignment: .trailing, hugs: true)
                if hovering {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Theme.time(context.date.timeIntervalSince(session.turnStarted ?? session.since)))
                            .monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                    .transition(.blurReplace)
                }
            }
            // Hovering adds time and usage but never hides the description,
            // which can be scrolled sideways.
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                MarqueeText(
                    text: session.statusLine, font: .system(size: 10.5, weight: .medium), color: session.statusColor,
                    alignment: .trailing, hugs: true, scrubber: model.leftStatusScrub)
                if hovering {
                    let chips = model.usageChips(for: session)
                    if !chips.isEmpty {
                        Group {
                            Text("·").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            UsageChipsView(chips: chips).fixedSize()
                        }
                        .transition(.blurReplace)
                    }
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .contentShape(Rectangle())
    }
}

/// Claude's piece: a faint wash under the pointer, a deeper one and a
/// slight sink while pressed. Hover comes from the model, which also
/// widens the piece.
private struct PieceButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(pressed ? Theme.Ink.hover : hovering ? Theme.Ink.faint : .clear)
                    .padding(.vertical, 3)
            }
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(pressed ? .spring(duration: 0.12, bounce: 0) : .spring(duration: 0.3, bounce: 0.2), value: pressed)
    }
}

/// A hairline between pieces sharing an ear.
struct PieceDivider: View {
    var body: some View {
        Capsule().fill(Theme.Ink.track).frame(width: 1).padding(.vertical, 9)
    }
}

/// Right ear for Claude-only: what's happening now, then time, model and
/// tokens (plus the usage figures picked in Settings).
struct ClaudeToolDetail: View {
    let session: ClaudeSession
    let expanded: Bool
    var chips: [UsageChip] = []
    var scrubber: MarqueeScrubber? = nil

    var body: some View {
        HStack(spacing: 7) {
            if case .tool(let name, _) = session.activity {
                Image(systemName: ToolInfo.symbol(name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.claude))
            }
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(
                    text: Self.primaryLine(session), font: .system(size: 11.5, weight: .medium),
                    color: lineColor, scrubber: scrubber)
                    .id(session.id)
                    .transition(.blurReplace)
                HStack(spacing: 4) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Theme.time(context.date.timeIntervalSince(session.turnStarted ?? session.since)))
                            .monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    if !chips.isEmpty {
                        Text("·").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        UsageChipsView(chips: chips).fixedSize()
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
    }

    private var lineColor: Color {
        switch session.activity {
        case .permission, .input: session.statusColor
        default: .white
        }
    }

    /// What's happening right now: the step in progress, the question
    /// asked, or (once finished) Claude's last words.
    static func primaryLine(_ session: ClaudeSession) -> String {
        switch session.activity {
        case .tool, .thinking, .compacting: return session.statusLine
        case .permission(let tool, let detail):
            return detail.map { "\(session.statusText) · \($0)" } ?? tool.map { "Allow \(ToolInfo.displayName($0))?" } ?? "Needs permission"
        case .input(let prompt): return prompt ?? "Claude is asking you something"
        case .done: return session.transcript.lastText ?? "Finished"
        case .idle: return session.transcript.lastText ?? session.statusText
        }
    }
}

/// Right ear for Claude-only, collapsed: a tiny hint of what's happening,
/// with a Dock-style count when more than one session is running.
struct ClaudeBadge: View {
    let model: NotchViewModel

    var body: some View {
        let count = model.claude.visibleSessions.count
        activity
            .frame(width: 16, height: 16)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(Capsule().fill(Color(nsColor: Theme.claude)))
                        .offset(x: 7, y: -6)
                        .transition(.blurReplace.combined(with: .scale(0.5)))
                }
            }
            .animation(.spring(duration: 0.24, bounce: 0), value: count)
    }

    /// One symbol per state, so a change animates as a symbol replace.
    private var activity: some View {
        let (symbol, color): (String, Color) =
            switch model.selectedSession?.activity {
            case .tool(let name, _): (ToolInfo.symbol(name), Theme.Ink.icon)
            case .permission: ("hand.raised.fill", Color(nsColor: Theme.amber))
            case .input: ("questionmark.bubble.fill", Color(nsColor: Theme.input))
            case .thinking: ("brain", Theme.Ink.icon)
            case .compacting: ("arrow.down.right.and.arrow.up.left", Theme.Ink.icon)
            case .done: ("text.bubble.fill", Theme.Ink.icon)
            case .idle, nil: ("moon.zzz.fill", Theme.secondary)
            }
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .animation(.smooth(duration: 0.25), value: symbol)
    }
}
