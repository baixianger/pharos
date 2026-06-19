import AppKit
import SwiftUI

struct AddProjectSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var localPath = ""
    @State private var github = ""
    @State private var group = ""
    @State private var yolo = true
    @State private var tmux = false
    @State private var detectedRemote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project").font(.title2.bold())

            Form {
                TextField("Name", text: $name)

                HStack {
                    TextField("Local folder", text: $localPath)
                    Button("Choose…") { chooseFolder() }
                }

                HStack(spacing: 6) {
                    TextField("GitHub URL (optional)", text: $github)
                        .textContentType(.URL)
                    if detectedRemote {
                        Label("detected", systemImage: "checkmark.seal.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                            .help("Remote detected from the folder's git origin")
                    }
                }

                HStack {
                    TextField("Group (optional)", text: $group)
                    if !store.groups.isEmpty {
                        Menu {
                            ForEach(store.groups, id: \.self) { g in Button(g) { group = g } }
                        } label: { Image(systemName: "chevron.down") }
                        .fixedSize()
                    }
                }

                HStack(spacing: 18) {
                    Toggle("yolo", isOn: $yolo)
                    Toggle("tmux", isOn: $tmux)
                }
                .toggleStyle(.switch)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { yolo = store.defaultYolo; tmux = store.defaultTmux }
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (!localPath.isEmpty || !github.isEmpty)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localPath = url.path
        if name.isEmpty { name = url.lastPathComponent }
        // Proactively detect the git remote and record it.
        if github.isEmpty, let remote = GitService.detectRemote(at: url.path) {
            github = remote
            detectedRemote = true
        }
    }

    private func add() {
        let g = group.trimmingCharacters(in: .whitespaces)
        let project = Project(
            name: name.trimmingCharacters(in: .whitespaces),
            localPath: localPath.isEmpty ? nil : localPath,
            githubRemote: github.isEmpty ? nil : github,
            tags: g.isEmpty ? [] : [g],
            yolo: yolo,
            tmux: tmux
        )
        if !g.isEmpty { store.addGroup(g) }
        store.add(project)
        dismiss()
    }
}
