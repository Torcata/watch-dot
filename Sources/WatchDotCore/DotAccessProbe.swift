import Foundation
import CoreFoundation

public enum DotProbeStage: String, Sendable, Equatable {
    case primary = "Dot primario"
    case room = "Sala del Dot"
    case send = "Envío al Dot"
    case history = "Respuesta del Dot"
}

public struct LocatedDot: Sendable, Equatable, Codable {
    public let name: String?
    public let dotID: String
    public let roomID: String
    public let accountID: String
    public let userID: String
    public let dotMemberID: String
}

public enum DotProbeState: Equatable {
    case idle, checking, cancelled
    case located(LocatedDot)
    case failed(String)
}

enum DotProbeError: Error, Equatable {
    case session, tokenMetadata, noPrimary, unavailable, destination, membership
    case invalidIdentifier
    case challenge(DotProbeStage, Int)
    case http(DotProbeStage, Int), schema(DotProbeStage), network(DotProbeStage), tls(DotProbeStage)

    var message: String {
        switch self {
        case .session: "La sesión no permite esta prueba o ha expirado. Vuelve a autorizar la cuenta."
        case .tokenMetadata: "La sesión no contiene los datos de cuenta necesarios para esta prueba."
        case .noPrimary: "OpenAI no devolvió un Dot primario para esta cuenta."
        case .unavailable: "El Dot primario no está disponible o aún no tiene sala."
        case .destination: "La sala recibida no coincide con el Dot primario. Prueba detenida."
        case .membership: "No se pudo verificar tu membresía y la del Dot en esta sala. Prueba detenida."
        case .invalidIdentifier: "El servicio devolvió un identificador vacío, excesivo o no utilizable. Prueba detenida."
        case .challenge(let stage, let status): "\(stage.rawValue): HTTP \(status), verificación del servicio requerida. Prueba detenida."
        case .schema(let stage): "\(stage.rawValue): respuesta no reconocida. Prueba detenida."
        case .network(let stage): "\(stage.rawValue): no se pudo completar la conexión. Puedes repetir la prueba."
        case .tls(let stage): "\(stage.rawValue): no se pudo verificar la conexión segura."
        case .http(let stage, let status):
            switch status {
            case 401: "\(stage.rawValue): HTTP 401. OpenAI no aceptó esta sesión."
            case 403: "\(stage.rawValue): HTTP 403. Acceso rechazado; no se intentará eludir verificaciones."
            case 429: "\(stage.rawValue): HTTP 429. Límite del servicio; espera antes de repetir."
            default: "\(stage.rawValue): HTTP \(status). Prueba detenida."
            }
        }
    }
}

/// Experimental, read-only contract, not a public API.
/// Uses only this app's OAuth account. No cookies, attestation, history or message writes.
struct DotAccessProbe: Sendable {
    let http: any SignInHTTP

