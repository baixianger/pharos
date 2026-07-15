import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RoomStore.self) private var store
    @State private var sheet: RootSheet?
    @State private var showNewRoom = false
    @State private var newRoomName = ""

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            RoomListView(selection: $store.selectedRoom)
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "slider.horizontal.3") { sheet = .settings }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New room", systemImage: "plus") { showNewRoom = true }
                    }
                }
        } detail: {
            if settings.mesh.host.isEmpty {
                ContentUnavailableView {
                    Label("Connect to your Mesh", systemImage: "network")
                } description: {
                    Text("Add the Tailscale address of the Mac hosting Pharos Mesh.")
                } actions: {
                    Button("Open Settings") { sheet = .settings }
                }
            } else if store.selectedRoom != nil {
                ConversationView()
            } else {
                ContentUnavailableView("No rooms", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .sheet(item: $sheet) { _ in SettingsView(showsDoneButton: true) }
        .alert("New room", isPresented: $showNewRoom) {
            TextField("Room name", text: $newRoomName)
            Button("Cancel", role: .cancel) { newRoomName = "" }
            Button("Create") {
                let name = newRoomName
                newRoomName = ""
                Task { await store.createRoom(named: name) }
            }
        }
        // Polling + the autoSelectsFirstRoom size-class rule are owned by
        // MainTabView so they apply app-wide, before the Chat tab is opened.
    }
}

private enum RootSheet: String, Identifiable {
    case settings
    var id: String { rawValue }
}
