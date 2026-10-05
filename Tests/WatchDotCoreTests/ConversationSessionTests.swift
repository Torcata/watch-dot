import XCTest
@testable import WatchDotCore

private actor RecordingTransport: ChatTransport {
    let displayName = "Mock"
    let isRealConnection: Bool
    let supportsIdempotentRetry: Bool
    private var requests: [TurnRequest] = []
    private var replies: [UUID: ChatMessage] = [:]
    private var effects = 0
    private var error: ChatTransportError?
    private var delay: Duration = .zero
    private var loseFirstReply = false
    private var invalidRole = false

    init(real: Bool = false, idempotent: Bool = true) {
        isRealConnection = real
        supportsIdempotentRetry = idempotent
    }
    func configure(error: ChatTransportError? = nil, delay: Duration = .zero,
                   loseFirstReply: Bool = false, invalidRole: Bool = false) {
        self.error = error
        self.delay = delay
        self.loseFirstReply = loseFirstReply
        self.invalidRole = invalidRole
    }
    func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        requests.append(request)
        if let error { throw error }
        await onAccepted()
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if let reply = replies[request.clientTurnID] { return reply }
        effects += 1
        let reply = ChatMessage(role: invalidRole ? .user : .assistant, text: "respuesta")
        replies[request.clientTurnID] = reply
        if loseFirstReply { throw ChatTransportError.unavailable }
        return reply
    }
    func recordedRequests() -> [TurnRequest] { requests }
    func effectCount() -> Int { effects }
    func reply(for id: UUID) -> ChatMessage? { replies[id] }
}

/// Deliberately ignores cancellation, as a remote service can still finish after disconnection.
private actor LateTransport: ChatTransport {
    let displayName = "Late mock"
    let isRealConnection = false
    let supportsIdempotentRetry = true
    private var completions: [CheckedContinuation<ChatMessage, Never>] = []
    func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        await onAccepted()
        return await withCheckedContinuation { completions.append($0) }
    }
    func count() -> Int { completions.count }
    func completeFirst() { completions.removeFirst().resume(returning: ChatMessage(role: .assistant, text: "tardía")) }
}

@MainActor
private final class MemoryStore: ConversationStore {
    var snapshot: ConversationSnapshot?
    var failSave = false
    func load() throws -> ConversationSnapshot? { snapshot }
    func save(_ snapshot: ConversationSnapshot) throws {
        if failSave { throw CocoaError(.fileWriteOutOfSpace) }
        self.snapshot = snapshot
    }
}

