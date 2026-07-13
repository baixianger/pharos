import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RoomStore.self) private var store
    @State private var showSettings = false
    @State private var showNewRoom = false
    @State private var newRoomName = ""

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            RoomListView(selection: $store.selectedRoom)
                .navigationTitle("Pharos")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gear") { showSettings = true }
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
                    Button("Open Settings") { showSettings = true }
                }
            } else if store.selectedRoom != nil {
                ConversationView()
            } else {
                ContentUnavailableView("No rooms", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("New room", isPresented: $showNewRoom) {
            TextField("Room name", text: $newRoomName)
            Button("Cancel", role: .cancel) { newRoomName = "" }
            Button("Create") {
                let name = newRoomName
                newRoomName = ""
                Task { await store.createRoom(named: name) }
            }
        }
        .task { await pollWhileVisible() }
    }

    private func pollWhileVisible() async {
        while !Task.isCancelled {
            await store.refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

