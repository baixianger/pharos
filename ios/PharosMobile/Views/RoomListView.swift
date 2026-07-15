import SwiftUI

struct RoomListView: View {
    @Environment(RoomStore.self) private var store
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if !store.rooms.isEmpty {
                Section {
                    ForEach(store.rooms) { room in
                        Button {
                            Task { await store.select(room: room.name) }
                        } label: {
                            RoomRow(
                                room: room,
                                members: room.members.compactMap { store.members[$0] },
                                isSelected: selection == room.name
                            )
                        }
                        .buttonStyle(.plain)
                        .tag(room.name)
                        .listRowInsets(.init(top: 5, leading: 12, bottom: 5, trailing: 12))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Rooms")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .overlay {
            if store.isRefreshing && store.rooms.isEmpty {
                ProgressView()
            } else if store.rooms.isEmpty {
                ContentUnavailableView(
                    "No rooms yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Connect to the Mesh hub in Settings, or create your first room with +.")
                )
            }
        }
        .refreshable { await store.refresh() }
    }
}

private struct RoomRow: View {
    let room: MeshRoom
    let members: [MeshMember]
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
                Image(systemName: "number")
                    .font(.body.weight(.bold))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(room.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if activeCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("\(activeCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var activeCount: Int {
        members.filter {
            guard let state = $0.state.flatMap(MeshSessionState.init(rawValue:)) else { return false }
            return state != .gone
        }.count
    }

    private var summary: String {
        let agents = room.members.filter { $0 != "human" }
        if agents.isEmpty { return "No agents joined" }
        if agents.count == 1 { return "@\(agents[0])" }
        return "@\(agents[0]) and \(agents.count - 1) more"
    }
}
