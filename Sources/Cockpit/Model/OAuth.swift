import Foundation
import Network
import CryptoKit
import AppKit

enum OAuthProvider: String, Codable, CaseIterable {
    case google
    case microsoft

    var label: String { self == .google ? "Google (Gmail)" : "Microsoft (Outlook)" }
    var imapHost: String { self == .google ? "imap.gmail.com" : "outlook.office365.com" }

    var authEndpoint: String {
        self == .google
            ? "https://accounts.google.com/o/oauth2/v2/auth"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    }
    var tokenEndpoint: String {
        self == .google
            ? "https://oauth2.googleapis.com/token"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    }
    var scope: String {
        self == .google
            ? "https://mail.google.com/"
            : "https://outlook.office365.com/IMAP.AccessAsUser.All offline_access"
    }
    /// Google fournit un « secret » aux apps bureau (non confidentiel mais
    /// exigé) ; Microsoft en « client public » n'en veut pas.
    var needsClientSecret: Bool { self == .google }
}

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date

    var isFresh: Bool { expiry.timeIntervalSinceNow > 120 }
}

enum OAuthError: LocalizedError {
    case cancelled
    case server(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:      return "Connexion annulée"
        case .server(let m):  return "OAuth : \(m)"
        }
    }
}

/// Flux OAuth 2.0 « application installée » : PKCE + redirection sur une
/// boucle locale (127.0.0.1), le navigateur système fait le consentement.
enum OAuthFlow {

    static func authorize(provider: OAuthProvider, clientID: String, clientSecret: String) async throws -> OAuthTokens {
        let verifier = randomURLString(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLString(16)

        let listener = LoopbackListener()
        defer { listener.stop() }
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: provider.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: provider.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(comps.url!)

        let params = try await listener.waitForCallback()
        guard params["state"] == state else { throw OAuthError.server("état invalide") }
        if let err = params["error"] { throw OAuthError.server(params["error_description"] ?? err) }
        guard let code = params["code"] else { throw OAuthError.cancelled }

        return try await exchange(provider: provider, clientID: clientID, clientSecret: clientSecret,
                                  body: [
                                    "grant_type": "authorization_code",
                                    "code": code,
                                    "redirect_uri": redirect,
                                    "code_verifier": verifier,
                                  ])
    }

    static func refresh(provider: OAuthProvider, clientID: String, clientSecret: String,
                        refreshToken: String) async throws -> OAuthTokens {
        try await exchange(provider: provider, clientID: clientID, clientSecret: clientSecret,
                           body: [
                            "grant_type": "refresh_token",
                            "refresh_token": refreshToken,
                           ], fallbackRefresh: refreshToken)
    }

    // MARK: Échange de jetons

    private static func exchange(provider: OAuthProvider, clientID: String, clientSecret: String,
                                body: [String: String], fallbackRefresh: String? = nil) async throws -> OAuthTokens {
        var form = body
        form["client_id"] = clientID
        if provider.needsClientSecret, !clientSecret.isEmpty { form["client_secret"] = clientSecret }

        var req = URLRequest(url: URL(string: provider.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        struct R: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let error: String?
            let error_description: String?
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        if let e = r.error { throw OAuthError.server(r.error_description ?? e) }
        guard let access = r.access_token else {
            throw OAuthError.server("réponse invalide (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return OAuthTokens(
            accessToken: access,
            refreshToken: r.refresh_token ?? fallbackRefresh ?? "",
            expiry: Date().addingTimeInterval(r.expires_in ?? 3300))
    }

    // MARK: Utilitaires

    private static func randomURLString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

/// Petit serveur HTTP à usage unique sur 127.0.0.1 pour récupérer le code.
private final class LoopbackListener {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?

    func start() async throws -> Int {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        return try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = l.port?.rawValue { cont.resume(returning: Int(port)) }
                case .failed(let e):
                    cont.resume(throwing: OAuthError.server(e.localizedDescription))
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: .global())
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in self.continuation = cont }
    }

    func stop() {
        listener?.cancel(); listener = nil
        continuation?.resume(throwing: OAuthError.cancelled)
        continuation = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8),
                  let line = text.split(separator: "\r\n").first,
                  let pathPart = line.split(separator: " ").dropFirst().first else {
                conn.cancel(); return
            }
            var params: [String: String] = [:]
            if let q = pathPart.split(separator: "?").dropFirst().first {
                for pair in q.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        params[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    }
                }
            }
            let html = "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'>"
                + "<h2>C'est bon.</h2><p>Vous pouvez fermer cet onglet et revenir à Cockpit.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })

            DispatchQueue.main.async {
                self.continuation?.resume(returning: params)
                self.continuation = nil
            }
        }
    }
}
