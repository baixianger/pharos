import SwiftUI

/// Transient "Undo" affordance shown after a reversible delete. It auto-dismisses
/// after a short window; the item stays recoverable from the Trash either way, so
/// the toast is a convenience, not the only safety net.
struct UndoToast: View {
    @Environment(ProjectStore.self) private var store
    let token: UndoToken

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
            Text(token.message)
                .font(.callout)
                .lineLimit(1)
            Divider().frame(height: 16)
            Button("Undo") { store.undoLastDelete() }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
            Button { store.dismissUndo() } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: Capsule())
        .shadow(radius: 8, y: 2)
        .task(id: token.id) {
            // Auto-dismiss after a short window; the Trash keeps the item anyway.
            try? await Task.sleep(for: .seconds(6))
            if store.lastUndo?.id == token.id { store.dismissUndo() }
        }
    }
}

/// The Trash: a single place to restore or permanently purge soft-deleted
/// projects, groups, and playbooks within the restore window.
struct TrashView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var retentionDays: Int { Int(StoreData.trashRetention / 86_400) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Trash").font(.title2).bold()
                Spacer()
                if !store.trash.isEmpty {
                    Button(role: .destructive) { store.emptyTrash() } label: {
                        Label("Empty Trash", systemImage: "trash")
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if store.trash.isEmpty {
                ContentUnavailableView(
                    "Trash is empty",
                    systemImage: "trash",
                    description: Text("Removed projects, groups, and playbooks appear here for \(retentionDays) days, then clear automatically.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.trash) { item in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.body).lineLimit(1)
                                Text("\(item.kindLabel) · deleted \(item.deletedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Restore") { store.restoreTrash(item.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button { store.purgeTrash(item.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete permanently")
                            .accessibilityLabel("Delete “\(item.title)” permanently")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)

                Divider()
                Text("Kept for \(retentionDays) days, then removed automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 500, height: 440)
    }

    private func icon(for item: TrashedItem) -> String {
        switch item.payload {
        case .project:  return "folder"
        case .group:    return "tag"
        case .playbook: return "play.rectangle"
        case .issue:    return "smallcircle.filled.circle"
        }
    }
}
