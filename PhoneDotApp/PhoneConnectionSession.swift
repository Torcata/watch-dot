import Foundation
import Combine

@MainActor
final class PhoneConnectionSession: ObservableObject {
    let connectivity = CompanionConnectivity()
    @Published private(set) var status = "Abre Watch Dot en tu Apple Watch para conectar."
    @Published private(set) var busy = false
    @Published private(set) var authorized = false
    private let vault = PhoneTransferVault()
    private let browser = PhoneOAuthBrowser()
    private var pending: PhoneCredentialTransfer?
    private var request: PhoneAuthorizationRequest?
    private var foreground = false
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var delivering = false
    private var operation = UUID()

    init() {
        connectivity.receive = { [weak self] message in await self?.receive(message) ?? .idle }
        connectivity.becameReachable = { [weak self] in self?.recover() }
        connectivity.activate()
    }
    func enterForeground() {
        foreground = true
        // Retry Keychain on unlock; do not assume a locked-device failure means no pending tokens.
        do {
            pending = try vault.load()
            if let pending { request = pending.request; scheduleExpiry(pending.request) }
        } catch { status = SignInError.storage.message; return }
        recover()
    }
    func enterBackground() { foreground = false }
    func start() {
        guard !busy, !delivering else { return }
        if pending != nil { recover(); return }
        busy = true
        authorized = false
        status = "Conectando con el Apple Watch…"
        let operation = UUID(); self.operation = operation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await connectivity.send(.prepare)
                guard self.operation == operation else { return }
                guard case .begin(let request) = response else {
                    if case .failure(let reason) = response { status = reason }
                    else { status = "Abre Watch Dot en el reloj y vuelve a intentar." }
                    busy = false; task = nil; return
                }
                try await authorize(request, operation: operation)
            } catch { fail(error, operation: operation) }
        }
    }
    private func begin(_ request: PhoneAuthorizationRequest) {
        guard foreground, !busy, pending == nil else { return }
        busy = true; authorized = false
        let operation = UUID(); self.operation = operation
        task = Task { [weak self] in
            guard let self else { return }
            do { try await authorize(request, operation: operation) }
            catch { fail(error, operation: operation) }
        }
    }
    private func authorize(_ request: PhoneAuthorizationRequest, operation: UUID) async throws {
        try request.validate(now: .now)
        self.request = request
        scheduleExpiry(request)
        status = "Autoriza tu cuenta en el navegador del iPhone."
        let account = try await browser.authorize(request)
        guard self.operation == operation, self.request == request else { throw CancellationError() }
        let transfer = PhoneCredentialTransfer(request: request, account: account)
        try vault.save(transfer)
        pending = transfer
        busy = false; task = nil
        status = "Cuenta autorizada. Entregando la sesión al Watch…"
        recover()
    }
    private func fail(_ error: Error, operation: UUID) {
        guard self.operation == operation else { return }
        busy = false; task = nil
        status = error is CancellationError ? "Autorización cancelada." : (error as? SignInError)?.message ?? "No se pudo autorizar. Vuelve a intentar."
        if case .denied = error as? SignInError, let request {
            Task { [weak self] in _ = try? await self?.connectivity.send(.cancel(request)) }
            self.request = nil
        }
    }
    func cancel() {
        let request = request
        operation = UUID()
        task?.cancel(); task = nil
        busy = false
        do { try discard() } catch { status = SignInError.storage.message; return }
        status = "Autorización cancelada."
        if let request { Task { [weak self] in _ = try? await self?.connectivity.send(.cancel(request)) } }
    }
    private func discard() throws {
        try vault.clear()
        pending = nil; request = nil
        expiryTask?.cancel(); expiryTask = nil
    }
    private func scheduleExpiry(_ request: PhoneAuthorizationRequest) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow))) } catch { return }
            guard let self, self.request == request else { return }
            cancel()
            status = "La autorización expiró. Inicia un nuevo intento."
        }
    }
    private func receive(_ message: CompanionMessage) async -> CompanionMessage {
        switch message {
        case .begin(let request):
            guard (try? request.validate(now: .now)) != nil else { return .failure(SignInError.expired.message) }
            if let previous = self.request, previous != request {
                operation = UUID()
                task?.cancel(); task = nil
                busy = false
                do { try discard() } catch { return .failure(SignInError.storage.message) }
            }
            // Application context can be stale: query the Watch before presenting any browser.
            self.request = request
            if foreground { recover() }
            else { status = "Solicitud recibida. Abre Watch Dot para autorizar." }
            return .status("Abre Watch Dot en tu iPhone para autorizar.")
        case .cancel(let request):
            if self.request == request { cancel() }
            return .idle
        case .idle:
            return .idle // Only a direct query may invalidate a persisted transfer.
        default: return .failure(SignInError.invalidResponse.message)
        }
    }
    private func recover() {
        guard foreground, connectivity.reachable, !delivering, !busy else { return }
        delivering = true
        let operation = operation
        Task { [weak self] in
            guard let self else { return }
            defer { delivering = false }
            do {
                let response = try await connectivity.send(.query)
                guard self.operation == operation else { return }
                if let pending {
                    switch response {
                    case .acknowledgement(let receipt) where receipt == pending.receipt:
                        try complete()
                    case .begin(let active) where active == pending.request:
                        let reply = try await connectivity.send(.credentials(pending))
                        guard self.operation == operation else { return }
                        if case .acknowledgement(let receipt) = reply, receipt == pending.receipt {
                            try complete()
                        } else if case .failure(let reason) = reply { status = reason }
                        else { status = "Entrega pendiente. Abre Watch Dot en el reloj y reintenta." }
                    case .failure(let reason): status = reason
                    default:
                        try discard()
                        status = "El reloj canceló o reemplazó este intento. Inicia otro login."
                    }
                } else if case .begin(let request) = response {
                    begin(request)
                } else if case .acknowledgement = response {
                    authorized = true
                    status = "El reloj tiene su sesión. Para cambiar de cuenta, cierra sesión en el Watch."
                }
            } catch {
                guard self.operation == operation else { return }
                status = pending == nil ? "Abre Watch Dot en el reloj y toca Continuar con ChatGPT."
                    : "Sesión pendiente de entrega. Abre Watch Dot en el reloj y reintenta."
            }
        }
    }
    private func complete() throws {
        try discard()
        authorized = true
        status = "Sesión guardada en el Apple Watch. El reloj renovará sus tokens por su cuenta."
    }
}
