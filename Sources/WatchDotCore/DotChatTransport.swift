import Foundation
import CryptoKit

public enum DotQueryParameter: String, Sendable {
    case limit, before, after
    case replyRoot = "reply_root_message_id"
}

/// Fixed local messages only; never surface error bodies, challenges or credentials.
public enum DotChatIssue: Sendable, Equatable {
    case session, destination, storage, notSubmitted, unconfirmed, unsupportedReply
    case http(Int), replyHTTP(Int), rejected(Int), challenge(Int), schema
    case invalidQuery(DotQueryParameter)

    var provesNotSent: Bool {
        switch self { case .notSubmitted, .rejected: true; default: false }
    }
    var message: String {
        switch self {
        case .session: "La sesión cambió o expiró. Vuelve a conectar la cuenta."
        case .destination: "El Dot o su sala cambiaron. Envío detenido; verifica de nuevo el destino."
        case .storage: "No se pudo guardar el comprobante de envío. Comprueba el almacenamiento."
        case .notSubmitted: "Este turno no llegó a iniciar el envío. Puedes reintentarlo o descartarlo."
        case .unconfirmed: "Entrega sin confirmar. Consultar respuesta solo lee la sala; no repite el envío."
        case .unsupportedReply: "Andy respondió con contenido que el reloj aún no puede mostrar. Revisa su chat en ChatGPT."
        case .replyHTTP(let status): "Mensaje enviado. Lectura: HTTP \(status). Usa Consultar respuesta."
        case .invalidQuery(let field): "Lectura rechazada: parámetro \(field.rawValue) (HTTP 422). El envío no se repetirá."
        case .http(let status): "Chat directo: HTTP \(status). Consulta detenida; el mensaje puede haber llegado."
        case .rejected(let status): "OpenAI rechazó el envío (HTTP \(status)). No se envió el mensaje."
        case .challenge(let status): "OpenAI exige una verificación del cliente (HTTP \(status)). Prueba detenida."
        case .schema: "No se pudo interpretar la respuesta de Andy. Vuelve a intentar."
        }
    }
}

/// Receipt of transport delivery, not a separate task/reminder registry. No credentials or text.
struct DotSendReceipt: Codable, Sendable {
    let requestID: UUID
    var messageID: String?
    var rejectedStatus: Int?
}

actor DotReceiptStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func load(_ id: UUID) throws -> DotSendReceipt? {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let receipt = try JSONDecoder().decode(DotSendReceipt.self, from: Data(contentsOf: url))
            guard receipt.requestID == id,
                  receipt.messageID == nil || DotChatTransport.validID(receipt.messageID!),
                  receipt.rejectedStatus == nil || (400..<500).contains(receipt.rejectedStatus!) && receipt.rejectedStatus != 408 && receipt.rejectedStatus != 409,
                  receipt.messageID == nil || receipt.rejectedStatus == nil else { throw ChatTransportError.direct(.storage) }
            return receipt
        } catch { throw ChatTransportError.direct(.storage) }
    }
    func save(_ receipt: DotSendReceipt) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(receipt)
            let url = directory.appendingPathComponent(receipt.requestID.uuidString + ".json")
            #if os(watchOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        } catch { throw ChatTransportError.direct(.storage) }
    }
}

/// Experimental contract. Uses only this app's OAuth session.
/// One POST per attempted turn. Recovery is read-only; server deduplication is NOT assumed.
struct DotChatTransport: ChatTransport {
    let destination: LocatedDot
    let http: any SignInHTTP
    let credentials: @Sendable () async throws -> SignedInAccount
    let receipts: DotReceiptStore
    let onDiagnostic: @Sendable (DotProbeDiagnostic) async -> Void
    var pollInterval: Duration = .seconds(5)
    var now: @Sendable () -> Date = Date.init
    var displayName: String { destination.name ?? "Dot" }
    let isRealConnection = true
    let supportsReadOnlyResume = true
    let allowsSendingWhileAwaitingReply = true
    let supportsHistorySync = true

