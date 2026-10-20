import SwiftUI

/// Claude waiting on you, answered in place: the question (or the exact
/// command) on top, the choices beneath it. Reads outwards from the spark,
/// so the main choice sits nearest the notch. After a click, a short echo
/// of what was sent replaces the choices.
struct ClaudeAnswerRow: View {
    let model: NotchViewModel
    let session: ClaudeSession
    let request: ClaudeRequest?
    let echo: AnswerEcho?
    /// One line (menu bars too short for two, on screens without a notch):
    /// the question rolls beside the choices.
    var compact = false

    /// Which question (one at a time), what's picked, and whether "⋯" has
    /// folded out the rarer choices. Kept by the model, which sizes the ear.
    private var draft: NotchViewModel.AnswerDraft {
        request.map(model.draft(for:)) ?? NotchViewModel.AnswerDraft()
    }
    private var step: Int { draft.step }
    private var more: Bool { draft.more }

    private func update(_ change: (inout NotchViewModel.AnswerDraft) -> Void) {
        guard let request else { return }
        withAnimation(Theme.contentSwap) { model.updateDraft(for: request, change) }
    }

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .trailing, spacing: 1))
        layout {
            MarqueeText(
                text: title, font: (compact ? Theme.TextStyle.label : Theme.TextStyle.title).font, color: tone,
                alignment: .trailing, hugs: true)
                .frame(maxWidth: compact ? AnswerMetrics.compactTitleCap : .infinity, alignment: .trailing)
            ZStack(alignment: .trailing) {
                if let echo {
                    Label(echo.text, systemImage: echo.symbol)
                        .font(Theme.TextStyle.label.font)
                        .foregroundStyle(Theme.Ink.icon)
                        .labelStyle(.titleAndIcon)
                        .transition(.blurReplace)
                } else if let request {
                    choices(request)
                        .id("\(request.id)-\(step)-\(more)")
                        .transition(.blurReplace)
                }
            }
            .frame(height: AnswerMetrics.chipHeight)
            .animation(Theme.contentSwap, value: echo)
            .animation(Theme.contentSwap, value: more)
            .animation(Theme.contentSwap, value: step)
        }
        .lineLimit(1)
    }

    // MARK: Text

    private var questions: [ClaudeQuestion] {
        if case .questions(let list) = request?.kind { return list }
        return []
    }

    private var title: String {
        guard let request else { return session.projectName }
        return Self.title(request, session: session, step: step)
    }

    static func title(_ request: ClaudeRequest, session: ClaudeSession, step: Int) -> String {
        // The project leads, so a request swapping in can't be mistaken for the last one.
        let lead = session.projectName
        switch request.kind {
        case .questions(let list):
            let question = list[min(step, list.count - 1)]
            let counter = list.count > 1 ? "\(min(step, list.count - 1) + 1)/\(list.count) " : ""
            return "\(lead) · \(counter)\(question.question)"
        case .plan(let summary):
            return "\(lead) · Plan ready" + (summary.map { ": \($0)" } ?? "")
        case .permission(let tool, let target, _):
            return "\(lead) · \(ToolInfo.displayName(tool))" + (target.map { " · \($0)" } ?? "")
        }
    }

    private var tone: Color {
        guard echo == nil, let request else { return .white }
        if case .permission = request.kind { return Color(nsColor: Theme.amber) }
        return Color(nsColor: Theme.input)
    }

    // MARK: Choices

    @ViewBuilder private func choices(_ request: ClaudeRequest) -> some View {
        HStack(spacing: AnswerMetrics.spacing) {
            switch request.kind {
            case .questions(let list):
                let question = list[min(step, list.count - 1)]
                terminalButton(request)
                ForEach(question.options, id: \.label) { option in
                    optionChip(option, question: question, request: request, list: list)
                }
                if question.multiSelect {
                    AnswerChip(title: "Done", prominent: true, tint: Theme.input) {
                        advance(request, list: list)
                    }
                    .disabled((draft.picked[question.question] ?? []).isEmpty)
                }
            case .plan:
                terminalButton(request)
                AnswerChip(title: "Keep planning") { model.claude.answer(request.id, with: .keepPlanning) }
                AnswerChip(title: "Approve", prominent: true, tint: Theme.input) {
                    model.claude.answer(request.id, with: .approvePlan)
                }
            case .permission(_, _, let rule):
                if more {
                    AnswerChip(symbol: "chevron.left", help: "Back") { update { $0.more = false } }
                    AnswerChip(title: "Deny and stop") { model.claude.answer(request.id, with: .denyAndStop) }
                    if let rule {
                        AnswerChip(title: "Always allow \(rule)", tint: Theme.amber) {
                            model.claude.answer(request.id, with: .allowAlways)
                        }
                        .help("Adds this rule, so Claude won't ask again")
                    }
                } else {
                    AnswerChip(symbol: "ellipsis", help: "More choices") { update { $0.more = true } }
                    terminalButton(request)
                    AnswerChip(title: "Deny") { model.claude.answer(request.id, with: .deny) }
                    AnswerChip(title: "Allow", prominent: true, tint: Theme.amber) {
                        model.claude.answer(request.id, with: .allow)
                    }
                }
            }
        }
        .modifier(WakeUp(id: request.id))
    }

    /// Hands the question to the terminal (or the Claude app) and goes there.
    private func terminalButton(_ request: ClaudeRequest) -> some View {
        AnswerChip(symbol: "arrow.up.forward.app", help: "Answer in \(session.hostSessionID != nil ? "Claude" : "the terminal")") {
            model.claude.handOver(request.id)
            model.claude.focus(session)
        }
    }

    private func optionChip(
        _ option: ClaudeQuestion.Option, question: ClaudeQuestion, request: ClaudeRequest, list: [ClaudeQuestion]
    ) -> some View {
        let selected = draft.picked[question.question]?.contains(option.label) == true
        return AnswerChip(title: option.label, selected: selected) {
            if question.multiSelect {
                update { draft in
                    var labels = draft.picked[question.question] ?? []
                    if let index = labels.firstIndex(of: option.label) { labels.remove(at: index) } else { labels.append(option.label) }
                    draft.picked[question.question] = labels
                }
            } else {
                update { $0.picked[question.question] = [option.label] }
                advance(request, list: list)
            }
        }
        .help(option.description ?? option.label)
    }

    /// Next question, or send them all after the last one.
    private func advance(_ request: ClaudeRequest, list: [ClaudeQuestion]) {
        guard request.isAwake else { return }
        if step + 1 < list.count {
            update { $0.step += 1 }
        } else {
            model.claude.answer(request.id, with: .options(model.draft(for: request).picked))
        }
    }
}

