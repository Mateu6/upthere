import AppKit

/// Answering Claude from the notch: the draft answer and the row's width.
extension NotchViewModel {
    /// The answer row may grow past the usual max ear width: the choices
    /// must all be there to be picked.
    static let answerLimit: CGFloat = 560

    /// Where you are in the shown request: which question, what's picked,
    /// whether the rarer choices are folded out.
    struct AnswerDraft: Equatable {
        var requestID: UUID?
        var step = 0
        var picked: [String: [String]] = [:]
        var more = false
    }



    func draft(for request: ClaudeRequest) -> AnswerDraft {
        answerDraft.requestID == request.id ? answerDraft : AnswerDraft(requestID: request.id)
    }

    func updateDraft(for request: ClaudeRequest, _ change: (inout AnswerDraft) -> Void) {
        var draft = draft(for: request)
        change(&draft)
        if answerDraft != draft { answerDraft = draft }
    }

    /// The shown chat's open request, or what you just answered in it.
    var shownRequest: ClaudeRequest? { selectedSession.flatMap { claude.requests[$0.id] } }
    var shownEcho: AnswerEcho? { selectedSession.flatMap { claude.echoes[$0.id] } }
    var answerShown: Bool { prefs.claudeEnabled && (shownRequest != nil || shownEcho != nil) }
    /// Two lines need a notch-height ear; shorter menu bars get one line.
    var answerIsCompact: Bool { unit < 30 }

    /// The answer row hugs its two lines: the question, and the choices.
    var answerRowWidth: CGFloat? {
        guard answerShown, let session = selectedSession else { return nil }
        let line1: CGFloat
        let line2: CGFloat
        if let request = shownRequest {
            let draft = draft(for: request)
            line1 = TextWidth.of(ClaudeAnswerRow.title(request, session: session, step: draft.step), Theme.TextStyle.title)
            line2 = Self.choicesWidth(request, draft: draft)
        } else {
            line1 = TextWidth.of(session.projectName, Theme.TextStyle.title)
            line2 = TextWidth.of(shownEcho?.text ?? "", Theme.TextStyle.label) + 18
        }
        // + the spark beside the notch, the edges and the text's fade.
        let content =
            answerIsCompact
            ? min(line1 * 10.5 / 12, AnswerMetrics.compactTitleCap) + 8 + line2 : max(min(line1, 320), line2)
        return min(unit + 4 + 8 + 10 + content, Self.answerLimit).rounded(.up)
    }

    static func choicesWidth(_ request: ClaudeRequest, draft: AnswerDraft) -> CGFloat {
        let icon = AnswerMetrics.iconChip
        let chips: [CGFloat]
        switch request.kind {
        case .questions(let list):
            let question = list[min(draft.step, list.count - 1)]
            chips = [icon] + question.options.map { AnswerMetrics.width($0.label) }
                + (question.multiSelect ? [AnswerMetrics.width("Done")] : [])
        case .plan:
            chips = [icon, AnswerMetrics.width("Keep planning"), AnswerMetrics.width("Approve")]
        case .permission(_, _, let rule):
            chips =
                draft.more
                ? [icon, AnswerMetrics.width("Deny and stop")] + (rule.map { [AnswerMetrics.width("Always allow \($0)")] } ?? [])
                : [icon, icon, AnswerMetrics.width("Deny"), AnswerMetrics.width("Allow")]
        }
        return chips.reduce(0, +) + CGFloat(max(0, chips.count - 1)) * AnswerMetrics.spacing
    }
}
