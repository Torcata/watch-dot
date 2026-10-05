import Foundation
import Combine
import CryptoKit
import Security

// Public native-client identifier.
// This is not a secret, a user's token, or permission to access their Dot.
enum OpenAIOAuthClient {
    static let codex = "app_EMoamEEZ73f0CkXaXp7hrann"
}

public enum SignInError: Error, Sendable {
    case configuration, storage, random, invalidResponse, identity, denied, expired, exchangeUncertain
    case clientUnavailable, browser, unavailable, tls
    case refreshRejected, refreshUnavailable

    public var message: String {
        switch self {
        case .refreshRejected: "OpenAI ya no permite renovar esta sesión. Inicia sesión de nuevo."
        case .refreshUnavailable: "No se pudo renovar la sesión. Comprueba la conexión y vuelve a intentar."
        case .configuration: "No se pudo preparar la conexión segura. Abre Watch Dot en tu iPhone y vuelve a intentar."
        case .storage: "No se pudo acceder a Keychain. Desbloquea el dispositivo y vuelve a intentar."
        case .random: "No se pudo preparar una autorización segura."
        case .invalidResponse: "La respuesta de autorización no es válida. Inicia otro intento."
        case .identity: "No se pudo verificar la identidad de OpenAI. No se guardó la sesión."
        case .denied: "Autorización rechazada. Puedes iniciar otro intento."
        case .expired: "La autorización expiró. Inicia sesión de nuevo."
        case .exchangeUncertain: "Se interrumpió la validación. Inicia una autorización nueva."
        case .clientUnavailable: "OpenAI rechazó el cliente de esta autorización (invalid_client). No se inició sesión."
        case .browser: "No se pudo abrir el navegador. Abre Watch Dot en tu iPhone y vuelve a intentar."
        case .unavailable: "No se pudo contactar con el servicio. Comprueba la conexión y vuelve a intentar."
        case .tls: "No se pudo verificar el certificado del servicio. Comprueba la conexión y vuelve a intentar."
        }
    }
}

public struct SignedInAccount: Codable, Sendable {
    public let subject: String
    public let clientID: String
    public let email: String?
    public let expiresAt: Date
    // Protected by the vault; never part of a chat snapshot or a published UI value.
    let idToken: String
    let accessToken: String?
    let refreshToken: String?
    let authorizationNonce: String?

    init(subject: String, clientID: String, email: String?, expiresAt: Date,
         idToken: String, accessToken: String?, refreshToken: String? = nil,
         authorizationNonce: String? = nil) {
        self.subject = subject; self.clientID = clientID; self.email = email
        self.expiresAt = expiresAt; self.idToken = idToken; self.accessToken = accessToken
        self.refreshToken = refreshToken; self.authorizationNonce = authorizationNonce
    }
}

public struct SignInRecord: Codable, Sendable {
    public var hostID: String = "urn:uuid:\(UUID().uuidString.lowercased())"
    public var account: SignedInAccount?
    public var phoneRequest: PhoneAuthorizationRequest?
    public var acceptedPhoneTransfer: PhoneReceipt?
    public init() {}
}

@MainActor
public protocol SignInStore {
    func load() throws -> SignInRecord?
    func save(_ record: SignInRecord) throws
}

@MainActor
public final class KeychainSignInStore: SignInStore {
    private let service = "cl.australapps.watchdot.authentication"
    public init() {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "connection-v1"]
    }
    public func load() throws -> SignInRecord? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SignInError.storage }
        do { return try JSONDecoder().decode(SignInRecord.self, from: data) }
        catch { throw SignInError.storage }
    }
    public func save(_ record: SignInRecord) throws {
        let data = try JSONEncoder().encode(record)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SignInError.storage }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SignInError.storage }
    }
}

public protocol SignInHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
    func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse
}

public enum SignInContentType: String, Codable, Sendable {
    case json, html, text, other, unknown
    init(_ raw: String?) {
        guard let raw else { self = .unknown; return }
        let mime = (raw.split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if mime == "application/json" || mime.hasSuffix("+json") { self = .json }
        else if mime == "text/html" || mime == "application/xhtml+xml" { self = .html }
        else if mime.hasPrefix("text/") { self = .text }
        else { self = .other }
    }
}

public struct SignInHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let contentType: SignInContentType
    public let clientChallenge: Bool
    public init(data: Data, status: Int, contentType: SignInContentType = .unknown, clientChallenge: Bool = false) {
        self.data = data
        self.status = status
        self.contentType = contentType
        self.clientChallenge = clientChallenge
    }
}

