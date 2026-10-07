import Foundation
import Security
import os

private nonisolated let usageLog = Logger(subsystem: "dev.upthere.app", category: "claude-usage")

/// Plan limits (5-hour session, weekly) from Anthropic's usage endpoint,
/// the same numbers the Claude app shows, using the Claude Code login.
///
/// Read-only by design: it reads the login from the Keychain (macOS asks
/// once), only ever calls api.anthropic.com, and never refreshes or writes
/// the login, so it can't interfere with Claude Code. When the token has
/// expired it simply waits until Claude Code refreshes it.
/// The endpoint is undocumented and may change; failures are silent.
final class ClaudeUsageClient {
    struct Result: Sendable {
        var usage: PlanUsage
        var plan: String?
    }

    enum UsageError: Error { case noLogin, expired, http(Int), format }

    private var token: (value: String, expiry: Date, plan: String?)?

    func fetch() async throws -> Result {
        let login = try currentLogin()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(login.value)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 { token = nil }
            throw UsageError.http(status)
        }
        guard let usage = Self.parse(data) else { throw UsageError.format }
        return Result(usage: usage, plan: login.plan)
    }

    /// `{"five_hour":{"utilization":15.0,"resets_at":"…"},"seven_day":{…}}`
    nonisolated static func parse(_ data: Data, now: Date = .now) -> PlanUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> LimitWindow? {
            guard let dict = json[key] as? [String: Any],
                let used = (dict["utilization"] as? NSNumber)?.doubleValue,
                let stamp = dict["resets_at"] as? String,
                let date = parseDate(stamp)
            else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: date)
        }
        let usage = PlanUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), updated: now)
        return usage.fiveHour == nil && usage.sevenDay == nil ? nil : usage
    }

    nonisolated private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func currentLogin() throws -> (value: String, expiry: Date, plan: String?) {
        if let token, token.expiry > .now.addingTimeInterval(60) { return token }
        guard let data = Self.readKeychain() else { throw UsageError.noLogin }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let access = oauth["accessToken"] as? String
        else { throw UsageError.format }
        let expiry = ((oauth["expiresAt"] as? NSNumber)?.doubleValue).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? .now.addingTimeInterval(300)
        guard expiry > .now else { throw UsageError.expired }
        let login = (access, expiry, (oauth["subscriptionType"] as? String)?.capitalized)
        token = login
        return login
    }

    private static func readKeychain() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess { usageLog.notice("Claude login not readable (status \(status))") }
        return result as? Data
    }
}
