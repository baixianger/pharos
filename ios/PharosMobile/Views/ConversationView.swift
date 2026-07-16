import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

struct ConversationView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var destination: ConversationSheet?
    @State private var replyingTo: MeshMessage?
    @State private var pendingAttachments: [MeshAttachment] = []
    @State private var showAttachmentActions = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isUploading = false
    @State private var previewURL: URL?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let notice = store.notice { noticeBar(notice) }
            if let error = store.error { errorBar(error) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { channelToolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .onAppear { draft = MobileRoomDraftCache.draft(for: store.selectedRoom) }
        .onChange(of: store.selectedRoom) { _, room in
            draft = MobileRoomDraftCache.draft(for: room)
        }
        .onChange(of: draft) { _, nextDraft in
            MobileRoomDraftCache.save(nextDraft, for: store.selectedRoom)
        }
        .sheet(item: $destination) { destination in
            if let room = store.selectedRoom {
                switch destination {
                case .spawn: SpawnAgentView(room: room)
                }
            }
        }
        .confirmationDialog("Add attachment", isPresented: $showAttachmentActions) {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            Button("Choose Image or PDF", systemImage: "folder") { showFileImporter = true }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in Task { await uploadPhoto(item) } }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image, .pdf]) { result in
            uploadFile(result)
        }
        .quickLookPreview($previewURL)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    channelWelcome

                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                        if startsNewDay(at: index) { dayDivider(for: message.date) }
                        MessageRow(
                            message: message,
                            member: store.members[message.from],
                            showsHeader: startsMessageGroup(at: index),
                            onReply: {
                                replyingTo = message
                                focused = true
                            },
                            onOpenAttachment: { attachment in
                                Task { previewURL = await store.downloadAttachment(attachment) }
                            }
                        )
                    }

                    Color.clear.frame(height: 10).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .background(Color(uiColor: .systemBackground))
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var channelToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "number")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(store.selectedRoom ?? "Chat")
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(channelSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if availableMembers.isEmpty {
                    Text("No agents in this room")
                } else {
                    ForEach(availableMembers, id: \.nick) { member in
                        Button {
                            store.insertMention(member.nick, into: &draft)
                            focused = true
                        } label: {
                            Label("Mention @\(member.nick)", systemImage: "at")
                        }
                    }
                }

                Divider()
                Button("Add agent", systemImage: "person.badge.plus") { destination = .spawn }
            } label: {
                Image(systemName: "person.2")
            }
            .accessibilityLabel("Room members")
        }
    }

    private var channelWelcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor.opacity(0.11))
                Image(systemName: "number")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 52, height: 52)

            Text("# \(store.selectedRoom ?? "chat")")
                .font(.title2.weight(.bold))
            Text("This is the beginning of the room. Messages and agent activity stay connected to this project context.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 7) {
            if let replyingTo { replyComposerCard(replyingTo) }
            if !pendingAttachments.isEmpty || isUploading { pendingAttachmentStrip }

            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 10) {
                    composerField
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 23))
                }
            } else {
                composerField
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .background(.bar.opacity(0.82))
    }

    private var composerField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                showAttachmentActions = true
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Add attachment")

            TextField("Message #\(store.selectedRoom ?? "room")", text: $draft, axis: .vertical)
                .lineLimit(1...7)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(sendDraft)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(trimmedDraft.isEmpty && pendingAttachments.isEmpty)
            .opacity(trimmedDraft.isEmpty && pendingAttachments.isEmpty ? 0.35 : 1)
            .accessibilityLabel("Send message")
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    private var availableMembers: [MeshMember] {
        guard let room = store.rooms.first(where: { $0.name == store.selectedRoom }) else { return [] }
        return room.members
            .filter { $0 != "human" }
            .compactMap { store.members[$0] }
            .sorted { $0.nick.localizedCaseInsensitiveCompare($1.nick) == .orderedAscending }
    }

    private var channelSubtitle: String {
        let total = availableMembers.count
        let active = availableMembers.filter { member in
            guard let state = member.state.flatMap(MeshSessionState.init(rawValue:)) else { return false }
            return state != .gone
        }.count
        return total == 0 ? "No agents" : "\(active) active · \(total) agents"
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendDraft() {
        guard !trimmedDraft.isEmpty || !pendingAttachments.isEmpty else { return }
        let text = draft
        let reply = replyingTo
        let attachments = pendingAttachments
        Task {
            if await store.send(text, replyTo: reply, attachments: attachments) {
                draft = ""
                replyingTo = nil
                pendingAttachments = []
            }
        }
    }

    private func replyComposerCard(_ message: MeshMessage) -> some View {
        HStack(spacing: 9) {
            Capsule().fill(Color.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(message.from == "human" ? "yourself" : message.from)")
                    .font(.caption.weight(.semibold))
                Text(message.text.isEmpty ? "Attachment" : message.text)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Cancel reply", systemImage: "xmark") { replyingTo = nil }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    private var pendingAttachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.mimeType == "application/pdf" ? "doc.richtext" : "photo")
                        Text(attachment.name).lineLimit(1)
                        Button("Remove", systemImage: "xmark.circle.fill") {
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.secondary.opacity(0.1), in: Capsule())
                }
                if isUploading { ProgressView().controlSize(.small).padding(.horizontal, 8) }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func uploadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isUploading = true
        defer { isUploading = false; selectedPhoto = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first ?? .image
        let ext = type.preferredFilenameExtension ?? "jpg"
        let name = "Image-\(UUID().uuidString.prefix(8)).\(ext)"
        if let attachment = await store.uploadAttachment(
            data: data, name: name, mimeType: type.preferredMIMEType ?? "image/jpeg"
        ) {
            pendingAttachments.append(attachment)
        }
    }

    private func uploadFile(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        Task {
            isUploading = true
            defer { isUploading = false }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let type = UTType(filenameExtension: url.pathExtension)
            if let attachment = await store.uploadAttachment(
                data: data, name: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream"
            ) {
                pendingAttachments.append(attachment)
            }
        }
    }

    private func startsMessageGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = store.messages[index]
        let previous = store.messages[index - 1]
        return current.from != previous.from || current.date.timeIntervalSince(previous.date) > 5 * 60
    }

    private func startsNewDay(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(store.messages[index].date, inSameDayAs: store.messages[index - 1].date)
    }

    private func dayDivider(for date: Date) -> some View {
        HStack(spacing: 10) {
            Divider()
            Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            Divider()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

/// Device-local room drafts survive tab switches and app relaunches without
/// turning unfinished text into synchronized Broker data.
private enum MobileRoomDraftCache {
    private static let defaultsKey = "pharos.mobile.roomDrafts.v1"

    static func draft(for room: String?) -> String {
        guard let room, !room.isEmpty else { return "" }
        return (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[room] ?? ""
    }

    static func save(_ draft: String, for room: String?) {
        guard let room, !room.isEmpty else { return }
        var drafts = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if draft.isEmpty { drafts.removeValue(forKey: room) }
        else { drafts[room] = draft }
        UserDefaults.standard.set(drafts, forKey: defaultsKey)
    }
}

private enum ConversationSheet: String, Identifiable {
    case spawn
    var id: String { rawValue }
}
