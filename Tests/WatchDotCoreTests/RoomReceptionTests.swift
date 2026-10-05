import XCTest
@testable import WatchDotCore

private let receptionNow = Date(timeIntervalSince1970: 1_800_000_000)
private let receptionDot = LocatedDot(name: "Andy fixture", dotID: "dot", roomID: "room/fixture",
    accountID: "account", userID: "self", dotMemberID: "andy")

private func roomItem(_ id: String, role: MessageRole = .assistant, text: String = "fixture",
                      requestID: UUID? = nil, replyTo: String? = nil) -> RoomMessage {
    RoomMessage(remoteID: id, message: ChatMessage(id: DotChatTransport.localID(id), role: role,
        text: text, createdAt: receptionNow), requestID: requestID, replyTo: replyTo)
}

private actor RecentHTTP: SignInHTTP {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let path = request.url!.path
        let body: [String: Any]
        if path.hasSuffix("/tbo/primary") {
            body = ["selection": ["available": true, "aeon_id": "dot", "messaging_room_id": "room/fixture"]]
        } else if !path.hasSuffix("/messages") {
            body = ["id": "room/fixture", "type": "DM", "app_source": "chatgpt:messaging", "aeon_id": "dot",
                    "members": [["account_user_id": "self"], ["account_user_id": "andy", "aeon_id": "dot"]]]
        } else {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let before = Int(query.first(where: { $0.name == "before" })?.value ?? "60") ?? 60
            let items = (max(0, before - 20)..<before).map { index in
                ["id": "message-\(index)", "account_user_id": index % 2 == 0 ? "self" : "andy",
                 "content": ["text": "text-\(index)"], "created_at": "2026-10-02T20:00:00.000Z"] as [String: Any]
            }
            body = ["items": items, "prev_cursor": before > 20 ? String(before - 20) : NSNull()]
        }
        return (try JSONSerialization.data(withJSONObject: body), 200)
    }
    func captured() -> [URLRequest] { requests }
}

private actor RecentTransport: ChatTransport {
    nonisolated let displayName = "fixture"
    nonisolated let isRealConnection = true
    nonisolated let supportsHistorySync = true
    nonisolated let supportsReadOnlyResume = true
    var items: [RoomMessage] = []
    var reads = 0
    var sends = 0
    func set(_ items: [RoomMessage]) { self.items = items }
    func count() -> Int { reads }
    func sendCount() -> Int { sends }
    func recentMessages(limit: Int) async throws -> [RoomMessage] { reads += 1; return items }
    func send(_ request: TurnRequest, onAccepted: @Sendable () async -> Void) async throws -> ChatMessage {
        sends += 1
        await onAccepted()
        return roomItem("reply-one").message
    }
}

