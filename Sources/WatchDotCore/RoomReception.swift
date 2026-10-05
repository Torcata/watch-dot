import Foundation

public struct RoomMessage: Sendable, Equatable {
    public let remoteID: String
    public let message: ChatMessage
    public let requestID: UUID?
    public let replyTo: String?
}

struct RoomPage: Sendable {
    let messages: [RoomMessage]
    let nextCursor: String?
}

public enum ChatHistorySettings {
    public static let limits = [20, 50, 100, 200]
    public static var limit: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "WatchDot.historyLimit")
            return limits.contains(value) ? value : 100
        }
        set { UserDefaults.standard.set(limits.contains(newValue) ? newValue : 100, forKey: "WatchDot.historyLimit") }
    }
}

extension ConversationSnapshot {
    var pendingTurns: [TurnRequest] {
        (awaitingReplies ?? []) + (pendingRequest.map { [$0] } ?? [])
    }

    /// Server history is authoritative for the configured recent window. Pending local inputs
    /// are retained, including their original IDs, payloads and receipt keys; never match by text.
    func merging(_ incoming: [RoomMessage], replaceWindow: Bool, limit: Int,
                 completed: Set<UUID> = [], at now: Date) -> ConversationSnapshot {
        var bindings = outgoingMessageIDs ?? [:]
        for turn in pendingTurns { bindings[turn.clientTurnID] = turn.messages.last?.id }
        let converted = incoming.compactMap { item -> ChatMessage? in
            if let turn = pendingTurns.first(where: { $0.clientTurnID == item.requestID }),
               turn.messages.last?.text != item.message.text { return nil }
            let id = item.requestID.flatMap { bindings[$0] } ?? item.message.id
            return ChatMessage(id: id, role: item.message.role, text: item.message.text, createdAt: item.message.createdAt)
        }
        var merged = replaceWindow ? [] : messages
        for message in converted {
            if let index = merged.firstIndex(where: { $0.id == message.id }) { merged[index] = message }
            else { merged.append(message) }
        }
        merged = Array(merged.suffix(limit))
        let remaining = pendingTurns.filter { !completed.contains($0.clientTurnID) }
        for turn in remaining {
            if let message = turn.messages.last, !merged.contains(where: { $0.id == message.id }) { merged.append(message) }
        }
        let pending = pendingRequest.flatMap { completed.contains($0.clientTurnID) ? nil : $0 }
        let awaiting = (awaitingReplies ?? []).filter { !completed.contains($0.clientTurnID) }
        var until = followUpUntil
        if !completed.isEmpty, deliveryState != .cancelled, until == nil { until = now.addingTimeInterval(60) }
        let state: DeliveryState = !completed.isEmpty && pending == nil && awaiting.isEmpty ? .answered : deliveryState
        return ConversationSnapshot(version: version, conversationID: conversationID, messages: merged,
            pendingRequest: pending, hasAttemptedDelivery: pending != nil && hasAttemptedDelivery,
            deliveryState: state, draft: draft, awaitingReplies: awaiting,
            followUpUntil: until, outgoingMessageIDs: bindings)
    }
}

/// Persisted without credentials. Only one bounded reception cycle is active for a room.
struct BackgroundReceptionPlan: Codable {
    let id: UUID
    let destination: LocatedDot
    let subject: String
    let credentialDigest: String
    let directoryKey: String
    var roots: [UUID: String]
    var cursor: String?
    var passedRoots: Set<UUID> = []
    var attempts = 0
    var followUpUntil: Date?
    let historyLimit: Int

    func shouldContinue(snapshot: ConversationSnapshot, now: Date) -> Bool {
        guard snapshot.deliveryState != .cancelled else { return false }
        return !snapshot.pendingTurns.isEmpty || (followUpUntil ?? snapshot.followUpUntil) != nil
    }

    /// Backoff applies only while waiting for a requested reply.
    var nextDelay: TimeInterval {
        return attempts < 4 ? 15 : attempts < 10 ? 30 : 60
    }

    func delay(snapshot: ConversationSnapshot, now: Date, waitingDelay: TimeInterval) -> TimeInterval {
        guard snapshot.pendingTurns.isEmpty else { return waitingDelay }
        return max(0, (followUpUntil ?? snapshot.followUpUntil ?? now).timeIntervalSince(now))
    }

    mutating func consume(_ page: RoomPage, snapshot: ConversationSnapshot, now: Date) -> ConversationSnapshot {
        for item in page.messages {
            if let request = item.requestID, snapshot.pendingTurns.contains(where: {
                $0.clientTurnID == request && $0.messages.last?.text == item.message.text
            }) {
                roots[request] = item.remoteID
            }
        }
        var completed = Set<UUID>()
        for turn in snapshot.pendingTurns {
            guard let root = roots[turn.clientTurnID] else { continue }
            let ownIndex = page.messages.firstIndex { $0.remoteID == root && $0.message.role == .user }
            if page.messages.enumerated().contains(where: { index, item in
                guard item.message.role == .assistant else { return false }
                if let replyTo = item.replyTo { return replyTo == root }
                if let ownIndex { return index > ownIndex }
                return cursor == root || passedRoots.contains(turn.clientTurnID)
            }) { completed.insert(turn.clientTurnID) }
        }
        let consumedFollowUp = (followUpUntil ?? snapshot.followUpUntil).map { $0 <= now } ?? false
        if consumedFollowUp { followUpUntil = nil }
        if !completed.isEmpty { followUpUntil = now.addingTimeInterval(60) }
        var merged = snapshot.merging(page.messages, replaceWindow: false, limit: historyLimit,
                                      completed: completed, at: now)
        merged.followUpUntil = followUpUntil
        for (turn, root) in roots where cursor == root || page.messages.contains(where: { $0.remoteID == root }) {
            passedRoots.insert(turn)
        }
        for turn in completed { roots[turn] = nil; passedRoots.remove(turn) }
        cursor = page.nextCursor ?? page.messages.last?.remoteID ?? cursor
        attempts += 1
        return merged
    }
}

@MainActor
public protocol BackgroundChatReceiving: AnyObject {
    func start(destination: LocatedDot, account: SignedInAccount, directory: URL) async
    func stop() async
}
