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

    init() {
        let settings = AppSettings()
        let identities = SSHIdentityStore()
        _settings = State(initialValue: settings)
        _identities = State(initialValue: identities)
        _rooms = State(initialValue: RoomStore(settings: settings, identities: identities))
    }

    var body: some View {
        RootView()
            .environment(settings)
            .environment(identities)
            .environment(rooms)
    }
}

