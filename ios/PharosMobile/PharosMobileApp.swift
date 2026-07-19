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
    private let isDemo: Bool

    init() {
        let isDemo = PharosDemoMode.isEnabled
        self.isDemo = isDemo
        let settings = AppSettings(demo: isDemo)
        let identities = SSHIdentityStore()
        _settings = State(initialValue: settings)
        _identities = State(initialValue: identities)
        _rooms = State(initialValue: RoomStore(
            settings: settings,
            identities: identities,
            demoData: isDemo ? .store : nil
        ))
    }

    var body: some View {
        @Bindable var pairing = pairing
        // The main app is always the root; the setup wizard is a dismissible
        // cover (auto-shown until a Broker is configured, re-openable from
        // Settings) rather than an inescapable root screen.
        MainTabView()
            .environment(settings)
            .environment(identities)
            .environment(rooms)
            .environment(pairing)
            .onOpenURL { pairing.receive($0) }
            .fullScreenCover(isPresented: $pairing.showsSetupGuide) {
                BrokerSetupGuide()
                    .environment(settings)
                    .environment(identities)
                    .environment(rooms)
                    .environment(pairing)
            }
            .sheet(item: $pairing.pending) { invitation in
                PairBrokerConfirmation(invitation: invitation)
                    .environment(settings)
            }
            .alert("Pairing link unavailable", isPresented: $pairing.showsError) {
                Button("OK") {}
            } message: {
                Text(pairing.errorMessage ?? "Use a new pairing code from Pharos on your desktop.")
            }
            // Open the wizard on first run; close it once a Broker is paired.
            .task {
                if !isDemo, settings.mesh.host.isEmpty { pairing.showsSetupGuide = true }
            }
            .onChange(of: settings.mesh.host) { _, host in
                if !host.isEmpty { pairing.showsSetupGuide = false }
            }
    }
}
