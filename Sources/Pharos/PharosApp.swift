import SwiftUI
import AppKit

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
        PharosApp.main()
    }
}

struct PharosApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var store = ProjectStore()
    @State private var showsBrokerSetup: Bool
    // Owns the Sparkle update lifecycle for the app's lifetime.
    private let updaterController = UpdaterController()

    init() {
        let prefs = PharosPrefs.shared
        let alreadyConfigured = prefs.bool(forKey: "pharos.hostBroker")
            || !(prefs.string(forKey: "pharos.meshServerEndpoint") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _showsBrokerSetup = State(initialValue: !alreadyConfigured)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showsBrokerSetup {
                    BrokerSetupOnboardingView {
                        showsBrokerSetup = false
                    }
                } else {
                    ContentView()
                }
            }
                .environment(store)
                .preferredColorScheme(store.appearance.colorScheme)
                .task {
                    // Upgrade bridge: restore a reachable legacy Mac pairing
                    // before mesh routing/spawn/poke reads `peerHost`.
                    await store.recoverLegacyPeerIfNeeded()
                    // The hub role comes from the synced store (Pharos#5 P2), so
                    // every Mac reads the same answer. Hub: bind the broker to TCP
                    // so peers can dial in. Everyone else: demote any stray
                    // TCP-bound broker (split-brain), then pair to the hub and
                    // persist the dial endpoint so CLI/hooks on this Mac follow
                    // it with zero env config — without waiting for the Rooms
                    // view to be opened.
                    if let endpoint = store.validMeshServerEndpoint {
                        // A persistent headless broker supersedes the old
                        // Mac-to-Mac hub election. Stop any stale local TCP hub
                        // and persist the endpoint so CLI/hooks follow it too.
                        if store.isMeshHub { store.setMeshHub(false) }
                        await Task.detached { MeshHosting.demoteStrayHub() }.value
                        MeshClient.hostTCPEndpoint = nil
                        MeshClient.remoteEndpoint = endpoint
                        MeshPaths.setDialEndpointFile(endpoint)
                    } else if store.isMeshHub {
                        await Task.detached { MeshHosting.apply(hosting: true) }.value
                    } else {
                        await Task.detached { MeshHosting.demoteStrayHub() }.value
                        let peer = store.peerHost
                        if !peer.isEmpty {
                            let ep = await Task.detached { MeshRemote.resolve(peerHost: peer, isHub: false) }.value
                            // Fail-open: an unreachable peer keeps the last-known
                            // endpoint file rather than islanding this Mac's agents.
                            if let ep {
                                MeshClient.remoteEndpoint = ep
                                MeshPaths.setDialEndpointFile(ep)
                            }
                        }
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
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
        }

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(nsImage: LighthouseIcon.menuBar)
        }
        .menuBarExtraStyle(.menu)
    }
}
