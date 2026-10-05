import Foundation
import XCTest
@testable import WatchDotCore

private let probeNow = Date(timeIntervalSince1970: 1_800_000_000)

// Synthetic payloads only. These are not signed credentials and are never sent to a real service.
private func fixtureJWT(_ claims: [String: Any]) throws -> String {
    "fixture.\(try JSONSerialization.data(withJSONObject: claims).base64URL).fixture"
}

private func probeAccount(accessChanges: [String: Any] = [:], idChanges: [String: Any] = [:],
                          expires: Date = probeNow.addingTimeInterval(3600), token: String? = nil) throws -> SignedInAccount {
    let routing = ["chatgpt_account_id": "account-fixture", "user_id": "user-fixture"]
    var access: [String: Any] = ["exp": probeNow.addingTimeInterval(3600).timeIntervalSince1970,
                               "https://api.openai.com/auth": routing]
    access.merge(accessChanges) { _, new in new }
    var identity: [String: Any] = ["sub": "subject-fixture", "https://api.openai.com/auth": routing]
    identity.merge(idChanges) { _, new in new }
    return SignedInAccount(subject: "subject-fixture", clientID: OpenAIOAuthClient.codex, email: nil,
                           expiresAt: expires, idToken: try fixtureJWT(identity),
                           accessToken: try token ?? fixtureJWT(access))
}

private func primaryFixture(roomID: String = "room-fixture", available: Bool = true) -> [String: Any] {
    ["selection": ["available": available, "aeon_id": "dot-fixture", "messaging_room_id": roomID]]
}

private func roomFixture(_ changes: [String: Any] = [:]) -> [String: Any] {
    var room: [String: Any] = [
        "id": "room-fixture", "type": "DM", "app_source": "chatgpt:messaging", "aeon_id": "dot-fixture",
        "members": [["account_user_id": "user-fixture"],
                    ["account_user_id": "dot-user-fixture", "aeon_id": "dot-fixture"]],
        "member_profile_snapshots": [["account_user_id": "dot-user-fixture", "name": "Andy fixture"]]
    ]
    room.merge(changes) { _, new in new }
    return room
}

private actor ProbeHTTPMock: SignInHTTP {
    let replies: [(Data, Int)]
    let holdFirst: Bool
    var requests: [URLRequest] = []
    var continuation: CheckedContinuation<Void, Never>?

    init(_ replies: [(Data, Int)], holdFirst: Bool = false) {
        self.replies = replies
        self.holdFirst = holdFirst
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let index = requests.count
        requests.append(request)
        if holdFirst && index == 0 { await withCheckedContinuation { continuation = $0 } }
        guard index < replies.count else { throw URLError(.notConnectedToInternet) }
        return replies[index]
    }
    func captured() -> [URLRequest] { requests }
    func isHeld() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
}

private func probeHTTP(_ replies: [([String: Any], Int)], holdFirst: Bool = false) throws -> ProbeHTTPMock {
    let encoded = try replies.map { (try JSONSerialization.data(withJSONObject: $0.0), $0.1) }
    return ProbeHTTPMock(encoded, holdFirst: holdFirst)
}

