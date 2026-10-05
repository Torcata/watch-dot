import XCTest
import Foundation
@testable import WatchDotCore

@MainActor
private final class CompanionStore: SignInStore {
    var record: SignInRecord?
    var failSave = false
    func load() throws -> SignInRecord? { record }
    func save(_ record: SignInRecord) throws {
        if failSave { throw SignInError.storage }
        self.record = record
    }
}

@MainActor
private final class CompanionLinkStub: WatchSignInLink {
    var requests: [PhoneAuthorizationRequest] = []
    var cancellations: [PhoneAuthorizationRequest] = []
    func requestAuthorization(_ request: PhoneAuthorizationRequest) { requests.append(request) }
    func cancelAuthorization(_ request: PhoneAuthorizationRequest) { cancellations.append(request) }
}

private actor CompanionHTTP: SignInHTTP {
    let jwks: Data
    var held = false
    var continuation: CheckedContinuation<Void, Never>?
    var reachedJWKS = false
    init(_ jwks: Data) { self.jwks = jwks }
    func hold() { held = true }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func hasReachedJWKS() -> Bool { reachedJWKS }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.path == "/.well-known/jwks.json" else { return (Data(), 503) }
        reachedJWKS = true
        if held { await withCheckedContinuation { continuation = $0 } }
        return (jwks, 200)
    }
}

