import SwiftUI

struct RoomListView: View {
    @Environment(RoomStore.self) private var store
    @Binding var selection: String?

    var body: some View {
        List(store.rooms, selection: $selection) { room in
            Button {
                Task { await store.select(room: room.name) }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.name).font(.headline)
                        Text(memberSummary(room)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .tag(room.name)
        }
        .overlay {
            if store.isRefreshing && store.rooms.isEmpty {
                ProgressView()
            } else if store.rooms.isEmpty {
                ContentUnavailableView(
                    "No rooms yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Open Settings to connect to the Mesh hub, or create a room with +.")
                )
            }
        }
        .refreshable { await store.refresh() }
    }

    private func memberSummary(_ room: MeshRoom) -> String {
        let agents = room.members.filter { $0 != "human" }
        return agents.isEmpty ? "No agents joined" : agents.map { "@\($0)" }.joined(separator: " · ")
    }
}
