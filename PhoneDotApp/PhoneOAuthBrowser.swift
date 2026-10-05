import Foundation
import AuthenticationServices
import UIKit
import Network

/// Browser and loopback listener exist only during an explicit authorization attempt.
@MainActor
final class PhoneOAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let service = SignInService(http: SecureSignInHTTP())
    private var browser: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<SignedInAccount, Error>?
    private var callbackReceived = false
    private var authorization: OAuthAuthorization?
    private var request: PhoneAuthorizationRequest?
    private var generation = UUID()

    func authorize(_ request: PhoneAuthorizationRequest) async throws -> SignedInAccount {
        try request.validate(now: .now)
        guard continuation == nil, browser == nil else { throw SignInError.browser }
        self.request = request
        callbackReceived = false
        generation = UUID()
        let generation = generation
        var authorization = try OAuthAuthorization(account: nil, now: .now, nonce: request.nonce)
        authorization.deadline = request.expiresAt
        let port: UInt16
        do { try await listen(port: 1455); port = 1455 }
        catch {
            guard !Task.isCancelled else { stop(); throw CancellationError() }
            try await listen(port: 1457); port = 1457
        }
        guard !Task.isCancelled, self.generation == generation else { stop(); throw CancellationError() }
        try authorization.prepare(redirect: "http://127.0.0.1:\(port)/auth/callback", hostID: request.installationID)
        self.authorization = authorization
        guard let url = authorization.authorizationURL.flatMap(URL.init(string:)) else {
            stop(); throw SignInError.invalidResponse
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // OpenAI returns to HTTP loopback, not to an invented app URL scheme.
                let completion: @Sendable (URL?, (any Error)?) -> Void = { [weak self] _, error in
                    Task { @MainActor in
                        guard let self, self.generation == generation, !self.callbackReceived else { return }
                        self.finish(.failure((error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                            ? SignInError.denied : SignInError.browser))
                    }
                }
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil, completionHandler: completion)
                self.browser = browser
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = false
                timeout = Task { [weak self] in
                    let remaining = max(0, request.expiresAt.timeIntervalSinceNow)
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                    guard self?.generation == generation else { return }
                    self?.finish(.failure(SignInError.expired))
                }
                if !browser.start() { finish(.failure(SignInError.browser)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func listen(port: UInt16) async throws {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection, port: port) }
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let latch = ListenerReady(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: latch.finish(.success(()))
                case .failed: latch.finish(.failure(SignInError.browser))
                case .cancelled: latch.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: .main)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                latch.finish(.failure(SignInError.browser))
            }
        }
    }

    private func accept(_ connection: NWConnection, port: UInt16) {
        guard !callbackReceived, connections.count < 8 else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection, port: port, accumulated: Data())
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            connection.cancel()
            self?.connections.removeAll { $0 === connection }
        }
    }
    private func receive(_ connection: NWConnection, port: UInt16, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                guard bytes.count <= 16_384, error == nil else { connection.cancel(); return }
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.process(bytes, connection: connection, port: port)
                } else if complete { connection.cancel() }
                else { self.receive(connection, port: port, accumulated: bytes) }
            }
        }
    }
    private func process(_ data: Data, connection: NWConnection, port: UInt16) {
        guard let authorization, let request, !callbackReceived else { connection.cancel(); return }
        let callback: LoopbackCallback
        do { callback = try .parse(data, port: port, state: authorization.state) }
        catch { respond(connection, status: "400 Bad Request"); return }
        callbackReceived = true
        respond(connection, status: "200 OK")
        // The HTTP callback owns completion; cancelling its browser sheet is not user denial.
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        let generation = generation
        Task {
            do {
                if let error = callback.error {
                    throw error == "invalid_client" ? SignInError.clientUnavailable : SignInError.denied
                }
                let result = OAuthCallback(code: callback.code!, state: authorization.state,
                    clientID: authorization.clientID, redirectURI: authorization.redirectURI!)
                let account = try await service.exchange(result, authorization: authorization, now: .now)
                guard request.expectedSubject == nil || request.expectedSubject == account.subject else { throw SignInError.identity }
                guard self.generation == generation else { return }
                finish(.success(account))
            } catch {
                guard self.generation == generation else { return }
                finish(.failure(error))
            }
        }
    }
    private func respond(_ connection: NWConnection, status: String) {
        let body = "Vuelve a Watch Dot para continuar."
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    private func finish(_ result: Result<SignedInAccount, Error>) {
        let continuation = continuation
        self.continuation = nil
        stop()
        continuation?.resume(with: result)
    }
    private func stop() {
        generation = UUID()
        timeout?.cancel(); timeout = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections = []
        authorization = nil; request = nil
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

/// NWListener callbacks run on the main queue, and resolve this continuation once.
private final class ListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}
