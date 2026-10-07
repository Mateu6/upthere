import SwiftUI

struct ClaudeGlyph: View {
    let session: ClaudeSession?
    let size: CGFloat

    var body: some View {
        Group {
            switch session?.activity {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.95, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .waiting:
                ClaudeSparkView(style: .waiting, color: Theme.amber)
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
                    .help("Show terminal")
                if count > 1 {
                    pagerButton("chevron.left") { model.cycleSession(by: -1) }
                    pagerButton("chevron.right") { model.cycleSession(by: 1) }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 4) {
                    if count > 1 && !expanded {
                        Text("+\(count - 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.white.opacity(0.7)))
                    }
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                HStack(spacing: 4) {
                    if expanded {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Theme.time(context.date.timeIntervalSince(session.turnStarted ?? session.since)) + " ·")
                                .monospacedDigit()
                        }
                    }
                    Text(statusLine)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(statusColor)
            }
            .lineLimit(1)
        }
    }

    private var statusLine: String {
        if case .tool(_, let detail?) = session.activity { return "\(session.statusText) · \(detail)" }
        return session.statusText
    }

    private var statusColor: Color {
        if case .waiting = session.activity { return Color(nsColor: Theme.amber) }
        return Theme.secondary
    }

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

/// Right ear for Claude-only: the current tool and how long it's been going.
struct ClaudeToolDetail: View {
    let session: ClaudeSession
    let expanded: Bool

    var body: some View {
        HStack(spacing: 7) {
            if case .tool(let name, _) = session.activity {
                Image(systemName: ToolInfo.symbol(name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.claude))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(primaryLine)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Theme.time(context.date.timeIntervalSince(session.turnStarted ?? session.since)))
                            .monospacedDigit()
                    }
                    if expanded, let meta = metaLine {
                        Text("·")
                        Text(meta)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
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
        case .waiting(let message): return message ?? "Waiting for you"
        case .done: return session.transcript.lastText ?? "Finished"
        default: return session.transcript.lastText ?? session.statusText
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let model = session.transcript.model {
            parts.append(model.replacingOccurrences(of: "claude-", with: ""))
        }
        if let tokens = session.transcript.contextTokens {
            parts.append(tokens >= 1000 ? "\(tokens / 1000)k ctx" : "\(tokens) ctx")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            } else if case .waiting = model.selectedSession?.activity {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.amber))
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
