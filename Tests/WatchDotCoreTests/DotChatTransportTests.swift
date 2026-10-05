import XCTest
@testable import WatchDotCore

private let chatNow = Date(timeIntervalSince1970: 1_800_000_000)
private let chatDot = LocatedDot(name: "Andy fixture", dotID: "dot-fixture", roomID: "room:fixture/path",
                                 accountID: "account-fixture", userID: "user-fixture", dotMemberID: "dot-user-fixture")
private func chatAccount() throws -> SignedInAccount {
    func jwt(_ body: [String: Any]) throws -> String {
        "fixture.\(try JSONSerialization.data(withJSONObject: body).base64URL).fixture"
    }
    let routing = ["chatgpt_account_id": chatDot.accountID, "user_id": chatDot.userID]
    return SignedInAccount(subject: "subject-fixture", clientID: OpenAIOAuthClient.codex, email: nil,
        expiresAt: chatNow.addingTimeInterval(3600),
        idToken: try jwt(["sub": "subject-fixture", "https://api.openai.com/auth": routing]),
        accessToken: try jwt(["exp": chatNow.addingTimeInterval(3600).timeIntervalSince1970,
                             "https://api.openai.com/auth": routing]))
}

private actor ChatHTTP: SignInHTTP {
    var requests: [URLRequest] = []
    var postStatus = 200
    var challenge = false
    var loseAck = false
    var answer = true
    var irrelevantFirst = false
    var changedDot = false
    var malformed = false
    var hideRequest = false
    var requestID = ""
    var text = ""
    var historyCount = 0
    var rejectNextHistory = false
    var failNextHistory = false
    var unthreadedAnswer = false
    var replySuffix = ""
    var replyCreatedAt: String?
    func setReplyCreatedAt(_ value: String?) { replyCreatedAt = value }
    func configure(status: Int = 200, challenge: Bool = false, loseAck: Bool = false,
                   answer: Bool = true, irrelevantFirst: Bool = false, changedDot: Bool = false,
                   malformed: Bool = false, hideRequest: Bool = false) {
        postStatus = status; self.challenge = challenge; self.loseAck = loseAck; self.answer = answer
        self.irrelevantFirst = irrelevantFirst; self.changedDot = changedDot
        self.malformed = malformed; self.hideRequest = hideRequest
    }
    func rejectOneHistoryRead() { rejectNextHistory = true }
    func loseOneHistoryRead() { failNextHistory = true }
    func answerWithoutReplyLink() { unthreadedAnswer = true }
    func uniqueReplies() { replySuffix = "unique" }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let r = try await sendWithMetadata(request); return (r.data, r.status)
    }
    func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse {
        requests.append(request)
        let path = request.url!.absoluteString
        var body: [String: Any]
        var status = 200
        var challenged = false
        if path.hasSuffix("/tbo/primary") {
            body = ["selection": ["available": true, "aeon_id": chatDot.dotID, "messaging_room_id": chatDot.roomID]]
        } else if !path.contains("/messages") {
            body = ["id": chatDot.roomID, "type": "DM", "app_source": "chatgpt:messaging",
                    "aeon_id": changedDot ? "different-dot" : chatDot.dotID,
                    "members": [["account_user_id": chatDot.userID],
                                ["account_user_id": chatDot.dotMemberID, "aeon_id": chatDot.dotID, "name": "Andy fixture"]]]
        } else if request.httpMethod == "POST" {
            let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            requestID = sent["request_id"] as? String ?? ""
            text = (sent["content"] as? [String: Any])?["text"] as? String ?? ""
            if loseAck { loseAck = false; throw URLError(.networkConnectionLost) }
            status = postStatus; challenged = challenge
            body = malformed ? ["private_error": "SECRET-PRIVATE"] : own()
        } else {
            historyCount += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if failNextHistory { failNextHistory = false; throw URLError(.networkConnectionLost) }
            let root = query.first { $0.name == "after" }?.value
            // A reply-thread query contains only the original message in this regression fixture.
            if query.contains(where: { $0.name == "reply_root_message_id" }) {
                return SignInHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["items": [own()]]),
                                          status: 200, contentType: .json, clientChallenge: false)
            }
        // Contract fixture: use a page size of 20.
            if query.first(where: { $0.name == "limit" })?.value != "20" || rejectNextHistory {
                rejectNextHistory = false
                status = 422
                body = ["detail": [["loc": ["query", "limit"], "msg": "PRIVATE-VALIDATION", "input": "PRIVATE"]]]
            } else if root == nil { body = ["items": hideRequest ? [] : [own()]] }
            else if irrelevantFirst && historyCount == 1 {
                body = ["items": [reply(id: "other-member", sender: "stranger", root: "sent-id"),
                                  reply(id: "unrelated", sender: chatDot.dotMemberID, root: "other-turn")]]
            } else {
                var message = reply(id: replySuffix.isEmpty ? "reply-id" : "reply-" + (root ?? ""),
                                    root: root ?? "sent-id")
                if unthreadedAnswer { message.removeValue(forKey: "reply_to") }
                body = ["items": answer ? [message] : []]
            }
        }
        return SignInHTTPResponse(data: try JSONSerialization.data(withJSONObject: body), status: status,
                                  contentType: .json, clientChallenge: challenged)
    }
    private func own() -> [String: Any] {
        ["id": replySuffix.isEmpty ? "sent-id" : "sent-" + requestID, "account_user_id": chatDot.userID, "request_id": requestID, "content": ["text": text]]
    }
    private func reply(id: String = "reply-id", sender: String = chatDot.dotMemberID, root: String = "sent-id") -> [String: Any] {
        var message: [String: Any] = ["id": id, "account_user_id": sender, "content": ["text": "Respuesta fixture"], "reply_to": ["message_id": root]]
        if let replyCreatedAt { message["created_at"] = replyCreatedAt }
        return message
    }
    func captured() -> [URLRequest] { requests }
    func posts() -> Int { requests.filter { $0.httpMethod == "POST" }.count }
}

