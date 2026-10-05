import Foundation

/// Strict HTTP callback parsing, shared with tests. Never logs request bytes or URLs.
struct LoopbackCallback {
    let code: String?
    let error: String?
    static func parse(_ data: Data, port: UInt16, state: String) throws -> Self {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8),
              text.contains("\r\n\r\n") else { throw SignInError.invalidResponse }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/auth/callback?"), !first[1].contains("#") else { throw SignInError.invalidResponse }
        let hosts = lines.dropFirst().prefix(while: { !$0.isEmpty }).filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)",
              let components = URLComponents(string: "http://127.0.0.1:\(port)\(first[1])"),
              components.path == "/auth/callback", let items = components.queryItems else {
            throw SignInError.invalidResponse
        }
        for name in ["state", "code", "error"] {
            guard items.filter({ $0.name == name }).count <= 1 else { throw SignInError.invalidResponse }
        }
        guard items.first(where: { $0.name == "state" })?.value == state else { throw SignInError.invalidResponse }
        let code = items.first(where: { $0.name == "code" })?.value
        let error = items.first(where: { $0.name == "error" })?.value
        guard (code != nil) != (error != nil), code == nil || (!code!.isEmpty && code!.utf8.count <= 4096),
              error == nil || (!error!.isEmpty && error!.utf8.count <= 200) else { throw SignInError.invalidResponse }
        return Self(code: code, error: error)
    }
}
