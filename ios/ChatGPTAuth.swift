import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
import UIKit
import OrderCore

// "Sign in with ChatGPT" (official OpenAI OAuth for personal/local apps).
// Docs: https://developers.openai.com/siwc/token-sharing-open-source
// The access token is used as a bearer token on POST /v1/responses so requests
// count against the user's ChatGPT plan instead of API credits. No secrets are
// hard-coded: the client id is issued by OpenAI during the first sign-in.

enum Keychain {
    private static let service = "local.ordnungsplaner.chatgpt"

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        remove(account)
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

struct ChatGPTCredentials: Codable {
    /// Issued by OpenAI at first sign-in; kept after sign-out so reconnecting reuses it.
    var clientID: String
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date?
    var scope: String?
    var email: String?
}

/// Tiny HTTP server on 127.0.0.1 that receives the OAuth redirect
/// (OpenAI requires a loopback redirect URI; only the port may vary).
final class LoopbackReceiver {
    private var listener: NWListener?
    var onCallback: (([String: String]) -> Void)?
    private let path = "/auth/callback"

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: OrderError.invalid("Lokaler Anmeldeempfänger hat keinen Port bekommen.")) }
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first else { connection.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
                  components.path == self.path else {
                Self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            var params: [String: String] = [:]
            for item in components.queryItems ?? [] { params[item.name] = item.value ?? "" }
            let page = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head>"
                + "<body style='font-family:-apple-system;text-align:center;padding:48px 24px'>"
                + "<h2>Verbunden</h2><p>Du kannst dieses Fenster schließen und zum Ordnungsplaner zurückkehren.</p></body></html>"
            Self.respond(connection, status: "200 OK", body: page) { self.onCallback?(params) }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String, then: (() -> Void)? = nil) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in
            connection.cancel()
            then?()
        })
    }
}

