import Foundation

/// Which Claude chat the ears show, and its usage figures.
extension NotchViewModel {
    /// The session shown in the agent ear. A chat picked by hand stays
    /// until another one starts needing you: that one always comes first.
    var selectedSession: ClaudeSession? {
        if let id = selectedSessionID, let session = claude.visibleSessions.first(where: { $0.id == id }) {
            if !session.activity.needsUser,
                let newer = claude.waiting.first(where: { $0.since > selectedAt })
            {
                return newer
            }
            return session
        }
        return claude.primary
    }

    /// Another chat waiting for you while a different one is on screen.
    var waitingElsewhere: ClaudeSession? {
        let shown = selectedSession?.id
        return claude.waiting.first { $0.id != shown }
    }

    func select(_ session: ClaudeSession) {
        selectedAt = .now
        selectedSessionID = session.id
    }

    /// The "+N" badge: jump to the chat that has waited longest.
    func showWaiting() {
        guard let session = waitingElsewhere else { return }
        select(session)
        if mode(.left) == .collapsed { setMode(.left, .peek) }
    }

    func usageChips(for session: ClaudeSession?) -> [UsageChip] {
        UsageInfo.chips(for: session, plan: claude.planUsage, weeklyTokens: claude.weeklyTokens, prefs: prefs)
    }

    /// The right ear when Claude has it: the model and the session's tokens
    /// always lead, then the usage figures picked in Settings.
    func claudeEarChips(for session: ClaudeSession) -> [UsageChip] {
        var chips = usageChips(for: session)
        var lead: [UsageChip] = []
        if !chips.contains(where: { $0.id == "model" }),
            let model = session.status?.modelName ?? session.transcript.model.map(UsageInfo.shortModel)
        {
            lead.append(UsageChip(id: "model", text: model))
        }
        let tokens = session.transcript.sessionTokens
        if tokens > 0, !chips.contains(where: { $0.text.hasSuffix(" tok") }) {
            lead.append(UsageChip(id: "tokens", text: "\(TokenFormat.short(tokens)) tok"))
        }
        chips.insert(contentsOf: lead, at: 0)
        return chips
    }

    var usageRing: Double? {
        UsageInfo.ringValue(for: selectedSession, plan: claude.planUsage, prefs: prefs)
    }

    func cycleSession(by offset: Int) {
        let sessions = claude.visibleSessions
        guard sessions.count > 1 else { return }
        let current = sessions.firstIndex { $0.id == selectedSession?.id } ?? 0
        select(sessions[(current + offset + sessions.count) % sessions.count])
    }
}
