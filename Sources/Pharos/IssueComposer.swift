import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Modal composer for a new issue: title, multi-line description, priority, and
/// image/file attachments (drag-drop, file picker, or paste). Attachment bytes
/// are copied to the issue's directory as you add them (staged under a draft id);
/// "Create" commits the issue, "Cancel" discards the staged files.
struct IssueComposer: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectID: Project.ID

    @State private var title = ""
    @State private var bodyText = ""
    @State private var priority: IssuePriority = .none
    @State private var draftID = UUID()
    @State private var staged: [IssueAttachment] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New issue").font(.title2).bold()

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            HStack(spacing: 8) {
                Text("Priority").foregroundStyle(.secondary)
                Menu {
                    ForEach(IssuePriority.allCases) { p in
                        Button { priority = p } label: { Label(p.label, systemImage: p.symbol) }
                    }
                } label: { Label(priority.label, systemImage: priority.symbol) }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }

            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            attachmentsSection

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Create issue") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 580)
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { addFiles() } label: { Label("Add files…", systemImage: "paperclip") }
                    .controlSize(.small)
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .controlSize(.small)
            }
            if staged.isEmpty {
                Text("Drag files here, or use Add files / Paste. Images show a thumbnail.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(staged) { attachmentChip($0) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 90)
            }
        }
    }

    private func attachmentChip(_ att: IssueAttachment) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if att.isImage, let img = NSImage(contentsOf: AttachmentStore.fileURL(att, issueID: draftID)) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.title)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                Button { removeStaged(att) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(2)
                .accessibilityLabel("Remove \(att.originalName)")
            }
            Text(att.originalName).font(.caption2).lineLimit(1).frame(width: 64)
        }
    }

    // MARK: Actions

    private func create() {
        store.addIssue(projectID, id: draftID,
                       title: title, body: bodyText, priority: priority, attachments: staged)
        dismiss()
    }

    private func cancel() {
        // The issue was never created — discard any staged files.
        try? FileManager.default.removeItem(at: AttachmentStore.directory(forIssue: draftID))
        dismiss()
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            for url in panel.urls { stage(url) }
        }
    }

    private func paste() {
        for url in PasteboardImport.fileURLs() {
            stage(url)
            if PasteboardImport.isTemp(url) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url { DispatchQueue.main.async { stage(url) } }
            }
        }
        return true
    }

    private func stage(_ url: URL) {
        do { staged.append(try AttachmentStore.add(fileAt: url, toIssue: draftID)) }
        catch { store.reportError("Couldn't attach \(url.lastPathComponent).") }
    }

    private func removeStaged(_ att: IssueAttachment) {
        try? FileManager.default.removeItem(at: AttachmentStore.fileURL(att, issueID: draftID))
        staged.removeAll { $0.id == att.id }
    }
}