@MainActor
final class ChatGPTAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = ChatGPTAuth()

    @Published private(set) var isConnected = false
    @Published private(set) var email: String?
    @Published private(set) var busy = false

    private static let authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let revokeURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    private static let resource = "https://api.openai.com/v1"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let planScope = "chatgpt.tokens.use.direct"
    private static let credentialsAccount = "credentials"
    private static let hostAccount = "host-id"

    private var credentials: ChatGPTCredentials?
    private var session: ASWebAuthenticationSession?
    private var browserContinuation: CheckedContinuation<[String: String], Error>?
    private var refreshTask: Task<Void, Error>?

    override init() {
        super.init()
        if let data = Keychain.read(Self.credentialsAccount),
           let stored = try? JSONDecoder().decode(ChatGPTCredentials.self, from: data) {
            credentials = stored
        }
        publish()
    }

    private func publish() {
        isConnected = credentials?.refreshToken != nil || credentials?.accessToken != nil
        email = credentials?.email
    }

    private func store(_ value: ChatGPTCredentials?) throws {
        credentials = value
        if let value {
            guard let data = try? JSONEncoder().encode(value), Keychain.write(data, account: Self.credentialsAccount) else {
                throw OrderError.invalid("Die Anmeldung konnte nicht sicher auf dem iPhone gespeichert werden.")
            }
        } else {
            Keychain.remove(Self.credentialsAccount)
        }
        publish()
    }

    /// Stable, opaque id for this install (required by OpenAI, not a secret).
    private var hostID: String {
        if let data = Keychain.read(Self.hostAccount), let text = String(data: data, encoding: .utf8) { return text }
        let created = "ordnungsplaner-" + Self.randomURLSafe(24)
        Keychain.write(Data(created.utf8), account: Self.hostAccount)
        return created
    }

    // MARK: Sign in

    func signIn() async throws {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        let verifier = Self.randomURLSafe(48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(24)
        let nonce = Self.randomURLSafe(24)
        let receiver = LoopbackReceiver()
        let port: UInt16
        do { port = try await receiver.start() }
        catch { throw OrderError.invalid("Der lokale Anmeldeempfänger konnte nicht starten. Bitte noch einmal versuchen.") }
        let redirect = "http://127.0.0.1:\(port)/auth/callback"

        var items: [URLQueryItem] = [
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: Self.scopes),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "ext_agent_host_id", value: hostID)
        ]
        if let known = credentials?.clientID, !known.isEmpty {
            items.append(.init(name: "client_id", value: known))
            if let id = credentials?.idToken { items.append(.init(name: "id_token_hint", value: id)) }
            if let mail = credentials?.email { items.append(.init(name: "login_hint", value: mail)) }
        } else {
            items.append(.init(name: "client_id", value: "dynamic_agent_client"))
            items.append(.init(name: "agent_name_hint", value: "Ordnungsplaner"))
        }
        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = items
        guard let url = components.url else { throw OrderError.invalid("Die Anmelde-Adresse konnte nicht gebildet werden.") }

        let params: [String: String]
        do { params = try await runBrowser(url: url, receiver: receiver) }
        catch { receiver.stop(); throw error }

        if let error = params["error"] {
            throw OrderError.invalid(error == "access_denied"
                ? "Die Verbindung wurde in ChatGPT abgelehnt."
                : "ChatGPT hat die Anmeldung abgelehnt (\(error)).")
        }
        guard params["state"] == state, let code = params["code"] else {
            throw OrderError.invalid("Die Antwort von ChatGPT passte nicht zur Anmeldung. Bitte noch einmal versuchen.")
        }
        let clientID = (credentials?.clientID.isEmpty == false ? credentials?.clientID : nil) ?? params["client_id"]
        guard let clientID, !clientID.isEmpty else {
            throw OrderError.invalid("OpenAI hat keine Anwendungs-Kennung vergeben. Die Registrierung ist für diese App vermutlich nicht freigeschaltet.")
        }

        let (status, json) = try await post(Self.tokenURL, form: [
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
            ("code_verifier", verifier), ("redirect_uri", redirect), ("resource", Self.resource)
        ])
        guard status == 200, let access = json["access_token"] as? String else {
            throw OrderError.invalid("ChatGPT hat die Verbindung nicht bestätigt (\(Self.errorCode(json) ?? "\(status)")). Bitte noch einmal versuchen.")
        }
        let scope = json["scope"] as? String ?? ""
        guard scope.split(separator: " ").contains(Substring(Self.planScope)) else {
            throw OrderError.invalid("Du hast die Nutzung deines ChatGPT-Tarifs nicht freigegeben. Verbinde noch einmal und bestätige die Tarif-Nutzung (ChatGPT Plus oder Pro nötig).")
        }
        let idToken = json["id_token"] as? String
        let claims = idToken.flatMap(Self.claims)
        if let claimed = claims?["nonce"] as? String, claimed != nonce {
            throw OrderError.invalid("Die Anmeldung konnte nicht überprüft werden. Bitte noch einmal versuchen.")
        }
        try store(ChatGPTCredentials(clientID: clientID, accessToken: access, refreshToken: json["refresh_token"] as? String,
                                     idToken: idToken, expiresAt: Self.expiry(json), scope: scope,
                                     email: (claims?["email"] as? String) ?? credentials?.email))
    }

    private func runBrowser(url: URL, receiver: LoopbackReceiver) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            browserContinuation = continuation
            receiver.onCallback = { [weak self] params in
                Task { @MainActor in self?.finishBrowser(.success(params), receiver: receiver) }
            }
            // The loopback page never matches a custom scheme; the session is closed
            // by us once the code arrives, or by the user via "Abbrechen".
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor in
                    self?.finishBrowser(.failure(OrderError.invalid("Die Anmeldung wurde abgebrochen.")), receiver: receiver)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                finishBrowser(.failure(OrderError.invalid("Das Anmeldefenster konnte nicht geöffnet werden.")), receiver: receiver)
            }
        }
    }

    private func finishBrowser(_ result: Result<[String: String], Error>, receiver: LoopbackReceiver) {
        guard let continuation = browserContinuation else { return }
        browserContinuation = nil
        receiver.stop()
        session?.cancel()
        session = nil
        continuation.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first ?? ASPresentationAnchor()
        }
    }

    // MARK: Tokens

    /// A valid access token, refreshed shortly before it expires.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = credentials, current.accessToken != nil || current.refreshToken != nil else {
            throw OrderError.invalid("Du bist noch nicht mit ChatGPT verbunden. Das geht unter Einstellungen → KI.")
        }
        if !forceRefresh, let token = current.accessToken, let expires = current.expiresAt, expires.timeIntervalSinceNow > 120 {
            return token
        }
        try await refresh()
        guard let token = credentials?.accessToken else {
            throw OrderError.invalid("Deine ChatGPT-Anmeldung ist abgelaufen. Bitte unter Einstellungen → KI erneut verbinden.")
        }
        return token
    }

    private func refresh() async throws {
        if let running = refreshTask { return try await running.value }
        let task = Task { @MainActor in try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        guard let current = credentials, let refresh = current.refreshToken else {
            try? store(ChatGPTCredentials(clientID: credentials?.clientID ?? "", email: credentials?.email))
            throw OrderError.invalid("Deine ChatGPT-Anmeldung ist abgelaufen. Bitte unter Einstellungen → KI erneut verbinden.")
        }
        let status: Int
        let json: [String: Any]
        do {
            (status, json) = try await post(Self.tokenURL, form: [
                ("grant_type", "refresh_token"), ("client_id", current.clientID),
                ("refresh_token", refresh), ("resource", Self.resource)
            ])
        } catch {
            throw OrderError.invalid("Keine Verbindung zu ChatGPT. Bitte Internet prüfen und noch einmal versuchen. Deine Anmeldung bleibt erhalten.")
        }
        if status == 200, let access = json["access_token"] as? String {
            var updated = current
            updated.accessToken = access
            updated.refreshToken = (json["refresh_token"] as? String) ?? refresh
            updated.expiresAt = Self.expiry(json)
            if let scope = json["scope"] as? String { updated.scope = scope }
            if let id = json["id_token"] as? String { updated.idToken = id }
            try store(updated)
            return
        }
        if status >= 500 || status == 429 {
            throw OrderError.invalid("ChatGPT ist gerade nicht erreichbar. Bitte in ein paar Minuten noch einmal versuchen. Deine Anmeldung bleibt erhalten.")
        }
        // Terminal refresh errors: drop the tokens but remember the client for a quick reconnect.
        try? store(ChatGPTCredentials(clientID: current.clientID, email: current.email))
        throw OrderError.invalid("Deine ChatGPT-Anmeldung ist abgelaufen oder wurde in ChatGPT widerrufen. Bitte unter Einstellungen → KI erneut verbinden.")
    }

    /// Revokes at OpenAI and clears local tokens. Returns false if revocation
    /// could not be confirmed (the user can then also disconnect in ChatGPT settings).
    @discardableResult
    func signOut() async -> Bool {
        guard let current = credentials else { return true }
        var confirmed = true
        if let token = current.refreshToken {
            confirmed = false
            if let result = try? await post(Self.revokeURL, form: [
                ("token", token), ("token_type_hint", "refresh_token"), ("client_id", current.clientID)
            ]), result.0 == 200 { confirmed = true }
        }
        try? store(ChatGPTCredentials(clientID: current.clientID, email: current.email))
        return confirmed
    }

    // MARK: Helpers

    private func post(_ url: URL, form pairs: [(String, String)]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    private static func errorCode(_ json: [String: Any]) -> String? {
        (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["code"] as? String)
    }

    private static func expiry(_ json: [String: Any]) -> Date {
        Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int) ?? 3600))
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        if status != errSecSuccess { data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }) }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