    func additionalMessages() async throws -> [RoomMessage] {
        // Destination already verified for this reception cycle. Each GET still checks the
        // current account and every item's author; avoid two extra discovery reads per poll.
        roomMessages(try await history(diagnostic: false))
    }

    func recentMessages(limit: Int) async throws -> [RoomMessage] {
        _ = try await verifyDestination()
        var result: [RoomMessage] = []
        var before: String?
        var cursors = Set<String>()
        let count = min(200, max(20, limit))
        for index in 0..<((count + 19) / 20) {
            let page = try await history(before: before, diagnostic: index == 0)
            result = roomMessages(page) + result
            guard let cursor = page.prev_cursor, Self.validID(cursor), cursors.insert(cursor).inserted else { break }
            before = cursor
        }
        _ = try await credentials()
        var seen = Set<String>()
        return Array(result.filter { seen.insert($0.remoteID).inserted }.suffix(count))
    }

    // The background adapter uses the same request builder and parser as the foreground chat.
    func receptionRequest(account: SignedInAccount, after: String?) throws -> URLRequest {
        var query = [URLQueryItem(name: "limit", value: "20")]
        if let after { query.append(.init(name: "after", value: after)) }
        return try makeRequest(method: "GET", account: account, query: query)
    }

    func receptionPage(_ response: SignInHTTPResponse) throws -> RoomPage {
        try check(response)
        let page: History = try decode(response.data)
        try validate(page)
        return RoomPage(messages: roomMessages(page), nextCursor: page.next_cursor)
    }

    private func roomMessages(_ page: History) -> [RoomMessage] {
        page.items.compactMap { item in
            guard Self.validID(item.id), item.deleted_at == nil,
                  let text = item.content?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.account_user_id == destination.userID || item.account_user_id == destination.dotMemberID else { return nil }
            return RoomMessage(remoteID: item.id,
                message: ChatMessage(id: Self.localID(item.id),
                    role: item.account_user_id == destination.userID ? .user : .assistant,
                    text: text, createdAt: Self.remoteDate(item.created_at) ?? now()),
                requestID: item.account_user_id == destination.userID ? UUID(uuidString: item.request_id ?? "") : nil,
                replyTo: item.reply_to?.message_id ?? item.reply_root_message_id)
        }
    }