@MainActor
final class RoomReceptionTests: XCTestCase {
    private func pending() -> ConversationSnapshot {
        let conversationID = UUID()
        let message = ChatMessage(role: .user, text: "fixture", createdAt: receptionNow)
        let turn = TurnRequest(conversationID: conversationID, clientTurnID: UUID(), messages: [message])
        return ConversationSnapshot(version: 1, conversationID: conversationID, messages: [message],
            pendingRequest: nil, hasAttemptedDelivery: false, deliveryState: .waiting, draft: "draft preserved",
            awaitingReplies: [turn])
    }
    private func plan(_ snapshot: ConversationSnapshot) -> BackgroundReceptionPlan {
        BackgroundReceptionPlan(id: UUID(), destination: receptionDot, subject: "fixture", credentialDigest: "fixture",
            directoryKey: String(repeating: "a", count: 64), roots: [snapshot.pendingTurns[0].clientTurnID: "sent"],
            cursor: "sent", historyLimit: 100)
    }
    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<100 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Condition not reached")
    }

    func testFirstAnswerSchedulesOneReadAtSixtySecondsEvenWhenOSDelaysIt() {
        let original = pending(); var reception = plan(original)
        let first = reception.consume(RoomPage(messages: [roomItem("reply-one")], nextCursor: nil),
            snapshot: original, now: receptionNow)
        XCTAssertTrue(first.pendingTurns.isEmpty)
        XCTAssertEqual(first.deliveryState, .answered)
        XCTAssertEqual(first.followUpUntil, receptionNow.addingTimeInterval(60))
        XCTAssertEqual(reception.delay(snapshot: first, now: receptionNow, waitingDelay: 0), 60)
        XCTAssertEqual(reception.delay(snapshot: first, now: receptionNow.addingTimeInterval(40), waitingDelay: 15), 20)
        XCTAssertTrue(reception.shouldContinue(snapshot: first, now: receptionNow.addingTimeInterval(90)))
        let next = reception.consume(RoomPage(messages: [roomItem("reply-one"), roomItem("reply-two")], nextCursor: nil),
            snapshot: first, now: receptionNow.addingTimeInterval(90))
        XCTAssertEqual(next.messages.filter { $0.role == .assistant }.count, 2)
        XCTAssertNil(next.followUpUntil)
        XCTAssertFalse(reception.shouldContinue(snapshot: next, now: receptionNow.addingTimeInterval(90)))
    }

    func testWaitingSurvivesPersistenceBacksOffAndCancellationStops() throws {
        let snapshot = pending(); var reception = plan(snapshot)
        for _ in 0..<12 {
            _ = reception.consume(RoomPage(messages: [], nextCursor: nil), snapshot: snapshot, now: receptionNow)
        }
        let restored = try JSONDecoder().decode(BackgroundReceptionPlan.self, from: JSONEncoder().encode(reception))
        XCTAssertEqual(restored.nextDelay, 60)
        XCTAssertTrue(restored.shouldContinue(snapshot: snapshot, now: receptionNow.addingTimeInterval(180)))
        var cancelled = snapshot; cancelled.deliveryState = .cancelled
        XCTAssertFalse(restored.shouldContinue(snapshot: cancelled, now: receptionNow))
    }

    func testPagingKeepsCorrelationAndDoesNotAcceptReplyToAnotherTurn() {
        let snapshot = pending(); var reception = plan(snapshot)
        let unrelated = roomItem("unrelated", replyTo: "someone-else")
        let first = reception.consume(RoomPage(messages: [unrelated], nextCursor: "page-two"), snapshot: snapshot, now: receptionNow)
        XCTAssertFalse(first.pendingTurns.isEmpty)
        XCTAssertEqual(reception.cursor, "page-two")
        let second = reception.consume(RoomPage(messages: [roomItem("actual")], nextCursor: nil), snapshot: first, now: receptionNow)
        XCTAssertTrue(second.pendingTurns.isEmpty)
    }

    func testLostAcknowledgementRecoveredByRequestIDWithoutMatchingTextAlone() {
        let snapshot = pending(); var reception = plan(snapshot)
        reception.roots = [:]; reception.cursor = nil
        let turn = snapshot.pendingTurns[0]
        let bad = roomItem("bad", role: .user, text: "different", requestID: turn.clientTurnID)
        let first = reception.consume(RoomPage(messages: [bad, roomItem("old-answer")], nextCursor: nil), snapshot: snapshot, now: receptionNow)
        XCTAssertFalse(first.pendingTurns.isEmpty)
        let own = roomItem("accepted", role: .user, requestID: turn.clientTurnID)
        let final = reception.consume(RoomPage(messages: [own, roomItem("answer")], nextCursor: nil), snapshot: snapshot, now: receptionNow)
        XCTAssertTrue(final.pendingTurns.isEmpty)
        XCTAssertEqual(final.messages.filter { $0.role == .user }.count, 1)
    }

    func testRecentWindowRetainsDraftAndPendingPayloadAcrossRestart() throws {
        let snapshot = pending()
        let imported = snapshot.merging([roomItem("external-user", role: .user), roomItem("external-answer")],
            replaceWindow: true, limit: 20, at: receptionNow)
        XCTAssertEqual(imported.draft, snapshot.draft)
        XCTAssertEqual(imported.pendingTurns, snapshot.pendingTurns)
        XCTAssertEqual(imported.messages.count, 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileConversationStore(url: directory.appendingPathComponent("conversation.json"))
        try store.save(imported)
        XCTAssertEqual(try store.load(), imported)
    }

    func testCorruptedBackgroundCacheIsPreservedAndBlocksSending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversation.json")
        let store = FileConversationStore(url: url)
        try store.save(pending())
        let session = ConversationSession(transport: RecentTransport(), store: store)
        let damaged = Data("damaged".utf8)
        try damaged.write(to: url)
        session.reloadAfterBackground()
        XCTAssertNotNil(session.storageIssue)
        XCTAssertFalse(session.canSend)
        session.retrySaving()
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testRecentHistoryPaginatesWithTwentyPerRequestAndKeepsOrderAndDates() async throws {
        let http = RecentHTTP()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claims: [String: Any] = ["sub": "subject", "exp": receptionNow.addingTimeInterval(3600).timeIntervalSince1970,
            "https://api.openai.com/auth": ["chatgpt_account_id": "account", "user_id": "self"]]
        let token = "fixture.\(try JSONSerialization.data(withJSONObject: claims).base64URL).fixture"
        let account = SignedInAccount(subject: "subject", clientID: OpenAIOAuthClient.codex, email: nil,
            expiresAt: receptionNow.addingTimeInterval(3600), idToken: token, accessToken: token)
        let transport = DotChatTransport(destination: receptionDot, http: http, credentials: { account },
            receipts: DotReceiptStore(directory: directory), onDiagnostic: { _ in }, now: { receptionNow })
        let messages = try await transport.recentMessages(limit: 50)
        XCTAssertEqual(messages.count, 50)
        XCTAssertEqual(messages.first?.remoteID, "message-10")
        XCTAssertEqual(messages.last?.remoteID, "message-59")
        XCTAssertEqual(messages.first?.message.createdAt, ISO8601DateFormatter().date(from: "2026-10-02T20:00:00Z"))
        let calls = await http.captured()
        XCTAssertEqual(calls.filter { $0.url!.path.hasSuffix("messages") }.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(calls.filter { $0.url!.path.hasSuffix("messages") }.allSatisfy { $0.url!.query!.contains("limit=20") })
        let background = try transport.receptionRequest(account: account, after: "id/with?reserved")
        XCTAssertEqual(background.httpMethod, "GET")
        XCTAssertNil(background.httpBody)
        XCTAssertEqual(URLComponents(url: background.url!, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "id/with?reserved")
        let untrusted = SignInHTTPResponse(data: Data(#"{"items":[{"id":"x","account_user_id":"stranger","content":{"text":"fake"}}]}"#.utf8), status: 200)
        XCTAssertTrue(try transport.receptionPage(untrusted).messages.isEmpty)
        XCTAssertThrowsError(try transport.receptionPage(SignInHTTPResponse(data: Data(), status: 403, clientChallenge: true)))
    }

    func testForegroundMakesOneDelayedReadAndIdleWakeMakesNone() async throws {
        let transport = RecentTransport()
        let session = ConversationSession(transport: transport, followUpDelay: 0.08)
        session.resumeAutomatically()
        session.send("fixture")
        await wait { session.deliveryState == .answered }
        let early = await transport.count()
        XCTAssertEqual(early, 0)
        await transport.set([roomItem("reply-one"), roomItem("reply-two")])
        await wait { session.followUpUntil == nil }
        XCTAssertEqual(session.messages.filter { $0.role == .assistant }.count, 2)
        let count = await transport.count()
        XCTAssertEqual(count, 1)
        session.suspend()
        session.resumeAutomatically()
        try await Task.sleep(for: .milliseconds(100))
        let afterWake = await transport.count()
        XCTAssertEqual(afterWake, 1)
        session.suspend()
    }

    func testSuspendedDelayIsRecoveredOnceWithoutRestartingMinute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileConversationStore(url: directory.appendingPathComponent("conversation.json"))
        let transport = RecentTransport()
        let session = ConversationSession(transport: transport, store: store, followUpDelay: 0.05)
        session.resumeAutomatically(); session.send("fixture")
        await wait { session.deliveryState == .answered }
        let due = session.followUpUntil
        session.suspend()
        try await Task.sleep(for: .milliseconds(80))
        let asleep = await transport.count()
        XCTAssertEqual(asleep, 0)
        let restored = ConversationSession(transport: transport, store: store)
        XCTAssertEqual(restored.followUpUntil, due)
        restored.resumeAutomatically()
        await wait { restored.followUpUntil == nil }
        let reads = await transport.count()
        XCTAssertEqual(reads, 1)
        restored.suspend()
    }

    func testCancellationPreventsDelayedRead() async throws {
        let transport = RecentTransport()
        let session = ConversationSession(transport: transport, followUpDelay: 0.03)
        session.resumeAutomatically(); session.send("fixture")
        await wait { session.deliveryState == .answered }
        session.cancel()
        try await Task.sleep(for: .milliseconds(60))
        let reads = await transport.count()
        XCTAssertEqual(reads, 0)
        XCTAssertNil(session.followUpUntil)
        session.suspend()
    }

    func testSuccessfulSyncClearsPersistedBackgroundNoticeAndKeepsDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileConversationStore(url: directory.appendingPathComponent("conversation.json"))
        var snapshot = pending()
        snapshot.awaitingReplies = []
        snapshot.deliveryState = .failed(ConversationSession.backgroundReceptionPendingMessage)
        try store.save(snapshot)
        let transport = RecentTransport()
        await transport.set([roomItem("recovered")])
        let session = ConversationSession(transport: transport, store: store)
        session.resumeAutomatically()
        session.synchronizeRecentMessages()
        await wait { !session.isSynchronizing }
        XCTAssertEqual(session.deliveryState, .idle)
        XCTAssertEqual(session.draft, "draft preserved")
        XCTAssertEqual(try store.load()?.deliveryState, .idle)
        XCTAssertTrue(session.messages.contains { $0.id == DotChatTransport.localID("recovered") })
        session.suspend()
    }

    func testGestureSyncCoalescesPullsAndDoesNotSendMessages() async throws {
        let transport = RecentTransport()
        let session = ConversationSession(transport: transport)
        session.resumeAutomatically()
        await wait { !session.isSynchronizing }
        session.refreshFromGesture()
        session.refreshFromGesture()
        await wait { !session.isSynchronizing }
        let reads = await transport.count()
        XCTAssertEqual(reads, 1)
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(session.deliveryState, .idle)
        session.suspend()
    }

    func testSuccessfulSyncPreservesCancelledPendingTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileConversationStore(url: directory.appendingPathComponent("conversation.json"))
        var snapshot = pending()
        snapshot.deliveryState = .cancelled
        try store.save(snapshot)
        let session = ConversationSession(transport: RecentTransport(), store: store)
        session.resumeAutomatically()
        session.synchronizeRecentMessages()
        await wait { !session.isSynchronizing }
        XCTAssertEqual(session.deliveryState, .cancelled)
        XCTAssertFalse(session.pendingMessageIDs.isEmpty)
        session.suspend()
    }

}
