import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLook

/// Read/edit view for a single issue: status, priority, title, description, and
/// an attachment grid with inline image previews. Tapping an attachment opens it
/// in an in-app QuickLook panel; files can be added (drag-drop / picker / paste)
/// or removed. The title and description are editable in place.
struct IssueDetailSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectID: Project.ID
    let number: Int

    @State private var editing = false
    @State private var editedTitle = ""
    @State private var editedBody = ""
    @State private var quickLookURL: URL?
    @State private var newLabel = ""

    private var issue: Issue? { store.project(projectID)?.issues.first { $0.number == number } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let issue {
                header(issue)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        bodySection(issue)
                        labelsSection(issue)
                        attachmentsSection(issue)
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView("Issue not found", systemImage: "questionmark.circle")
            }
        }
        .frame(width: 640, height: 640)
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
        .quickLookPreview($quickLookURL)
    }

    private func header(_ issue: Issue) -> some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(IssueStatus.allCases) { s in
                    Button { store.setIssueStatus(projectID, number: number, status: s) } label: {
                        Label(s.label, systemImage: s.symbol)
                    }
                }
            } label: { Label(issue.status.label, systemImage: issue.status.symbol) }
                .menuStyle(.borderlessButton).fixedSize()

            Text("#\(issue.number)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)

            if editing {
                TextField("Title", text: $editedTitle).textFieldStyle(.roundedBorder).font(.title3)
            } else {
                Text(issue.title).font(.title3).bold().lineLimit(2)
            }

            Spacer()

            Menu {
                ForEach(IssuePriority.allCases) { p in
                    Button { store.setIssuePriority(projectID, number: number, priority: p) } label: {
                        Label(p.label, systemImage: p.symbol)
                    }
                }
            } label: {
                Image(systemName: issue.priority.symbol)
                    .foregroundStyle(issue.priority == .urgent ? .orange : .secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Priority: \(issue.priority.label)")

            if editing {
                Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                Button("Save") { saveEdits() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editedTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button { startEditing(issue) } label: { Image(systemName: "pencil") }
                    .help("Edit title & description")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func bodySection(_ issue: Issue) -> some View {
        if editing {
            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $editedBody)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        } else if !issue.body.isEmpty {
            Text(issue.body)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labelsSection(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Labels").font(.caption).foregroundStyle(.secondary)
            if !issue.labels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(issue.labels, id: \.self) { label in
                            HStack(spacing: 4) {
                                Text(label).font(.caption)
                                Button { store.removeIssueLabel(projectID, number: number, label: label) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Add a label…", text: $newLabel)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .onSubmit { commitLabel() }
                Button("Add") { commitLabel() }
                    .controlSize(.small)
                    .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitLabel() {
        let l = newLabel.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return }
        store.addIssueLabel(projectID, number: number, label: l)
        newLabel = ""
    }

    private func attachmentsSection(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attachments (\(issue.attachments.count))").font(.headline)
                Spacer()
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .controlSize(.small)
                Button { addFiles() } label: { Label("Add files…", systemImage: "paperclip") }
                    .controlSize(.small)
            }
            if issue.attachments.isEmpty {
                Text("No attachments. Drag files here, use Add files, or Paste.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(issue.attachments) { attachmentTile($0, issueID: issue.id) }
                }
            }
        }
    }

    private func attachmentTile(_ att: IssueAttachment, issueID: UUID) -> some View {
        let url = AttachmentStore.fileURL(att, issueID: issueID)
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if att.isImage, let img = NSImage(contentsOf: url) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 44)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { quickLookURL = url }
                .help("Click to preview (QuickLook)")

                Button {
                    store.removeAttachment(projectID, number: number, attachment: att)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(5)
                .accessibilityLabel("Remove \(att.originalName)")
            }
            Text(att.originalName).font(.caption).lineLimit(1)
            Text(byteString(att.byteSize)).font(.caption2).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button { quickLookURL = url } label: { Label("Quick Look", systemImage: "eye") }
            Button { NSWorkspace.shared.open(url) } label: { Label("Open in default app", systemImage: "arrow.up.forward.app") }
            Button { LaunchService.revealInFinder(url.path) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button(role: .destructive) {
                store.removeAttachment(projectID, number: number, attachment: att)
            } label: { Label("Remove", systemImage: "trash") }
        }
    }

    // MARK: Editing

    private func startEditing(_ issue: Issue) {
        editedTitle = issue.title
        editedBody = issue.body
        editing = true
    }

    private func saveEdits() {
        store.setIssueContent(projectID, number: number, title: editedTitle, body: editedBody)
        editing = false
    }

    // MARK: Attachments

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            store.addAttachments(projectID, number: number, urls: panel.urls)
        }
    }

    private func paste() {
        let urls = PasteboardImport.fileURLs()
        store.addAttachments(projectID, number: number, urls: urls)
        for url in urls where PasteboardImport.isTemp(url) { try? FileManager.default.removeItem(at: url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url {
                    DispatchQueue.main.async { store.addAttachments(projectID, number: number, urls: [url]) }
                }
            }
        }
        return true
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
