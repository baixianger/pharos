import SwiftUI

struct ConversationView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var destination: ConversationSheet?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let notice = store.notice { noticeBar(notice) }
            if let error = store.error { errorBar(error) }
        }
        .navigationTitle(store.selectedRoom ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Remote Control now lives in the Agents tab (tap an agent). The
                // room keeps only "add a member" here.
                Button("Spawn member", systemImage: "person.badge.plus") { destination = .spawn }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .sheet(item: $destination) { destination in
            if let room = store.selectedRoom {
                switch destination {
                case .spawn: SpawnAgentView(room: room)
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(store.messages) { MessageRow(message: $0, member: store.members[$0.from]) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !availableAgents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(availableAgents, id: \.self) { nick in
                            Button("@\(nick)") { store.insertMention(nick, into: &draft); focused = true }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message the room…", text: $draft, axis: .vertical)
                    .lineLimit(1...7).focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                Button {
                    let text = draft
                    Task { if await store.send(text) { draft = "" } }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var availableAgents: [String] {
        guard let room = store.rooms.first(where: { $0.name == store.selectedRoom }) else { return [] }
        return room.members.filter { $0 != "human" }.sorted()
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: text.contains("⚡") ? "bolt.fill" : "info.circle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark") { store.dismissNotice() }.labelStyle(.iconOnly)
        }
        .padding(10).background(.orange.opacity(0.1))
    }

    private func errorBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") { Task { await store.refresh() } }.font(.caption.weight(.semibold))
        }
        .padding(10).background(.red.opacity(0.08))
    }
}

private enum ConversationSheet: String, Identifiable {
    case spawn
    var id: String { rawValue }
}
