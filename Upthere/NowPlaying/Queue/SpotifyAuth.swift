import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Spotify sign-in with Authorization Code + PKCE (no client secret).
///
/// The browser redirects to a loopback address that only this Mac can reach;
/// a one-shot listener there picks up the code. The refresh token lives in
/// the Keychain; access tokens only in memory.
final class SpotifyAuth {
    static let port: UInt16 = 47863
    static let redirectURI = "http://127.0.0.1:\(port)/callback"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing"

    enum AuthError: LocalizedError {
        case missingClientID, cancelled, denied(String), badResponse(Int, String)
        var errorDescription: String? {
            switch self {
            case .missingClientID: "Enter your Spotify app's Client ID first."
            case .cancelled: "Sign-in was cancelled or timed out."
            case .denied(let reason): "Spotify denied access (\(reason))."
            case .badResponse(let code, let body): "Spotify returned \(code): \(body.prefix(160))"
            }
        }
    }

    var clientID: String
    private var accessToken: String?
    private var expiry = Date.distantPast
    /// Read from the Keychain at most once per run (each read of an ad-hoc
    /// signed app's item can make macOS ask for the password).
    private var refreshToken: String?
    private var refreshTokenLoaded = false

    init(clientID: String) {
        self.clientID = clientID
    }

    /// A plain flag, so checking it (e.g. in Settings) never touches the Keychain.
    var isConnected: Bool { UserDefaults.standard.bool(forKey: "spotifyConnected") }

    /// Settles the flag for logins made before it existed.
    func migrateConnectionFlag() {
        guard UserDefaults.standard.object(forKey: "spotifyConnected") == nil else { return }
        UserDefaults.standard.set(storedRefreshToken() != nil, forKey: "spotifyConnected")
    }

    func disconnect() {
        Keychain.delete("spotify-refresh-token")
        UserDefaults.standard.set(false, forKey: "spotifyConnected")
        accessToken = nil
        refreshToken = nil
        refreshTokenLoaded = true
    }

    private func storedRefreshToken() -> String? {
        if !refreshTokenLoaded {
            refreshToken = Keychain.get("spotify-refresh-token")
            refreshTokenLoaded = true
        }
        return refreshToken
    }

    private func storeRefreshToken(_ token: String?) {
        refreshToken = token
        refreshTokenLoaded = true
        if let token { Keychain.set(token, for: "spotify-refresh-token") } else { Keychain.delete("spotify-refresh-token") }
        UserDefaults.standard.set(token != nil, forKey: "spotifyConnected")
    }

    func connect() async throws {
        guard !clientID.isEmpty else { throw AuthError.missingClientID }
        let verifier = PKCE.verifier()
        let state = PKCE.verifier(length: 24)
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state),
        ]
        let receiver = LoopbackReceiver(port: Self.port)
        async let callback = receiver.waitForCallback(timeout: 180)
        NSWorkspace.shared.open(url.url!)
        let query = try await callback

        guard query["state"] == state else { throw AuthError.cancelled }
        if let error = query["error"] { throw AuthError.denied(error) }
        guard let code = query["code"] else { throw AuthError.cancelled }
        try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
            "client_id": clientID, "code_verifier": verifier,
        ])
    }

    /// A valid access token, refreshed when needed.
    func token() async throws -> String {
        if let accessToken, expiry > .now.addingTimeInterval(30) { return accessToken }
        guard let refresh = storedRefreshToken() else { throw AuthError.cancelled }
        try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        guard let accessToken else { throw AuthError.cancelled }
        return accessToken
    }

    func invalidateAccessToken() { accessToken = nil }

    private func tokenRequest(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = PKCE.formEncode(form).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String
        else {
            if status == 400 || status == 401 { storeRefreshToken(nil) }
            throw AuthError.badResponse(status, String(decoding: data, as: UTF8.self))
        }
        accessToken = access
        expiry = .now.addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        if let refresh = json["refresh_token"] as? String, refresh != refreshToken { storeRefreshToken(refresh) }
    }
}

nonisolated enum PKCE {
    private static let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func verifier(length: Int = 64) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.sorted().joined(separator: "&")
    }
}

/// One-shot HTTP listener on 127.0.0.1 for the OAuth redirect.
nonisolated final class LoopbackReceiver: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "dev.upthere.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?

    init(port: UInt16) { self.port = port }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: self.port)!)
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters)
                    listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                    listener.start(queue: self.queue)
                    self.listener = listener
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(SpotifyAuth.AuthError.cancelled)) }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            guard let query = Self.parseCallback(request) else {
                connection.send(content: Self.response(404, "Not found"), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let ok = query["error"] == nil
            let body = ok
                ? "<h2 style='font-family:-apple-system'>Upthere is connected to Spotify. You can close this tab.</h2>"
                : "<h2 style='font-family:-apple-system'>Spotify sign-in failed: \(query["error"] ?? "")</h2>"
            connection.send(content: Self.response(200, body), completion: .contentProcessed { _ in connection.cancel() })
            self.finish(.success(query))
        }
    }

    /// `GET /callback?code=…&state=… HTTP/1.1` → query items.
    static func parseCallback(_ request: String) -> [String: String]? {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: String(parts[1])),
            url.path == "/callback"
        else { return nil }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return query
    }

    private static func response(_ status: Int, _ html: String) -> Data {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private func finish(_ result: Result<[String: String], Error>) {
        listener?.cancel()
        listener = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Generic-password Keychain items for this app.
nonisolated enum Keychain {
    private static let service = "dev.upthere.app"

    static func set(_ value: String, for account: String) {
        delete(account)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}
