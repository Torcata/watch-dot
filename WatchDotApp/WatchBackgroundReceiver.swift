import Foundation
import WatchKit
import CryptoKit

/// The OS owns these GET downloads. This does not keep a process, socket or timer alive.
@MainActor
final class WatchBackgroundReceiver: NSObject, BackgroundChatReceiving {
    static let shared = WatchBackgroundReceiver()
    static let sessionID = "cl.australapps.watchdot.reply-downloads"
    private let root = URL.applicationSupportDirectory.appendingPathComponent("WatchDot/direct", isDirectory: true)
    private var planURL: URL { root.appendingPathComponent("background-reception.json") }
    private let vault = KeychainSignInStore()
    private var plan: BackgroundReceptionPlan?
    private var wakes: [WKURLSessionRefreshBackgroundTask] = []
    private var processing = 0
    private var eventsFinished = false
    private lazy var delegate = DownloadDelegate(owner: self)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false // A response explicitly requested by the user.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: planURL) {
            plan = try? JSONDecoder().decode(BackgroundReceptionPlan.self, from: data)
        }
        _ = session // Reconnect to OS downloads after a background process relaunch.
    }

    func start(destination: LocatedDot, account: SignedInAccount, directory: URL) async {
        await stop()
        guard !Task.isCancelled, let snapshot = try? FileConversationStore(url: directory.appendingPathComponent("conversation.json")).load(),
              snapshot.deliveryState != .cancelled,
              !snapshot.pendingTurns.isEmpty || snapshot.followUpUntil != nil,
              let token = account.accessToken else { return }
        let key = directory.lastPathComponent
        guard key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return }
        let receipts = DotReceiptStore(directory: directory.appendingPathComponent("receipts"))
        var roots: [UUID: String] = [:]
        for turn in snapshot.pendingTurns {
            if let receipt = try? await receipts.load(turn.clientTurnID), let message = receipt.messageID {
                roots[turn.clientTurnID] = message
            }
        }
        guard !Task.isCancelled else { return }
        plan = BackgroundReceptionPlan(id: UUID(), destination: destination, subject: account.subject,
            credentialDigest: Self.digest(token), directoryKey: key, roots: roots,
            cursor: snapshot.pendingTurns.compactMap { roots[$0.clientTurnID] }.first,
            followUpUntil: snapshot.followUpUntil, historyLimit: ChatHistorySettings.limit)
        do { try savePlan(); try enqueue(delay: 0) }
        catch { stopWithIssue(ConversationSession.backgroundReceptionPendingMessage) }
    }

    func stop() async {
        plan = nil
        try? FileManager.default.removeItem(at: planURL)
        for task in await session.allTasks { task.cancel() }
    }

    func handle(_ task: WKURLSessionRefreshBackgroundTask) {
        wakes.append(task)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.completeWakes() }
        }
        _ = session
        if eventsFinished, processing == 0 { completeWakes() }
    }

    fileprivate func finishedEvents() {
        eventsFinished = true
        if processing == 0 { completeWakes() }
    }

    private func completeWakes() {
        let finished = wakes
        wakes = []
        for wake in finished { wake.setTaskCompletedWithSnapshot(false) }
    }

    private func account(for plan: BackgroundReceptionPlan) throws -> SignedInAccount {
        guard let account = try vault.load()?.account, account.subject == plan.subject,
              account.expiresAt > .now, account.clientID == OpenAIOAuthClient.codex,
              let token = account.accessToken, Self.digest(token) == plan.credentialDigest,
              plan.directoryKey == Self.binding(account: account, dot: plan.destination) else {
            throw ChatTransportError.direct(.session)
        }
        return account
    }

    private func directory(for plan: BackgroundReceptionPlan) -> URL {
        root.appendingPathComponent(plan.directoryKey, isDirectory: true)
    }

    private func transport(for plan: BackgroundReceptionPlan, account: SignedInAccount) -> DotChatTransport {
        DotChatTransport(destination: plan.destination, http: SecureSignInHTTP(), credentials: { account },
            receipts: DotReceiptStore(directory: directory(for: plan).appendingPathComponent("receipts")), onDiagnostic: { _ in })
    }

    private func enqueue(delay: TimeInterval) throws {
        guard let plan else { return }
        let store = FileConversationStore(url: directory(for: plan).appendingPathComponent("conversation.json"))
        guard let snapshot = try store.load(), plan.shouldContinue(snapshot: snapshot, now: .now) else {
            self.plan = nil; try? FileManager.default.removeItem(at: planURL); return
        }
        // No GET during the extra minute: schedule exactly one read at its end.
        let delay = plan.delay(snapshot: snapshot, now: .now, waitingDelay: delay)
        let account = try account(for: plan)
        let request = try transport(for: plan, account: account).receptionRequest(account: account, after: plan.cursor)
        let task = session.downloadTask(with: request)
        task.taskDescription = plan.id.uuidString // No credentials, message text, room or account in metadata.
        if delay > 0 { task.earliestBeginDate = Date.now.addingTimeInterval(delay) }
        task.countOfBytesClientExpectsToReceive = 32_000
        eventsFinished = false
        task.resume()
    }

    fileprivate func received(id: String?, response: SignInHTTPResponse?, retryable: Bool) {
        guard let current = plan, current.id.uuidString == id else { return }
        processing += 1
        Task {
            defer { processing -= 1; if eventsFinished, processing == 0 { completeWakes() } }
            do {
                let account = try account(for: current)
                let store = FileConversationStore(url: directory(for: current).appendingPathComponent("conversation.json"))
                guard let snapshot = try store.load(), snapshot.deliveryState != .cancelled else {
                    self.plan = nil; try? FileManager.default.removeItem(at: planURL); return
                }
                var updated = current
                if let response {
                    let page = try transport(for: current, account: account).receptionPage(response)
                    let merged = updated.consume(page, snapshot: snapshot, now: .now)
                    let receipts = DotReceiptStore(directory: directory(for: current).appendingPathComponent("receipts"))
                    for item in page.messages {
                        if let request = item.requestID,
                           let turn = snapshot.pendingTurns.first(where: { $0.clientTurnID == request }),
                           turn.messages.last?.text == item.message.text {
                            try await receipts.save(DotSendReceipt(requestID: request, messageID: item.remoteID))
                        }
                    }
                    guard plan?.id == current.id else { return }
                    _ = try self.account(for: current)
                    try store.save(merged)
                } else if retryable, !snapshot.pendingTurns.isEmpty { updated.attempts += 1 }
                else { throw ChatTransportError.direct(.schema) }
                guard plan?.id == current.id else { return }
                plan = updated
                try savePlan()
                // OS may postpone this date. Never hold the wake waiting for a timer/network.
                let deliveredEventsFinished = eventsFinished
                try enqueue(delay: updated.nextDelay)
                // enqueue starts another batch. Finish this wake if its callbacks already ended;
                // otherwise the new batch's future download would unnecessarily hold it open.
                if deliveredEventsFinished { completeWakes() }
            } catch {
                guard plan?.id == current.id else { return }
                stopWithIssue((error as? ChatTransportError)?.userMessage
                    ?? ConversationSession.backgroundReceptionPendingMessage)
            }
        }
    }

    private func stopWithIssue(_ reason: String) {
        if let plan {
            let store = FileConversationStore(url: directory(for: plan).appendingPathComponent("conversation.json"))
            if var snapshot = try? store.load() {
                if snapshot.pendingTurns.isEmpty { snapshot.followUpUntil = nil }
                snapshot.deliveryState = .failed(reason)
                try? store.save(snapshot)
            }
        }
        plan = nil
        try? FileManager.default.removeItem(at: planURL)
    }

    private func savePlan() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: planURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func binding(account: SignedInAccount, dot: LocatedDot) -> String {
        let data = (try? JSONEncoder().encode([account.subject, dot.accountID, dot.userID, dot.dotID, dot.roomID, dot.dotMemberID])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// All delegate callbacks are delivered on OperationQueue.main, configured above.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private weak var owner: WatchBackgroundReceiver?
    @MainActor init(owner: WatchBackgroundReceiver) { self.owner = owner }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        var result: SignInHTTPResponse?
        if let response = downloadTask.response as? HTTPURLResponse,
           response.url?.scheme == "https", response.url?.host == "chatgpt.com",
           response.url == downloadTask.originalRequest?.url,
           (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= 256_000 }) == true,
           let data = try? Data(contentsOf: location) {
            result = SignInHTTPResponse(data: data, status: response.statusCode,
                contentType: SignInContentType(response.value(forHTTPHeaderField: "Content-Type")),
                clientChallenge: response.value(forHTTPHeaderField: "cf-mitigated") == "challenge")
        }
        MainActor.assumeIsolated { owner?.received(id: downloadTask.taskDescription, response: result, retryable: false) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let code = (error as? URLError)?.code
        let retryable = code == .timedOut || code == .networkConnectionLost || code == .notConnectedToInternet || code == .cannotConnectToHost || code == .cannotFindHost
        MainActor.assumeIsolated { owner?.received(id: task.taskDescription, response: nil, retryable: retryable) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 256_000 || totalBytesExpectedToWrite > 256_000 { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Background sessions follow redirects themselves. Only trust the fixed HTTPS origin;
        // the final URL is also checked before accepting any content.
        let allowed = challenge.protectionSpace.host == "chatgpt.com" &&
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        completionHandler(allowed ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { owner?.finishedEvents() }
    }
}

@MainActor
final class WatchDotDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let download = task as? WKURLSessionRefreshBackgroundTask,
               download.sessionIdentifier == WatchBackgroundReceiver.sessionID {
                WatchBackgroundReceiver.shared.handle(download)
            } else { task.setTaskCompletedWithSnapshot(false) }
        }
    }
}
