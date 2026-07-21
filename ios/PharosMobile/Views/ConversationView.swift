import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
import UIKit

struct ConversationView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var destination: ConversationSheet?
    @State private var replyingTo: MeshMessage?
    @State private var pendingAttachments: [MeshAttachment] = []
    @State private var showAttachmentPanel = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCameraPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var previewURL: URL?
    /// Armed only after the opening scroll-to-bottom has settled, so the
    /// top sentinel can't page (and re-anchor upward) while the room opens.
    @State private var allowsHistoryPaging = false
    /// Bumped after a successful send to force a scroll to the newest message,
    /// independent of whether the reloaded tail's last id changed.
    @State private var scrollBottomTick = 0
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
            allowsHistoryPaging = false
        }
        .onChange(of: draft) { _, nextDraft in
            MobileRoomDraftCache.save(nextDraft, for: store.selectedRoom)
        }
        .sheet(item: $destination) { destination in
            if let room = store.selectedRoom {
                switch destination {
                case .spawn: SpawnAgentView(room: room)
                case .manage: ManageRoomSheet(roomName: room)
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos,
                      maxSelectionCount: 5, matching: .images)
        .onChange(of: selectedPhotos) { _, items in Task { await uploadPhotos(items) } }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image, .pdf]) { result in
            uploadFile(result)
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraPickerView { image in uploadCameraImage(image) }
                .ignoresSafeArea()
        }
        .quickLookPreview($previewURL)
    }

    // Inverted transcript: the LazyVStack renders newest→oldest, and both the
    // ScrollView and every cell are flipped upside down. The newest message
    // therefore rests at scroll offset 0 (the visual bottom) — an offset the
    // keyboard and the growing composer can't move, which is what made the old
    // .scrollPosition(anchor:.bottom) approach jump to a blank region while
    // typing. Prepended history lands off-screen at the visual top (no yank),
    // and a new message inserts at offset 0 so it auto-appears when at rest.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(transcriptCells.reversed())) { cell in
                        transcriptCellView(cell).flipUpsideDown()
                    }
                    Group {
                        if store.hasMoreHistory { historyLoader } else { channelWelcome }
                    }
                    .flipUpsideDown()
                }
                .scrollTargetLayout()
                .padding(.vertical, 8)
            }
            .flipUpsideDown()
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemBackground))
            .scrollDismissesKeyboard(.interactively)
            // Arm history paging only after the first page has loaded and the
            // view has settled at the bottom, so the top sentinel can't page
            // during the opening layout.
            .task(id: store.selectedRoom) {
                allowsHistoryPaging = false
                for _ in 0..<80 {
                    if !store.messages.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .milliseconds(300))
                allowsHistoryPaging = true
            }
            // On send, return to the newest message even if the user had
            // scrolled up. ScrollViewReader works in untransformed layout space,
            // where the newest cell is the layout-top (offset 0), so anchor .top.
            .onChange(of: scrollBottomTick) {
                guard let last = store.messages.last?.stableID else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo(last, anchor: .top)
                }
            }
        }
    }

    private enum TranscriptCell: Identifiable {
        case divider(id: String, date: Date)
        case message(id: String, message: MeshMessage, showsHeader: Bool)
        var id: String {
            switch self {
            case .divider(let id, _): return id
            case .message(let id, _, _): return id
            }
        }
    }

    /// Chronological (oldest→newest) cells; the transcript renders them reversed
    /// under the upside-down flip. A day divider sits just before the first
    /// message of its day, which after reversal appears directly above it.
    private var transcriptCells: [TranscriptCell] {
        var cells: [TranscriptCell] = []
        for (index, message) in store.messages.enumerated() {
            if startsNewDay(at: index) {
                cells.append(.divider(id: "day-\(message.stableID)", date: message.date))
            }
            cells.append(.message(id: message.stableID, message: message,
                                  showsHeader: startsMessageGroup(at: index)))
        }
        return cells
    }

    @ViewBuilder
    private func transcriptCellView(_ cell: TranscriptCell) -> some View {
        switch cell {
        case .divider(_, let date):
            dayDivider(for: date)
        case .message(let id, let message, let showsHeader):
            MessageRow(
                message: message,
                member: store.members[message.from],
                showsHeader: showsHeader,
                onReply: {
                    replyingTo = message
                    focused = true
                },
                onOpenAttachment: { attachment in
                    Task { previewURL = await store.downloadAttachment(attachment) }
                }
            )
            .id(id)
        }
    }

    /// Top-of-transcript sentinel: becoming visible (user scrolled up) pulls one
    /// older page. The .scrollPosition(id:) binding preserves the reading
    /// position automatically when rows prepend above.
    private var historyLoader: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .onAppear { requestOlderPage() }
    }

    private func requestOlderPage() {
        guard allowsHistoryPaging, !store.isLoadingOlder else { return }
        Task { await store.loadOlderMessages() }
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
            Button("Add agent", systemImage: "person.badge.plus") { destination = .spawn }
                .labelStyle(.iconOnly)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Manage room", systemImage: "slider.horizontal.3") { destination = .manage }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Room settings")
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
            if !availableMembers.isEmpty {
                RoomMentionStrip(members: availableMembers) { member in
                    store.insertMention(member.nick, into: &draft)
                    showAttachmentPanel = false
                    focused = true
                }
            }
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

            if showAttachmentPanel {
                AttachmentTray(
                    cameraAvailable: UIImagePickerController.isSourceTypeAvailable(.camera),
                    onCamera: {
                        showAttachmentPanel = false
                        showCameraPicker = true
                    },
                    onPhotos: {
                        showAttachmentPanel = false
                        showPhotoPicker = true
                    },
                    onFiles: {
                        showAttachmentPanel = false
                        showFileImporter = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
                focused = false
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
                    showAttachmentPanel.toggle()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .rotationEffect(showAttachmentPanel ? .degrees(45) : .zero)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Add attachment")

            TextField("Message #\(store.selectedRoom ?? "room")", text: $draft, axis: .vertical)
                .font(.body)
                .lineSpacing(2)
                .lineLimit(1...6)
                .padding(.vertical, 5)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .onChange(of: focused) { _, isFocused in
                    guard isFocused, showAttachmentPanel else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        showAttachmentPanel = false
                    }
                }

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

    /// Room members eligible to @mention: live agents only. A gone agent can't
    /// be poked, so surfacing it in the mention strip is misleading.
    private var availableMembers: [MeshMember] {
        guard let room = store.rooms.first(where: { $0.name == store.selectedRoom }) else { return [] }
        return room.members
            .filter { $0 != "human" }
            .compactMap { store.members[$0] }
            .filter { ($0.state.flatMap(MeshSessionState.init(rawValue:))) != .gone }
            .sorted { $0.nick.localizedCaseInsensitiveCompare($1.nick) == .orderedAscending }
    }

    private var channelSubtitle: String {
        let total = availableMembers.count
        return total == 0 ? "No active agents" : (total == 1 ? "1 agent" : "\(total) agents")
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
                scrollBottomTick += 1      // pin to the message just sent
            }
        }
    }

    private func replyComposerCard(_ message: MeshMessage) -> some View {
        HStack(spacing: 9) {
            Capsule().fill(Color.accentColor).frame(width: 3, height: 30)
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
        // Hug the content; a long quote (or a stray flexible child) must not
        // stretch this bar to fill the composer.
        .fixedSize(horizontal: false, vertical: true)
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
        .frame(height: 34)   // a horizontal ScrollView otherwise grabs vertical space
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isUploading = true
        defer { isUploading = false; selectedPhotos = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first ?? .image
            let ext = type.preferredFilenameExtension ?? "jpg"
            let name = "Image-\(UUID().uuidString.prefix(8)).\(ext)"
            if let attachment = await store.uploadAttachment(
                data: data, name: name, mimeType: type.preferredMIMEType ?? "image/jpeg"
            ) {
                pendingAttachments.append(attachment)
            }
        }
    }

    private func uploadCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        Task {
            isUploading = true
            defer { isUploading = false }
            let name = "Photo-\(UUID().uuidString.prefix(8)).jpg"
            if let attachment = await store.uploadAttachment(
                data: data, name: name, mimeType: "image/jpeg"
            ) {
                pendingAttachments.append(attachment)
            }
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

private struct RoomMentionStrip: View {
    let members: [MeshMember]
    let onMention: (MeshMember) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(members) { member in
                    Button { onMention(member) } label: {
                        HStack(spacing: 5) {
                            // Live status dot (busy/idle/blocked), matching the
                            // macOS mention strip and this view's member list.
                            Circle().fill(AgentStatus.color(member.state)).frame(width: 6, height: 6)
                            Text("@\(member.nick)")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.secondary.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mention \(member.nick)")
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
        .frame(height: 34)   // a horizontal ScrollView otherwise grabs vertical space
    }
}

private struct AttachmentTray: View {
    let cameraAvailable: Bool
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AttachmentTrayButton(title: "Camera", systemImage: "camera",
                                 isEnabled: cameraAvailable, action: onCamera)
            AttachmentTrayButton(title: "Photos", systemImage: "photo.on.rectangle",
                                 action: onPhotos)
            AttachmentTrayButton(title: "Files", systemImage: "folder",
                                 action: onFiles)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

private struct AttachmentTrayButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct CameraPickerView: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView

        init(parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImagePicked(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
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

private extension View {
    /// Vertical flip for the inverted chat transcript. Rotating 180° then
    /// mirroring horizontally is a pure vertical reflection (crisper than a
    /// negative-y scaleEffect); applied to both the ScrollView and each cell it
    /// reverses the visual stacking order while keeping content upright.
    func flipUpsideDown() -> some View {
        rotationEffect(.radians(.pi)).scaleEffect(x: -1, y: 1, anchor: .center)
    }
}

private enum ConversationSheet: String, Identifiable {
    case spawn
    case manage
    var id: String { rawValue }
}

struct ManageRoomSheet: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let roomName: String

    @State private var newRoomName: String
    @State private var busy = false
    @State private var showingDeleteRoom = false
    @State private var memberToRemove: MeshMember?
    @State private var memberToRename: MeshMember?
    @State private var renameMemberText = ""

    init(roomName: String) {
        self.roomName = roomName
        _newRoomName = State(initialValue: roomName)
    }

    private var members: [MeshMember] {
        guard let room = store.rooms.first(where: { $0.name == roomName }) else { return [] }
        return room.members.compactMap { store.members[$0] }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Room name") {
                    TextField("Room name", text: $newRoomName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Rename room") {
                        busy = true
                        Task {
                            _ = await store.renameRoom(roomName, to: newRoomName)
                            busy = false
                            dismiss()
                        }
                    }
                    .disabled(busy || newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || newRoomName == roomName)
                }

                Section("Members") {
                    if members.isEmpty {
                        Text("No members to manage.").foregroundStyle(.secondary)
                    }
                    ForEach(members) { member in
                        HStack(spacing: 10) {
                            Circle().fill(AgentStatus.color(member.state)).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("@\(member.nick)")
                                if let host = member.host {
                                    Text(host).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { memberToRemove = member } label: {
                                Label("Remove", systemImage: "person.badge.minus")
                            }
                            Button {
                                renameMemberText = member.nick
                                memberToRename = member
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }.tint(.indigo)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) { showingDeleteRoom = true } label: {
                        Label("Delete room", systemImage: "trash")
                    }
                    .disabled(busy)
                } footer: {
                    Text(PharosMeshRuntimeMode.usesDistributedMesh
                         ? "Deleting replicates the room removal to every trusted device. Existing signed message events remain in replica history."
                         : "Deleting removes the room and its membership for everyone. Message history is retained by the Broker.")
                }

                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .pharosPlainList()
            .navigationTitle("Manage room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .interactiveDismissDisabled(busy)
            .confirmationDialog("Delete #\(roomName)?", isPresented: $showingDeleteRoom,
                                titleVisibility: .visible) {
                Button("Delete room", role: .destructive) {
                    busy = true
                    Task {
                        _ = await store.deleteRoom(roomName)
                        busy = false
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(memberToRemove.map { "Remove @\($0.nick)?" } ?? "",
                                isPresented: Binding(get: { memberToRemove != nil },
                                                     set: { if !$0 { memberToRemove = nil } }),
                                titleVisibility: .visible) {
                Button("Remove member", role: .destructive) {
                    guard let m = memberToRemove else { return }
                    memberToRemove = nil
                    Task { _ = await store.removeMember(m.nick, memberID: m.id, from: roomName) }
                }
                Button("Cancel", role: .cancel) { memberToRemove = nil }
            }
            .alert("Rename member", isPresented: Binding(get: { memberToRename != nil },
                                                          set: { if !$0 { memberToRename = nil } })) {
                TextField("New nickname", text: $renameMemberText)
                Button("Rename") {
                    guard let m = memberToRename else { return }
                    memberToRename = nil
                    Task { _ = await store.renameMember(m.nick, to: renameMemberText, memberID: m.id, in: roomName) }
                }
                Button("Cancel", role: .cancel) { memberToRename = nil }
            }
        }
    }
}