@MainActor
final class CompanionAuthenticationTests: XCTestCase {
    private func transfer(_ request: PhoneAuthorizationRequest, signer: SigningFixture,
                          subject: String = "test-subject") throws -> PhoneCredentialTransfer {
        let token = try signer.token(nonce: request.nonce, client: OpenAIOAuthClient.codex, changes: ["sub": subject])
        let account = SignedInAccount(subject: subject, clientID: OpenAIOAuthClient.codex,
            email: "test@example.invalid", expiresAt: Date().addingTimeInterval(1800),
            idToken: token, accessToken: "fixture-access", refreshToken: "fixture-refresh",
            authorizationNonce: request.nonce)
        return PhoneCredentialTransfer(request: request, account: account)
    }
    private func receipt(_ result: CompanionMessage, file: StaticString = #filePath, line: UInt = #line) -> PhoneReceipt? {
        guard case .acknowledgement(let receipt) = result else {
            XCTFail("Expected saved-session acknowledgement", file: file, line: line); return nil
        }
        return receipt
    }
    func testRequestPersistsAndSurvivesSessionRestart() throws {
        let store = CompanionStore(), link = CompanionLinkStub()
        let first = ConnectionSession(store: store, companion: link)
        first.connect()
        let request = try XCTUnwrap(store.record?.phoneRequest)
        XCTAssertEqual(link.requests, [request])
        let second = ConnectionSession(store: store, companion: link)
        XCTAssertEqual(try second.preparePhoneAuthorization(), request)
        XCTAssertEqual(second.phase, .awaitingConsent)
    }
    func testSavesBeforeAckAndDuplicateDoesNotOverwriteRotatedTokens() async throws {
        let signer = try SigningFixture(), store = CompanionStore()
        let http = CompanionHTTP(signer.jwks)
        let session = ConnectionSession(store: store, http: http, companion: CompanionLinkStub())
        let request = try session.preparePhoneAuthorization()
        let packet = try transfer(request, signer: signer)
        let first = await session.receiveCompanionMessage(.credentials(packet))
        XCTAssertEqual(receipt(first), packet.receipt)
        XCTAssertEqual(store.record?.account?.accessToken, "fixture-access")
        XCTAssertNil(store.record?.phoneRequest)
        var rotated = try XCTUnwrap(store.record)
        rotated.account = SignedInAccount(subject: packet.account.subject, clientID: packet.account.clientID,
            email: packet.account.email, expiresAt: packet.account.expiresAt,
            idToken: packet.account.idToken, accessToken: "rotated-access", refreshToken: "rotated-refresh",
            authorizationNonce: request.nonce)
        try store.save(rotated)
        let restarted = ConnectionSession(store: store, http: http, companion: CompanionLinkStub())
        let duplicate = await restarted.receiveCompanionMessage(.credentials(packet))
        XCTAssertEqual(receipt(duplicate), packet.receipt)
        XCTAssertEqual(store.record?.account?.accessToken, "rotated-access")
        XCTAssertEqual(store.record?.account?.refreshToken, "rotated-refresh")
    }
    func testKeychainFailureHasNoAckAndCanRetrySameTransfer() async throws {
        let signer = try SigningFixture(), store = CompanionStore()
        let session = ConnectionSession(store: store, http: CompanionHTTP(signer.jwks), companion: CompanionLinkStub())
        let request = try session.preparePhoneAuthorization()
        let packet = try transfer(request, signer: signer)
        store.failSave = true
        let result = await session.receiveCompanionMessage(.credentials(packet))
        guard case .failure = result else { return XCTFail("Storage failure must not acknowledge") }
        XCTAssertNil(store.record?.account)
        XCTAssertEqual(store.record?.phoneRequest, request)
        store.failSave = false
        let retry = await session.receiveCompanionMessage(.credentials(packet))
        XCTAssertEqual(receipt(retry), packet.receipt)
    }
    func testCancellationAndSignOutRejectLateDelivery() async throws {
        let signer = try SigningFixture(), store = CompanionStore()
        let session = ConnectionSession(store: store, http: CompanionHTTP(signer.jwks), companion: CompanionLinkStub())
        let request = try session.preparePhoneAuthorization()
        let packet = try transfer(request, signer: signer)
        session.cancel()
        let cancelled = await session.receiveCompanionMessage(.credentials(packet))
        guard case .failure = cancelled else { return XCTFail("Cancelled attempt accepted") }
        let newRequest = try session.preparePhoneAuthorization()
        let newPacket = try transfer(newRequest, signer: signer)
        _ = await session.receiveCompanionMessage(.credentials(newPacket))
        session.signOutLocally()
        let late = await session.receiveCompanionMessage(.credentials(newPacket))
        guard case .failure = late else { return XCTFail("Signed-out attempt accepted") }
        XCTAssertNil(store.record?.account)
        XCTAssertNil(store.record?.acceptedPhoneTransfer)
    }
    func testCancelDuringValidationCannotReviveSession() async throws {
        let signer = try SigningFixture(), store = CompanionStore(), http = CompanionHTTP(signer.jwks)
        let session = ConnectionSession(store: store, http: http, companion: CompanionLinkStub())
        let request = try session.preparePhoneAuthorization(), packet = try transfer(request, signer: signer)
        await http.hold()
        let work = Task { await session.receiveCompanionMessage(.credentials(packet)) }
        for _ in 0..<100 {
            if await http.hasReachedJWKS() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        session.cancel()
        await http.release()
        let result = await work.value
        guard case .failure = result else { return XCTFail("Cancelled validation accepted") }
        XCTAssertNil(store.record?.account)
    }
    func testWrongIdentityAndInvalidTokenAreNotStored() async throws {
        let signer = try SigningFixture(), store = CompanionStore()
        var old = SignInRecord()
        old.account = SignedInAccount(subject: "original-subject", clientID: OpenAIOAuthClient.codex,
            email: nil, expiresAt: .distantPast, idToken: "old-fixture", accessToken: nil)
        store.record = old
        let session = ConnectionSession(store: store, http: CompanionHTTP(signer.jwks), companion: CompanionLinkStub())
        let request = try session.preparePhoneAuthorization()
        let packet = try transfer(request, signer: signer)
        let result = await session.receiveCompanionMessage(.credentials(packet))
        guard case .failure = result else { return XCTFail("Changed account accepted") }
        XCTAssertEqual(store.record?.account?.subject, "original-subject")
        let invalid = PhoneCredentialTransfer(request: request, account: SignedInAccount(
            subject: "original-subject", clientID: OpenAIOAuthClient.codex, email: nil,
            expiresAt: .now.addingTimeInterval(300), idToken: "invalid-fixture", accessToken: "fixture",
            authorizationNonce: request.nonce))
        let invalidResult = await session.receiveCompanionMessage(.credentials(invalid))
        guard case .failure = invalidResult else { return XCTFail("Invalid signature accepted") }
    }
    func testExpiredTransferAndOtherInstallationAreRejected() async throws {
        let signer = try SigningFixture(), store = CompanionStore()
        var date = Date()
        let session = ConnectionSession(store: store, http: CompanionHTTP(signer.jwks), now: { date }, companion: CompanionLinkStub())
        let request = try session.preparePhoneAuthorization(), packet = try transfer(request, signer: signer)
        date = date.addingTimeInterval(601)
        let expired = await session.receiveCompanionMessage(.credentials(packet))
        guard case .failure = expired else { return XCTFail("Expired attempt accepted") }
        let otherRequest = try PhoneAuthorizationRequest(installationID: "urn:uuid:\(UUID().uuidString)", expectedSubject: nil, now: .now)
        let other = await session.receiveCompanionMessage(.credentials(try transfer(otherRequest, signer: signer)))
        guard case .failure = other else { return XCTFail("Other installation accepted") }
        XCTAssertNil(store.record?.account)
    }
    func testCallbackRejectsWrongHostStateAndDuplicateParameters() throws {
        func callback(_ query: String, host: String = "127.0.0.1:1455") -> Data {
            Data("GET /auth/callback?\(query) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)
        }
        XCTAssertEqual(try LoopbackCallback.parse(callback("code=fixture&state=expected"), port: 1455, state: "expected").code, "fixture")
        XCTAssertThrowsError(try LoopbackCallback.parse(callback("code=fixture&state=other"), port: 1455, state: "expected"))
        XCTAssertThrowsError(try LoopbackCallback.parse(callback("code=fixture&state=expected&state=other"), port: 1455, state: "expected"))
        XCTAssertThrowsError(try LoopbackCallback.parse(callback("code=fixture&state=expected", host: "localhost:1455"), port: 1455, state: "expected"))
        XCTAssertThrowsError(try LoopbackCallback.parse(callback("code=fixture&error=access_denied&state=expected"), port: 1455, state: "expected"))
        XCTAssertEqual(try LoopbackCallback.parse(callback("error=access_denied&state=expected"), port: 1455, state: "expected").error, "access_denied")
    }
    func testEnvelopeRejectsUnsupportedVersionAndOversizedPayload() throws {
        let encoded = try CompanionEnvelope(.query).encoded()
        guard case .query = try CompanionEnvelope.decode(encoded) else { return XCTFail("Query did not round-trip") }
        let unsupported = Data(String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)
        XCTAssertThrowsError(try CompanionEnvelope.decode(unsupported))
        XCTAssertThrowsError(try CompanionEnvelope.decode(Data(repeating: 0, count: 200_001)))
    }

    func testReplyAndErrorFromBackgroundQueueReachMainActorWithoutCrashing() async throws {
        let success = expectation(description: "background transport reply")
        let failure = expectation(description: "background transport error")
        let callbacks = CompanionReplyCallbacks { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result {
            case .success(.query): success.fulfill()
            case .failure: failure.fulfill()
            default: XCTFail("Unexpected transport reply")
            }
        }
        let data = try CompanionEnvelope(.query).encoded()
        DispatchQueue.global(qos: .utility).async {
            callbacks.reply(data)
            callbacks.failure(SignInError.unavailable)
        }
        await fulfillment(of: [success, failure], timeout: 2)
    }
}
