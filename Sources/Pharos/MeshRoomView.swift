import SwiftUI

/// In-window chat-room pane: the conversation in the middle, the room list on the
/// right. Reads the per-room transcript JSONL the broker writes, refreshing on a
/// timer. There's a human input box at the bottom — kept as a placeholder; for now
/// a human message only queues for whoever is already waiting, it can't wake a
/// stopped agent.
struct MeshRoomView: View {
    @State private var rooms: [String] = []
    @State private var room: String = ""
    @State private var messages: [MeshMsg] = []
    @State private var draft: String = ""
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
    }

    // MARK: middle — the conversation

    private var chatPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sailboat.fill").foregroundStyle(.tint)
                Text(room.isEmpty ? "Chat Rooms" : room).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            if room.isEmpty {
                ContentUnavailableView("No chat rooms yet",
                    systemImage: "sailboat",
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
            Text(m.text).font(.callout).textSelection(.enabled)
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
