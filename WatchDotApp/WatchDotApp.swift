import SwiftUI
import WidgetKit

@main
struct WatchDotApp: App {
    @WKApplicationDelegateAdaptor(WatchDotDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: ConversationSession
    @StateObject private var connection: ConnectionSession

    init() {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("WatchDot", isDirectory: true)
        // Demo and real account/room histories remain in different stores.
        var demoFile = "demo-conversation.json"
        #if DEBUG && targetEnvironment(simulator)
        let previewRefresh = ProcessInfo.processInfo.arguments.contains("--preview-refresh")
        let previewChat = ProcessInfo.processInfo.arguments.contains("--preview-chat") || previewRefresh
        if previewChat { demoFile = "layout-preview.json" }
        #endif
        let store = FileConversationStore(url: directory.appendingPathComponent(demoFile))
        #if DEBUG && targetEnvironment(simulator)
        if previewChat {
            let messages = ProcessInfo.processInfo.arguments.contains("--preview-refresh-short")
                ? [ChatMessage(role: .assistant, text: "Mensaje de prueba.")]
                : [
                ChatMessage(role: .user, text: "Estoy probando el espacio del chat en el reloj."),
                ChatMessage(role: .assistant, text: "Vista de demostración. Aquí se mostrarán los mensajes del chat.")
            ]
            try? store.save(ConversationSnapshot(version: 1, conversationID: UUID(), messages: messages,
                pendingRequest: nil, hasAttemptedDelivery: false, deliveryState: .idle, draft: ""))
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let transport: any ChatTransport = previewRefresh
            ? RefreshPreviewTransport(messages: (try? store.load())?.messages ?? []) : DemoChatTransport()
        #else
        let transport: any ChatTransport = DemoChatTransport()
        #endif
        let session = ConversationSession(transport: transport, store: store)
        #if DEBUG && targetEnvironment(simulator)
        if previewRefresh { session.resumeAutomatically() }
        #endif
        _session = StateObject(wrappedValue: session)
        let bridge = CompanionConnectivity()
        let connection = ConnectionSession(store: KeychainSignInStore(),
            chatDirectory: directory.appendingPathComponent("direct", isDirectory: true),
            backgroundReceiver: WatchBackgroundReceiver.shared, companion: bridge)
        #if DEBUG && targetEnvironment(simulator)
        if previewChat { connection.selectDemo(true) }
        #endif
        bridge.receive = { [weak connection] message in
            await connection?.receiveCompanionMessage(message) ?? .idle
        }
        bridge.requestFailed = { [weak connection] in connection?.companionRequestFailed() }
        bridge.activate()
        _connection = StateObject(wrappedValue: connection)
        refreshComplicationImageIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ChatRootView(connection: connection, demo: session)
                .onAppear {
                    if scenePhase == .active {
                        connection.enterForeground()
                        refreshComplicationImageIfNeeded()
                    }
                }
                .onChange(of: connection.demoEnabled) { _, enabled in
                    if !enabled { session.suspend() }
                }
                .onChange(of: connection.phase) { _, _ in connectChatIfReady() }
                .onChange(of: connection.dotProbeState) { _, state in
                    if case .located = state { session.suspend() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        session.suspend()
                        connection.enterBackground()
                    } else if phase == .active {
                        connection.enterForeground()
                        refreshComplicationImageIfNeeded()
                    }
                }
        }
    }
    private func refreshComplicationImageIfNeeded() {
        // One refresh per icon revision; the launcher still has no periodic timeline.
        let key = "WatchDot.complicationIconRevision"
        guard UserDefaults.standard.integer(forKey: key) < 6 else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: "cl.australapps.watchdot.launcher")
        #if DEBUG
        WidgetCenter.shared.getCurrentConfigurations { result in
            let record: [String: Any]
            switch result {
            case .success(let widgets):
                record = ["revision": 6, "widgets": widgets.map { ["kind": $0.kind, "family": $0.family.rawValue] as [String: Any] }]
            case .failure:
                record = ["revision": 6, "status": "unavailable"]
            }
            if let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys) {
                try? data.write(to: URL.cachesDirectory.appendingPathComponent("watchdot-widget-configurations.json"), options: .atomic)
            }
        }
        #endif
        UserDefaults.standard.set(6, forKey: key)
    }

    private func connectChatIfReady() {
        if scenePhase == .active, connection.phase == .signedIn, connection.dotProbeState == .idle {
            connection.probeDotAccess()
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// An offline fixture for exercising pull, release and loading without a real account.
private actor RefreshPreviewTransport: ChatTransport {
    let displayName = "Vista previa local"
    let isRealConnection = true
    let supportsHistorySync = true
    private var messages: [ChatMessage]
    private var reads = 0

    init(messages: [ChatMessage]) { self.messages = messages }

    func recentMessages(limit: Int) async throws -> [RoomMessage] {
        reads += 1
        try await Task.sleep(for: .seconds(4))
        messages.append(ChatMessage(role: .assistant, text: "Consulta local \(reads): mensajes actualizados."))
        return messages.map { RoomMessage(remoteID: $0.id.uuidString, message: $0, requestID: nil, replyTo: nil) }
    }

    func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        throw ChatTransportError.rejected("Vista previa de sincronización: sin envíos.")
    }
}
#endif

/// An unavailable real transport is a connection screen, never an implicit demo session.
private struct ChatRootView: View {
    @ObservedObject var connection: ConnectionSession
    @ObservedObject var demo: ConversationSession
    @State private var showConnection = false

    var body: some View {
        NavigationStack {
            Group {
                if let session = connection.selectedConversation(demo: demo) {
                    ConversationView(session: session)
                } else {
                    VStack(spacing: 10) {
                        ScrollView {
                            VStack(spacing: 8) {
                                Text(connection.chatBlockReason).font(.footnote)
                                if connection.phase.isBusy || connection.dotProbeState == .checking {
                                    ProgressView()
                                    Button("Ver conexión") { showConnection = true }
                                } else {
                                    Button(connection.phase == .signedIn ? "Conectar con Andy" : connection.actionTitle) {
                                        if connection.phase == .signedIn { connection.probeDotAccess() }
                                        else if connection.isConfigured {
                                            connection.connect()
                                            showConnection = true
                                        } else { showConnection = true }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ChatHeader(name: connection.directConversation?.transportName ?? "Andy",
                               color: connectionColor, status: connection.phase.title) {
                        showConnection = true
                    }
                }
            }
        }
        .sheet(isPresented: $showConnection) {
            ConnectionView(connection: connection, session: connection.selectedConversation(demo: demo) ?? demo)
        }
    }

    private var connectionColor: Color {
        switch connection.phase {
        case .signedIn: .green
        case .connecting, .awaitingConsent, .verifying, .paused, .expired: .orange
        case .failed: .red
        case .setupRequired, .signedOut, .cancelled: .gray
        }
    }
}

/// The whole header opens connection details inside the system toolbar's hit area.
private struct ChatHeader: View {
    let name: String
    let color: Color
    let status: String
    let showDetails: () -> Void

    var body: some View {
        Button(action: showDetails) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 60, alignment: .leading)
                Circle().fill(color).frame(width: 6, height: 6)
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), detalles de conexión")
        .accessibilityValue(status)
    }
}

private struct ConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var session: ConversationSession
    @State private var bottomPosition = CGFloat.greatestFiniteMagnitude
    @State private var refreshGestureState = MessageRefreshGestureState()

    var body: some View {
        VStack(spacing: 4) {
            if !session.isRealConnection {
                Text("DEMO")
                    .font(.caption2).foregroundStyle(.orange)
            }

            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if session.messages.isEmpty {
                                Text(session.isRealConnection
                                     ? "Sala verificada. Envía un mensaje a Andy; la primera respuesta confirmará la conexión completa."
                                     : "Demo local, sin conexión a Andy. Toca ⓘ para conectar.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            ForEach(session.messages) { message in
                                MessageBubble(message: message, pending: session.pendingMessageIDs.contains(message.id),
                                              assistantName: session.isRealConnection ? session.transportName : "Demo")
                            }
                            statusView
                            if let issue = session.storageIssue {
                                Text(issue).font(.caption2).foregroundStyle(.red)
                                Button("Volver a guardar", action: session.retrySaving).font(.caption2)
                            }
                            Color.clear.frame(height: 1).id("latest")
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: ChatBottomPosition.self,
                                        value: geometry.frame(in: .named("chat-scroll")).maxY)
                                })
                        }
                        .frame(minHeight: viewport.size.height, alignment: .bottom)
                    }
                    .coordinateSpace(name: "chat-scroll")
                    .onPreferenceChange(ChatBottomPosition.self) { bottomPosition = $0 }
                    .modifier(ChatRefreshObservation(session: session, gestureState: $refreshGestureState,
                        bottomPosition: bottomPosition, viewportHeight: viewport.size.height,
                        legacyGesture: refreshGesture(atBottom: bottomPosition <= viewport.size.height + 2)))
                    .overlay(alignment: .bottom) {
                        if session.isRealConnection && (refreshGestureState.pullDistance > 0 || refreshGestureState.isArmed || session.isSynchronizing) {
                            Group {
                                if session.isSynchronizing { ChatRefreshSpinner() }
                                else {
                                    Image(systemName: "arrow.clockwise")
                                        .rotationEffect(.degrees(min(refreshGestureState.pullDistance / refreshThreshold, 1) * 180))
                                        .foregroundStyle(refreshGestureState.isArmed ? .green : .white)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.9), in: Circle())
                            .allowsHitTesting(false)
                            .accessibilityLabel(session.isSynchronizing ? "Consultando mensajes nuevos"
                                : refreshGestureState.isArmed ? "Suelta para refrescar" : "Desliza hacia arriba para refrescar")
                        }
                    }
                    .accessibilityAction(named: Text("Sincronizar mensajes")) { session.refreshFromGesture() }
                    .onChange(of: session.deliveryState) { _, _ in
                        withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
                    }
                    .onChange(of: session.messages) { _, _ in
                        withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                }
            }

            HStack(spacing: 6) {
                TextField("Mensaje", text: $session.draft)
                    .font(.footnote)
                    .controlSize(.small)
                    .submitLabel(.done)
                    .accessibilityLabel("Mensaje: dictado o teclado nativo")
                    .disabled(!session.canEditDraft)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                        .frame(minWidth: 38, minHeight: 38)
                }
                .buttonStyle(.plain)
                .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.canSend)
                .accessibilityLabel(session.isRealConnection ? "Enviar mensaje al Dot" : "Enviar mensaje de demostración")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 8)
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { refreshGestureState.cancel() }
        }
        .task(id: session.conversationID) {
            if scenePhase == .active, !session.isRealConnection { session.resumeAutomatically() }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if session.isSynchronizing {
            Text("Sincronizando…").font(.caption2).foregroundStyle(.secondary)
        } else if let issue = session.synchronizationIssue {
            Text(issue).font(.caption2).foregroundStyle(.orange)
        }
        switch session.deliveryState {
        case .idle:
            EmptyView()
        case .answered:
            if session.followUpUntil != nil {
                Text("Refresca para ver mensajes desde otros clientes de tu Dot").font(.caption2).foregroundStyle(.secondary)
            }
        case .sending, .waiting:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(session.isRealConnection
                         ? (session.deliveryState == .sending ? "Conectando con Andy…" : "Esperando a Andy…")
                         : (session.deliveryState == .sending ? "Enviando demo…" : "Esperando demo…"))
                }
            }
            .font(.caption2)
        case .waitingForConnection:
            Text(session.isRealConnection ? "Sin conexión. El mensaje sigue pendiente." : "Sin conexión (simulada). El mensaje sigue pendiente.").font(.caption2)
        case .cancelled:
            if session.showsCancellationNotice {
                Text("Espera cancelada. No confirma una cancelación en el servicio.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            recoveryActions
        case .failed(let reason):
            Text(reason).font(.caption2).foregroundStyle(.orange)
            recoveryActions
        }
    }

    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.canRetry && !session.retryIsReadOnly {
                Button("Reanudar mensaje", action: session.retry)
            }
            if session.canDiscard {
                Button(session.isRealConnection ? "Descartar no enviado" : "Descartar demo", action: session.discardFailedTurn)
            }
        }
        .font(.caption2)
    }

    private var refreshThreshold: Double {
        // Native overscroll is rubber-banded; it is shorter than the finger's travel.
        if #available(watchOS 11.0, *) { return 28 }
        return 56
    }

    // Compatibility for watchOS 10, which has no native scroll observation API.
    private func refreshGesture(atBottom: Bool) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if !refreshGestureState.isTracking {
                    refreshGestureState.begin(enabled: atBottom && session.isRealConnection && !session.isSynchronizing,
                                              threshold: refreshThreshold)
                }
                guard -value.translation.height > abs(value.translation.width) else { return }
                refreshGestureState.update(distance: -value.translation.height)
            }
            .onEnded { _ in
                if refreshGestureState.release() { session.refreshFromGesture() }
            }
    }

    private func send() { session.send(session.draft) }

}

