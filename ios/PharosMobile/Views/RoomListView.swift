import SwiftUI

struct RoomListView: View {
    @Environment(RoomStore.self) private var store
    @Binding var selection: String?
    var suppressesSystemSelection = false
    @State private var search = ""

    var body: some View {
        List(selection: suppressesSystemSelection ? nil : $selection) {
            if !filteredRooms.isEmpty {
                Section {
                    ForEach(filteredRooms) { room in
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
                        .listRowInsets(.init(top: 0, leading: PharosDesign.pageInset,
                                            bottom: 0, trailing: PharosDesign.pageInset))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    PharosSectionTitle(title: "Rooms", count: filteredRooms.count)
                }
            }
        }
        .pharosPlainList()
        .overlay {
            if store.isRefreshing && store.rooms.isEmpty {
                PharosSkeletonRows(count: 5)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .background(PharosDesign.pageBackground)
            } else if store.rooms.isEmpty {
                ContentUnavailableView {
                    Label(store.error == nil ? "No rooms yet" : "Chat unavailable",
                          systemImage: store.error == nil ? "bubble.left.and.bubble.right" : "exclamationmark.triangle")
                } description: {
                    Text(store.error ?? emptyMessage)
                } actions: {
                    if store.error != nil { Button("Try again") { Task { await store.refresh() } } }
                }
            } else if filteredRooms.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .refreshable { await store.refresh() }
        .searchable(text: $search, prompt: "Search rooms")
    }

    private var filteredRooms: [MeshRoom] {
        guard !search.isEmpty else { return store.rooms }
        return store.rooms.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var emptyMessage: String {
        if PharosMeshRuntimeMode.usesDistributedMesh {
            return "Create your first room with +, or pair a trusted device to receive replicated rooms."
        }
        return "Connect to the Mesh Broker in Settings, or create your first room with +."
    }
}

private struct RoomRow: View {
    let room: MeshRoom
    let members: [MeshMember]
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor : roomColor.opacity(0.13))
                Image(systemName: "number")
                    .font(.body.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : roomColor)
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
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var roomColor: Color {
        let palette: [Color] = [.indigo, .teal, .orange, .blue, .purple, .pink]
        let checksum = room.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[checksum % palette.count]
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
