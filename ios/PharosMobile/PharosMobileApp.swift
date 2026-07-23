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
    @State private var lastAutoAcceptedDeviceLink: String?
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
        // cover (auto-shown until a personal Mesh is configured, re-openable from
        // Settings) rather than an inescapable root screen.
        MainTabView()
            .environment(settings)
            .environment(identities)
            .environment(rooms)
            .environment(pairing)
            .environment(distributedMesh)
            .onOpenURL { receivePairingURL($0) }
            .fullScreenCover(isPresented: $pairing.showsSetupGuide) {
                MeshSetupGuide()
                    .environment(settings)
                    .environment(identities)
                    .environment(rooms)
                    .environment(pairing)
                    .environment(distributedMesh)
            }
            .sheet(item: $pairing.pending) { invitation in
                PairBrokerConfirmation(invitation: invitation)
                    .environment(settings)
            }
            .sheet(item: $pairing.pendingDevice) { pending in
                PairDeviceConfirmation(invitation: pending.invitation)
                    .environment(distributedMesh)
                    .environment(pairing)
            }
            .alert("Pairing link unavailable", isPresented: $pairing.showsError) {
                Button("OK") {}
            } message: {
                Text(pairing.errorMessage ?? "Use a new pairing code from Pharos on your desktop.")
            }
            // Open the wizard on first run; close it once a Broker is paired.
            .task {
                await distributedMesh.start()
                let distributed = PharosMeshRuntimeMode.usesDistributedMesh
                if !isDemo {
                    if distributed {
                        pairing.showsSetupGuide =
                            distributedMesh.activeTrustGroupID == nil
                    } else if settings.mesh.host.isEmpty {
                        pairing.showsSetupGuide = true
                    }
                }
                while !Task.isCancelled, !isDemo {
                    await distributedMesh.ensureNetworkRunning()
                    distributedMesh.scheduleSynchronization()
                    // The task is scene-bound and is suspended with the app,
                    // so foreground chat can converge quickly without a
                    // permanent background polling cost.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onChange(of: settings.mesh.host) { _, host in
                if !host.isEmpty { pairing.showsSetupGuide = false }
            }
            .foregroundMeshSynchronization(
                distributedMesh: distributedMesh,
                isDemo: isDemo
            )
    }

    private func receivePairingURL(_ url: URL) {
#if DEBUG
        let autoAcceptsDeviceLinks = ProcessInfo.processInfo.environment[
            "PHAROS_TEST_AUTO_ACCEPT_DEVICE"
        ] == "1"
        if autoAcceptsDeviceLinks,
           lastAutoAcceptedDeviceLink == url.absoluteString {
            return
        }
        if autoAcceptsDeviceLinks {
            lastAutoAcceptedDeviceLink = url.absoluteString
        }
#endif
        pairing.receive(url)
#if DEBUG
        // Device-lab hook: exercise the signed, single-use network handshake
        // without screen-coordinate automation. Release builds always require
        // the visible confirmation sheet.
        guard autoAcceptsDeviceLinks,
              let pending = pairing.pendingDevice else { return }
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
                    pending.invitation,
                    displayName: UIDevice.current.name,
                    existingGroupDisposition: .archive
                )
                pairing.showsSetupGuide = false
                print("PHAROS_DEVICE_TEST pairing-accepted")
            } catch {
                print("PHAROS_DEVICE_TEST pairing-failed \(error)")
                pairing.errorMessage = "Pairing failed: \(error.localizedDescription)"
                pairing.showsError = true
            }
        }
#endif
    }
}

private struct ForegroundMeshSynchronizationModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let distributedMesh: DistributedMeshSupport
    let isDemo: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !isDemo else { return }
                Task { @MainActor in
                    await distributedMesh.ensureNetworkRunning()
                    _ = await distributedMesh.synchronizeOnce()
                }
            }
    }
}

private extension View {
    func foregroundMeshSynchronization(
        distributedMesh: DistributedMeshSupport,
        isDemo: Bool
    ) -> some View {
        modifier(ForegroundMeshSynchronizationModifier(
            distributedMesh: distributedMesh,
            isDemo: isDemo
        ))
    }
}
