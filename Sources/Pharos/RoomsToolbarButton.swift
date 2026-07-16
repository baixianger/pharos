import SwiftUI
import UniformTypeIdentifiers

/// Toolbar chat-room switcher/manager. Replaces the in-view room tab strip: one
/// button in the window toolbar opens a popover to switch the current tab's
/// room, add a room, or rename/delete one. Each window tab holds its own
/// `openRoom`, so switching here only affects this tab.
struct RoomsToolbarButton: View {
    @Binding var openRoom: String?
    @State private var rooms: [String] = []
    @State private var show = false
    @State private var opening = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var addMemberTo: String?
    @State private var manageMembersIn: String?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Button { togglePopover() } label: {
            Label("Chat rooms", systemImage: "bubble.left.and.bubble.right")
        }
        .disabled(opening)
        .help("Switch, add, or manage chat rooms")
        .accessibilityLabel("Chat rooms")
        .onReceive(tick) { _ in if show { refresh() } }
        .task { refresh() } // warm the cache, but opening still awaits fresh data
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
        .sheet(item: Binding(get: { addMemberTo.map { RoomBox(name: $0) } },
                             set: { addMemberTo = $0?.name })) { box in
            AddMemberSheet(room: box.name)
        }
        .sheet(item: Binding(get: { manageMembersIn.map { RoomBox(name: $0) } },
                             set: { manageMembersIn = $0?.name })) { box in
            ManageRoomMembersSheet(room: box.name)
        }
    }

    private struct RoomBox: Identifiable { let name: String; var id: String { name } }

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
            Button { addMemberTo = r; show = false } label: { Image(systemName: "person.badge.plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Add an agent to this room")
            Button { manageMembersIn = r; show = false } label: { Image(systemName: "person.2") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename or remove members")
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

    /// Do not present from an empty/stale snapshot. SwiftUI fixes a popover's
    /// initial layout before its async `onAppear` refresh completes, which made
    /// the first click show only the first room; the second click used the now-
    /// warm cache. Fetch first, then present one complete snapshot.
    private func togglePopover() {
        if show { show = false; return }
        guard !opening else { return }
        opening = true
        Task {
            rooms = await fetchRooms()
            opening = false
            show = true
        }
    }

    private func fetchRooms() async -> [String] {
        await Task.detached {
            (MeshClient.send(MeshRequest(cmd: "list")).rooms ?? []).map(\.name).sorted()
        }.value
    }

    private func refresh() {
        Task {
            rooms = await fetchRooms()
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

/// Per-room member administration. Display names are aliases; rename keeps the
/// immutable session ID and mailbox, while remove only leaves this room.
struct ManageRoomMembersSheet: View {
    let room: String
    @Environment(\.dismiss) private var dismiss
    @State private var members: [MeshMemberInfo] = []
    @State private var loading = true
    @State private var memberToRename: MeshMemberInfo?
    @State private var renameText = ""
    @State private var memberToRemove: MeshMemberInfo?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Members · \(room)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }

            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            } else if members.isEmpty {
                ContentUnavailableView("No members", systemImage: "person.2.slash",
                                       description: Text("Agents that join this room appear here."))
                    .frame(minHeight: 140)
            } else {
                List(members, id: \.id) { member in
                    HStack(spacing: 10) {
                        Circle().fill(stateColor(member.state)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.nick).font(.callout.weight(.medium))
                            Text("session \(member.id.prefix(8))…")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            renameText = member.nick
                            memberToRename = member
                        } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Rename member")
                        Button(role: .destructive) { memberToRemove = member } label: {
                            Image(systemName: "person.badge.minus")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.red).help("Remove from room")
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(18)
        .frame(width: 430, height: 330)
        .task { await reload() }
        .alert("Rename member", isPresented: Binding(get: { memberToRename != nil },
                                                      set: { if !$0 { memberToRename = nil } }),
               presenting: memberToRename) { member in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { memberToRename = nil }
            Button("Rename") { rename(member) }
        } message: { member in
            Text("Only the room name changes. Session \(member.id.prefix(8))… remains the same.")
        }
        .confirmationDialog("Remove @\(memberToRemove?.nick ?? "") from \(room)?",
                            isPresented: Binding(get: { memberToRemove != nil },
                                                 set: { if !$0 { memberToRemove = nil } }),
                            titleVisibility: .visible,
                            presenting: memberToRemove) { member in
            Button("Remove member", role: .destructive) { remove(member) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the member from this room and discards its unread messages here. It does not stop the agent session.")
        }
        .alert("Member action failed", isPresented: Binding(get: { error != nil },
                                                            set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "Unknown error") }
    }

    private func reload() async {
        let roster = await Task.detached {
            MeshClient.send(MeshRequest(cmd: "who")).members ?? []
        }.value
        members = roster.filter { $0.rooms.contains(room) }.sorted { $0.nick < $1.nick }
        loading = false
    }

    private func rename(_ member: MeshMemberInfo) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        memberToRename = nil
        Task {
            let response = await Task.detached {
                MeshClient.send(MeshRequest(cmd: "rename-member", room: room, nick: member.nick,
                                            memberID: member.id, text: newName))
            }.value
            if response.ok { await reload() } else { error = response.error ?? "Rename failed" }
        }
    }

    private func remove(_ member: MeshMemberInfo) {
        memberToRemove = nil
        Task {
            let response = await Task.detached {
                MeshClient.send(MeshRequest(cmd: "leave", room: room, nick: member.nick,
                                            memberID: member.id))
            }.value
            if response.ok { await reload() } else { error = response.error ?? "Remove failed" }
        }
    }

    private func stateColor(_ raw: String?) -> Color {
        switch raw.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy: .orange
        case .blocked: .red
        case .stopped, .idle: .green
        case .gone: .gray.opacity(0.4)
        case nil: .gray
        }
    }
}

/// Spawn a Claude or Codex agent into a tmux session and drive it to join a
/// room, with live status. Ports the passive-join flow to a GUI sheet.
struct AddMemberSheet: View {
    let room: String
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    private enum SpawnHost: Hashable { case local, remote(UUID) }
    private enum DirChoice: Hashable { case scratch, project(String), custom }
    @State private var kind: AgentKind = .claude
    @State private var spawnHost: SpawnHost = .local
    @State private var nick = ""
    @State private var spawning = false
    @State private var phase: MeshSpawn.Phase?
    @State private var detail = ""
    @State private var dirChoice: DirChoice = .scratch
    @State private var customPath = ""
    @State private var showFolderPicker = false

    private var projectNames: [String] {
        store.projects.filter { $0.localPath != nil || !$0.localPaths.isEmpty }.map(\.name).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an agent to \(room)").font(.headline)

            Picker("Agent", selection: $kind) {
                Text("Claude").tag(AgentKind.claude)
                Text("Codex").tag(AgentKind.codex)
            }
            .pickerStyle(.segmented)
            .disabled(spawning)

            Picker("Host", selection: $spawnHost) {
                Text("This Mac · \(HostIdentity.current)").tag(SpawnHost.local)
                ForEach(store.executionHosts) { host in
                    Text("\(host.displayName) · \(host.sshHost)").tag(SpawnHost.remote(host.id))
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(spawning)

            Picker("Directory", selection: $dirChoice) {
                Text("Scratch (default)").tag(DirChoice.scratch)
                ForEach(projectNames, id: \.self) { Text($0).tag(DirChoice.project($0)) }
                Text("Custom folder…").tag(DirChoice.custom)
            }
            .disabled(spawning)
            if dirChoice == .custom {
                HStack {
                    Text(customPath.isEmpty ? "No folder chosen"
                         : (customPath as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { showFolderPicker = true }.disabled(spawning)
                }
            }

            HStack {
                Text("Nick").foregroundStyle(.secondary)
                TextField("e.g. reviewer", text: $nick)
                    .textFieldStyle(.roundedBorder)
                    .disabled(spawning)
                    .onSubmit(spawn)
            }

            if let phase {
                HStack(spacing: 8) {
                    switch phase {
                    case .joined:  Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    default:       ProgressView().controlSize(.small)
                    }
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Spawns \(kind == .claude ? "Claude" : "Codex") in a tmux session "
                     + (selectedHost.map { "on \($0.displayName) over SSH" } ?? "on this Mac")
                     + ", then has it join the room. Confirms once it's in.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(phase == .joined ? "Done" : "Cancel") { dismiss() }
                Button("Spawn & join") { spawn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(spawning || nick.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { customPath = url.path }
        }
    }

    private func spawn() {
        let n = nick.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !spawning else { return }
        let workDir: MeshSpawn.WorkDir
        switch dirChoice {
        case .scratch:            workDir = .scratch
        case .project(let name):  workDir = .project(name)
        case .custom:             workDir = customPath.isEmpty ? .scratch : .path(customPath)
        }
        spawning = true
        phase = .booting; detail = "starting…"
        let k = kind
        let host = selectedHost?.sshHost
        Task.detached {
            await MeshSpawn.spawn(room: room, nick: n, kind: k, host: host, workDir: workDir) { p in
                Task { @MainActor in
                    phase = p.phase; detail = p.detail
                    if p.phase == .joined || p.phase == .failed { spawning = false }
                }
            }
        }
    }

    private var selectedHost: ExecutionHostProfile? {
        guard case .remote(let id) = spawnHost else { return nil }
        return store.executionHosts.first { $0.id == id }
    }
}