private actor CapturedDiagnostics {
    var items: [DotProbeDiagnostic] = []
    func append(_ item: DotProbeDiagnostic) { items.append(item) }
    func data() throws -> Data { try JSONEncoder().encode(items) }
}

@MainActor
private final class ChatAccountStore: SignInStore {
    var record: SignInRecord
    init(account: SignedInAccount) { record = SignInRecord(); record.account = account }
    func load() throws -> SignInRecord? { record }
    func save(_ record: SignInRecord) throws { self.record = record }
}

@MainActor
final class DotChatTransportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-dot-chat-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func transport(_ http: ChatHTTP, directory: URL, diagnostics: CapturedDiagnostics = .init()) throws -> DotChatTransport {
        let account = try chatAccount()
        return DotChatTransport(destination: chatDot, http: http, credentials: { account },
            receipts: DotReceiptStore(directory: directory.appendingPathComponent("receipts")),
            onDiagnostic: { await diagnostics.append($0) }, pollInterval: .milliseconds(2), now: { chatNow })
    }
    private func request() -> TurnRequest {
        TurnRequest(conversationID: UUID(), clientTurnID: UUID(), messages: [
            ChatMessage(role: .assistant, text: "Prior local context is not replayed"),
            ChatMessage(role: .user, text: "Mensaje fixture")])
    }
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }
    private func failed(_ session: ConversationSession) -> Bool {
        if case .failed = session.deliveryState { return true }; return false
    }

    func testDirectRoundTripUsesExactRoomOnlyNewTextAndVerifiedAuthorReplyLink() async throws {
        let http = ChatHTTP(); let transport = try transport(http, directory: directory())
        let turn = request()
        let reply = try await transport.send(turn, onAccepted: {})
        XCTAssertEqual(reply.text, "Respuesta fixture")
        XCTAssertEqual(reply.id, DotChatTransport.localID("reply-id"))
        XCTAssertEqual(reply.createdAt, chatNow)
        let calls = await http.captured()
        XCTAssertEqual(calls.map(\.httpMethod), ["GET", "GET", "POST", "GET"])
        let post = try XCTUnwrap(calls.first { $0.httpMethod == "POST" })
        XCTAssertEqual(post.url!.absoluteString, "https://chatgpt.com/backend-api/messaging/rooms/room%3Afixture%2Fpath/messages")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: post.httpBody!) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["content", "request_id", "idempotency_token"])
        XCTAssertEqual(body["request_id"] as? String, turn.clientTurnID.uuidString)
        XCTAssertEqual(body["idempotency_token"] as? String, turn.clientTurnID.uuidString)
        XCTAssertFalse(String(decoding: post.httpBody!, as: UTF8.self).contains("Prior local context"))
        for call in calls {
            XCTAssertEqual(call.url?.host, "chatgpt.com")
            XCTAssertEqual(call.value(forHTTPHeaderField: "originator"), "watch-dot")
            XCTAssertNil(call.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(call.httpShouldHandleCookies)
            XCTAssertEqual(call.value(forHTTPHeaderField: "ChatGPT-Account-Id"), chatDot.accountID)
        }
        // Accidental repeated send of the same turn only reads its persisted receipt.
        _ = try await transport.send(turn, onAccepted: {})
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
    }

    func testReplyUsesServerTimestampInsteadOfTimeItWasFetched() async throws {
        for timestamp in ["2026-10-04T18:30:00Z", "2026-10-04T18:30:00.000Z"] {
            let http = ChatHTTP()
            await http.setReplyCreatedAt(timestamp)
            let reply = try await transport(http, directory: directory()).send(request(), onAccepted: {})
            let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T18:30:00Z"))
            XCTAssertEqual(reply.createdAt, expected)
            XCTAssertNotEqual(reply.createdAt, chatNow)
        }
    }

    func testIgnoresUnrelatedRepliesAndOtherAuthors() async throws {
        let http = ChatHTTP(); await http.configure(irrelevantFirst: true)
        let reply = try await transport(http, directory: directory()).send(request(), onAccepted: {})
        XCTAssertEqual(reply.id, DotChatTransport.localID("reply-id"))
        let calls = await http.captured(); XCTAssertEqual(calls.filter { $0.url!.query != nil }.count, 2)
    }

    func testLostAcknowledgementAndRestartRecoverByRequestIDWithoutPostingAgain() async throws {
        let dir = try directory(); let http = ChatHTTP(); await http.configure(loseAck: true)
        let first = ConversationSession(transport: try transport(http, directory: dir),
                                        store: FileConversationStore(url: dir.appendingPathComponent("chat.json")))
        first.send("Mensaje fixture"); await wait { self.failed(first) }
        XCTAssertTrue(first.canRetry); XCTAssertTrue(first.retryIsReadOnly); XCTAssertFalse(first.canDiscard)
        let reopened = ConversationSession(transport: try transport(http, directory: dir),
                                           store: FileConversationStore(url: dir.appendingPathComponent("chat.json")))
        reopened.retry(); await wait { reopened.deliveryState == .answered }
        XCTAssertEqual(reopened.messages.count, 2)
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
    }

    func testCancellationAndReconnectOnlyResumeReading() async throws {
        let http = ChatHTTP(); await http.configure(answer: false)
        let session = ConversationSession(transport: try transport(http, directory: directory()))
        session.send("Mensaje fixture"); await wait { session.deliveryState == .waiting }
        session.cancel(); XCTAssertEqual(session.deliveryState, .cancelled)
        await http.configure(answer: true)
        session.retry(); session.retry()
        await wait { session.deliveryState == .answered }
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
        XCTAssertEqual(session.messages.count, 2)
    }

    func testTimeoutRetainsReceiptAndReconnectDoesNotReplay() async throws {
        let http = ChatHTTP(); await http.configure(answer: false)
        let session = ConversationSession(transport: try transport(http, directory: directory()), responseTimeout: .milliseconds(30))
        session.send("Mensaje fixture"); await wait { self.failed(session) }
        await http.configure(answer: true)
        session.retry(); await wait { session.deliveryState == .answered }
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
    }

    func testClientChallengeStopsWithoutTryingAttestation() async throws {
        let http = ChatHTTP(); await http.configure(challenge: true)
        let session = ConversationSession(transport: try transport(http, directory: directory()))
        session.send("Mensaje fixture"); await wait { self.failed(session) }
        XCTAssertEqual(session.deliveryState, .failed(DotChatIssue.challenge(200).message))
        XCTAssertFalse(session.canDiscard)
        let calls = await http.captured(); XCTAssertEqual(calls.count, 3)
    }

    func testDefinitiveRejectionAllowsDiscardButConflictDoesNot() async throws {
        for status in [403, 409] {
            let http = ChatHTTP(); await http.configure(status: status)
            let session = ConversationSession(transport: try transport(http, directory: directory()))
            session.send("Mensaje fixture"); await wait { self.failed(session) }
            XCTAssertEqual(session.canDiscard, status == 403)
            XCTAssertEqual(session.retryIsReadOnly, status == 409)
            let calls = await http.captured(); XCTAssertEqual(calls.count, 3)
        }
    }

    func testUnknownDeliveryNotFoundInHistoryNeverResends() async throws {
        let http = ChatHTTP(); await http.configure(loseAck: true, hideRequest: true)
        let session = ConversationSession(transport: try transport(http, directory: directory()))
        session.send("Mensaje fixture"); await wait { self.failed(session) }
        session.retry(); await wait { self.failed(session) }
        XCTAssertEqual(session.deliveryState, .failed(DotChatIssue.unconfirmed.message))
        XCTAssertFalse(session.canDiscard)
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
    }

    func testDestinationChangeStopsBeforePostAndMissingReceiptProvesNoSubmission() async throws {
        let http = ChatHTTP(); await http.configure(changedDot: true)
        let transport = try transport(http, directory: directory())
        let turn = request()
        do { _ = try await transport.send(turn, onAccepted: {}); XCTFail() }
        catch { XCTAssertEqual(error as? ChatTransportError, .direct(.destination)) }
        await http.configure()
        do { _ = try await transport.resume(turn, onAccepted: {}); XCTFail() }
        catch { XCTAssertEqual(error as? ChatTransportError, .direct(.notSubmitted)) }
        let posts = await http.posts(); XCTAssertEqual(posts, 0)
    }

    func testExpiredOrChangedCredentialsStopBeforeNetwork() async throws {
        let http = ChatHTTP(); var transport = try transport(http, directory: directory())
        transport.now = { chatNow.addingTimeInterval(7200) }
        do { _ = try await transport.send(request(), onAccepted: {}); XCTFail() } catch {}
        let calls = await http.captured(); XCTAssertTrue(calls.isEmpty)
    }

    func testVerifiedProbeSelectsDirectChatAndSignOutRevokesIt() async throws {
        let http = ChatHTTP()
        let connection = ConnectionSession(store: ChatAccountStore(account: try chatAccount()), http: http,
            now: { chatNow }, chatDirectory: try directory())
        let demo = ConversationSession(transport: DemoChatTransport())
        XCTAssertNil(connection.directConversation)
        XCTAssertNil(connection.selectedConversation(demo: demo))
        connection.probeDotAccess()
        await wait { connection.directConversation != nil }
        let chat = try XCTUnwrap(connection.directConversation)
        XCTAssertTrue(chat.isRealConnection)
        XCTAssertTrue(connection.selectedConversation(demo: demo) === chat)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(connection.andyConnected) // Read success is not a round trip.
        chat.send("Mensaje fixture")
        await wait { chat.deliveryState == .answered }
        XCTAssertTrue(connection.andyConnected)
        connection.signOutLocally()
        XCTAssertNil(connection.directConversation)
        XCTAssertNil(connection.selectedConversation(demo: demo))
        XCTAssertFalse(connection.andyConnected)
        chat.send("No debe enviarse")
        await wait { self.failed(chat) }
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
    }

    func testHistory422AfterAcceptanceRecoversPersistedTurnWithoutAnotherPost() async throws {
        let dir = try directory(); let http = ChatHTTP()
        await http.rejectOneHistoryRead()
        let url = dir.appendingPathComponent("chat.json")
        let original = ConversationSession(transport: try transport(http, directory: dir), store: FileConversationStore(url: url))
        original.send("Mensaje fixture")
        await wait { self.failed(original) }
        XCTAssertEqual(original.deliveryState, .failed(DotChatIssue.invalidQuery(.limit).message))
        XCTAssertTrue(original.retryIsReadOnly)
        XCTAssertFalse(original.canDiscard)
        let reopened = ConversationSession(transport: try transport(http, directory: dir), store: FileConversationStore(url: url))
        reopened.retry()
        await wait { reopened.deliveryState == .answered }
        XCTAssertEqual(reopened.messages.count, 2)
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
        let queries = await http.captured().filter { $0.url?.query != nil }
        for query in queries {
            let items = URLComponents(url: query.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "limit" }?.value, "20")
            XCTAssertNil(items.first { $0.name == "reply_root_message_id" })
            XCTAssertEqual(items.first { $0.name == "after" }?.value, "sent-id")
        }
    }

    func testAutomaticUnthreadedReplyAndNetworkRecoveryWithoutButtonOrDuplicatePost() async throws {
        let http = ChatHTTP()
        await http.answerWithoutReplyLink()
        await http.loseOneHistoryRead()
        let session = ConversationSession(transport: try transport(http, directory: directory()), recoveryDelay: .milliseconds(5))
        session.resumeAutomatically()
        session.send("Mensaje fixture")
        await wait { session.deliveryState == .answered }
        XCTAssertEqual(session.messages.last?.text, "Respuesta fixture")
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
        let calls = await http.captured()
        XCTAssertFalse(calls.contains { $0.url!.query?.contains("reply_root_message_id") == true })
    }

    func testAcceptedMessageAllowsAnotherSendAndBothRepliesSurviveRestart() async throws {
        let http = ChatHTTP(); await http.configure(answer: false)
        await http.uniqueReplies()
        let dir = try directory(); let url = dir.appendingPathComponent("chat.json")
        let first = ConversationSession(transport: try transport(http, directory: dir), store: FileConversationStore(url: url))
        first.send("primero")
        await wait { first.deliveryState == .waiting }
        XCTAssertTrue(first.canEditDraft)
        XCTAssertTrue(first.canSend)
        XCTAssertTrue(first.send("segundo"))
        await wait { first.canSend }
        XCTAssertEqual(first.pendingMessageIDs.count, 2)
        first.suspend()
        await http.configure(answer: true)
        let restored = ConversationSession(transport: try transport(http, directory: dir), store: FileConversationStore(url: url))
        XCTAssertNil(restored.storageIssue)
        restored.resumeAutomatically()
        await wait { restored.deliveryState == .answered }
        XCTAssertEqual(restored.messages.filter { $0.role == .user }.count, 2)
        XCTAssertEqual(restored.messages.filter { $0.role == .assistant }.count, 2)
        let posts = await http.posts(); XCTAssertEqual(posts, 2)
    }

    func testTwoReadersOfSameRoomReplyDisplayItOnlyOnce() async throws {
        let http = ChatHTTP(); await http.configure(answer: false)
        let session = ConversationSession(transport: try transport(http, directory: directory()))
        session.send("uno"); await wait { session.canSend }
        session.send("dos"); await wait { session.canSend }
        await http.configure(answer: true)
        await wait { session.deliveryState == .answered }
        XCTAssertEqual(session.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(session.pendingMessageIDs.isEmpty)
    }

    func testCancellationAndBackgroundStopAutomaticReadsUntilForegroundResumes() async throws {
        let http = ChatHTTP(); await http.configure(answer: false)
        let session = ConversationSession(transport: try transport(http, directory: directory()), recoveryDelay: .milliseconds(5))
        session.resumeAutomatically()
        session.send("Mensaje fixture"); await wait { session.canSend }
        session.suspend()
        // A request already dispatched can reach the mock after cancellation. Drain it,
        // then verify that no new polling starts while the app is in the background.
        try await Task.sleep(for: .milliseconds(10))
        let before = await http.captured().count
        try await Task.sleep(for: .milliseconds(15))
        let after = await http.captured().count
        XCTAssertEqual(before, after)
        session.resumeAutomatically()
        session.cancel()
        await http.configure(answer: true)
        session.resumeAutomatically()
        XCTAssertEqual(session.deliveryState, .cancelled)
        session.retry()
        await wait { session.deliveryState == .answered }
        let posts = await http.posts(); XCTAssertEqual(posts, 1)
    }

    func testValidationErrorOnlyExposesKnownQueryParameter() {
        let valid = Data(#"{"detail":[{"loc":["query","reply_root_message_id"],"msg":"PRIVATE","input":"PRIVATE","ctx":{"secret":"PRIVATE"}}]}"#.utf8)
        XCTAssertEqual(DotChatTransport.invalidQueryParameter(valid), .replyRoot)
        XCTAssertFalse(DotChatIssue.invalidQuery(.replyRoot).message.contains("PRIVATE"))
        for body in [#"{"detail":[{"loc":["query","PRIVATE"]}]}"#,
                     #"{"detail":[{"loc":["body","limit"]}]}"#, #"{"detail":"PRIVATE"}"#] {
            XCTAssertNil(DotChatTransport.invalidQueryParameter(Data(body.utf8)))
        }
    }

    func testDemoRequiresExplicitSelectionAndDisablingItNeverFallsBack() throws {
        let connection = ConnectionSession(store: ChatAccountStore(account: try chatAccount()), http: ChatHTTP(),
                                           now: { chatNow }, chatDirectory: try directory())
        let demo = ConversationSession(transport: DemoChatTransport())
        XCTAssertFalse(connection.demoEnabled)
        XCTAssertNil(connection.selectedConversation(demo: demo))
        connection.selectDemo(true)
        XCTAssertTrue(connection.selectedConversation(demo: demo) === demo)
        connection.selectDemo(false)
        XCTAssertNil(connection.selectedConversation(demo: demo))
        XCTAssertEqual(connection.chatBlockReason, "Falta verificar la sala de Andy.")
    }

    func testExpiryBlocksChatInsteadOfSelectingDemoAndExposesReauthorization() async throws {
        var now = chatNow
        let store = ChatAccountStore(account: try chatAccount())
        let connection = ConnectionSession(store: store, http: ChatHTTP(), now: { now },
                                           chatDirectory: try directory(), companion: AuthLinkStub())
        let demo = ConversationSession(transport: DemoChatTransport())
        connection.probeDotAccess()
        await wait { connection.directConversation != nil }
        now = chatNow.addingTimeInterval(7200)
        connection.refresh()
        XCTAssertEqual(connection.phase, .expired)
        XCTAssertEqual(connection.chatBlockReason, "Sesión expirada")
        XCTAssertEqual(connection.actionTitle, "Volver a autorizar")
        XCTAssertNil(connection.selectedConversation(demo: demo))
        XCTAssertFalse(connection.demoEnabled)
    }

    func testUnreadableReceiptStopsBeforePost() async throws {
        let dir = try directory(); let http = ChatHTTP(); let turn = request()
        let receipts = dir.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try Data("corrupted".utf8).write(to: receipts.appendingPathComponent(turn.clientTurnID.uuidString + ".json"))
        do { _ = try await transport(http, directory: dir).send(turn, onAccepted: {}); XCTFail() }
        catch { XCTAssertEqual(error as? ChatTransportError, .direct(.storage)) }
        let calls = await http.captured(); XCTAssertTrue(calls.isEmpty)
    }

    func testDiagnosticsNeverIncludeMessagesIDsOrTokensEvenOnInvalidResponse() async throws {
        let http = ChatHTTP(); await http.configure(malformed: true)
        let logs = CapturedDiagnostics()
        do { _ = try await transport(http, directory: directory(), diagnostics: logs).send(request(), onAccepted: {}); XCTFail() }
        catch { XCTAssertEqual(error as? ChatTransportError, .direct(.schema)) }
        let json = String(decoding: try await logs.data(), as: UTF8.self)
        for value in ["SECRET-PRIVATE", "Mensaje fixture", "account-fixture", "sent-id", "Bearer", "fixture."] {
            XCTAssertFalse(json.contains(value))
        }
        XCTAssertTrue(json.contains("send"))
        let response = SignInHTTPResponse(data: Data(#"{"items":[{"id":"PRIVATE","content":{"text":"PRIVATE"},"reply_to":{"message_id":"PRIVATE"}}]}"#.utf8), status: 200, contentType: .json, clientChallenge: false)
        let diagnostic = DotProbeDiagnostic(stage: .history, response: response)
        XCTAssertEqual(diagnostic.fields["items.0.content.text"], .string)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains("PRIVATE"))
    }
}
