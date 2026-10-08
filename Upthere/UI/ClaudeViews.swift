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
                    .foregroundStyle(.green)
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
                            .background(Capsule().fill(.white.opacity(0.7)))
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
                        alignment: .trailing)
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
                .foregroundStyle(.white.opacity(0.8))
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
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if count > 1 {
                    Text("+\(count - 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(.white.opacity(0.7)))
                }
                MarqueeText(
                    text: session.projectName, font: .system(size: 12, weight: .semibold), alignment: .trailing, hugs: true)
            }
            ZStack(alignment: .trailing) {
                if hovering {
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Theme.time(context.date.timeIntervalSince(session.turnStarted ?? session.since)))
                                .monospacedDigit()
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        let chips = model.usageChips(for: session)
                        if !chips.isEmpty {
                            Text("·").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            UsageChipsView(chips: chips)
                        }
                    }
                    .transition(.blurReplace)
                } else {
                    MarqueeText(
                        text: session.statusLine, font: .system(size: 10.5, weight: .medium), color: session.statusColor,
                        alignment: .trailing
                    )
                    .transition(.blurReplace)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(hovering ? 0.07 : 0))
                .padding(.vertical, 3)
        }
        .onHover { model.claudePieceHovered = $0 }
        .onDisappear { model.claudePieceHovered = false }
        .animation(.smooth(duration: 0.22), value: hovering)
        .onTapGesture { model.claude.focus(session) }
        .help(session.hostSessionID != nil ? "Open this chat in Claude" : "Show terminal")
    }
}

/// A hairline between pieces sharing an ear.
struct PieceDivider: View {
    var body: some View {
        Capsule().fill(.white.opacity(0.14)).frame(width: 1).padding(.vertical, 9)
    }
}

/// Right ear for Claude-only: the current tool and how long it's been going.
struct ClaudeToolDetail: View {
    let session: ClaudeSession
    let expanded: Bool
    var chips: [UsageChip] = []

    var body: some View {
        HStack(spacing: 7) {
            if case .tool(let name, _) = session.activity {
                Image(systemName: ToolInfo.symbol(name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.claude))
            }
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: primaryLine, font: .system(size: 11.5, weight: .medium))
                HStack(spacing: 4) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Theme.time(context.date.timeIntervalSince(session.turnStarted ?? session.since)))
                            .monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    if !chips.isEmpty {
                        Text("·").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        UsageChipsView(chips: chips)
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
    }

    private var primaryLine: String {
        switch session.activity {
        case .tool(_, let detail?): return detail
        case .permission(let tool, let detail): return detail ?? tool.map { "Allow \(ToolInfo.displayName($0))?" } ?? "Needs permission"
        case .input(let prompt): return prompt ?? "Claude is asking you something"
        case .done: return session.transcript.lastText ?? "Finished"
        default: return session.transcript.lastText ?? session.statusText
        }
    }
}

/// Right ear for Claude-only, collapsed: a tiny hint of what's happening.
struct ClaudeBadge: View {
    let model: NotchViewModel

    var body: some View {
        let count = model.claude.visibleSessions.count
        Group {
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            } else if case .tool(let name, _) = model.selectedSession?.activity {
                Image(systemName: ToolInfo.symbol(name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            } else if case .permission = model.selectedSession?.activity {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.amber))
            } else if case .input = model.selectedSession?.activity {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.input))
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
