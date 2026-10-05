import XCTest
import Foundation
import Security
import CryptoKit
@testable import WatchDotCore

@MainActor
private final class MemorySignInStore: SignInStore {
    var record: SignInRecord?
    var failLoad = false
    var failSave = false
    func load() throws -> SignInRecord? {
        if failLoad { throw SignInError.storage }
        return record
    }
    func save(_ record: SignInRecord) throws {
        if failSave { throw SignInError.storage }
        self.record = record
    }
}

// Ephemeral RSA key generated for tests. No OpenAI key, token or network is used.
struct SigningFixture: @unchecked Sendable {
    let privateKey: SecKey
    let jwks: Data
    init() throws {
        privateKey = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048
        ] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let data = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let bytes = Array(data)
        var index = 0
        func field() -> [UInt8] {
            index += 1 // tag
            var size = Int(bytes[index]); index += 1
            if size & 0x80 != 0 {
                let lengthBytes = size & 0x7f
                size = 0
                for _ in 0..<lengthBytes { size = (size << 8) | Int(bytes[index]); index += 1 }
            }
            let result = Array(bytes[index..<(index + size)])
            index += size
            return result
        }
        let sequence = field()
        // Decode the two unsigned integers in the PKCS#1 public key.
        func integers(_ sequence: [UInt8]) -> [Data] {
            var offset = 0
            var values = [Data]()
            while offset < sequence.count {
                offset += 1
                var length = Int(sequence[offset]); offset += 1
                if length & 0x80 != 0 {
                    let count = length & 0x7f; length = 0
                    for _ in 0..<count { length = (length << 8) | Int(sequence[offset]); offset += 1 }
                }
                values.append(Data(sequence[offset..<(offset + length)].drop(while: { $0 == 0 })))
                offset += length
            }
            return values
        }
        let values = integers(sequence)
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "test-key", "kty": "RSA", "alg": "RS256", "use": "sig",
            "n": values[0].base64URL, "e": values[1].base64URL
        ]]])
    }
    func token(nonce: String, client: String = "oaiapp_test", changes: [String: Any] = [:],
               algorithm: String = "RS256") throws -> String {
        let now = Date().timeIntervalSince1970
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "test-subject",
                                    "aud": client, "nonce": nonce, "iat": now - 1, "exp": now + 3600,
                                    "email": "test@example.invalid"]
        claims.merge(changes) { _, new in new }
        let header = try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "test-key"]).base64URL
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
        let signed = Data("\(header).\(payload)".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
            signed as CFData, nil)) as Data
        return "\(header).\(payload).\(signature.base64URL)"
    }
}