private struct ChatBottomPosition: PreferenceKey {
    static let defaultValue = CGFloat.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Observe native scrolling without installing a competing pan recognizer on watchOS 11+.
private struct ChatRefreshObservation<LegacyGesture: Gesture>: ViewModifier {
    @ObservedObject var session: ConversationSession
    @Binding var gestureState: MessageRefreshGestureState
    let bottomPosition: CGFloat
    let viewportHeight: CGFloat
    let legacyGesture: LegacyGesture
    @State private var interacting = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content
                .scrollBounceBehavior(.always, axes: .vertical)
                .onScrollPhaseChange { oldPhase, phase, context in
                    if phase == .tracking || phase == .interacting {
                        if !gestureState.isTracking {
                            gestureState.begin(enabled: session.isRealConnection && !session.isSynchronizing)
                        }
                        if phase == .interacting {
                            gestureState.update(distance: max(viewportHeight - bottomPosition,
                                                              overscroll(context.geometry)))
                        }
                    } else if oldPhase == .interacting && (phase == .decelerating || phase == .idle) {
                        // The preference can be one layout pass behind the final touch sample.
                        gestureState.update(distance: overscroll(context.geometry))
                        if gestureState.release() { session.refreshFromGesture() }
                    } else if phase == .idle || phase == .animating {
                        gestureState.cancel()
                    }
                    interacting = phase == .interacting
                }
                .onChange(of: bottomPosition) { _, bottom in
                    guard interacting, !session.isSynchronizing else { return }
                    gestureState.update(distance: viewportHeight - bottom)
                }
                .onScrollGeometryChange(for: CGFloat.self, of: overscroll) { _, distance in
                    guard interacting, !session.isSynchronizing else { return }
                    gestureState.update(distance: distance)
                }
                .onChange(of: session.isSynchronizing) { _, refreshing in
                    if refreshing { gestureState.cancel() }
                }
                .onDisappear { gestureState.cancel() }
        } else {
            content.simultaneousGesture(legacyGesture)
        }
    }

    @available(watchOS 11.0, *)
    private func overscroll(_ geometry: ScrollGeometry) -> CGFloat {
        // watchOS includes the top navigation inset in contentSize. Subtract it once.
        let bottom = max(-geometry.contentInsets.top, geometry.contentSize.height -
            geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height)
        return max(0, geometry.contentOffset.y - bottom)
    }
}

