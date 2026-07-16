import SwiftUI

@main
struct PharosMobileApp: App {
    var body: some Scene {
        WindowGroup { AppContainer() }
    }
}

private struct AppContainer: View {
    @State private var settings: AppSettings
    @State private var identities: SSHIdentityStore
    @State private var rooms: RoomStore
    @State private var pairing = PairingCoordinator()

    init() {
        let settings = AppSettings()
        let identities = SSHIdentityStore()
        _settings = State(initialValue: settings)
        _identities = State(initialValue: identities)
        _rooms = State(initialValue: RoomStore(settings: settings, identities: identities))
    }

    var body: some View {
        @Bindable var pairing = pairing
        Group {
            if settings.mesh.host.isEmpty {
                BrokerSetupGuide()
            } else {
                MainTabView()
            }
        }
            .environment(settings)
            .environment(identities)
            .environment(rooms)
            .environment(pairing)
            .onOpenURL { pairing.receive($0) }
            .sheet(item: $pairing.pending) { invitation in
                PairBrokerConfirmation(invitation: invitation)
                    .environment(settings)
            }
            .alert("Pairing link unavailable", isPresented: $pairing.showsError) {
                Button("OK") {}
            } message: {
                Text(pairing.errorMessage ?? "Use a new pairing code from Pharos on your desktop.")
            }
    }
}