extension SignInHTTP {
    public func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse {
        let (data, status) = try await send(request)
        return SignInHTTPResponse(data: data, status: status)
    }

}

private final class NoAuthRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward authorization codes or credentials to a redirect.
    }
}

public struct SecureSignInHTTP: SignInHTTP {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoAuthRedirects(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await sendWithMetadata(request)
        return (response.data, response.status)
    }
    public func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse {
        guard request.url?.scheme == "https" else { throw SignInError.configuration }
        return try await perform(request)
    }
    private func perform(_ request: URLRequest) async throws -> SignInHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, data.count <= 256_000 else {
                throw SignInError.invalidResponse
            }
            return SignInHTTPResponse(data: data, status: http.statusCode,
                contentType: SignInContentType(http.value(forHTTPHeaderField: "Content-Type")),
                clientChallenge: http.value(forHTTPHeaderField: "cf-mitigated") == "challenge")
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            if [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .secureConnectionFailed].contains(error.code) {
                throw SignInError.tls
            }
            throw SignInError.unavailable
        }
    }
}

struct OAuthCallback: Codable, Sendable {
    let code: String
    let state: String
    let clientID: String
    let redirectURI: String
}
struct OAuthAuthorization: Sendable {
    let state: String
    let nonce: String
    let verifier: String
    let clientID: String
    let expectedSubject: String?
    var deadline: Date
    var authorizationURL: String?
    var redirectURI: String?
    var usesCodexLogin: Bool { clientID == OpenAIOAuthClient.codex }

    init(account: SignedInAccount?, now: Date, nonce: String? = nil) throws {
        state = try Self.random()
        self.nonce = try nonce ?? Self.random()
        verifier = try Self.random()
        clientID = account?.clientID ?? OpenAIOAuthClient.codex
        expectedSubject = account?.subject
        deadline = now.addingTimeInterval(600)
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SignInError.random
        }
        return Data(bytes).base64URL
    }
    mutating func prepare(redirect: String, hostID: String) throws {
        guard let uri = URLComponents(string: redirect), uri.scheme == "http", uri.host == "127.0.0.1",
              let port = uri.port, (1...65535).contains(port), uri.path == "/auth/callback",
              uri.query == nil, uri.fragment == nil, uri.user == nil, uri.password == nil
        else { throw SignInError.invalidResponse }
        // Registered loopback callback ports.
        guard !usesCodexLogin || [1455, 1457].contains(port) else { throw SignInError.configuration }
        redirectURI = redirect
        var values = [
            "client_id": clientID, "response_type": "code",
            "redirect_uri": redirect, "scope": "openid profile email",
            "state": state, "nonce": nonce, "code_challenge_method": "S256",
            "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        ]
        if usesCodexLogin {
            values["scope"] = "openid profile email offline_access"
            values["id_token_add_organizations"] = "true"
            values["codex_cli_simplified_flow"] = "true"
            values["originator"] = "watch-dot"
        } else {
            values["ext_agent_host_id"] = hostID
            values["resource"] = "https://api.openai.com/v1"
            if clientID == "dynamic_agent_client" { values["agent_name_hint"] = "Watch Dot" }
        }
        let path = usesCodexLogin ? "/oauth/authorize" : "/api/accounts/authorize"
        var url = URLComponents(string: "https://auth.openai.com\(path)")!
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        authorizationURL = url.url?.absoluteString
    }
}