private struct ChatRefreshSpinner: View {
    @State private var rotating = false

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .foregroundStyle(.blue)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
    }
}

private struct ConnectionView: View {
    @ObservedObject var connection: ConnectionSession
    @ObservedObject var session: ConversationSession
    @Environment(\.dismiss) private var dismiss
    @State private var historyLimit = ChatHistorySettings.limit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(connection.phase.title).font(.headline)
                Text("Watch Dot D7 · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")").font(.caption2).foregroundStyle(.secondary)
                if let account = connection.accountLabel { Text(account) }
                if case .failed(let reason) = connection.phase {
                    Text(reason).foregroundStyle(.orange)
                }
                if connection.phase == .awaitingConsent {
                    Text("Abre Watch Dot en tu iPhone y completa la autorización en el navegador. La sesión llegará al reloj automáticamente.")
                }
                if connection.isRenewingSession {
                    ProgressView("Renovando sesión…")
                } else if connection.phase.isBusy {
                    ProgressView()
                    Button("Cancelar autorización", action: connection.cancel)
                } else if connection.phase != .signedIn {
                    Button(connection.actionTitle, action: connection.connect)
                    if connection.canResume {
                        Button("Cancelar autorización", action: connection.cancel)
                    }
                }
                Text(connection.phase == .signedIn
                     ? "El punto verde indica cuenta autorizada. El chat directo sigue siendo experimental."
                     : "Autoriza tu cuenta desde Watch Dot en tu iPhone. El chat con Andy se ejecuta en el reloj.")
                    .foregroundStyle(.secondary)

