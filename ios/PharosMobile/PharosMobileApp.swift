import SwiftUI
import UIKit

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
    @State private var distributedMesh: DistributedMeshSupport
    private let isDemo: Bool

    init() {
        let isDemo = PharosDemoMode.isEnabled
        self.isDemo = isDemo
        let settings = AppSettings(demo: isDemo)
        let identities = SSHIdentityStore()
        let distributedMesh = DistributedMeshSupport(demo: isDemo)
        _settings = State(initialValue: settings)
        _identities = State(initialValue: identities)
        _distributedMesh = State(initialValue: distributedMesh)
        _rooms = State(initialValue: RoomStore(
            settings: settings,
            identities: identities,
            distributedMesh: distributedMesh,
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
            .environment(distributedMesh)
            .onOpenURL { receivePairingURL($0) }
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
            .sheet(item: $pairing.pendingDevice) { pending in
                PairDeviceConfirmation(invitation: pending.invitation)
                    .environment(distributedMesh)
            }
            .alert("Pairing link unavailable", isPresented: $pairing.showsError) {
                Button("OK") {}
            } message: {
                Text(pairing.errorMessage ?? "Use a new pairing code from Pharos on your desktop.")
            }
            // Open the wizard on first run; close it once a Broker is paired.
            .task {
                await distributedMesh.start()
                let distributed = ProcessInfo.processInfo.environment[
                    "PHAROS_DISTRIBUTED"
                ] == "1"
                if !isDemo, !distributed, settings.mesh.host.isEmpty {
                    pairing.showsSetupGuide = true
                }
                while !Task.isCancelled, !isDemo {
                    _ = await distributedMesh.synchronizeOnce()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .onChange(of: settings.mesh.host) { _, host in
                if !host.isEmpty { pairing.showsSetupGuide = false }
            }
    }

    private func receivePairingURL(_ url: URL) {
        pairing.receive(url)
#if DEBUG
        // Device-lab hook: exercise the signed, single-use network handshake
        // without screen-coordinate automation. Release builds always require
        // the visible confirmation sheet.
        guard ProcessInfo.processInfo.environment[
            "PHAROS_TEST_AUTO_ACCEPT_DEVICE"
        ] == "1", let pending = pairing.pendingDevice else { return }
        pairing.pendingDevice = nil
        print("PHAROS_DEVICE_TEST invitation-received")
        Task { @MainActor in
            for _ in 0..<100 {
                if case .opening = distributedMesh.state {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                break
            }
            do {
                try await distributedMesh.accept(
                    pending.invitation, displayName: UIDevice.current.name
                )
                print("PHAROS_DEVICE_TEST pairing-accepted")
            } catch {
                print("PHAROS_DEVICE_TEST pairing-failed \(error)")
                pairing.errorMessage = "Pairing failed: \(error)"
                pairing.showsError = true
            }
        }
#endif
    }
}