enum AnswerMetrics {
    static let chipHeight: CGFloat = 16
    static let spacing: CGFloat = 4
    static let chipPadding: CGFloat = 7
    static let iconChip: CGFloat = 20
    static let labelCap: CGFloat = 150
    static let compactTitleCap: CGFloat = 200

    /// One chip as drawn, for the ear to hug its row.
    static func width(_ title: String) -> CGFloat {
        min(TextWidth.of(title, Theme.TextStyle.label), labelCap) + chipPadding * 2
    }
}

/// A choice in the answer row. Prominent: filled in the wait's tone with
/// dark text. Plain: text with a faint wash under the pointer, the less
/// prominent option. Selected (multi-select): a steady wash.
struct AnswerChip: View {
    var title: String? = nil
    var symbol: String? = nil
    var help: String? = nil
    var prominent = false
    var selected = false
    var tint: NSColor? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: AnswerMetrics.iconChip)
                } else if let title {
                    Text(title)
                        .font(Theme.TextStyle.label.font)
                        .truncationMode(.middle)
                        .frame(maxWidth: AnswerMetrics.labelCap)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, AnswerMetrics.chipPadding)
                }
            }
            .frame(height: AnswerMetrics.chipHeight)
            .foregroundStyle(prominent ? Color.black : tint.map { Color(nsColor: $0) } ?? Theme.Ink.icon)
            .contentShape(Capsule())
        }
        .buttonStyle(AnswerChipStyle(prominent: prominent, selected: selected, tint: tint))
        .help(help ?? title ?? "")
        .accessibilityLabel(help ?? title ?? "")
    }
}

private struct AnswerChipStyle: ButtonStyle {
    let prominent: Bool
    let selected: Bool
    let tint: NSColor?

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, prominent: prominent, selected: selected, tint: tint)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let selected: Bool
        let tint: NSColor?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .background {
                    Capsule().fill(fill(pressed: pressed))
                }
                .overlay {
                    if selected { Capsule().strokeBorder(Theme.Ink.icon.opacity(0.6), lineWidth: 1) }
                }
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(pressed ? 0.95 : 1)
                .brightness(prominent ? (pressed ? -0.08 : hovering ? 0.06 : 0) : 0)
                .onHover { hovering = $0 }
                .animation(pressed ? .spring(duration: 0.12, bounce: 0) : .spring(duration: 0.3, bounce: 0.2), value: pressed)
                .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
                .animation(.spring(duration: 0.24, bounce: 0), value: selected)
        }

        private func fill(pressed: Bool) -> Color {
            if prominent { return Color(nsColor: tint ?? Theme.claude) }
            let base = tint.map { Color(nsColor: $0) } ?? .white
            let opacity = pressed ? Theme.Ink.pressedOpacity : hovering || selected ? Theme.Ink.hoverOpacity : 0
            return base.opacity(opacity)
        }
    }
}

/// Choices take clicks only once they've been on screen for a moment.
private struct WakeUp: ViewModifier {
    let id: UUID
    @State private var awake = false

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(awake)
            .task(id: id) {
                awake = false
                try? await Task.sleep(for: .seconds(ClaudeRequest.wakeDelay))
                awake = true
            }
    }
}