struct SignInService: Sendable {
    let http: any SignInHTTP
    func exchange(_ callback: OAuthCallback, authorization attempt: OAuthAuthorization, now: Date) async throws -> SignedInAccount {
        guard attempt.deadline > now else { throw SignInError.expired }
        guard callback.state == attempt.state, callback.redirectURI == attempt.redirectURI,
              attempt.usesCodexLogin ? callback.clientID == OpenAIOAuthClient.codex :
                callback.clientID.range(of: "^oaiapp_[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil,
              attempt.clientID == "dynamic_agent_client" || callback.clientID == attempt.clientID,
              !callback.code.isEmpty, callback.code.utf8.count <= 4096 else { throw SignInError.invalidResponse }
        let path = attempt.usesCodexLogin ? "/oauth/token" : "/api/accounts/oauth/token"
        var request = URLRequest(url: URL(string: "https://auth.openai.com\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["grant_type": "authorization_code", "client_id": callback.clientID,
                      "code": callback.code, "code_verifier": attempt.verifier,
                      "redirect_uri": callback.redirectURI]
        if !attempt.usesCodexLogin { fields["resource"] = "https://api.openai.com/v1" }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let (data, status) = try await http.send(request)
        if status != 200, let failure = try? JSONDecoder().decode([String: String].self, from: data),
           failure["error"] == "invalid_client" { throw SignInError.clientUnavailable }
        guard status == 200 else { throw SignInError.identity }
        struct Tokens: Decodable {
            let id_token: String
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
        }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { throw SignInError.identity }
        let (jwks, jwksStatus) = try await http.send(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
        guard jwksStatus == 200 else { throw SignInError.identity }
        let identity = try OpenAIIdentityVerifier.verify(tokens.id_token, jwks: jwks,
            clientID: callback.clientID, nonce: attempt.nonce, now: now)
        guard attempt.expectedSubject == nil || attempt.expectedSubject == identity.subject else {
            throw SignInError.identity
        }
        let expiresAt = min(identity.expiresAt, now.addingTimeInterval(tokens.expires_in ?? identity.expiresAt.timeIntervalSince(now)))
        guard expiresAt > now else { throw SignInError.expired }
        return SignedInAccount(subject: identity.subject, clientID: callback.clientID, email: identity.email,
            expiresAt: expiresAt, idToken: tokens.id_token, accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token, authorizationNonce: attempt.nonce)
    }

    /// Refreshes only this app's Keychain tokens.
    func renew(_ account: SignedInAccount, now: Date) async throws -> SignedInAccount {
        guard account.clientID == OpenAIOAuthClient.codex,
              let refresh = account.refreshToken, !refresh.isEmpty else { throw SignInError.refreshRejected }
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token", "client_id": account.clientID, "refresh_token": refresh
        ])
        let (data, status) = try await http.send(request)
        if status != 200 {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let nested = failure?["error"] as? [String: Any]
            let code = (failure?["error"] as? String ?? nested?["code"] as? String
                ?? failure?["code"] as? String)?.lowercased()
            if status == 401 || ((400..<500).contains(status) && status != 429 &&
                ["invalid_grant", "invalid_client", "refresh_token_expired",
                 "refresh_token_reused", "refresh_token_invalidated"].contains(code ?? "")) {
                throw SignInError.refreshRejected
            }
            throw SignInError.refreshUnavailable
        }
        struct Tokens: Decodable {
            let access_token: String
            let id_token: String?
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data),
              !tokens.access_token.isEmpty, tokens.access_token.utf8.count <= 64_000,
              tokens.refresh_token == nil || !tokens.refresh_token!.isEmpty else { throw SignInError.invalidResponse }
        var identity: OpenAIIdentityVerifier.Identity?
        if let token = tokens.id_token {
            let (jwks, status) = try await http.send(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
            guard status == 200 else { throw SignInError.refreshUnavailable }
            identity = try OpenAIIdentityVerifier.verifyRefresh(token, jwks: jwks, clientID: account.clientID,
                originalNonce: account.authorizationNonce, now: now)
            guard identity?.subject == account.subject else { throw SignInError.identity }
        }
        // Expiration metadata only; this decoded access-token payload is not identity proof.
        let parts = tokens.access_token.split(separator: ".")
        let metadata = parts.count == 3 ? Data(base64URL: String(parts[1])) : nil
        let claims = metadata.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let accessExpiry = (claims?["exp"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        let lifetimeExpiry = tokens.expires_in.flatMap { $0.isFinite && $0 > 0 ? now.addingTimeInterval($0) : nil }
        guard let expires = [accessExpiry, lifetimeExpiry, identity?.expiresAt].compactMap({ $0 }).min(),
              expires > now else { throw SignInError.invalidResponse }
        return SignedInAccount(subject: account.subject, clientID: account.clientID,
            email: identity?.email ?? account.email, expiresAt: expires,
            idToken: tokens.id_token ?? account.idToken, accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token ?? refresh, authorizationNonce: account.authorizationNonce)
    }

}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL: String) {
        guard base64URL.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}