                if connection.phase == .signedIn {
                    if connection.canRenewSession {
                        Text("Renovación automática activada.").font(.caption2)
                    } else {
                        Text("Autoriza una vez más para activar la renovación automática de esta sesión.")
                            .font(.caption2)
                        Button("Activar renovación automática", action: connection.connect)
                    }
                    dotAccessProbe
                }

                if connection.accountLabel != nil {
                    Button("Cerrar sesión local", action: connection.signOutLocally)
                }
                Divider()
                Picker("Mensajes al sincronizar", selection: $historyLimit) {
                    ForEach(ChatHistorySettings.limits, id: \.self) { Text("\($0)").tag($0) }
                }
                .onChange(of: historyLimit) { _, value in ChatHistorySettings.limit = value }
                Text("Consulta mientras espera tu respuesta y una vez más al minuto. Al abrir solo muestra lo guardado. Al final del chat, desliza hacia arriba hasta que el icono cambie de color y suelta para sincronizar. watchOS puede aplazar la recepción.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Volver al chat") { dismiss() }
            }
            .font(.footnote)
            .padding(.horizontal, 8)
        }
        .onAppear { connection.refresh() }
    }

    private var dotAccessProbe: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat directo · experimental D4").font(.caption2).foregroundStyle(.secondary)
            if connection.dotProbeState == .checking {
                ProgressView("Consultando OpenAI…")
                Button("Cancelar prueba", action: connection.cancelDotProbe)
            } else {
                Button("Probar acceso a Andy", action: connection.probeDotAccess)
            }
            switch connection.dotProbeState {
            case .idle:
                Text("Consulta tu Dot primario y su sala desde el reloj. Solo lectura, directamente desde el reloj.")
            case .checking:
                EmptyView()
            case .cancelled:
                Text("Prueba cancelada. Puedes repetirla.")
            case .located(let dot):
                Text("Dot primario: \(dot.name ?? "sin nombre visible"). Sala y miembros verificados.")
                Text(session.isRealConnection
                     ? (session.deliveryState == .answered ? "Envío y respuesta de Andy verificados."
                        : "Chat directo habilitado. Vuelve al chat y envía un mensaje para verificar la respuesta de Andy.")
                     : "Sala verificada. Preparando el chat directo…")
                    .foregroundStyle(.orange)
            case .failed(let message):
                Text(message).foregroundStyle(.orange)
            }

        }
        .font(.caption2)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let pending: Bool
    let assistantName: String

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 14) }
            VStack(alignment: .leading, spacing: 3) {
                Text(message.role == .user ? "Tú" : assistantName)
                    .font(.caption2).foregroundStyle(.secondary)
                Text(message.text).font(.footnote)
                if pending { Text("Pendiente").font(.caption2).foregroundStyle(.orange) }
                HStack(spacing: 4) {
                    Text(message.timestampLabel())
                        .monospacedDigit()
                        .foregroundStyle(Color(white: 0.55))
                    if message.role == .assistant {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(red: 0.20, green: 0.72, blue: 0.95))
                            .accessibilityLabel("Mensaje recibido")
                    }
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 2)
            }
            .padding(8)
            .background(message.role == .user ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 14) }
        }
        .frame(maxWidth: .infinity)
    }
}
