import SwiftUI

@main
struct PhoneDotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = PhoneConnectionSession()
    var body: some Scene {
        WindowGroup {
            PhoneConnectionView(connection: connection, connectivity: connection.connectivity)
                .onAppear { if scenePhase == .active { connection.enterForeground() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { connection.enterForeground() }
                    else if phase == .background { connection.enterBackground() }
                }
        }
    }
}

private struct PhoneConnectionView: View {
    @ObservedObject var connection: PhoneConnectionSession
    @ObservedObject var connectivity: CompanionConnectivity
    var body: some View {
        NavigationStack {
            List {
                Section("Apple Watch") {
                    Label(connectivity.reachable ? "Watch Dot disponible" : "Esperando al reloj",
                          systemImage: connectivity.reachable ? "applewatch.radiowaves.left.and.right" : "applewatch")
                    if !connectivity.counterpartInstalled {
                        Text("Instala Watch Dot desde la app Watch de tu iPhone.")
                    } else if !connectivity.reachable {
                        Text("Abre Watch Dot en tu Apple Watch y mantenlo cerca durante la autorización.")
                    }
                }
                Section("Cuenta de ChatGPT") {
                    Text(connection.status)
                    Text("Versión \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if connection.busy { ProgressView("Autorizando…") }
                    Button("Continuar con ChatGPT", action: connection.start)
                        .disabled(connection.busy || !connectivity.reachable)
                    if connection.busy || !connection.authorized {
                        Button("Cancelar autorización", role: .cancel, action: connection.cancel)
                    }
                }
                Section {
                    Text("El chat con Andy está en tu Apple Watch. Después del login, el reloj puede funcionar con su propia conexión a internet.")
                }
            }
            .navigationTitle("Watch Dot")
        }
    }
}
