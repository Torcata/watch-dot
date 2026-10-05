import Foundation
import Combine

/// Arms while pulling, but requests a single refresh only when the finger is released.
public struct MessageRefreshGestureState: Equatable {
    public private(set) var isTracking = false
    public private(set) var isArmed = false
    public private(set) var pullDistance: Double = 0
    private var threshold: Double = 28

    public init() {}

    public mutating func begin(enabled: Bool, threshold: Double = 28) {
        cancel()
        isTracking = enabled
        self.threshold = threshold
    }

    public mutating func update(distance: Double) {
        guard isTracking else { return }
        pullDistance = max(0, distance)
        // Keep the gesture armed across the native bounce as the finger is lifted.
        if pullDistance >= threshold { isArmed = true }
    }

    public mutating func release() -> Bool {
        let shouldRefresh = isTracking && isArmed
        cancel()
        return shouldRefresh
    }

    public mutating func cancel() {
        isTracking = false
        isArmed = false
        pullDistance = 0
    }
}

public enum MessageRole: String, Sendable, Codable {
    case user, assistant
}

public struct ChatMessage: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let role: MessageRole
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), role: MessageRole, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    public func timestampLabel(relativeTo now: Date = .now, calendar: Calendar = .current,
                               locale: Locale = .current) -> String {
        let time = createdAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
            locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        guard calendar.startOfDay(for: createdAt) < calendar.startOfDay(for: now) else { return time }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM-dd"
        let day = formatter.string(from: createdAt).lowercased().replacingOccurrences(of: ".", with: "")
        return "\(day) \(time)"
    }
}

public struct TurnRequest: Sendable, Equatable, Codable {
    public let conversationID: UUID
    public let clientTurnID: UUID
    public let messages: [ChatMessage]

    public init(conversationID: UUID, clientTurnID: UUID, messages: [ChatMessage]) {
        self.conversationID = conversationID
        self.clientTurnID = clientTurnID
        self.messages = messages
    }
}

public enum ChatTransportError: Error, Sendable, Equatable {
    case unavailable, timedOut, authenticationRequired, invalidResponse
    case rejected(String)
    case direct(DotChatIssue)

    public var userMessage: String {
        switch self {
        case .unavailable: "Conexión interrumpida. El mensaje podría haber llegado."
        case .timedOut: "Sin respuesta a tiempo. El mensaje podría haber llegado."
        case .authenticationRequired: "Debes volver a autorizar la conexión."
        case .invalidResponse: "La respuesta no es válida para este turno."
        case .rejected: "El servicio rechazó la solicitud."
        case .direct(let issue): issue.message
        }
    }
}

/// Only enable retries after verifying server-side deduplication by conversation + clientTurnID.
/// `onAccepted` must mean the destination acknowledged this turn, not just local transmission.
/// A real adapter must validate account, Andy identity, remote conversation and reply correlation.
public protocol ChatTransport: Sendable {
    var displayName: String { get }
    var isRealConnection: Bool { get }
    var supportsIdempotentRetry: Bool { get }
    var supportsReadOnlyResume: Bool { get }
    var allowsSendingWhileAwaitingReply: Bool { get }
    var supportsHistorySync: Bool { get }
    func recentMessages(limit: Int) async throws -> [RoomMessage]
    func additionalMessages() async throws -> [RoomMessage]
    func resume(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage
    func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage
}

public extension ChatTransport {
    var supportsIdempotentRetry: Bool { false }
    var supportsReadOnlyResume: Bool { false }
    var allowsSendingWhileAwaitingReply: Bool { false }
    var supportsHistorySync: Bool { false }
    func recentMessages(limit: Int) async throws -> [RoomMessage] { [] }
    func additionalMessages() async throws -> [RoomMessage] { try await recentMessages(limit: 20) }
    func resume(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        throw ChatTransportError.invalidResponse
    }
}

public enum DeliveryState: Sendable, Equatable, Codable {
    case idle, sending, waiting, waitingForConnection, answered, cancelled
    case failed(String)