private actor AuthHTTPMock: SignInHTTP {
    let signer: SigningFixture
    let authorization: OAuthAuthorization
    let status: Int
    let subject: String
    private var requests: [URLRequest] = []
    init(_ authorization: OAuthAuthorization, status: Int = 200, subject: String = "test-subject") throws {
        signer = try SigningFixture()
        self.authorization = authorization
        self.status = status
        self.subject = subject
    }
    func captured() -> [URLRequest] { requests }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard request.url?.scheme == "https", request.url?.host == "auth.openai.com" else {
            throw SignInError.invalidResponse
        }
        if request.url?.path == "/.well-known/jwks.json" { return (signer.jwks, 200) }
        guard request.url?.path == (authorization.usesCodexLogin ? "/oauth/token" : "/api/accounts/oauth/token") else {
            throw SignInError.invalidResponse
        }
        if status != 200 { return (Data(#"{"error":"invalid_client"}"#.utf8), status) }
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(string: "https://example.invalid/?" +
            String(decoding: request.httpBody!, as: UTF8.self))!.queryItems!.map { ($0.name, $0.value!) })
        guard fields["grant_type"] == "authorization_code", fields["client_id"] == authorization.clientID,
              fields["redirect_uri"] == authorization.redirectURI,
              fields["code_verifier"] == authorization.verifier else { throw SignInError.identity }
        return (try JSONSerialization.data(withJSONObject: [
            "id_token": signer.token(nonce: authorization.nonce, client: authorization.clientID, changes: ["sub": subject]),
            "access_token": "login-access-fixture", "refresh_token": "login-refresh-fixture", "expires_in": 3600
        ]), 200)
    }
}

@MainActor
final class AuthLinkStub: WatchSignInLink {
    var requests: [PhoneAuthorizationRequest] = []
    func requestAuthorization(_ request: PhoneAuthorizationRequest) { requests.append(request) }
    func cancelAuthorization(_ request: PhoneAuthorizationRequest) {}
}

@MainActor
final class ConnectionSessionTests: XCTestCase {
    private func authorization(account: SignedInAccount? = nil) throws -> OAuthAuthorization {
        var attempt = try OAuthAuthorization(account: account, now: .now)
        try attempt.prepare(redirect: "http://127.0.0.1:1455/auth/callback", hostID: "urn:uuid:\(UUID())")
        return attempt
    }
    private func callback(_ attempt: OAuthAuthorization) -> OAuthCallback {
        OAuthCallback(code: "fixture-code", state: attempt.state, clientID: attempt.clientID,
                      redirectURI: attempt.redirectURI!)
    }
    func testHTTPSIsRequiredWithoutLocalRelayException() async throws {
        let transport = SecureSignInHTTP()
        for target in ["http://auth.openai.com/oauth/token", "http://192.168.1.2:8765/config"] {
            do {
                _ = try await transport.send(URLRequest(url: URL(string: target)!))
                XCTFail("HTTP must be rejected")
            } catch { XCTAssertEqual(error as? SignInError, .configuration) }
        }
    }
    func testMissingCompanionDoesNotPretendLoginOrSendRequests() throws {
        let http = try AuthHTTPMock(authorization())
        let session = ConnectionSession(store: MemorySignInStore(), http: http)
        XCTAssertEqual(session.phase, .setupRequired)
        session.connect()
        XCTAssertEqual(session.phase, .setupRequired)
        XCTAssertFalse(session.andyConnected)
        XCTAssertFalse(session.isConfigured)
    }
    func testKeychainFailureBlocksPhoneRequest() throws {
        let store = MemorySignInStore(), link = AuthLinkStub()
        let session = ConnectionSession(store: store, companion: link)
        store.failSave = true
        session.connect()
        XCTAssertEqual(session.phase, .failed(SignInError.storage.message))
        XCTAssertTrue(link.requests.isEmpty)
        XCTAssertNil(store.record)
        store.failLoad = true
        let reopened = ConnectionSession(store: store, companion: link)
        reopened.connect()
        XCTAssertEqual(reopened.phase, .failed(SignInError.storage.message))
        XCTAssertTrue(link.requests.isEmpty)
    }
    func testCodexOAuthUsesPKCEAndNoMacParameters() throws {
        let attempt = try authorization()
        let url = try XCTUnwrap(URLComponents(string: attempt.authorizationURL!))
        let params = Dictionary(uniqueKeysWithValues: url.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertEqual(params["client_id"], OpenAIOAuthClient.codex)
        XCTAssertEqual(params["scope"], "openid profile email offline_access")
        XCTAssertEqual(params["originator"], "watch-dot")
        XCTAssertEqual(params["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(params["id_token_add_organizations"], "true")
        XCTAssertEqual(params["state"], attempt.state)
        XCTAssertEqual(params["nonce"], attempt.nonce)
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertEqual(params["code_challenge"], Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64URL)
        XCTAssertNil(params["resource"])
        XCTAssertNil(params["ext_agent_host_id"])
        XCTAssertNil(params["agent_name_hint"])
        XCTAssertNil(params["code_verifier"])
        XCTAssertNotEqual(attempt.state, attempt.nonce)
        XCTAssertNotEqual(attempt.state, attempt.verifier)
    }
    func testExchangeValidatesIdentityAndReturnsRenewableSessionOverHTTPS() async throws {
        let attempt = try authorization(), http = try AuthHTTPMock(attempt)
        let account = try await SignInService(http: http).exchange(callback(attempt), authorization: attempt, now: .now)
        XCTAssertEqual(account.subject, "test-subject")
        XCTAssertEqual(account.refreshToken, "login-refresh-fixture")
        XCTAssertEqual(account.authorizationNonce, attempt.nonce)
        let requests = await http.captured()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.host == "auth.openai.com" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }
    func testExistingAccountKeepsItsOAuthIdentityBinding() throws {
        let account = SignedInAccount(subject: "test-subject", clientID: "oaiapp_existing",
            email: nil, expiresAt: .distantPast, idToken: "fixture", accessToken: nil)
        let attempt = try authorization(account: account)
        let url = try XCTUnwrap(URLComponents(string: attempt.authorizationURL!))
        let params = Dictionary(uniqueKeysWithValues: url.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(attempt.expectedSubject, account.subject)
        XCTAssertEqual(url.path, "/api/accounts/authorize")
        XCTAssertEqual(params["client_id"], account.clientID)
        XCTAssertNil(params["codex_cli_simplified_flow"])
    }
    func testPublicCodexClientRequiresRegisteredLoopbackPorts() throws {
        for port in [1455, 1457, 54321] {
            var attempt = try OAuthAuthorization(account: nil, now: .now)
            if port == 54321 {
                XCTAssertThrowsError(try attempt.prepare(redirect: "http://127.0.0.1:\(port)/auth/callback", hostID: "unused"))
            } else {
                XCTAssertNoThrow(try attempt.prepare(redirect: "http://127.0.0.1:\(port)/auth/callback", hostID: "unused"))
            }
        }
    }
    func testCallbackBindingsAndExpiryAreCheckedBeforeExchange() async throws {
        let attempt = try authorization(), http = try AuthHTTPMock(attempt)
        let service = SignInService(http: http)
        for invalid in [
            OAuthCallback(code: "fixture", state: "wrong", clientID: attempt.clientID, redirectURI: attempt.redirectURI!),
            OAuthCallback(code: "fixture", state: attempt.state, clientID: "oaiapp_other", redirectURI: attempt.redirectURI!),
            OAuthCallback(code: "fixture", state: attempt.state, clientID: attempt.clientID, redirectURI: "https://example.invalid"),
            OAuthCallback(code: "", state: attempt.state, clientID: attempt.clientID, redirectURI: attempt.redirectURI!)
        ] {
            do { _ = try await service.exchange(invalid, authorization: attempt, now: .now); XCTFail("Invalid binding") }
            catch { XCTAssertEqual(error as? SignInError, .invalidResponse) }
        }
        do { _ = try await service.exchange(callback(attempt), authorization: attempt, now: attempt.deadline); XCTFail("Expired") }
        catch { XCTAssertEqual(error as? SignInError, .expired) }
        let requests = await http.captured()
        XCTAssertTrue(requests.isEmpty)
    }
    func testInvalidClientIsVisible() async throws {
        let attempt = try authorization(), http = try AuthHTTPMock(attempt, status: 400)
        do { _ = try await SignInService(http: http).exchange(callback(attempt), authorization: attempt, now: .now); XCTFail("Rejected client") }
        catch { XCTAssertEqual(error as? SignInError, .clientUnavailable) }
    }
    func testReauthorizationRejectsChangedAccountEvenWithValidSignature() async throws {
        let existing = SignedInAccount(subject: "test-subject", clientID: OpenAIOAuthClient.codex,
            email: nil, expiresAt: .distantPast, idToken: "fixture", accessToken: nil)
        let attempt = try authorization(account: existing), http = try AuthHTTPMock(attempt, subject: "another-subject")
        do { _ = try await SignInService(http: http).exchange(callback(attempt), authorization: attempt, now: .now); XCTFail("Changed account") }
        catch { XCTAssertEqual(error as? SignInError, .identity) }
    }
    func testRefusesRedirectToOtherHost() throws {
        var attempt = try OAuthAuthorization(account: nil, now: .now)
        for uri in ["https://example.org/callback", "http://localhost:1455/auth/callback",
                    "http://127.0.0.1:1455/wrong", "http://127.0.0.1:1455/auth/callback?x=y"] {
            XCTAssertThrowsError(try attempt.prepare(redirect: uri, hostID: "urn:uuid:\(UUID())"))
        }
    }
    func testRemovingMacSettingsPreservesKeychainAccountAndPhoneDelivery() throws {
        var record = SignInRecord()
        record.account = SignedInAccount(subject: "test-subject", clientID: OpenAIOAuthClient.codex,
            email: nil, expiresAt: .now.addingTimeInterval(3600), idToken: "fixture-id",
            accessToken: "fixture-access", refreshToken: "fixture-refresh")
        record.phoneRequest = try PhoneAuthorizationRequest(installationID: record.hostID, expectedSubject: nil, now: .now)
        record.acceptedPhoneTransfer = PhoneReceipt(request: record.phoneRequest!)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["settings"] = ["address": "http://192.168.1.2:8765", "pairingKey": "000123"]
        let decoded = try JSONDecoder().decode(SignInRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.hostID, record.hostID)
        XCTAssertEqual(decoded.account?.accessToken, record.account?.accessToken)
        XCTAssertEqual(decoded.account?.refreshToken, record.account?.refreshToken)
        XCTAssertEqual(decoded.phoneRequest, record.phoneRequest)
        XCTAssertEqual(decoded.acceptedPhoneTransfer, record.acceptedPhoneTransfer)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(encoded["settings"])
    }
    func testIDTokenSignatureAndAllIdentityBindingsAreRequired() throws {
        let signer = try SigningFixture()
        let nonce = try OAuthAuthorization.random()
        let token = try signer.token(nonce: nonce)
        let identity = try OpenAIIdentityVerifier.verify(token, jwks: signer.jwks, clientID: "oaiapp_test", nonce: nonce, now: .now)
        XCTAssertEqual(identity.subject, "test-subject")
        for changes: [String: Any] in [
            ["iss": "https://example.invalid"], ["aud": "oaiapp_other"], ["nonce": "wrong"],
            ["exp": Date().addingTimeInterval(-10).timeIntervalSince1970], ["sub": ""],
            ["iat": Date().addingTimeInterval(1000).timeIntervalSince1970],
            ["nbf": Date().addingTimeInterval(1000).timeIntervalSince1970],
            ["aud": ["oaiapp_test", "oaiapp_other"]], ["azp": "oaiapp_other"]
        ] {
            XCTAssertThrowsError(try OpenAIIdentityVerifier.verify(signer.token(nonce: nonce, changes: changes),
                jwks: signer.jwks, clientID: "oaiapp_test", nonce: nonce, now: .now))
        }
        XCTAssertThrowsError(try OpenAIIdentityVerifier.verify(signer.token(nonce: nonce, algorithm: "none"),
            jwks: signer.jwks, clientID: "oaiapp_test", nonce: nonce, now: .now))
        let otherSigner = try SigningFixture()
        XCTAssertThrowsError(try OpenAIIdentityVerifier.verify(token,
            jwks: otherSigner.jwks, clientID: "oaiapp_test", nonce: nonce, now: .now))
    }
}

private actor RefreshHTTPMock: SignInHTTP {
    let signer: SigningFixture
    var calls: [URLRequest] = []
    var status = 200
    var code = "invalid_grant"
    var subject = "test-subject"
    var omitIdentity = false
    var omitRotation = false
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    init() throws { signer = try SigningFixture() }
    func configure(status: Int = 200, subject: String = "test-subject", omitIdentity: Bool = false,
                   omitRotation: Bool = false, hold: Bool = false) {
        self.status = status; self.subject = subject; self.omitIdentity = omitIdentity
        self.omitRotation = omitRotation; self.hold = hold
    }
    func count() -> Int { calls.filter { $0.url?.path == "/oauth/token" }.count }
    func captured() -> [URLRequest] { calls }
    func release() { hold = false; continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls.append(request)
        guard request.url?.host == "auth.openai.com" else { throw SignInError.invalidResponse }
        if request.url?.path == "/.well-known/jwks.json" { return (signer.jwks, 200) }
        if hold { await withCheckedContinuation { continuation = $0 } }
        else { try await Task.sleep(for: .milliseconds(20)) }
        if status != 200 { return (try JSONSerialization.data(withJSONObject: ["error": code]), status) }
        let payload = try JSONSerialization.data(withJSONObject: ["exp": Date().addingTimeInterval(3600).timeIntervalSince1970]).base64URL
        var data: [String: Any] = ["access_token": "fixture.\(payload).fixture", "expires_in": 3600]
        if !omitIdentity {
            data["id_token"] = try signer.token(nonce: "login-nonce", client: OpenAIOAuthClient.codex,
                changes: ["sub": subject, "nonce": NSNull()])
        }
        if !omitRotation { data["refresh_token"] = "rotated-fixture" }
        return (try JSONSerialization.data(withJSONObject: data), 200)
    }
}

@MainActor
final class TokenRenewalTests: XCTestCase {
    private func make(_ http: RefreshHTTPMock) -> (MemorySignInStore, ConnectionSession) {
        let store = MemorySignInStore()
        var record = SignInRecord()
        record.account = SignedInAccount(subject: "test-subject", clientID: OpenAIOAuthClient.codex,
            email: nil, expiresAt: .distantPast, idToken: "previous-verified-fixture", accessToken: "old-fixture",
            refreshToken: "refresh-fixture", authorizationNonce: "login-nonce")
        store.record = record
        return (store, ConnectionSession(store: store, http: http))
    }

    func testConcurrentRefreshUsesOneRequestAndPersistsRotation() async throws {
        let http = try RefreshHTTPMock()
        let (store, session) = make(http)
        let first = Task { try await session.ensureCurrentAccount() }
        let second = Task { try await session.ensureCurrentAccount() }
        let a = try await first.value; let b = try await second.value
        XCTAssertEqual(a.accessToken, b.accessToken)
        XCTAssertEqual(store.record?.account?.refreshToken, "rotated-fixture")
        XCTAssertEqual(session.phase, .signedIn)
        let requests = await http.captured()
        XCTAssertEqual(requests.filter { $0.url?.path == "/oauth/token" }.count, 1)
        let request = try XCTUnwrap(requests.first)
        let fields = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["client_id"], OpenAIOAuthClient.codex)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let reopened = ConnectionSession(store: store, http: http)
        _ = try await reopened.ensureCurrentAccount()
        let count = await http.count(); XCTAssertEqual(count, 1)
    }

    func testMissingOptionalTokensKeepsOriginalRefreshAndVerifiedIdentity() async throws {
        let http = try RefreshHTTPMock()
        await http.configure(omitIdentity: true, omitRotation: true)
        let (store, session) = make(http)
        let renewed = try await session.ensureCurrentAccount()
        XCTAssertEqual(renewed.refreshToken, "refresh-fixture")
        XCTAssertEqual(renewed.idToken, "previous-verified-fixture")
        XCTAssertGreaterThan(renewed.expiresAt, .now)
        XCTAssertEqual(store.record?.account?.accessToken, renewed.accessToken)
    }

    func testRejectionRequiresLoginButNetworkFailureKeepsRefresh() async throws {
        let http = try RefreshHTTPMock()
        await http.configure(status: 503)
        let (store, session) = make(http)
        do { _ = try await session.ensureCurrentAccount(); XCTFail("Must fail") } catch {}
        XCTAssertEqual(store.record?.account?.refreshToken, "refresh-fixture")
        do { _ = try await session.ensureCurrentAccount(); XCTFail("Backoff") } catch {}
        var count = await http.count(); XCTAssertEqual(count, 1)
        await http.configure(status: 400)
        do { _ = try await session.ensureCurrentAccount(force: true); XCTFail("Must reject") } catch {}
        XCTAssertNil(store.record?.account?.refreshToken)
        XCTAssertEqual(session.phase, .expired)
        do { _ = try await session.ensureCurrentAccount(); XCTFail("Needs login") } catch {}
        count = await http.count(); XCTAssertEqual(count, 2)
    }

    func testDifferentSignedIdentityIsRejected() async throws {
        let http = try RefreshHTTPMock()
        await http.configure(subject: "another-account")
        let (store, session) = make(http)
        do { _ = try await session.ensureCurrentAccount(); XCTFail("Must reject account switch") } catch {}
        XCTAssertEqual(store.record?.account?.subject, "test-subject")
        XCTAssertNil(store.record?.account?.refreshToken)
        XCTAssertEqual(session.phase, .expired)
    }

    func testKeychainFailureRetainsRotatedTokenForSaveRetryWithoutRefreshingAgain() async throws {
        let http = try RefreshHTTPMock()
        let (store, session) = make(http)
        store.failSave = true
        do { _ = try await session.ensureCurrentAccount(); XCTFail("Must persist first") } catch {}
        store.failSave = false
        _ = try await session.ensureCurrentAccount()
        XCTAssertEqual(store.record?.account?.refreshToken, "rotated-fixture")
        let count = await http.count(); XCTAssertEqual(count, 1)
    }

    func testSigningOutDuringRefreshCannotRestoreSession() async throws {
        let http = try RefreshHTTPMock()
        await http.configure(hold: true)
        let (store, session) = make(http)
        let request = Task { try await session.ensureCurrentAccount() }
        for _ in 0..<100 {
            if await http.count() > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        session.signOutLocally()
        await http.release()
        do { _ = try await request.value; XCTFail("Cancelled session") } catch {}
        XCTAssertNil(store.record?.account)
        XCTAssertEqual(session.phase, .setupRequired)
    }

    func testOldKeychainRecordDecodesWithoutRefreshToken() throws {
        let http = try RefreshHTTPMock()
        let (store, _) = make(http)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.record!)) as? [String: Any])
        var account = try XCTUnwrap(json["account"] as? [String: Any])
        account.removeValue(forKey: "refreshToken"); account.removeValue(forKey: "authorizationNonce")
        json["account"] = account
        let old = try JSONDecoder().decode(SignInRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.account?.refreshToken)
        XCTAssertEqual(old.account?.subject, "test-subject")
    }
    func testRefreshIdentityAllowsMissingNonceButRejectsWrongNonceAndSignature() throws {
        let signer = try SigningFixture()
        let token = try signer.token(nonce: "login-nonce", client: OpenAIOAuthClient.codex,
                                     changes: ["nonce": NSNull()])
        XCTAssertNoThrow(try OpenAIIdentityVerifier.verifyRefresh(token, jwks: signer.jwks,
            clientID: OpenAIOAuthClient.codex, originalNonce: "login-nonce", now: .now))
        XCTAssertThrowsError(try OpenAIIdentityVerifier.verifyRefresh(
            signer.token(nonce: "wrong", client: OpenAIOAuthClient.codex), jwks: signer.jwks,
            clientID: OpenAIOAuthClient.codex, originalNonce: "login-nonce", now: .now))
        let otherSigner = try SigningFixture()
        XCTAssertThrowsError(try OpenAIIdentityVerifier.verifyRefresh(token, jwks: otherSigner.jwks,
            clientID: OpenAIOAuthClient.codex, originalNonce: "login-nonce", now: .now))
    }

}
