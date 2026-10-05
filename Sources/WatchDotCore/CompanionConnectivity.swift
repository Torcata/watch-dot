#if os(iOS) || os(watchOS)
import Foundation
import WatchConnectivity
import Combine

/// One delegate per process. Metadata may queue; credentials only use acknowledged messages.
@MainActor
public final class CompanionConnectivity: NSObject, ObservableObject, WatchSignInLink {
    @Published public private(set) var reachable = false
    @Published public private(set) var counterpartInstalled = false
    public var receive: (@MainActor (CompanionMessage) async -> CompanionMessage)?
    public var becameReachable: (@MainActor () -> Void)?
    public var requestFailed: (@MainActor () -> Void)?
    private let session: WCSession
    private var outbox: [UUID: CheckedContinuation<CompanionMessage, Error>] = [:]

    public override init() {
        session = .default
        super.init()
    }
    public func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }
    private func update() {
        let wasReachable = reachable
        reachable = session.activationState == .activated && session.isReachable
        #if os(iOS)
        counterpartInstalled = session.isPaired && session.isWatchAppInstalled
        #else
        counterpartInstalled = session.isCompanionAppInstalled
        #endif
        if reachable && !wasReachable { becameReachable?() }
    }

    public func send(_ message: CompanionMessage) async throws -> CompanionMessage {
        guard session.activationState == .activated, session.isReachable else { throw SignInError.unavailable }
        let data = try CompanionEnvelope(message).encoded()
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            outbox[id] = continuation
            // WCSession invokes these on its operation queue. Explicit Sendable closures
            // prevent Swift 6 from inheriting this method's MainActor isolation.
            let callbacks = CompanionReplyCallbacks { [weak self] result in
                self?.finish(id, result: result)
            }
            session.sendMessageData(data, replyHandler: callbacks.reply, errorHandler: callbacks.failure)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(40))
                self?.finish(id, result: .failure(SignInError.unavailable))
            }
        }
    }
    private func finish(_ id: UUID, result: Result<CompanionMessage, Error>) {
        outbox.removeValue(forKey: id)?.resume(with: result)
    }
    public func requestAuthorization(_ request: PhoneAuthorizationRequest) {
        publishRequest(request)
        Task { [weak self] in
            do { _ = try await self?.send(.begin(request)) }
            catch { self?.requestFailed?() }
        }
    }
    public func cancelAuthorization(_ request: PhoneAuthorizationRequest) {
        publishRequest(nil)
        Task { [weak self] in _ = try? await self?.send(.cancel(request)) }
    }
    private func publishRequest(_ request: PhoneAuthorizationRequest?) {
        guard session.activationState == .activated else { return }
        // Contains request metadata only. It never contains an authorization code or token.
        let message: CompanionMessage = request.map { .begin($0) } ?? .idle
        if let data = try? CompanionEnvelope(message).encoded() {
            try? session.updateApplicationContext(["watchDotAuth": data])
        }
    }
}

extension CompanionConnectivity: WCSessionDelegate {
    nonisolated public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                                    error: (any Error)?) {
        Task { @MainActor [weak self] in self?.update() }
    }
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.update() }
    }
    #if os(iOS)
    nonisolated public func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.update() }
    }
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.update() }
    }
    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
    nonisolated public func session(_ session: WCSession, didReceiveMessageData data: Data,
                                    replyHandler: @escaping (Data) -> Void) {
        // Wrap Apple's legacy callback for transfer to the main actor; invoke exactly once.
        let reply = ConnectivityReply(replyHandler)
        Task { @MainActor [weak self] in
            let message: CompanionMessage
            do {
                let decoded = try CompanionEnvelope.decode(data)
                message = await self?.receive?(decoded) ?? .failure("Abre Watch Dot para continuar.")
            } catch { message = .failure(SignInError.invalidResponse.message) }
            if let encoded = try? CompanionEnvelope(message).encoded() { reply.call(encoded) }
        }
    }
    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["watchDotAuth"] as? Data else { return }
        Task { @MainActor [weak self] in
            guard let message = try? CompanionEnvelope.decode(data) else { return }
            _ = await self?.receive?(message)
        }
    }
}

private final class ConnectivityReply: @unchecked Sendable {
    private let handler: (Data) -> Void
    init(_ handler: @escaping (Data) -> Void) { self.handler = handler }
    func call(_ data: Data) { handler(data) }
}
#endif