@MainActor
final class ConversationSessionTests: XCTestCase {
    func testBlankMessagesAreIgnoredAndRepliesStayInSameConversation() async {
        let transport = RecordingTransport()
        let id = UUID()
        let session = ConversationSession(transport: transport, conversationID: id)
        XCTAssertFalse(session.send(" \n"))
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertTrue(session.send(" Hola Andy "))
        await waitUntil { session.deliveryState == .answered }
        session.send("continúa")
        await waitUntil { session.deliveryState == .answered }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.conversationID), [id, id])
        XCTAssertEqual(requests[1].messages.count, 3)
        XCTAssertEqual(session.messages.first?.text, "Hola Andy")
        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertFalse(session.isRealConnection)
    }

    func testSendWhileInFlightDoesNotCreateDuplicateTurnAndWaitsForAck() async {
        let transport = RecordingTransport()
        await transport.configure(delay: .milliseconds(100))
        let session = ConversationSession(transport: transport)
        session.send("primero")
        XCTAssertEqual(session.deliveryState, .sending)
        XCTAssertFalse(session.send("duplicado"))
        await waitUntil { session.deliveryState == .waiting }
        await waitUntil { session.deliveryState == .answered }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(session.messages.count, 2)
    }

    func testRetryReusesSameIdempotencyKeyAndDoesNotAppendUserMessageAgain() async {
        let transport = RecordingTransport()
        await transport.configure(error: .unavailable)
        let session = ConversationSession(transport: transport)
        session.send("¿sigues ahí?")
        await waitUntil { self.isFailed(session) }
        await transport.configure()
        session.retry()
        session.retry()
        await waitUntil { session.deliveryState == .answered }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(session.messages.filter { $0.role == .user }.count, 1)
    }

    func testLostReplyAfterServerAcceptanceDoesNotRepeatRemoteEffect() async {
        let transport = RecordingTransport()
        await transport.configure(loseFirstReply: true)
        let session = ConversationSession(transport: transport)
        session.send("anota una tarea")
        await waitUntil { self.isFailed(session) }
        session.retry()
        await waitUntil { session.deliveryState == .answered }
        let effects = await transport.effectCount()
        let request = await transport.recordedRequests()[0]
        let remoteReply = await transport.reply(for: request.clientTurnID)
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(session.messages.last, remoteReply) // preserve remote ID and date
    }

    func testCancelKeepsPendingMessageAndIgnoresLateReply() async {
        let transport = LateTransport()
        let session = ConversationSession(transport: transport)
        session.send("cancelar espera")
        await waitForRequest(transport)
        session.cancel()
        XCTAssertEqual(session.deliveryState, .cancelled)
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertFalse(session.canSend)
        await transport.completeFirst()
        await Task.yield()
        XCTAssertEqual(session.messages.count, 1)
        session.discardFailedTurn()
        XCTAssertTrue(session.canSend)
    }

    func testLateReplyFromCancelledTurnDoesNotCompleteNewTurn() async {
        let transport = LateTransport()
        let session = ConversationSession(transport: transport)
        session.send("primero")
        await waitForRequest(transport)
        session.cancel()
        session.discardFailedTurn()
        session.send("segundo")
        await transport.completeFirst()
        await waitForRequest(transport)
        XCTAssertEqual(session.messages.map(\.text), ["segundo"])
        await transport.completeFirst()
        await waitUntil { session.deliveryState == .answered }
        XCTAssertEqual(session.messages.count, 2)
    }

    func testOfflineQueueAndReconnectRequireExplicitRetry() async {
        let transport = RecordingTransport()
        let session = ConversationSession(transport: transport)
        session.setNetworkAvailable(false)
        session.send("pendiente")
        XCTAssertEqual(session.deliveryState, .waitingForConnection)
        var requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        session.setNetworkAvailable(true)
        XCTAssertTrue(isFailed(session))
        requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        session.retry()
        await waitUntil { session.deliveryState == .answered }
        XCTAssertEqual(session.messages.count, 2)
    }

    func testDisconnectWhileWaitingIgnoresOldCompletionAndReusesTurn() async {
        let transport = RecordingTransport()
        await transport.configure(delay: .seconds(1))
        let session = ConversationSession(transport: transport)
        session.send("corte")
        await waitUntil { session.deliveryState == .waiting }
        session.setNetworkAvailable(false)
        XCTAssertEqual(session.deliveryState, .waitingForConnection)
        await transport.configure()
        session.setNetworkAvailable(true)
        session.retry()
        await waitUntil { session.deliveryState == .answered }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(session.messages.count, 2)
    }

    func testTimeoutAndRetryKeepOriginalTurn() async {
        let transport = RecordingTransport()
        await transport.configure(delay: .seconds(1))
        let session = ConversationSession(transport: transport, responseTimeout: .milliseconds(30))
        session.send("lento")
        await waitUntil { self.isFailed(session) }
        XCTAssertEqual(session.deliveryState, .failed(ChatTransportError.timedOut.userMessage))
        await transport.configure()
        session.retry()
        await waitUntil { session.deliveryState == .answered }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests[0], requests[1])
    }

    func testRelaunchRestoresPendingIdentityAndNeverSendsAutomatically() async {
        let store = MemoryStore()
        let transport = RecordingTransport()
        await transport.configure(delay: .seconds(1))
        let first = ConversationSession(transport: transport, store: store)
        first.send("recordatorio pendiente")
        await waitUntil { first.deliveryState == .waiting }
        first.suspend()
        let second = ConversationSession(transport: transport, store: store)
        XCTAssertEqual(first.conversationID, second.conversationID)
        XCTAssertEqual(first.messages, second.messages)
        let before = await transport.recordedRequests()
        XCTAssertEqual(before.count, 1)
        await transport.configure()
        second.retry()
        await waitUntil { second.deliveryState == .answered }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests[0], requests[1])
    }

    func testFileStorePersistsDraftHistoryAndConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileConversationStore(url: directory.appendingPathComponent("demo.json"))
        let transport = RecordingTransport()
        let first = ConversationSession(transport: transport, store: store)
        first.send("hola")
        await waitUntil { first.deliveryState == .answered }
        first.draft = "borrador"
        let second = ConversationSession(transport: transport, store: store)
        XCTAssertEqual(first.conversationID, second.conversationID)
        XCTAssertEqual(first.messages, second.messages)
        XCTAssertEqual(second.draft, "borrador")
        XCTAssertEqual(second.deliveryState, .answered)
    }

    func testCorruptStoreIsPreservedAndBlocksSending() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: url)
        let session = ConversationSession(transport: RecordingTransport(), store: FileConversationStore(url: url))
        XCTAssertNotNil(session.storageIssue)
        XCTAssertFalse(session.send("no enviar"))
        session.draft = "no sobrescribir"
        session.retrySaving()
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testSaveFailureBlocksTransmissionUntilPersistenceWorks() async {
        let store = MemoryStore()
        store.failSave = true
        let transport = RecordingTransport()
        let session = ConversationSession(transport: transport, store: store)
        session.send("guardar antes de enviar")
        XCTAssertNotNil(session.storageIssue)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        store.failSave = false
        session.retrySaving()
        session.retry()
        await waitUntil { session.deliveryState == .answered }
    }

    func testRealTransportWithoutDedupCannotRetryOrDiscardUncertainDelivery() async {
        let transport = RecordingTransport(real: true, idempotent: false)
        await transport.configure(error: .unavailable)
        let session = ConversationSession(transport: transport)
        session.send("crear tarea")
        await waitUntil { self.isFailed(session) }
        XCTAssertFalse(session.canRetry)
        XCTAssertFalse(session.canDiscard)
        session.retry()
        session.discardFailedTurn()
        XCTAssertEqual(session.messages.count, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testCrashBeforeTransmissionRecoversPendingTurnEvenFromIdleState() {
        let store = MemoryStore()
        let id = UUID()
        let messages = [ChatMessage(role: .user, text: "pendiente")]
        let request = TurnRequest(conversationID: id, clientTurnID: UUID(), messages: messages)
        store.snapshot = ConversationSnapshot(version: 1, conversationID: id, messages: messages,
            pendingRequest: request, hasAttemptedDelivery: false, deliveryState: .idle, draft: "")
        let session = ConversationSession(transport: RecordingTransport(), store: store)
        XCTAssertTrue(isFailed(session))
        XCTAssertTrue(session.canRetry)
        XCTAssertEqual(session.messages, messages)
    }

    func testFailedLocalSaveDoesNotMarkUnsentRealRequestAsDelivered() async {
        let store = MemoryStore()
        store.failSave = true
        let transport = RecordingTransport(real: true, idempotent: false)
        let session = ConversationSession(transport: transport, store: store)
        session.send("sin enviar")
        store.failSave = false
        session.retrySaving()
        XCTAssertTrue(session.canRetry)
        XCTAssertTrue(session.canDiscard)
        session.retry()
        await waitUntil { session.deliveryState == .answered }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testSavingReceivedReplyAgainDoesNotResendRequest() async {
        let store = MemoryStore()
        let transport = RecordingTransport()
        await transport.configure(delay: .milliseconds(60))
        let session = ConversationSession(transport: transport, store: store)
        session.send("respuesta antes de fallo de disco")
        await waitUntil { session.deliveryState == .waiting }
        store.failSave = true
        await waitUntil { session.deliveryState == .answered }
        XCTAssertNotNil(session.storageIssue)
        XCTAssertFalse(session.canSend)
        store.failSave = false
        session.retrySaving()
        XCTAssertTrue(session.canSend)
        XCTAssertEqual(store.snapshot?.messages.count, 2)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testRejectionDoesNotExposeRawServerPayload() async {
        let transport = RecordingTransport()
        await transport.configure(error: .rejected("private server payload"))
        let session = ConversationSession(transport: transport)
        session.send("hola")
        await waitUntil { self.isFailed(session) }
        XCTAssertEqual(session.deliveryState, .failed("El servicio rechazó la solicitud."))
    }

    func testInvalidReplyDoesNotBecomeAssistantConfirmation() async {
        let transport = RecordingTransport()
        await transport.configure(invalidRole: true)
        let session = ConversationSession(transport: transport)
        session.send("tarea")
        await waitUntil { self.isFailed(session) }
        XCTAssertEqual(session.deliveryState, .failed(ChatTransportError.invalidResponse.userMessage))
        XCTAssertEqual(session.messages.count, 1)
    }

    func testDemoNeverClaimsToCreateTaskOrReminder() async throws {
        let demo = DemoChatTransport()
        let request = TurnRequest(conversationID: UUID(), clientTurnID: UUID(),
                                  messages: [ChatMessage(role: .user, text: "recuérdame mañana")])
        let reply = try await demo.send(request, onAccepted: {})
        XCTAssertFalse(demo.isRealConnection)
        XCTAssertTrue(reply.text.contains("No se envió a Andy"))
        XCTAssertEqual(reply.id, request.clientTurnID)
    }

    private func isFailed(_ session: ConversationSession) -> Bool {
        if case .failed = session.deliveryState { return true }
        return false
    }
    private func waitUntil(condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Timed out waiting for session")
    }
    private func waitForRequest(_ transport: LateTransport) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while await transport.count() == 0 && ContinuousClock.now < deadline { await Task.yield() }
        let count = await transport.count()
        XCTAssertGreaterThan(count, 0)
    }
}
