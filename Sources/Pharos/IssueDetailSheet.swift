import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Read/manage view for a single issue: status, priority, description, and an
/// attachment grid with inline image previews. Clicking an image opens it
/// full-size in the default app; files can be added (drag-drop / picker) or
/// removed here on the existing issue.
struct IssueDetailSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectID: Project.ID
    let number: Int

    private var issue: Issue? { store.project(projectID)?.issues.first { $0.number == number } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let issue {
                header(issue)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !issue.body.isEmpty {
                            Text(issue.body)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
            Text(issue.title).font(.title3).bold().lineLimit(2)
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

            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func attachmentsSection(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attachments (\(issue.attachments.count))").font(.headline)
                Spacer()
                Button { addFiles() } label: { Label("Add files…", systemImage: "paperclip") }
                    .controlSize(.small)
            }
            if issue.attachments.isEmpty {
                Text("No attachments. Drag files here, or use Add files.")
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
                .onTapGesture { NSWorkspace.shared.open(url) }
                .help("Click to open full-size")

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
            Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button { LaunchService.revealInFinder(url.path) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button(role: .destructive) {
                store.removeAttachment(projectID, number: number, attachment: att)
            } label: { Label("Remove", systemImage: "trash") }
        }
    }

    // MARK: Actions

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