private actor DiagnosticHTTPMock: SignInHTTP {
    let response: SignInHTTPResponse
    var reads = 0
    init(_ response: SignInHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> (Data, Int) { (response.data, response.status) }
    func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse {
        reads += 1
        return response
    }
    func readCount() -> Int { reads }
}

@MainActor
private final class ProbeStore: SignInStore {
    var record: SignInRecord?
    var failLoad = false
    init(_ account: SignedInAccount) { record = SignInRecord(); record?.account = account }
    func load() throws -> SignInRecord? {
        if failLoad { throw SignInError.storage }
        return record
    }
    func save(_ record: SignInRecord) throws { self.record = record }
}

@MainActor
final class DotAccessProbeTests: XCTestCase {
    private func expect(_ expected: DotProbeError, replies: [([String: Any], Int)],
                        account: SignedInAccount? = nil, calls: Int) async throws {
        let http = try probeHTTP(replies)
        do {
            _ = try await DotAccessProbe(http: http).run(account: try account ?? probeAccount(), now: probeNow)
            XCTFail("Must stop without claiming Dot access")
        } catch { XCTAssertEqual(error as? DotProbeError, expected) }
        let requests = await http.captured()
        XCTAssertEqual(requests.count, calls)
    }

    func testLocatesPrimaryDotAndMembersUsingOnlyTwoDirectReadRequests() async throws {
        let http = try probeHTTP([(primaryFixture(), 200), (roomFixture(), 200)])
        let account = try probeAccount()
        let found = try await DotAccessProbe(http: http).run(account: account, now: probeNow)
        XCTAssertEqual(found, LocatedDot(name: "Andy fixture", dotID: "dot-fixture", roomID: "room-fixture", accountID: "account-fixture", userID: "user-fixture", dotMemberID: "dot-user-fixture"))
        let requests = await http.captured()
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://chatgpt.com/backend-api/tbo/primary",
            "https://chatgpt.com/backend-api/messaging/rooms/room-fixture"
        ])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(account.accessToken!)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "watch-dot")
            XCTAssertEqual(Set(request.allHTTPHeaderFields!.keys.map { $0.lowercased() }),
                           Set(["authorization", "chatgpt-account-id", "originator", "user-agent", "accept"]))
        }
    }

    func testRejectionsAndRedirectsStopWithoutRetryOrExposingBody() async throws {
        for status in [301, 302, 401, 403, 404, 429, 500] {
            let error = DotProbeError.http(.primary, status)
            try await expect(error, replies: [(["error": "PRIVATE-BODY-MARKER"], status)], calls: 1)
            XCTAssertFalse(error.message.contains("PRIVATE-BODY-MARKER"))
        }
        try await expect(.http(.room, 403), replies: [(primaryFixture(), 200), ([:], 403)], calls: 2)
    }

    func testNoPrimaryAndUnavailableNeverQueryRoom() async throws {
        try await expect(.noPrimary, replies: [(["selection": NSNull()], 200)], calls: 1)
        try await expect(.unavailable, replies: [(primaryFixture(available: false), 200)], calls: 1)
        try await expect(.unavailable, replies: [(["selection": ["available": true, "aeon_id": "dot-fixture"]], 200)], calls: 1)
    }

    func testUnexpectedSuccessBodiesAreNotTreatedAsDotAccess() async throws {
        try await expect(.schema(.primary), replies: [(["challenge": "fixture"], 200)], calls: 1)
        try await expect(.schema(.room), replies: [(primaryFixture(), 200), (["ok": true], 200)], calls: 2)
    }

    func testEmptyControlAndDotSegmentRoomIDsAreRejectedBeforeRequest() async throws {
        for id in ["", " ", ".", "..", "room\r\nCookie: x", String(repeating: "x", count: 4097)] {
            try await expect(.invalidIdentifier, replies: [(primaryFixture(roomID: id), 200)], calls: 1)
        }
    }

    func testOpaqueIdentifiersPreserveIdentityWithoutAssumingAnAlphabetOrUUIDLength() async throws {
        // Same field types as the real D2 report, with synthetic identifiers outside the old regex.
        for dotID in ["dot:fixture.with~punctuation", String(repeating: "d", count: 250)] {
            let roomID = "dm:fixture.room~1"
            let primary: [String: Any] = ["selection": ["available": true, "aeon_id": dotID, "messaging_room_id": roomID]]
            let room = roomFixture(["id": roomID, "aeon_id": dotID,
                "members": [["account_user_id": "user-fixture"], ["account_user_id": "dot:user.fixture", "aeon_id": dotID]]])
            let http = try probeHTTP([(primary, 200), (room, 200)])
            let found = try await DotAccessProbe(http: http).run(account: probeAccount(), now: probeNow)
            XCTAssertEqual(found.dotID, dotID)
            XCTAssertEqual(found.roomID, roomID)
            let requests = await http.captured()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[1].url?.absoluteString,
                           "https://chatgpt.com/backend-api/messaging/rooms/dm%3Afixture.room~1")
        }
    }

    func testReservedCharactersAreEncodedOnceAndCannotChangeOriginQueryOrPathStructure() async throws {
        for (id, encoded) in [
            ("../other", "..%2Fother"), ("room?x=y", "room%3Fx%3Dy"), ("room#x", "room%23x"),
            ("%2fother", "%252fother"), ("https://example.invalid", "https%3A%2F%2Fexample.invalid"),
            ("room/child", "room%2Fchild"), ("sala:ñ", "sala%3A%C3%B1"), ("room+one=", "room%2Bone%3D")
        ] {
            let http = try probeHTTP([(primaryFixture(roomID: id), 200), (roomFixture(["id": id]), 200)])
            let found = try await DotAccessProbe(http: http).run(account: probeAccount(), now: probeNow)
            XCTAssertEqual(found.roomID, id)
            let requests = await http.captured()
            let url = try XCTUnwrap(requests.last?.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "chatgpt.com")
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(components.percentEncodedPath, "/backend-api/messaging/rooms/\(encoded)")
            XCTAssertEqual(components.percentEncodedPath.split(separator: "/").count, 4)
        }
    }

    func testRoomMustMatchSelectedDotAndMessagingChannel() async throws {
        for change in [["id": "another-room"], ["aeon_id": "another-dot"], ["type": "GROUP_DM"], ["app_source": "other"]] {
            try await expect(.destination, replies: [(primaryFixture(), 200), (roomFixture(change), 200)], calls: 2)
        }
    }

    func testMembershipMustIdentifyUserAndExactlyOneSelectedDot() async throws {
        for members: [[String: String]] in [
            [["account_user_id": "other-user"], ["account_user_id": "dot-user", "aeon_id": "dot-fixture"]],
            [["account_user_id": "user-fixture"], ["account_user_id": "dot-user", "aeon_id": "wrong-dot"]],
            [["account_user_id": "user-fixture"], ["account_user_id": "dot-user", "aeon_id": "dot-fixture"],
             ["account_user_id": "dot-user-2", "aeon_id": "dot-fixture"]],
            [["account_user_id": "user-fixture"], ["account_user_id": "user-fixture", "aeon_id": "dot-fixture"]]
        ] {
            try await expect(.membership, replies: [(primaryFixture(), 200), (roomFixture(["members": members]), 200)], calls: 2)
        }
    }

    func testExpiredOrUnsupportedCredentialsNeverLeaveApp() async throws {
        try await expect(.session, replies: [], account: probeAccount(expires: .distantPast), calls: 0)
        try await expect(.session, replies: [], account: probeAccount(accessChanges: ["exp": 0]), calls: 0)
        try await expect(.tokenMetadata, replies: [], account: probeAccount(token: "opaque-fixture"), calls: 0)
        let account = SignedInAccount(subject: "fixture", clientID: "oaiapp_fixture", email: nil,
                                      expiresAt: .distantFuture, idToken: "fixture", accessToken: nil)
        try await expect(.session, replies: [], account: account, calls: 0)
    }

    func testIdentityRoutingMustAgreeWithVerifiedAccount() async throws {
        for change: [String: Any] in [
            ["sub": "other-subject"],
            ["https://api.openai.com/auth": ["chatgpt_account_id": "another-account"]],
            ["https://api.openai.com/auth": ["user_id": "another-user"]]
        ] {
            try await expect(.tokenMetadata, replies: [], account: probeAccount(idChanges: change), calls: 0)
        }
        try await expect(.tokenMetadata, replies: [], account: probeAccount(accessChanges: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "account\r\nX: other", "user_id": "user-fixture"]
        ]), calls: 0)
    }

    func testNetworkFailureReportsStageAndAllowsExplicitRetry() async throws {
        let http = try probeHTTP([(primaryFixture(), 200)])
        let store = ProbeStore(try probeAccount())
        let session = ConnectionSession(store: store, http: http, now: { probeNow })
        session.probeDotAccess()
        await wait { session.dotProbeState == .failed(DotProbeError.network(.room).message) }
        XCTAssertEqual(session.phase, .signedIn)
        XCTAssertFalse(session.andyConnected)
        session.probeDotAccess()
        await wait { session.dotProbeState == .failed(DotProbeError.network(.primary).message) }
        let requests = await http.captured()
        XCTAssertEqual(requests.count, 3)
    }

    func testRepeatedTapHasOneProbeAndSuccessfulReadDoesNotEnableChat() async throws {
        let http = try probeHTTP([(primaryFixture(), 200), (roomFixture(), 200)], holdFirst: true)
        let session = ConnectionSession(store: ProbeStore(try probeAccount()), http: http, now: { probeNow })
        session.probeDotAccess()
        await wait { await http.isHeld() }
        session.probeDotAccess()
        let requests = await http.captured()
        XCTAssertEqual(requests.count, 1)
        await http.release()
        await wait { if case .located = session.dotProbeState { true } else { false } }
        XCTAssertFalse(session.andyConnected)
        XCTAssertEqual(session.phase, .signedIn)
    }

    func testCancelPauseSignOutAndAccountChangeIgnoreLateResponse() async throws {
        for action in ["cancel", "pause", "signOut", "accountChange", "keychainFailure"] {
            let http = try probeHTTP([(primaryFixture(), 200), (roomFixture(), 200)], holdFirst: true)
            let store = ProbeStore(try probeAccount())
            let session = ConnectionSession(store: store, http: http, now: { probeNow })
            session.probeDotAccess()
            await wait { await http.isHeld() }
            switch action {
            case "cancel": session.cancelDotProbe()
            case "pause": session.pause()
            case "signOut": session.signOutLocally()
            case "accountChange": store.record?.account = nil; session.refresh()
            default: store.failLoad = true; session.refresh()
            }
            let expected = session.dotProbeState
            await http.release()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(session.dotProbeState, expected)
            let requests = await http.captured()
            XCTAssertEqual(requests.count, 1)
            XCTAssertFalse(session.andyConnected)
        }
    }

    func testProbeRequiresExistingAuthorizedSession() async throws {
        let http = try probeHTTP([])
        let store = ProbeStore(try probeAccount(expires: .distantPast))
        let session = ConnectionSession(store: store, http: http, now: { probeNow })
        session.probeDotAccess()
        XCTAssertEqual(session.dotProbeState, .failed(DotProbeError.session.message))
        let requests = await http.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDiagnosticsContainOnlyAllowlistedStructureAndNeverValuesOrUnknownKeys() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "selection": ["available": "PRIVATE", "aeon_id": "PRIVATE", "messaging_room_id": "PRIVATE"],
            "error": "PRIVATE", "PRIVATE": "PRIVATE", "response": ["token": "PRIVATE"]
        ])
        let diagnostic = DotProbeDiagnostic(stage: .primary, response: SignInHTTPResponse(data: body, status: 200))
        XCTAssertEqual(diagnostic.bodyKind, .object)
        XCTAssertEqual(diagnostic.fields["selection.available"], .string)
        XCTAssertEqual(diagnostic.fields["response"], .object)
        let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE"))
        XCTAssertFalse(encoded.contains("token"))
        XCTAssertEqual(DotJSONKind.of(NSNumber(value: true)), .boolean)
        XCTAssertEqual(DotJSONKind.of(NSNumber(value: 1)), .number)
    }

    func testDiagnosticDistinguishesHTMLJSONEmptyAndInvalidDataWithoutEchoingIt() {
        for (body, type, expected): (String, SignInContentType, DotJSONKind) in [
            ("<!DOCTYPE html><html>PRIVATE</html>", .unknown, .html),
            ("PRIVATE", .html, .html), ("PRIVATE", .text, .invalidJSON),
            ("", .unknown, .empty), ("[]", .json, .array), ("null", .json, .null),
            ("true", .json, .boolean), ("1", .json, .number)
        ] {
            let diagnostic = DotProbeDiagnostic(stage: .primary,
                response: SignInHTTPResponse(data: Data(body.utf8), status: 200, contentType: type))
            XCTAssertEqual(diagnostic.bodyKind, expected)
            XCTAssertFalse(diagnostic.summary.contains("PRIVATE"))
        }
        XCTAssertEqual(SignInContentType("text/html; charset=utf-8"), .html)
        XCTAssertEqual(SignInContentType("application/problem+json"), .json)
        XCTAssertEqual(SignInContentType(""), .other)
        XCTAssertEqual(SignInContentType(nil), .unknown)
    }

    func testChallengeHeaderStopsEvenIfBodyLooksLikeValidPrimarySelection() async throws {
        let body = try JSONSerialization.data(withJSONObject: primaryFixture())
        let http = DiagnosticHTTPMock(SignInHTTPResponse(data: body, status: 200, contentType: .json, clientChallenge: true))
        do {
            _ = try await DotAccessProbe(http: http).run(account: probeAccount(), now: probeNow)
            XCTFail("Challenge must stop the probe")
        } catch { XCTAssertEqual(error as? DotProbeError, .challenge(.primary, 200)) }
        let count = await http.readCount()
        XCTAssertEqual(count, 1)
    }

    func testHTTP200SchemaErrorShowsSafeDiagnosticWithoutUploadingToMac() async throws {
        let response = SignInHTTPResponse(data: Data("<html>PRIVATE</html>".utf8), status: 200, contentType: .html)
        let http = DiagnosticHTTPMock(response)
        let session = ConnectionSession(store: ProbeStore(try probeAccount()), http: http, now: { probeNow })
        session.probeDotAccess()
        await wait { if case .failed = session.dotProbeState { return true }; return false }
        XCTAssertEqual(session.dotProbeState, .failed(DotProbeDiagnostic(stage: .primary, response: response).summary))
        XCTAssertFalse(session.andyConnected)
        let reads = await http.readCount()
        XCTAssertEqual(reads, 1)
    }

    private func wait(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for probe state")
    }
}
