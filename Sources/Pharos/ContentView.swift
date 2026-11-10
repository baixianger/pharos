import SwiftUI

/// Guards the launch-count increment so it fires once per PROCESS, not once per
/// `ContentView` lifetime. SwiftUI can recreate `ContentView` (window reopen,
/// state restoration) within the same app launch; a per-`@State` flag would
/// re-fire and inflate the count, making the star prompt appear too early.
/// Only touched from the main actor (`onAppear`), so the unchecked access is safe.
private nonisolated(unsafe) var launchCountedThisProcess = false

enum ContentRouteState {
    /// Child room views load asynchronously. Once their parent route is nil,
    /// a late child write is stale and must not reopen Chat Rooms.
    static func applyingRoomWrite(current: String?, next: String) -> String? {
        current == nil ? nil : next
    }
}

enum WorkspaceSurface: Equatable {
    case dashboard
    case sessions
}

/// The unified content view for Pharos, presenting the new Grok-Bot inspired 3-pane client shell.
struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @State private var snapSettingsTab: Int?
    @State private var desktopClient: DesktopPharosClientService?

    var body: some View {
        @Bindable var store = store
        Group {
            if let t = snapSettingsTab {
                SettingsView(initialTab: t)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let desktopClient {
                PharosMainShellView(clientService: desktopClient, onAddProject: store.requestAdd)
            } else {
                ProgressView()
            }
        }
        .sheet(isPresented: $store.addRequested) { AddProjectSheet() }
        .task {
            if desktopClient == nil {
                desktopClient = DesktopPharosClientService(store: store, mesh: distributedMesh)
            }
            await SnapshotMode.run(
                store: store,
                select: { _ in },
                openRoom: { _ in },
                showSettings: { snapSettingsTab = $0 }
            )
        }
    }
}
