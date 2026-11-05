import SwiftUI
import AppKit
import PharosRuntime
import PharosMeshCore

/// Real entry point. Two front doors share one binary:
///   • a CLI subcommand   → the `pharos` CLI (e.g. `Pharos list`, `Pharos launch …`)
///   • anything else      → the SwiftUI GUI, unchanged
/// The CLI is only entered for a bare-word subcommand (or `--help`/`--version`),
/// so GUI launch arguments from LaunchServices (`-psn_…`, `-NSDocument…`) still
/// open the app normally.
@main
enum PharosMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        // Invoked as `chat` (a symlink to this binary) → it's the mesh chat room.
        let invokedAs = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? ""
        if invokedAs == "chat" {
            exit(await CLI.run(["mesh"] + args))
        }
        if let first = args.first, CLI.isCommand(first) {
            exit(await CLI.run(args))
        }
        // Snapshot mode: become an ACCESSORY app BEFORE any window exists, so it
        // never activates, never steals focus, and never switches Spaces — the
        // capture window lives off-screen and the user's foreground app is
        // untouched. Referencing NSApplication.shared here (pre-`main()`)
        // creates the app instance so the very first window inherits the policy.
        if ProcessInfo.processInfo.environment["PHAROS_SNAPSHOT"]?.isEmpty == false {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        if PharosMeshRuntimeMode.usesDistributedMesh {
            MeshClient.allowsLocalDaemonAutoSpawn = false
        }
        PharosApp.main()
    }
}

struct PharosApp: App {
    @NSApplicationDelegateAdaptor(PharosApplicationDelegate.self)
    private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var store = ProjectStore()
    @State private var distributedMesh = DistributedMeshSupport()
    @State private var showsBrokerSetup: Bool
    @State private var pendingMeshInvitation: PendingMacMeshInvitation?
    // Owns the Sparkle update lifecycle for the app's lifetime.
    private let updaterController = UpdaterController()

    init() {
        let prefs = PharosPrefs.shared
        let distributed = PharosMeshRuntimeMode.usesDistributedMesh
        let runtimeStore = PharosRuntimeConfigurationStore(defaults: prefs)
        let alreadyConfigured = runtimeStore.isConfigured
            || prefs.bool(forKey: "pharos.hostBroker")
            || !(prefs.string(forKey: "pharos.meshServerEndpoint") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _showsBrokerSetup = State(
            initialValue: !distributed && !alreadyConfigured
        )
    }

    var body: some Scene {
        WindowGroup("Pharos") {
            PharosRootView(showsBrokerSetup: $showsBrokerSetup)
                .environment(store)
                .environment(distributedMesh)
                .tint(PharosTheme.accent)
                .preferredColorScheme(store.appearance.colorScheme)
                .onOpenURL { url in
                    guard distributedMesh.isProductModeEnabled,
                          let invitation = try? MeshTrustInvitationLink.decode(url)
                    else { return }
                    pendingMeshInvitation = PendingMacMeshInvitation(
                        invitation: invitation
                    )
                }
                .sheet(item: $pendingMeshInvitation) { pending in
                    JoinMeshSheet(invitation: pending.invitation)
                        .environment(distributedMesh)
                }
                .task {
                    if distributedMesh.isProductModeEnabled {
                        applicationDelegate.shutdownDistributedMesh = {
                            await distributedMesh.shutdownApplicationRuntime()
                        }
                        distributedMesh.ensureApplicationRuntime(store: store)
                        return
                    }
                    await distributedMesh.start()
                    guard !store.didBootstrapMesh else { return }
                    store.didBootstrapMesh = true
                    store.startMeshSnapshotPolling()
                    await store.recoverLegacyPeerIfNeeded()
                    // Runtime ownership lives in PharosRuntime. Startup only
                    // asks the application service to converge saved intent.
                    do {
                        try await store.applyRuntimeConfiguration(store.runtimeConfiguration)
                    } catch {
                        fputs("Pharos runtime reconcile failed: \(error.localizedDescription)\n", stderr)
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            // Replace the default "About Pharos" with our custom window.
            CommandGroup(replacing: .appInfo) {
                Button("About Pharos") { openWindow(id: "about") }
            }
            // "Check for Updates…" appears in the app menu (after About Pharos).
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .newItem) {
                Button("Add Project…") { store.requestAdd() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Command Palette…") { store.requestPalette() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }

        // Custom About window
        Window("About Pharos", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Set Up Mesh Broker", id: "broker-setup") {
            BrokerSetupWindow()
                .environment(store)
        }
        .defaultSize(width: 900, height: 720)

        Settings {
            SettingsView()
                .environment(store)
                .environment(distributedMesh)
        }

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(nsImage: LighthouseIcon.menuBar)
                // The menu-bar label exists even when macOS restores no main
                // window, so it is the reliable application-lifetime anchor
                // for the decentralized endpoint.
                .task {
                    distributedMesh.ensureApplicationRuntime(store: store)
                }
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct PharosRootView: View {
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Binding var showsBrokerSetup: Bool

    var body: some View {
        if distributedMesh.isProductModeEnabled {
            switch distributedMesh.state {
            case .opening:
                ProgressView("Opening your private Mesh…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if distributedMesh.activeTrustGroupID == nil {
                    MeshSetupView()
                } else {
                    ContentView()
                }
            case .failed(let message):
                ContentUnavailableView(
                    "Private Mesh unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        } else if showsBrokerSetup {
            BrokerSetupOnboardingView {
                showsBrokerSetup = false
            }
        } else {
            ContentView()
        }
    }
}
