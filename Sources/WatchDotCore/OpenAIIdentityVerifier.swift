import Foundation
import Security

// Signature verification uses Apple's Security framework. Never trust decoded claims alone.
enum OpenAIIdentityVerifier {
    struct Identity { let subject: String; let email: String?; let expiresAt: Date }
    private struct Header: Decodable { let alg: String; let kid: String; let crit: [String]? }
    private struct Claims: Decodable {
        let iss: String; let sub: String; let exp: Double; let iat: Double; let nbf: Double?
        let nonce: String?; let email: String?; let azp: String?; let aud: Audience
    }
    private enum Audience: Decodable {
        case one(String), many([String])
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .one(value) }
            else { self = .many(try container.decode([String].self)) }
        }
        var values: [String] { switch self { case .one(let v): [v]; case .many(let v): v } }
    }
    private struct Keys: Decodable { let keys: [JWK] }
    private struct JWK: Decodable {
        let kty: String; let kid: String?; let use: String?; let alg: String?
        let n: String?; let e: String?
    }
    static func verify(_ token: String, jwks: Data, clientID: String, nonce: String, now: Date) throws -> Identity {
        do { return try checked(token, jwks: jwks, clientID: clientID, nonce: nonce, refreshing: false, now: now) }
        catch { throw SignInError.identity }
    }
    static func verifyRefresh(_ token: String, jwks: Data, clientID: String, originalNonce: String?, now: Date) throws -> Identity {
        do { return try checked(token, jwks: jwks, clientID: clientID, nonce: originalNonce, refreshing: true, now: now) }
        catch { throw SignInError.identity }
    }
    private static func checked(_ token: String, jwks: Data, clientID: String, nonce: String?, refreshing: Bool, now: Date) throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard token.utf8.count <= 32_000, parts.count == 3,
              let headerData = Data(base64URL: parts[0]), let claimsData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]) else { throw SignInError.identity }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: headerData)
        guard header.alg == "RS256", header.crit == nil, !header.kid.isEmpty else { throw SignInError.identity }
        let keys = try decoder.decode(Keys.self, from: jwks).keys.filter {
            $0.kid == header.kid && $0.kty == "RSA" && ($0.use == nil || $0.use == "sig") &&
            ($0.alg == nil || $0.alg == "RS256")
        }
        guard keys.count == 1, let n = keys[0].n.flatMap({ Data(base64URL: $0) }),
              let e = keys[0].e.flatMap({ Data(base64URL: $0) }),
              (256...1024).contains(n.count), (1...8).contains(e.count) else { throw SignInError.identity }
        let der = encode(0x30, integer(n) + integer(e))
        guard let key = SecKeyCreateWithData(der as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic
        ] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil)
        else { throw SignInError.identity }
        let claims = try decoder.decode(Claims.self, from: claimsData)
        let timestamp = now.timeIntervalSince1970
        guard claims.iss == "https://auth.openai.com", !claims.sub.isEmpty,
              claims.aud.values.contains(clientID),
              claims.aud.values.count == 1 || claims.azp == clientID,
              claims.azp == nil || claims.azp == clientID,
              (refreshing ? (claims.nonce == nil || (nonce != nil && claims.nonce == nonce)) : (nonce != nil && claims.nonce == nonce)), claims.exp.isFinite, claims.iat.isFinite,
              claims.exp > timestamp, claims.iat <= timestamp + 30, claims.iat < claims.exp,
              claims.nbf == nil || claims.nbf! <= timestamp + 30 else { throw SignInError.identity }
        return Identity(subject: claims.sub, email: claims.email, expiresAt: Date(timeIntervalSince1970: claims.exp))
    }
    private static func integer(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return encode(0x02, bytes)
    }
    private static func encode(_ tag: UInt8, _ contents: Data) -> Data {
        let count = contents.count
        let length: [UInt8] = count < 128 ? [UInt8(count)] :
            count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)]
        return Data([tag] + length) + contents
    }
}
