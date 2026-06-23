import SwiftUI

/// In-window chat-room pane: the conversation in the middle, the room list on the
/// right. Reads the per-room transcript JSONL the broker writes, refreshing on a
/// timer. There's a human input box at the bottom — kept as a placeholder; for now
/// a human message only queues for whoever is already waiting, it can't wake a
/// stopped agent.
struct MeshRoomView: View {
    @Environment(ProjectStore.self) private var store
    @State private var rooms: [String] = []
    @State private var room: String = ""
    @State private var messages: [MeshMsg] = []
    @State private var draft: String = ""
    @State private var renameTarget: String?
    @State private var renameText: String = ""
    @State private var issueRef: IssueRef?
    private struct IssueRef: Identifiable { let project: String; let number: Int; var id: String { "\(project)#\(number)" } }
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            chatPane
            Divider()
            roomList.frame(width: 210)
        }
        .navigationTitle("Chat Rooms")
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reload() }
        .onChange(of: room) { _, r in messages = load(r) }
        .alert("Rename room", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let old = renameTarget { renameRoom(old, to: renameText) }
                renameTarget = nil
            }
        }
        // Issue references (project#number) in messages are tappable links.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "pharosissue" else { return .systemAction }
            let parts = url.pathComponents                       // ["/", project, number]
            if parts.count >= 3, let n = Int(parts[2]) {
                issueRef = IssueRef(project: parts[1].removingPercentEncoding ?? parts[1], number: n)
            }
            return .handled
        })
        .sheet(item: $issueRef) { issuePopup($0) }
    }

    /// Turn `project#number` tokens into tappable issue links.
    private func attributed(_ text: String) -> AttributedString {
        guard let regex = try? NSRegularExpression(pattern: "([A-Za-z0-9._-]+)#([0-9]+)") else { return AttributedString(text) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var idx = 0
        for m in matches {
            if m.range.location > idx {
                result += AttributedString(ns.substring(with: NSRange(location: idx, length: m.range.location - idx)))
            }
            let proj = ns.substring(with: m.range(at: 1))
            let num = ns.substring(with: m.range(at: 2))
            var run = AttributedString(ns.substring(with: m.range))
            let enc = proj.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? proj
            run.link = URL(string: "pharosissue://x/\(enc)/\(num)")
            run.foregroundColor = .accentColor
            run.underlineStyle = .single
            result += run
            idx = m.range.location + m.range.length
        }
        if idx < ns.length { result += AttributedString(ns.substring(from: idx)) }
        return result
    }

    @ViewBuilder
    private func issuePopup(_ ref: IssueRef) -> some View {
        let issue = store.projects.first { $0.name == ref.project }?.issues.first { $0.number == ref.number }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(ref.project) #\(ref.number)").font(.headline)
                Spacer()
                Button("Done") { issueRef = nil }.keyboardShortcut(.cancelAction)
            }
            if let i = issue {
                HStack(spacing: 6) {
                    Image(systemName: i.status.symbol).foregroundStyle(.secondary)
                    Text(i.status.label).font(.callout).foregroundStyle(.secondary)
                }
                Text(i.title).font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !i.body.isEmpty {
                    ScrollView {
                        Text(i.body).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("No issue “\(ref.project)#\(ref.number)” found in this registry.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 440, height: 340)
    }

    private func deleteRoom(_ r: String) {
        rooms.removeAll { $0 == r }                 // optimistic
        if room == r { room = rooms.first ?? "" }
        Task.detached { _ = MeshClient.send(MeshRequest(cmd: "delete", room: r)) }
    }

    private func renameRoom(_ old: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old else { return }
        Task.detached { _ = MeshClient.send(MeshRequest(cmd: "rename", room: old, text: n)) }
        if let i = rooms.firstIndex(of: old) { rooms[i] = n; rooms.sort() }   // optimistic
        if room == old { room = n }
    }

    // MARK: middle — the conversation

    private var chatPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "message.fill").foregroundStyle(.tint)
                Text(room.isEmpty ? "Chat Rooms" : room).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            if room.isEmpty {
                ContentUnavailableView("No chat rooms yet",
                    systemImage: "message",
                    description: Text("When agents talk via `pharos mesh`, rooms appear on the right."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }

            Divider()
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in row(m) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func row(_ m: MeshMsg) -> some View {
        let mine = m.from == "human"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(m.from).font(.callout.weight(.semibold)).foregroundStyle(mine ? Color.secondary : Color.accentColor)
                if !m.to.isEmpty {
                    Text("→ " + m.to.map { "@\($0)" }.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Date(timeIntervalSince1970: m.ts).formatted(date: .omitted, time: .standard))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(attributed(m.text)).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Placeholder human input. Posting works (queues for any waiting agent) but
    /// can't wake a stopped one — hence the honest placeholder text.
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Human messages can't notify agents yet — they queue for whoever's waiting",
                      text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(room.isEmpty)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(room.isEmpty || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    // MARK: right — the room list

    private var roomList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ROOMS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
            if rooms.isEmpty {
                Text("none yet").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rooms, id: \.self) { r in
                        Button { room = r } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.bubble.right").font(.caption)
                                Text(r).font(.callout).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(r == room ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { renameText = r; renameTarget = r } label: { Label("Rename…", systemImage: "pencil") }
                            Button(role: .destructive) { deleteRoom(r) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.18))
    }

    // MARK: data

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !room.isEmpty else { return }
        let r = room
        draft = ""
        Task.detached { _ = MeshClient.send(MeshRequest(cmd: "say", room: r, nick: "human", text: text, to: nil)) }
    }

    private func reload() {
        refreshRooms()
        if room.isEmpty, let first = rooms.first { room = first }
        if !room.isEmpty { messages = load(room) }
    }

    private func refreshRooms() {
        let dir = MeshPaths.transcriptDir
        let found = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        rooms = found.filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func load(_ room: String) -> [MeshMsg] {
        guard !room.isEmpty, let data = try? String(contentsOf: MeshPaths.transcript(room), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: "\n").compactMap { try? dec.decode(MeshMsg.self, from: Data($0.utf8)) }
    }
}
