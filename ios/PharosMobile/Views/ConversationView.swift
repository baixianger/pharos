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
    /// Bound to the message pinned at the bottom of the viewport via
    /// .scrollPosition(id:anchor:.bottom). Setting it scrolls there.
    @State private var scrolledID: String?
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

    private var transcript: some View {
        ScrollView {
            // LazyVStack + scrollTargetLayout + the .scrollPosition(id:) binding
            // is the reliable "open at newest" for chat: setting scrolledID to
            // the last message (anchor .bottom) pins it at the bottom, works
            // lazily, and preserves position automatically when older rows are
            // prepended. (defaultScrollAnchor(.bottom) leaves LazyVStack blank.)
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.hasMoreHistory {
                    historyLoader
                } else {
                    channelWelcome
                }

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
                    .id(message.id)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 8)
        }
        .scrollPosition(id: $scrolledID, anchor: .bottom)
        .background(Color(uiColor: .systemBackground))
        .scrollDismissesKeyboard(.interactively)
        // Pin to the newest message on open; repeat to catch late layout /
        // late first-page load, then arm history paging.
        .task(id: store.selectedRoom) {
            allowsHistoryPaging = false
            for _ in 0..<80 {
                if !store.messages.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            for _ in 0..<5 {
                scrolledID = store.messages.last?.id
                try? await Task.sleep(for: .milliseconds(120))
            }
            allowsHistoryPaging = true
            // Test hook: open a reply on the newest message so the reply
            // composer can be screenshotted in the simulator.
            if ProcessInfo.processInfo.arguments.contains("--ui-reply") {
                replyingTo = store.messages.last
            }
        }
        // Follow new messages only when already at the bottom (scrolledID was
        // the previous newest); never yank a user who scrolled up.
        .onChange(of: store.messages.last?.id) { old, new in
            guard allowsHistoryPaging, let new else { return }
            if scrolledID == old || scrolledID == nil {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scrolledID = new }
            }
        }
        .onChange(of: scrollBottomTick) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                scrolledID = store.messages.last?.id
            }
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
                        Text("@\(member.nick)")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
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

private enum ConversationSheet: String, Identifiable {
    case spawn
    var id: String { rawValue }
}
