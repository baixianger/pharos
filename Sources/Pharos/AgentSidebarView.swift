import SwiftUI
import PharosMeshCore

struct AgentSidebarView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var selectedProject: Project.ID?
    @Binding var openRoom: String?
    @Binding var surface: WorkspaceSurface
    let toggleSidebar: () -> Void

    @AppStorage("pharos.sidebar.pinned.rooms") private var pinnedRoomsValue = ""
    @AppStorage("pharos.sidebar.pinned.sessions") private var pinnedSessionsValue = ""
    @State private var rooms: [MeshRoomInfo] = []
    @State private var members: [MeshMemberInfo] = []
    @State private var query = ""
    @State private var showsSearch = false
    @State private var showsNewSession = false
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            topControls
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            if showsSearch { searchField.transition(.move(edge: .top).combined(with: .opacity)) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    navigation

                    if !pinnedRooms.isEmpty || !pinnedMembers.isEmpty {
                        sectionTitle("Pinned")
                        ForEach(pinnedRooms, id: \.name) { roomRow($0, pinned: true) }
                        ForEach(pinnedMembers) { sessionRow($0, pinned: true) }
                    }

                    sectionTitle("Active sessions", count: filteredMembers.count)
                    ForEach(filteredMembers.prefix(8)) { sessionRow($0, pinned: false) }
                    if filteredMembers.count > 8 {
                        compactAction("Show all sessions", symbol: "ellipsis") {
                            openSessions()
                        }
                    }

                    if filteredMembers.isEmpty {
                        Text(query.isEmpty ? "No active sessions" : "No matching sessions")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }

            hostFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showsNewSession) {
            NewSessionLauncherSheet(isPresented: $showsNewSession,
                                    selectedProject: $selectedProject,
                                    surface: $surface)
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .task { reload() }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in reload() }
    }

    private var topControls: some View {
        HStack(spacing: 8) {
            Button { showsNewSession = true } label: {
                Label("New Session", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.glassProminent)

            utilityButton("magnifyingglass", help: "Search") {
                withAnimation(.easeInOut(duration: 0.18)) { showsSearch.toggle() }
            }
            utilityButton("sidebar.left", help: "Hide sidebar", action: toggleSidebar)
        }
    }

    private func utilityButton(_ symbol: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.glass)
        .help(help)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search rooms and sessions", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 11)
        .frame(height: 36)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var navigation: some View {
        VStack(spacing: 1) {
            navigationRow("Projects", count: store.projects.count, symbol: "square.grid.2x2",
                          selected: selectedProject != nil || (openRoom == nil && surface == .dashboard)) {
                openRoom = nil; selectedProject = nil; surface = .dashboard
            }
            .contextMenu {
                ForEach(store.projects) { project in
                    Button(project.name) { selectedProject = project.id; openRoom = nil; surface = .dashboard }
                }
            }

            navigationRow("Sessions", count: liveMembers.count, symbol: "rectangle.stack",
                          selected: surface == .sessions && selectedProject == nil && openRoom == nil) {
                openRoom = nil; selectedProject = nil; surface = .sessions
            }

            navigationRow("Rooms", count: rooms.count, symbol: "bubble.left.and.bubble.right",
                          selected: openRoom != nil) {
                selectedProject = nil; surface = .dashboard; openRoom = openRoom ?? ""
            }
            .contextMenu {
                ForEach(rooms, id: \.name) { room in
                    Button(pinnedRoomNames.contains(room.name) ? "Unpin #\(room.name)" : "Pin #\(room.name)") {
                        toggleRoomPin(room.name)
                    }
                }
            }

            navigationRow("Settings", count: nil, symbol: "gearshape", selected: false) {
                showsSettings = true
            }
        }
        .padding(.bottom, 4)
    }

    private func navigationRow(_ title: String, count: Int?, symbol: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                if let count {
                    Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(selected ? PharosTheme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack {
            Text(title.uppercased()).tracking(0.65)
            if let count { Text("\(count)").monospacedDigit() }
            Spacer()
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.top, 14)
        .padding(.bottom, 5)
    }

    private func sessionRow(_ member: MeshMemberInfo, pinned: Bool) -> some View {
        Button { openSessions() } label: {
            HStack(spacing: 9) {
                projectMarker(for: member)
                kindMark(member.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.nick).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text([member.kind?.capitalized, member.project].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                statusMark(member)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin") { toggleSessionPin(member.id) }
            if let room = member.rooms.first {
                Button("Open #\(room)") { openRoom = room; selectedProject = nil; surface = .dashboard }
            }
        }
    }

    private func roomRow(_ room: MeshRoomInfo, pinned: Bool) -> some View {
        Button {
            openRoom = room.name; selectedProject = nil; surface = .dashboard
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "number").font(.system(size: 11, weight: .semibold)).frame(width: 18)
                Text(room.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                Text("\(room.members.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .contextMenu { Button(pinned ? "Unpin" : "Pin") { toggleRoomPin(room.name) } }
    }

    private func kindMark(_ kind: String?) -> some View {
        let symbol: String = switch kind {
        case "claude": "sparkles"
        case "dsh": "point.3.connected.trianglepath.dotted"
        default: "terminal"
        }
        return Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func projectMarker(for member: MeshMemberInfo) -> some View {
        let project = store.projects.first { $0.name == member.project }
        return Capsule()
            .fill(project.map(projectColor) ?? Color.secondary.opacity(0.35))
            .frame(width: 3, height: 22)
    }

    private func projectColor(_ project: Project) -> Color {
        let bytes = project.id.uuidString.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff }
        return Color(hue: Double(bytes % 360) / 360, saturation: 0.58, brightness: 0.82)
    }

    private func statusMark(_ member: MeshMemberInfo) -> some View {
        let color: Color = switch member.state {
        case "blocked": PharosTheme.warning
        case "busy": PharosTheme.accent
        case "gone": .secondary
        default: PharosTheme.success
        }
        return Circle().fill(color).frame(width: 7, height: 7)
            .help(member.state ?? "online")
    }

    private func compactAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).padding(.horizontal, 9)
        }
        .buttonStyle(.plain)
    }

    private var hostFooter: some View {
        HStack(spacing: 7) {
            Circle().fill(PharosTheme.success).frame(width: 6, height: 6)
            Text(hostNames.isEmpty ? "Local runtime" : hostNames.joined(separator: " + "))
                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
        .glassEffect(.regular, in: Rectangle())
    }

    private var filteredMembers: [MeshMemberInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return liveMembers.filter {
            q.isEmpty || [$0.nick, $0.kind, $0.project, $0.host].compactMap { $0 }
                .joined(separator: " ").localizedCaseInsensitiveContains(q)
        }
    }

    private var liveMembers: [MeshMemberInfo] {
        var seen = Set<String>()
        return members.filter { $0.state != "gone" && seen.insert($0.id).inserted }
            .sorted { attentionRank($0) < attentionRank($1) }
    }

    private var pinnedRoomNames: Set<String> { decodedPins(pinnedRoomsValue) }
    private var pinnedSessionIDs: Set<String> { decodedPins(pinnedSessionsValue) }
    private var pinnedRooms: [MeshRoomInfo] { rooms.filter { pinnedRoomNames.contains($0.name) } }
    private var pinnedMembers: [MeshMemberInfo] { liveMembers.filter { pinnedSessionIDs.contains($0.id) } }
    private var hostNames: [String] { Array(Set(liveMembers.compactMap(\.host))).sorted() }

    private func attentionRank(_ member: MeshMemberInfo) -> Int {
        switch member.state { case "blocked": 0; case "busy": 1; case "stopped", "idle": 2; default: 3 }
    }

    private func decodedPins(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    private func toggleRoomPin(_ name: String) {
        var values = pinnedRoomNames
        if !values.insert(name).inserted { values.remove(name) }
        pinnedRoomsValue = values.sorted().joined(separator: "\n")
    }

    private func toggleSessionPin(_ id: String) {
        var values = pinnedSessionIDs
        if !values.insert(id).inserted { values.remove(id) }
        pinnedSessionsValue = values.sorted().joined(separator: "\n")
    }

    private func openSessions() {
        openRoom = nil; selectedProject = nil; surface = .sessions
    }

    private func reload() {
        let roomResponse = MeshClient.send(MeshRequest(cmd: "rooms"))
        let memberResponse = MeshClient.send(MeshRequest(cmd: "who"))
        if roomResponse.ok { rooms = roomResponse.rooms ?? [] }
        if memberResponse.ok { members = memberResponse.members ?? [] }
    }
}
