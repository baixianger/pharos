import SwiftUI

/// Read-only window into the agent chat rooms: pick a room, watch the agents
/// talk. Reads the per-room transcript JSONL the broker writes and refreshes on
/// a timer. No human send (agents-only for now) — this is a viewer.
struct MeshRoomView: View {
    @State private var rooms: [String] = []
    @State private var room: String = ""
    @State private var messages: [MeshMsg] = []
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rooms.isEmpty {
                ContentUnavailableView("No chat rooms yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("When agents talk via `pharos mesh`, the room transcript shows up here."))
                    .frame(maxHeight: .infinity)
            } else {
                transcript
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reload() }
        .onChange(of: room) { _, r in messages = load(r) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
            Text("Chat Rooms").font(.headline)
            Spacer()
            if !rooms.isEmpty {
                Picker("Room", selection: $room) {
                    ForEach(rooms, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 220)
            }
        }
        .padding(12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                        row(m)
                    }
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(m.from).font(.callout.weight(.semibold)).foregroundStyle(.tint)
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

    // MARK: data

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
        return data.split(separator: "\n").compactMap { line in
            try? dec.decode(MeshMsg.self, from: Data(line.utf8))
        }
    }
}
