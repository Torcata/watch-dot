import Foundation
import Security

public struct PhoneAuthorizationRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let installationID: String
    public let nonce: String
    public let expiresAt: Date
    public let expectedSubject: String?

    init(installationID: String, expectedSubject: String?, now: Date) throws {
        id = UUID()
        self.installationID = installationID
        nonce = try OAuthAuthorization.random()
        expiresAt = now.addingTimeInterval(600)
        self.expectedSubject = expectedSubject
    }

    func validate(now: Date) throws {
        guard expiresAt > now, expiresAt.timeIntervalSince(now) <= 630,
              installationID.hasPrefix("urn:uuid:"),
              UUID(uuidString: String(installationID.dropFirst(9))) != nil,
              nonce.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
        else { throw SignInError.expired }
    }
}

public struct PhoneReceipt: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let installationID: String
    public let nonce: String
    init(request: PhoneAuthorizationRequest) {
        requestID = request.id; installationID = request.installationID; nonce = request.nonce
    }
}

public struct PhoneCredentialTransfer: Codable, Sendable {
    public let request: PhoneAuthorizationRequest
    public let account: SignedInAccount
    var receipt: PhoneReceipt { PhoneReceipt(request: request) }
}

public enum CompanionMessage: Codable, Sendable {
    case prepare, query, idle
    case begin(PhoneAuthorizationRequest)
    case credentials(PhoneCredentialTransfer)
    case acknowledgement(PhoneReceipt)
    case cancel(PhoneAuthorizationRequest)
    case status(String)
    case failure(String)
}

public struct CompanionEnvelope: Codable, Sendable {
    let version: Int
    public let message: CompanionMessage
    public init(_ message: CompanionMessage) { version = 1; self.message = message }
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 200_000 else { throw SignInError.invalidResponse }
        return data
    }
    public static func decode(_ data: Data) throws -> CompanionMessage {
        guard data.count <= 200_000 else { throw SignInError.invalidResponse }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        guard envelope.version == 1 else { throw SignInError.invalidResponse }
        return envelope.message
    }
}

/// ObjC transport callbacks must not inherit an actor. Only delivery runs on MainActor.
struct CompanionReplyCallbacks: Sendable {
    let reply: @Sendable (Data) -> Void
    let failure: @Sendable (any Error) -> Void
    init(deliver: @escaping @MainActor @Sendable (Result<CompanionMessage, Error>) -> Void) {
        reply = { data in
            Task { @MainActor in deliver(Result { try CompanionEnvelope.decode(data) }) }
        }
        failure = { _ in
            Task { @MainActor in deliver(.failure(SignInError.unavailable)) }
        }
    }
}

@MainActor
public protocol WatchSignInLink: AnyObject {
    func requestAuthorization(_ request: PhoneAuthorizationRequest)
    func cancelAuthorization(_ request: PhoneAuthorizationRequest)
}

/// Independent device Keychains. Acknowledgement removes the phone's only token copy.
@MainActor
public final class PhoneTransferVault {
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cl.australapps.watchdot.phone-transfer",
        kSecAttrAccount as String: "pending-v1"
    ]
    public init() {}
    public func load() throws -> PhoneCredentialTransfer? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SignInError.storage }
        do { return try JSONDecoder().decode(PhoneCredentialTransfer.self, from: data) }
        catch { throw SignInError.storage }
    }
    public func save(_ transfer: PhoneCredentialTransfer) throws {
        let data = try JSONEncoder().encode(transfer)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SignInError.storage }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SignInError.storage }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SignInError.storage }
    }
}

extension SignInService {
    func validateTransfer(_ transfer: PhoneCredentialTransfer, now: Date) async throws {
        try transfer.request.validate(now: now)
        let account = transfer.account
        guard account.clientID == OpenAIOAuthClient.codex,
              account.authorizationNonce == transfer.request.nonce,
              account.expiresAt > now,
              let access = account.accessToken, !access.isEmpty, access.utf8.count <= 64_000,
              account.refreshToken == nil || (!account.refreshToken!.isEmpty && account.refreshToken!.utf8.count <= 64_000)
        else { throw SignInError.invalidResponse }
        let (jwks, status) = try await http.send(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
        guard status == 200 else { throw SignInError.identity }
        let identity = try OpenAIIdentityVerifier.verify(account.idToken, jwks: jwks,
            clientID: account.clientID, nonce: transfer.request.nonce, now: now)
        guard identity.subject == account.subject, identity.email == account.email,
              account.expiresAt <= identity.expiresAt,
              transfer.request.expectedSubject == nil || transfer.request.expectedSubject == identity.subject
        else { throw SignInError.identity }
    }
}