    private static func remoteDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        // Also protects against a caller accidentally invoking send twice after a crash.
        if let receipt = try await receipts.load(request.clientTurnID), receipt.rejectedStatus == nil {
            return try await resume(request, onAccepted: onAccepted)
        }
        let account = try await verifyDestination()
        guard let message = request.messages.last, message.role == .user,
              !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatTransportError.invalidResponse
        }
        try Task.checkCancellation()
        var receipt = DotSendReceipt(requestID: request.clientTurnID)
        // Durable marker BEFORE POST: even a lost HTTP response must never cause another POST.
        try await receipts.save(receipt)
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(SendBody(content: .init(text: message.text),
            request_id: request.clientTurnID.uuidString, idempotency_token: request.clientTurnID.uuidString))
        let response = try await perform(method: "POST", account: account, body: body)
        await onDiagnostic(DotProbeDiagnostic(stage: .send, response: response))
        try Task.checkCancellation()
        if (400..<500).contains(response.status), response.status != 408, response.status != 409, !response.clientChallenge {
            receipt.rejectedStatus = response.status
            try await receipts.save(receipt)
            throw ChatTransportError.direct(.rejected(response.status))
        }
        try check(response)
        let posted: RemoteMessage = try decode(response.data)
        guard validOwnMessage(posted, request: request), Self.validID(posted.id) else {
            throw ChatTransportError.direct(.schema)
        }
        receipt.messageID = posted.id
        try await receipts.save(receipt)
        await onAccepted()
        return try await waitForReply(to: posted.id)
    }

    func resume(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        _ = try await verifyDestination()
        guard var receipt = try await receipts.load(request.clientTurnID) else {
            throw ChatTransportError.direct(.notSubmitted)
        }
        if let status = receipt.rejectedStatus { throw ChatTransportError.direct(.rejected(status)) }
        if receipt.messageID == nil {
            // Search a bounded history window by request_id, never by text or display name.
            var before: String?
            var seen = Set<String>()
            for pageIndex in 0..<5 {
                let page = try await history(before: before, diagnostic: pageIndex == 0)
                let matches = page.items.filter { UUID(uuidString: $0.request_id ?? "") == request.clientTurnID }
                guard matches.count <= 1 else { throw ChatTransportError.direct(.schema) }
                if let match = matches.first {
                    guard validOwnMessage(match, request: request), Self.validID(match.id) else {
                        throw ChatTransportError.direct(.schema)
                    }
                    receipt.messageID = match.id
                    try await receipts.save(receipt)
                    break
                }
                guard let cursor = page.prev_cursor, Self.validID(cursor), seen.insert(cursor).inserted else { break }
                before = cursor
            }
        }
        guard let messageID = receipt.messageID else { throw ChatTransportError.direct(.unconfirmed) }
        await onAccepted()
        return try await waitForReply(to: messageID)
    }

    private func verifyDestination() async throws -> SignedInAccount {
        let account = try await credentials()
        let found: LocatedDot
        do { found = try await DotAccessProbe(http: http).run(account: account, now: now()) }
        catch is CancellationError { throw CancellationError() }
        catch DotProbeError.session { throw ChatTransportError.direct(.session) }
        catch DotProbeError.http(_, let status) { throw ChatTransportError.direct(.http(status)) }
        catch DotProbeError.challenge(_, let status) { throw ChatTransportError.direct(.challenge(status)) }
        catch DotProbeError.network { throw ChatTransportError.unavailable }
        catch { throw ChatTransportError.direct(.destination) }
        guard found.accountID == destination.accountID, found.userID == destination.userID,
              found.dotID == destination.dotID, found.roomID == destination.roomID,
              found.dotMemberID == destination.dotMemberID else { throw ChatTransportError.direct(.destination) }
        return account
    }

    private func waitForReply(to messageID: String) async throws -> ChatMessage {
        var first = true
        var emptyReads = 0
        while true {
            try Task.checkCancellation()
            let page: History
            do { page = try await history(after: messageID, diagnostic: first) }
            catch ChatTransportError.direct(.http(let status)) {
                // This branch has a persisted, verified acknowledgement; do not imply the POST failed.
                throw ChatTransportError.direct(.replyHTTP(status))
            }
            first = false
            // Read the main room after the acknowledged message, not the reply-thread view.
            // Dot messages need not carry reply_to. Verify the member and, when present,
            // explicit linkage; an unthreaded item is a new message in this same Dot room.
            // It is not independent proof that a task/reminder was completed.
            let candidates = page.items.filter {
                $0.account_user_id == destination.dotMemberID && $0.deleted_at == nil &&
                ($0.reply_to?.message_id == messageID || $0.reply_root_message_id == messageID ||
                 ($0.reply_to == nil && $0.reply_root_message_id == nil))
            }
            for reply in candidates {
                guard Self.validID(reply.id), reply.id != messageID else { throw ChatTransportError.direct(.schema) }
                if let text = reply.content?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try Task.checkCancellation()
                    _ = try await credentials() // Account still current before displaying a late response.
                    return ChatMessage(id: Self.localID(reply.id), role: .assistant, text: text,
                                       createdAt: Self.remoteDate(reply.created_at) ?? now())
                }
                if reply.content?.attachments?.isEmpty == false {
                    throw ChatTransportError.direct(.unsupportedReply)
                }
            }
            emptyReads += 1
            // Fast initial reply, then fewer radio wakeups for long-running work.
            try await Task.sleep(for: pollInterval * (emptyReads < 6 ? 1 : emptyReads < 12 ? 2 : 6))
        }
    }

    private func validOwnMessage(_ message: RemoteMessage, request: TurnRequest) -> Bool {
        message.account_user_id == destination.userID && message.deleted_at == nil &&
        UUID(uuidString: message.request_id ?? "") == request.clientTurnID && message.content?.text == request.messages.last?.text
    }

    private func history(before: String? = nil, after: String? = nil, diagnostic: Bool) async throws -> History {
        // Use a page size of 20; the previous request with 50 returned HTTP 422.
        var query = [URLQueryItem(name: "limit", value: "20")]
        if let before { query.append(.init(name: "before", value: before)) }
        if let after { query.append(.init(name: "after", value: after)) }
        let account = try await credentials()
        let response = try await perform(method: "GET", account: account, query: query)
        if diagnostic || response.status != 200 || response.clientChallenge {
            await onDiagnostic(DotProbeDiagnostic(stage: .history, response: response))
        }
        if response.status == 422, !response.clientChallenge,
           let parameter = Self.invalidQueryParameter(response.data) {
            throw ChatTransportError.direct(.invalidQuery(parameter))
        }
        try check(response)
        let history: History = try decode(response.data)
        try validate(history)
        return history
    }

    private func validate(_ history: History) throws {
        guard history.items.count <= 100, Set(history.items.map(\.id)).count == history.items.count,
              history.items.allSatisfy({ Self.validID($0.id) }),
              history.next_cursor == nil || Self.validID(history.next_cursor!) else {
            throw ChatTransportError.direct(.schema)
        }
    }

    private func perform(method: String, account: SignedInAccount, body: Data? = nil,
                         query: [URLQueryItem] = []) async throws -> SignInHTTPResponse {
        try Task.checkCancellation()
        let request = try makeRequest(method: method, account: account, body: body, query: query)
        let response: SignInHTTPResponse
        do { response = try await http.sendWithMetadata(request) }
        catch { try Task.checkCancellation(); throw ChatTransportError.unavailable }
        try Task.checkCancellation()
        _ = try await credentials()
        return response
    }

    private func makeRequest(method: String, account: SignedInAccount, body: Data? = nil,
                             query: [URLQueryItem] = []) throws -> URLRequest {
        guard account.clientID == OpenAIOAuthClient.codex, account.expiresAt > now(), let token = account.accessToken else {
            throw ChatTransportError.direct(.session)
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard Self.validID(destination.roomID), destination.roomID != ".", destination.roomID != "..",
              let room = destination.roomID.addingPercentEncoding(withAllowedCharacters: unreserved),
              var url = URLComponents(string: "https://chatgpt.com/backend-api/messaging/rooms/\(room)/messages") else {
            throw ChatTransportError.direct(.destination)
        }
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(destination.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("watch-dot", forHTTPHeaderField: "originator")
        request.setValue("WatchDot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        // No App Attest, Sentinel, DeviceCheck, official-client headers or cookies.
        return request
    }

    private func check(_ response: SignInHTTPResponse) throws {
        if response.clientChallenge { throw ChatTransportError.direct(.challenge(response.status)) }
        guard (200..<300).contains(response.status) else { throw ChatTransportError.direct(.http(response.status)) }
        guard response.data.count <= 256_000 else { throw ChatTransportError.direct(.schema) }
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ChatTransportError.direct(.schema) }
    }
    /// Extract only a known query field from validation errors, never msg/input/ctx or raw text.
    static func invalidQueryParameter(_ data: Data) -> DotQueryParameter? {
        guard data.count <= 256_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = object["detail"] as? [[String: Any]] else { return nil }
        for detail in details.prefix(10) {
            guard let location = detail["loc"] as? [String], location.count == 2,
                  location[0] == "query", let field = DotQueryParameter(rawValue: location[1]) else { continue }
            return field
        }
        return nil
    }

    static func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4096 &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func localID(_ remote: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(remote.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private struct SendBody: Encodable {
        struct Content: Encodable { let text: String }
        let content: Content
        let request_id: String
        let idempotency_token: String
    }
    private struct History: Decodable {
        let items: [RemoteMessage]
        let prev_cursor: String?
        let next_cursor: String?
    }
    private struct RemoteMessage: Decodable {
        struct Content: Decodable { let text: String?; let attachments: [Attachment]? }
        struct Attachment: Decodable { let type: String }
        struct Reply: Decodable { let message_id: String }
        let id: String
        let account_user_id: String?
        let request_id: String?
        let content: Content?
        let reply_to: Reply?
        let reply_root_message_id: String?
        let deleted_at: String?
        let created_at: String?
    }
}