    func run(account: SignedInAccount, now: Date,
             onDiagnostic: @Sendable (DotProbeDiagnostic) async -> Void = { _ in }) async throws -> LocatedDot {
        try Task.checkCancellation()
        guard account.clientID == OpenAIOAuthClient.codex, account.expiresAt > now,
              let token = account.accessToken, !token.isEmpty else { throw DotProbeError.session }
        let identity = try routingIdentity(token, account: account, now: now)
        let primary: Primary = try await get("/tbo/primary", stage: .primary, token: token,
                                             accountID: identity.accountID, onDiagnostic: onDiagnostic)
        guard let selection = primary.selection else { throw DotProbeError.noPrimary }
        guard selection.available, let dotID = selection.aeon_id, let roomID = selection.messaging_room_id else {
            throw DotProbeError.unavailable
        }
        // Treat these as opaque strings, not UUIDs or base64url identifiers.
        // Encode exactly one path segment; reserved characters must never become URL syntax.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard validOpaqueID(dotID), validOpaqueID(roomID), roomID != ".", roomID != "..",
              let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw DotProbeError.invalidIdentifier
        }
        let room: Room = try await get("/messaging/rooms/\(encodedRoomID)", stage: .room, token: token,
                                      accountID: identity.accountID, onDiagnostic: onDiagnostic)
        guard room.id == roomID, room.type == "DM", room.app_source == "chatgpt:messaging",
              room.aeon_id == dotID else { throw DotProbeError.destination }
        let dots = room.members.filter { $0.aeon_id == dotID }
        // Personal accounts use user_id as account_user_id. If a workspace uses a different
        // membership ID, stop rather than infer a mapping or choose a member by display name.
        guard dots.count == 1, let dot = dots.first, validOpaqueID(dot.account_user_id),
              dot.account_user_id != identity.userID,
              room.members.filter({ $0.account_user_id == identity.userID && $0.aeon_id == nil }).count == 1,
              Set(room.members.map(\.account_user_id)).count == room.members.count else {
            throw DotProbeError.membership
        }
        let snapshot = room.member_profile_snapshots?.first { $0.account_user_id == dot.account_user_id }
        let name = displayName(dot.name) ?? displayName(snapshot?.name)
        try Task.checkCancellation()
        return LocatedDot(name: name, dotID: dotID, roomID: roomID, accountID: identity.accountID,
                          userID: identity.userID, dotMemberID: dot.account_user_id)
    }

    private func get<T: Decodable>(_ path: String, stage: DotProbeStage,
                                  token: String, accountID: String,
                                  onDiagnostic: @Sendable (DotProbeDiagnostic) async -> Void) async throws -> T {
        try Task.checkCancellation()
        // All paths are built above; opaque room IDs arrive percent-encoded as one segment.
        let url = URL(string: "https://chatgpt.com/backend-api\(path)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("watch-dot", forHTTPHeaderField: "originator")
        request.setValue("WatchDot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: SignInHTTPResponse
        do {
            response = try await http.sendWithMetadata(request)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if case SignInError.tls = error { throw DotProbeError.tls(stage) }
            throw DotProbeError.network(stage)
        }
        try Task.checkCancellation()
        await onDiagnostic(DotProbeDiagnostic(stage: stage, response: response))
        try Task.checkCancellation()
        let data = response.data
        let status = response.status
        if response.clientChallenge { throw DotProbeError.challenge(stage, status) }
        // Never expose response bodies: failures may contain challenges, private context or credentials.
        guard status == 200 else { throw DotProbeError.http(stage, status) }
        guard data.count <= 256_000 else { throw DotProbeError.schema(stage) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DotProbeError.schema(stage) }
    }

    private func routingIdentity(_ token: String, account: SignedInAccount, now: Date) throws -> (accountID: String, userID: String) {
        // Decode only routing metadata from the OAuth response already stored by this app.
        // This is not signature validation; authentication still depends on the verified ID
        // token at sign-in and on the server accepting the bearer token for this exact route.
        let claims = try payload(token)
        guard let exp = claims["exp"] as? Double, exp.isFinite, exp > now.timeIntervalSince1970 else {
            throw DotProbeError.session
        }
        guard let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String ?? auth["account_id"] as? String,
              let userID = auth["user_id"] as? String ?? auth["chatgpt_user_id"] as? String,
              safeID(accountID), safeID(userID) else { throw DotProbeError.tokenMetadata }
        let verified = try payload(account.idToken)
        guard verified["sub"] as? String == account.subject else { throw DotProbeError.tokenMetadata }
        if let binding = verified["https://api.openai.com/auth"] as? [String: Any] {
            if let boundAccount = binding["chatgpt_account_id"] as? String ?? binding["account_id"] as? String,
               boundAccount != accountID { throw DotProbeError.tokenMetadata }
            if let boundUser = binding["user_id"] as? String ?? binding["chatgpt_user_id"] as? String,
               boundUser != userID { throw DotProbeError.tokenMetadata }
        }
        return (accountID, userID)
    }

    private func payload(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 64_000, parts.count == 3,
              parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }),
              let data = Data(base64URL: String(parts[1])),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DotProbeError.tokenMetadata
        }
        return value
    }

    private func safeID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil
    }

    private func validOpaqueID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4096 &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func displayName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 100,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private struct Primary: Decodable {
        let selection: Selection?
        // Distinguish a real null selection from a challenge/error object returned with HTTP 200.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.selection) else { throw DotProbeError.schema(.primary) }
            selection = try container.decodeIfPresent(Selection.self, forKey: .selection)
        }
        private enum CodingKeys: String, CodingKey { case selection }
    }
    private struct Selection: Decodable {
        let available: Bool
        let aeon_id: String?
        let messaging_room_id: String?
    }
    private struct Room: Decodable {
        let id: String
        let type: String
        let app_source: String
        let aeon_id: String?
        let members: [Member]
        let member_profile_snapshots: [Profile]?
    }
    private struct Member: Decodable {
        let account_user_id: String
        let aeon_id: String?
        let name: String?
    }
    private struct Profile: Decodable {
        let account_user_id: String
        let name: String?
    }
}

