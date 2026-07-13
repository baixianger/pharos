import SwiftUI

/// Toolbar chat-room switcher/manager. Replaces the in-view room tab strip: one
/// button in the window toolbar opens a popover to switch the current tab's
/// room, add a room, or rename/delete one. Each window tab holds its own
/// `openRoom`, so switching here only affects this tab.
struct RoomsToolbarButton: View {
    @Binding var openRoom: String?
    @State private var rooms: [String] = []
    @State private var show = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Button { show.toggle() } label: {
            Label("Chat rooms", systemImage: "bubble.left.and.bubble.right")
        }
        .help("Switch, add, or manage chat rooms")
        .accessibilityLabel("Chat rooms")
        .onReceive(tick) { _ in if show { refresh() } }
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
        .alert("Rename room", isPresented: Binding(get: { renaming != nil },
                                                   set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let old = renaming { rename(old, to: renameText) }
                renaming = nil
            }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CHAT ROOMS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)

            if rooms.isEmpty {
                Text("No rooms yet — add one below, or agents create them when they `join`.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rooms, id: \.self) { r in roomRow(r) }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 260)
            }

            Divider().padding(.vertical, 6)
            HStack(spacing: 6) {
                Image(systemName: "plus.bubble").foregroundStyle(.secondary)
                TextField("New room…", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addRoom)
                Button("Add", action: addRoom)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: 280)
        .onAppear(perform: refresh)
    }

    private func roomRow(_ r: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right").font(.caption)
                .foregroundStyle(r == openRoom ? Color.accentColor : .secondary)
            Text(r).font(.callout).lineLimit(1)
                .foregroundStyle(r == openRoom ? Color.primary : .primary)
            Spacer(minLength: 8)
            Button { renameText = r; renaming = r } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
            Button(role: .destructive) { deleteRoom(r) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.red.opacity(0.85)).help("Delete room + transcript")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(r == openRoom ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { openRoom = r; show = false }   // switch THIS tab to the room
    }

    // MARK: data

    private func refresh() {
        Task {
            let names = await Task.detached { () -> [String] in
                (MeshClient.send(MeshRequest(cmd: "list")).rooms ?? []).map(\.name).sorted()
            }.value
            rooms = names
        }
    }

    private func addRoom() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        newName = ""
        Task.detached { _ = MeshClient.send(MeshRequest(cmd: "create", room: n)) }
        if !rooms.contains(n) { rooms.append(n); rooms.sort() }   // optimistic
        openRoom = n; show = false                                // open it in this tab
    }

    private func rename(_ old: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old else { return }
        Task.detached { _ = MeshClient.send(MeshRequest(cmd: "rename", room: old, text: n)) }
        if let i = rooms.firstIndex(of: old) { rooms[i] = n; rooms.sort() }   // optimistic
        if openRoom == old { openRoom = n }
    }

    private func deleteRoom(_ r: String) {
        rooms.removeAll { $0 == r }
        if openRoom == r { openRoom = rooms.first ?? "" }
        Task.detached { _ = MeshClient.send(MeshRequest(cmd: "delete", room: r)) }
    }
}