    public var isActive: Bool { self == .sending || self == .waiting }
}

public struct ConversationSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let conversationID: UUID
    public let messages: [ChatMessage]
    public let pendingRequest: TurnRequest?
    public let hasAttemptedDelivery: Bool
    public var deliveryState: DeliveryState
    public let draft: String
    public var awaitingReplies: [TurnRequest]? = nil
    public var followUpUntil: Date? = nil
    public var outgoingMessageIDs: [UUID: UUID]? = nil
}

@MainActor
public protocol ConversationStore {
    func load() throws -> ConversationSnapshot?
    func save(_ snapshot: ConversationSnapshot) throws
}

/// Local chat cache only: no task database, tokens or account credentials.
@MainActor
public final class FileConversationStore: ConversationStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> ConversationSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(ConversationSnapshot.self, from: Data(contentsOf: url))
        let pending = (snapshot.awaitingReplies ?? []) + (snapshot.pendingRequest.map { [$0] } ?? [])
        guard snapshot.version == 1,
              Set(snapshot.messages.map(\.id)).count == snapshot.messages.count,
              Set(pending.map(\.clientTurnID)).count == pending.count,
              pending.allSatisfy({ request in
                  request.conversationID == snapshot.conversationID && request.messages.last?.role == .user &&
                  !request.messages.isEmpty && snapshot.messages.contains(where: {
                      $0.id == request.messages.last?.id && $0.role == .user && $0.text == request.messages.last?.text
                  })
              }) else { throw ChatTransportError.invalidResponse }
        return snapshot
    }

    public func save(_ snapshot: ConversationSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        #if os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

@MainActor
public final class ConversationSession: ObservableObject {
    public static let backgroundReceptionPendingMessage = "Recepción pendiente. Se sincronizará al volver al chat."
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var deliveryState: DeliveryState = .idle
    @Published public private(set) var showsCancellationNotice = false
    @Published public private(set) var storageIssue: String?
    @Published public private(set) var networkAvailable = true
    @Published public private(set) var isSynchronizing = false
    @Published public private(set) var synchronizationIssue: String?
    @Published public private(set) var followUpUntil: Date?
    @Published public var draft = "" { didSet { _ = persist() } }

    public private(set) var conversationID: UUID
    public let transportName: String
    public let isRealConnection: Bool
    public var pendingMessageID: UUID? { pendingRequest?.messages.last?.id ?? awaitingReplies.first?.messages.last?.id }
    public var pendingMessageIDs: Set<UUID> {
        Set((awaitingReplies + (pendingRequest.map { [$0] } ?? [])).compactMap { $0.messages.last?.id })
    }
    public var canEditDraft: Bool { storageIssue == nil }
    public var canSend: Bool { pendingRequest == nil && storageIssue == nil }
    public var canRetry: Bool {
        storageIssue == nil && !deliveryState.isActive &&
        ((!awaitingReplies.isEmpty && transport.supportsReadOnlyResume) ||
         (pendingRequest != nil && (!hasAttemptedDelivery || transport.supportsIdempotentRetry || transport.supportsReadOnlyResume)))
    }
    public var retryIsReadOnly: Bool {
        (hasAttemptedDelivery || !awaitingReplies.isEmpty) && transport.supportsReadOnlyResume && !transport.supportsIdempotentRetry
    }
    // Once a real request might have arrived, dropping it could cause duplicate tasks on a new send.
    public var canDiscard: Bool { pendingRequest != nil && (!isRealConnection || !hasAttemptedDelivery) }

    private let transport: any ChatTransport
    private let store: (any ConversationStore)?
    private let responseTimeout: Duration
    private var pendingRequest: TurnRequest?
    private var hasAttemptedDelivery = false
    private var loadFailed = false
    private var attemptID: UUID?
    private var sendTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cancellationNoticeTask: Task<Void, Never>?
    private var awaitingReplies: [TurnRequest] = []
    private struct ReplyOperation {
        let request: TurnRequest
        var task: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }
    private var replyOperations: [UUID: ReplyOperation] = [:]
    private var automaticRetry: Task<Void, Never>?
    private var foreground = false
    private var readsPaused = false
    private let recoveryDelay: Duration
    private var outgoingMessageIDs: [UUID: UUID] = [:]
    private var syncTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?
    private let now: () -> Date
    private let followUpDelay: TimeInterval

    public init(transport: any ChatTransport, conversationID: UUID = UUID(),
                store: (any ConversationStore)? = nil, responseTimeout: Duration = .seconds(45),
                recoveryDelay: Duration = .seconds(30), now: @escaping () -> Date = Date.init,
                followUpDelay: TimeInterval = 60) {
        self.transport = transport
        self.conversationID = conversationID
        self.transportName = transport.displayName
        self.isRealConnection = transport.isRealConnection
        self.store = store
        self.responseTimeout = responseTimeout
        self.recoveryDelay = recoveryDelay
        self.now = now
        self.followUpDelay = followUpDelay
        do {
            if let saved = try store?.load() {
                self.conversationID = saved.conversationID
                messages = saved.messages
                pendingRequest = saved.pendingRequest
                awaitingReplies = saved.awaitingReplies ?? []
                followUpUntil = saved.followUpUntil
                outgoingMessageIDs = saved.outgoingMessageIDs ?? [:]
                for turn in saved.pendingTurns { outgoingMessageIDs[turn.clientTurnID] = turn.messages.last?.id }
                hasAttemptedDelivery = saved.hasAttemptedDelivery
                deliveryState = saved.deliveryState
                draft = saved.draft
                if pendingRequest != nil || !awaitingReplies.isEmpty {
                    switch deliveryState {
                    case .failed, .cancelled: break
                    default: deliveryState = .failed("Turno pendiente recuperado. Reanuda para comprobar su respuesta.")
                    }
                }
            }
        } catch {
            loadFailed = true
            storageIssue = "No se pudo leer el historial. Se conserva el archivo; vuelve a abrir la app."
        }
    }

    @discardableResult
    public func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend else { return false }
        readsPaused = false
        messages.append(ChatMessage(role: .user, text: trimmed))
        pendingRequest = TurnRequest(conversationID: conversationID, clientTurnID: UUID(), messages: messages)
        outgoingMessageIDs[pendingRequest!.clientTurnID] = messages.last!.id
        hasAttemptedDelivery = false
        draft = ""
        beginSend()
        return true
    }

    public func retry() {
        guard canRetry else { return }
        readsPaused = false
        if pendingRequest != nil { beginSend() }
        resumeAcceptedReplies()
    }

    /// Foreground-only recovery: this method never starts a new POST.
    public func resumeAutomatically() {
        foreground = true
        resumeFollowUp()
        guard transport.supportsReadOnlyResume, !readsPaused, deliveryState != .cancelled,
              storageIssue == nil else { return }
        if pendingRequest != nil, hasAttemptedDelivery, attemptID == nil { beginSend() }
        resumeAcceptedReplies()
    }

    private func resumeAcceptedReplies() {
        for request in awaitingReplies where !replyOperations.values.contains(where: { $0.request.clientTurnID == request.clientTurnID }) {
            let generation = UUID()
            let task = Task { [weak self, transport] in
                do {
                    let answer = try await transport.resume(request, onAccepted: {})
                    guard !Task.isCancelled else { return }
                    self?.finish(answer, generation: generation)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error, generation: generation)
                }
            }
            let timeout = Task { [weak self, responseTimeout] in
                do { try await Task.sleep(for: responseTimeout) } catch { return }
                self?.fail(ChatTransportError.timedOut, generation: generation)
            }
            replyOperations[generation] = ReplyOperation(request: request, task: task, timeout: timeout)
        }
        if !replyOperations.isEmpty, pendingRequest == nil { deliveryState = .waiting }
    }

    private func stopReplyOperations() {
        for operation in replyOperations.values { operation.task?.cancel(); operation.timeout?.cancel() }
        replyOperations = [:]
        automaticRetry?.cancel()
        automaticRetry = nil
    }

    private func scheduleReadRecovery(_ error: Error) {
        guard foreground, !readsPaused, transport.supportsReadOnlyResume, storageIssue == nil else { return }
        let transient: Bool
        switch error {
        case ChatTransportError.unavailable, ChatTransportError.timedOut: transient = true
        case ChatTransportError.direct(.http(let status)), ChatTransportError.direct(.replyHTTP(let status)):
            transient = status == 429 || (500..<600).contains(status)
        default: transient = false
        }
        guard transient, automaticRetry == nil else { return }
        automaticRetry = Task { [weak self, recoveryDelay] in
            do { try await Task.sleep(for: recoveryDelay) } catch { return }
            guard let self, self.foreground, !self.readsPaused else { return }
            self.automaticRetry = nil
            self.resumeAutomatically()
        }
    }

    /// Stops local waiting. It does not promise to cancel work already accepted remotely.
    public func cancel() {
        guard deliveryState.isActive || deliveryState == .waitingForConnection || followUpUntil != nil else { return }
        readsPaused = true
        followUpUntil = nil
        followUpTask?.cancel(); followUpTask = nil
        stopReplyOperations()
        invalidateAttempt()
        deliveryState = .cancelled
        // Transient presentation only: keep cancellation and pending requests intact.
        // This notice is not persisted, so reopening a saved chat cannot revive it.
        cancellationNoticeTask?.cancel()
        showsCancellationNotice = true
        cancellationNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.showsCancellationNotice = false
            self?.cancellationNoticeTask = nil
        }
        _ = persist()
    }

    public func suspend() {
        foreground = false
        syncTask?.cancel(); syncTask = nil; isSynchronizing = false
        followUpTask?.cancel(); followUpTask = nil
        stopReplyOperations()
        guard deliveryState.isActive else { return }
        invalidateAttempt()
        deliveryState = .failed("Espera pausada. Se retomará al abrir el chat.")
        _ = persist()
    }

    public func discardFailedTurn() {
        guard canDiscard, !deliveryState.isActive else { return }
        invalidateAttempt()
        // A demo or provably unsent message may be removed; real uncertain turns stay pending.
        if let id = pendingMessageID { messages.removeAll { $0.id == id } }
        pendingRequest = nil
        hasAttemptedDelivery = false
        deliveryState = .idle
        _ = persist()
    }

    public func setNetworkAvailable(_ available: Bool) {
        guard available != networkAvailable else { return }
        networkAvailable = available
        if !available && deliveryState.isActive {
            invalidateAttempt()
            deliveryState = .waitingForConnection
            _ = persist()
        } else if available && deliveryState == .waitingForConnection {
            // Explicit retry: reconnecting never silently replays a task/reminder request.
            deliveryState = .failed("Conexión recuperada. Reanuda el mismo mensaje.")
            _ = persist()
        }
    }

    public func retrySaving() { _ = persist() }

    private func beginSend() {
        guard let request = pendingRequest else { return }
        guard networkAvailable else {
            deliveryState = .waitingForConnection
            _ = persist()
            return
        }
        invalidateAttempt()
        deliveryState = .sending
        // Persist the same id BEFORE transmission, including possible delivery after a crash.
        let previouslyAttempted = hasAttemptedDelivery
        hasAttemptedDelivery = true
        guard persist() else {
            hasAttemptedDelivery = previouslyAttempted
            deliveryState = .failed("Guarda el historial antes de reanudar.")
            return
        }
        let generation = UUID()
        attemptID = generation
        sendTask = Task { [weak self, transport] in
            do {
                let accepted: @Sendable () async -> Void = { [weak self] in
                    await self?.accepted(generation)
                }
                let answer: ChatMessage
                if previouslyAttempted && transport.supportsReadOnlyResume && !transport.supportsIdempotentRetry {
                    answer = try await transport.resume(request, onAccepted: accepted)
                } else {
                    answer = try await transport.send(request, onAccepted: accepted)
                }
                guard !Task.isCancelled else { return }
                self?.finish(answer, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error, generation: generation)
            }
        }
        timeoutTask = Task { [weak self, responseTimeout] in
            do { try await Task.sleep(for: responseTimeout) } catch { return }
            self?.fail(ChatTransportError.timedOut, generation: generation)
        }
    }

    private func accepted(_ generation: UUID) {
        guard attemptID == generation else { return }
        deliveryState = .waiting
        if transport.allowsSendingWhileAwaitingReply, let request = pendingRequest {
            awaitingReplies.append(request)
            replyOperations[generation] = ReplyOperation(request: request, task: sendTask, timeout: timeoutTask)
            pendingRequest = nil
            hasAttemptedDelivery = false
            attemptID = nil
            sendTask = nil
            timeoutTask = nil
        }
        _ = persist()
    }

    private func finish(_ answer: ChatMessage, generation: UUID) {
        if let operation = replyOperations[generation] {
            guard answer.role == .assistant, !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail(ChatTransportError.invalidResponse, generation: generation)
                return
            }
            operation.task?.cancel(); operation.timeout?.cancel()
            replyOperations[generation] = nil
            awaitingReplies.removeAll { $0.clientTurnID == operation.request.clientTurnID }
            // Multiple accepted inputs can observe the same later room message. Show it once.
            if !messages.contains(where: { $0.id == answer.id }) { messages.append(answer) }
            startFollowUp()
            if pendingRequest == nil { deliveryState = awaitingReplies.isEmpty ? .answered : .waiting }
            _ = persist()
            return
        }
        guard attemptID == generation else { return }
        guard answer.role == .assistant, !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !messages.contains(where: { $0.id == answer.id }) else {
            fail(ChatTransportError.invalidResponse, generation: generation)
            return
        }
        invalidateAttempt()
        messages.append(answer)
        pendingRequest = nil
        hasAttemptedDelivery = false
        deliveryState = .answered
        startFollowUp()
        _ = persist()
    }

    private func fail(_ error: Error, generation: UUID) {
        if let operation = replyOperations[generation] {
            operation.task?.cancel(); operation.timeout?.cancel()
            replyOperations[generation] = nil
            if pendingRequest == nil {
                let retryable = error as? ChatTransportError == .unavailable || error as? ChatTransportError == .timedOut
                deliveryState = .failed(retryable
                    ? "Mensaje enviado. Recuperando la respuesta al reconectar…"
                    : (error as? ChatTransportError)?.userMessage ?? "No se pudo leer la respuesta.")
            }
            _ = persist()
            scheduleReadRecovery(error)
            return
        }
        guard attemptID == generation else { return }
        invalidateAttempt()
        if case ChatTransportError.direct(let issue) = error, issue.provesNotSent {
            hasAttemptedDelivery = false
        }
        // Do not display arbitrary server errors: they may contain tokens, URLs or private payloads.
        deliveryState = .failed((error as? ChatTransportError)?.userMessage ?? "No se pudo completar el turno. Comprueba la conexión.")
        _ = persist()
        scheduleReadRecovery(error)
    }

    private func invalidateAttempt() {
        attemptID = nil
        sendTask?.cancel()
        timeoutTask?.cancel()
        sendTask = nil
        timeoutTask = nil
    }

    @discardableResult
    private func persist() -> Bool {
        guard !loadFailed else { return false }
        do {
            try store?.save(ConversationSnapshot(version: 1, conversationID: conversationID,
                messages: messages, pendingRequest: pendingRequest, hasAttemptedDelivery: hasAttemptedDelivery,
                deliveryState: deliveryState, draft: draft, awaitingReplies: awaitingReplies,
                followUpUntil: followUpUntil, outgoingMessageIDs: outgoingMessageIDs))
            storageIssue = nil
            return true
        } catch {
            storageIssue = "No se pudo guardar el chat. Libera espacio y vuelve a guardar."
            return false
        }
    }

    /// Called after the OS background receiver finishes saving, before resuming foreground work.
    public func reloadAfterBackground() {
        do {
            guard let saved = try store?.load() else { return }
            guard saved.conversationID == conversationID else { throw ChatTransportError.invalidResponse }
            messages = saved.messages
            pendingRequest = saved.pendingRequest
            awaitingReplies = saved.awaitingReplies ?? []
            hasAttemptedDelivery = saved.hasAttemptedDelivery
            deliveryState = saved.deliveryState
            followUpUntil = saved.followUpUntil
            outgoingMessageIDs = saved.outgoingMessageIDs ?? [:]
            for turn in saved.pendingTurns { outgoingMessageIDs[turn.clientTurnID] = turn.messages.last?.id }
        } catch {
            loadFailed = true
            storageIssue = "No se pudo recuperar el chat guardado. Se conserva el archivo; vuelve a abrir la app."
        }
    }

    /// An explicit upward pull may resume read-only reception, never a new send.
    public func refreshFromGesture() {
        if canRetry && retryIsReadOnly { retry() }
        synchronizeRecentMessages()
    }

    public func synchronizeRecentMessages() {
        guard foreground, transport.supportsHistorySync, syncTask == nil, storageIssue == nil else { return }
        isSynchronizing = true
        let originalMessages = messages
        syncTask = Task { [weak self, transport] in
            do {
                let page = try await transport.recentMessages(limit: ChatHistorySettings.limit)
                guard let self, !Task.isCancelled else { return }
                let snapshot = self.snapshot.merging(page, replaceWindow: !page.isEmpty && self.messages == originalMessages,
                    limit: ChatHistorySettings.limit, at: self.now())
                self.messages = snapshot.messages
                self.outgoingMessageIDs = snapshot.outgoingMessageIDs ?? [:]
                self.synchronizationIssue = nil
                if case .failed(let reason) = self.deliveryState,
                   reason == Self.backgroundReceptionPendingMessage || self.snapshot.pendingTurns.isEmpty {
                    self.deliveryState = self.attemptID != nil || !self.replyOperations.isEmpty ? .waiting : .idle
                }
                _ = self.persist()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.synchronizationIssue = (error as? ChatTransportError)?.userMessage
                    ?? "No se pudo sincronizar. Se conserva el chat guardado."
            }
            self?.isSynchronizing = false
            self?.syncTask = nil
        }
    }

    private var snapshot: ConversationSnapshot {
        ConversationSnapshot(version: 1, conversationID: conversationID, messages: messages,
            pendingRequest: pendingRequest, hasAttemptedDelivery: hasAttemptedDelivery,
            deliveryState: deliveryState, draft: draft, awaitingReplies: awaitingReplies,
            followUpUntil: followUpUntil, outgoingMessageIDs: outgoingMessageIDs)
    }

    private func startFollowUp() {
        guard transport.supportsHistorySync else { return }
        // This is the first answer of a requested turn. Extra room messages do not call here.
        followUpUntil = now().addingTimeInterval(followUpDelay)
        followUpTask?.cancel(); followUpTask = nil
        resumeFollowUp()
    }

    private func resumeFollowUp() {
        guard foreground, !readsPaused, transport.supportsHistorySync,
              let due = followUpUntil, followUpTask == nil else { return }
        followUpTask = Task { [weak self, transport] in
            guard let delay = self.map({ max(0, due.timeIntervalSince($0.now())) }) else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.foreground, !Task.isCancelled, self.followUpUntil == due else { return }
            do {
                let page = try await transport.additionalMessages()
                guard !Task.isCancelled, self.followUpUntil == due else { return }
                self.messages = self.snapshot.merging(page, replaceWindow: false,
                    limit: ChatHistorySettings.limit, at: self.now()).messages
            } catch {
                guard !Task.isCancelled, self.followUpUntil == due else { return }
                self.synchronizationIssue = "No se pudo completar la actualización adicional. Desliza hacia arriba para sincronizar."
            }
            // One attempt only; no periodic polling or retry loop after a reply.
            self.followUpUntil = nil
            self.followUpTask = nil
            _ = self.persist()
        }
    }

}

/// Local-only sample. Deterministic reply IDs also survive process restarts and retries.
public struct DemoChatTransport: ChatTransport {
    public let displayName = "Demostración local"
    public let isRealConnection = false
    public let supportsIdempotentRetry = true
    public init() {}

    public func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        try await Task.sleep(for: .milliseconds(300))
        await onAccepted()
        try await Task.sleep(for: .milliseconds(900))
        try Task.checkCancellation()
        return ChatMessage(id: request.clientTurnID, role: .assistant,
                           text: "Demo: mensaje recibido. No se envió a Andy ni se creó una tarea o recordatorio.")
    }
}