/// Values can only be fixed categories, counts and allowlisted field names, never response text.
enum DotJSONKind: String, Codable, Sendable {
    case absent, null, object, array, string, boolean, number, empty, html, invalidJSON

    static func of(_ value: Any?) -> Self {
        guard let value else { return .absent }
        if value is NSNull { return .null }
        if value is [String: Any] { return .object }
        if value is [Any] { return .array }
        if value is String { return .string }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .boolean : .number
        }
        return .invalidJSON
    }
    var label: String {
        switch self {
        case .absent: "ausente"
        case .null: "nulo"
        case .object: "objeto"
        case .array: "lista"
        case .string: "texto"
        case .boolean: "booleano"
        case .number: "número"
        case .empty: "vacío"
        case .html: "HTML"
        case .invalidJSON: "no es JSON"
        }
    }
}

struct DotProbeDiagnostic: Codable, Sendable, Equatable {
    let stage: String
    let httpStatus: Int
    let contentType: SignInContentType
    let clientChallenge: Bool
    let byteCount: Int
    let bodyKind: DotJSONKind
    let fields: [String: DotJSONKind]

    init(stage: DotProbeStage, response: SignInHTTPResponse) {
        switch stage {
        case .primary: self.stage = "primary"
        case .room: self.stage = "room"
        case .send: self.stage = "send"
        case .history: self.stage = "history"
        }
        httpStatus = response.status
        contentType = response.contentType
        clientChallenge = response.clientChallenge
        byteCount = response.data.count
        let parsed = try? JSONSerialization.jsonObject(with: response.data, options: [.fragmentsAllowed])
        let prefix = String(decoding: response.data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if response.data.isEmpty { bodyKind = .empty }
        else if parsed != nil { bodyKind = DotJSONKind.of(parsed) }
        else if contentType == .html || prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") { bodyKind = .html }
        else { bodyKind = .invalidJSON }
        let messagePaths = ["id", "account_user_id", "request_id", "content", "content.text", "content.attachments",
                            "reply_to", "reply_to.message_id", "reply_root_message_id", "raw_messages", "deleted_at"]
        let paths: [String]
        switch stage {
        case .primary:
            paths = ["selection", "selection.available", "selection.aeon_id", "selection.messaging_room_id",
                     "data", "response", "result", "error", "detail"]
        case .room:
            paths = ["id", "type", "app_source", "aeon_id", "members", "member_profile_snapshots", "error", "detail"]
        case .send: paths = messagePaths + ["error", "detail"]
        case .history: paths = ["items", "prev_cursor", "next_cursor", "error", "detail"] + messagePaths.map { "items.0." + $0 }
        }
        fields = Dictionary(uniqueKeysWithValues: paths.map { path in
            let value = path.split(separator: ".").reduce(parsed) { object, key in
                if key == "0", let array = object as? [Any] { return array.first }
                return (object as? [String: Any])?[String(key)]
            }
            return (path, DotJSONKind.of(value))
        })
    }

    var summary: String {
        let label = stage == "primary" ? "Dot primario" : "Sala del Dot"
        let format = bodyKind == .object ? "JSON objeto" : bodyKind.label
        let selection = stage == "primary" && bodyKind == .object
            ? " selection: \(fields["selection"]?.label ?? "ausente")." : ""
        return "\(label): HTTP \(httpStatus), \(format).\(selection) Formato no compatible (D2.1)."
    }
}
