import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            LaunchSettingsTab()
                .tabItem { Label("Launch", systemImage: "terminal") }
            ProjectsSettingsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "link") }
        }
        .frame(width: 500, height: 430)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(ProjectStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $store.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("New projects default to") {
                Toggle("yolo", isOn: $store.defaultYolo)
                Toggle("tmux", isOn: $store.defaultTmux)
            }
            Section("Notifications") {
                Toggle("Notify when an agent finishes", isOn: $store.notifyOnFinish)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Launch

private struct LaunchSettingsTab: View {
    @Environment(ProjectStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Apps") {
                Picker("Terminal", selection: $store.terminal) {
                    ForEach(TerminalApp.allCases) { Text($0.label).tag($0) }
                }
                Picker("Editor", selection: $store.editor) {
                    ForEach(EditorApp.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Agent arguments") {
                LabeledContent("Claude extra args") {
                    TextField("e.g. --verbose", text: $store.claudeArgs)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                LabeledContent("Codex extra args") {
                    TextField("e.g. --verbose", text: $store.codexArgs)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                Text("Appended to the launch command for every project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Projects

private struct ProjectsSettingsTab: View {
    @Environment(ProjectStore.self) private var store
    var body: some View {
        Form {
            Section("Project roots") {
                if store.scanRoots.isEmpty {
                    Text("No roots added yet.").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(store.scanRoots, id: \.self) { root in
                    HStack {
                        Text(root).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { store.removeScanRoot(root) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Add Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Add Root"
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        store.addScanRoot(url.path)
                    }
                    Button("Scan now") { Task { await store.scanForProjects() } }
                        .disabled(store.scanRoots.isEmpty)
                }
                .buttonStyle(.borderless)
                Text("Scans each root's immediate subfolders for git repos and imports new ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Integrations

private struct IntegrationsSettingsTab: View {
    @Environment(ProjectStore.self) private var store

    private static var executablePath: String {
        Bundle.main.executablePath ?? "<Pharos.app>/Contents/MacOS/Pharos"
    }
    private static var cliSymlinkSnippet: String {
        "ln -s \"\(executablePath)\" /usr/local/bin/pharos"
    }
    @State private var cliInstallStatus: String?

    /// Symlink the bundled binary as `pharos` into the first user-writable dir
    /// (preferring ones already on a typical PATH). Returns a status message.
    private static func installCLISymlink() -> String {
        guard let exec = Bundle.main.executablePath else { return "Couldn't locate the Pharos binary." }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
        for dir in candidates {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dir, isDirectory: &isDir) {
                guard dir.hasPrefix(home) else { continue }            // don't create system dirs
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            guard fm.isWritableFile(atPath: dir) else { continue }
            let dest = "\(dir)/pharos"
            if (try? fm.destinationOfSymbolicLink(atPath: dest)) != nil {
                try? fm.removeItem(atPath: dest)                       // replace our old symlink
            } else if fm.fileExists(atPath: dest) {
                continue                                               // a real file is here — don't clobber
            }
            do {
                try fm.createSymbolicLink(atPath: dest, withDestinationPath: exec)
                let short = dest.replacingOccurrences(of: home, with: "~")
                let needsPathHint = dir.hasPrefix(home)
                return needsPathHint
                    ? "Installed → \(short)  (make sure \(dir.replacingOccurrences(of: home, with: "~")) is on your PATH)"
                    : "Installed → \(short)"
            } catch { continue }
        }
        return "Couldn't auto-install (no writable PATH dir found) — use the command below."
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Data location") {
                Picker("Store project data in", selection: Binding(
                    get: { store.dataLocationIsICloud },
                    set: { store.relocateData(toICloud: $0) }
                )) {
                    Text("This Mac (Application Support)").tag(false)
                    Text("iCloud Drive").tag(true)
                }
                .pickerStyle(.radioGroup)
                .disabled(!store.iCloudAvailable && !store.dataLocationIsICloud)
                Text(store.iCloudAvailable
                     ? "iCloud Drive syncs your projects, issues, and logs across your Macs. Each Mac keeps its own local checkout path, so paths never clobber each other."
                     : "Turn on iCloud Drive in System Settings to sync across Macs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Current") {
                    Text(store.dataDirectoryPath.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("This host") {
                    Text(HostIdentity.current).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Peer machine") {
                LabeledContent("SSH host") {
                    TextField("e.g. home-ts", text: $store.peerHost)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                Text("Compares each project's git HEAD on this machine over SSH. Leave empty to disable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Peer host key") {
                    TextField("e.g. macbook-air", text: $store.peerHostKey)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                Text("The peer Mac's computer name (run `pharos host` there). When set, each project's path on the peer is read from its per-host map — no per-project override needed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Command line") {
                Text("Pharos is scriptable from the command line — and it's how agents drive it: a Claude Code or Codex session can shell out to update issues and post progress. Symlink it onto your PATH, then run `pharos help` (e.g. `pharos list --json`, `pharos issue start <project> 3 claude`).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.cliSymlinkSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Install command") { cliInstallStatus = Self.installCLISymlink() }
                        .buttonStyle(.borderedProminent)
                    Button("Copy command") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(Self.cliSymlinkSnippet, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                if let status = cliInstallStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
