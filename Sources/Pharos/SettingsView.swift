import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            LaunchSettingsTab()
                .tabItem { Label("Launch", systemImage: "paperplane.fill") }
            ProjectsSettingsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
            CLISettingsTab()
                .tabItem { Label("CLI", systemImage: "terminal") }
            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 500, height: 460)
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

private struct SyncSettingsTab: View {
    @Environment(ProjectStore.self) private var store

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
                     : "iCloud Drive isn't active on this Mac yet (no iCloud Drive folder found). Turn on iCloud Drive → “Sync this Mac” in System Settings; the option un-greys once its folder appears.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.iCloudAvailable {
                    Button("Open iCloud Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
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
        }
        .formStyle(.grouped)
    }
}

// MARK: - CLI

private struct CLISettingsTab: View {
    @State private var pharosStatus: String?
    @State private var chatStatus: String?
    @State private var skillStatus: String?
    @State private var meshHookInstalled = false
    @State private var meshHookStatus: String?

    private static var exec: String { Bundle.main.executablePath ?? "<Pharos.app>/Contents/MacOS/Pharos" }

    /// First user-writable dir on a typical PATH — so neither the button nor the
    /// copy-command needs `sudo` (the old `/usr/local/bin` snippet did).
    private static var installDir: String {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        for d in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"] {
            if fm.fileExists(atPath: d) { if fm.isWritableFile(atPath: d) { return d } }
            else if d.hasPrefix(home) { return d }   // we'll create it
        }
        return "\(home)/.local/bin"
    }

    private static func snippet(_ name: String) -> String { "ln -sf \"\(exec)\" \"\(installDir)/\(name)\"" }

    /// Symlink the bundled binary under `name` into the first writable PATH dir.
    private static func install(_ name: String) -> String {
        guard let exec = Bundle.main.executablePath else { return "Couldn't locate the Pharos binary." }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"] {
            if !fm.fileExists(atPath: dir) {
                guard dir.hasPrefix(home) else { continue }
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            guard fm.isWritableFile(atPath: dir) else { continue }
            let dest = "\(dir)/\(name)"
            if (try? fm.destinationOfSymbolicLink(atPath: dest)) != nil { try? fm.removeItem(atPath: dest) }
            else if fm.fileExists(atPath: dest) { continue }     // don't clobber a real file
            do {
                try fm.createSymbolicLink(atPath: dest, withDestinationPath: exec)
                let short = dest.replacingOccurrences(of: home, with: "~")
                return dir.hasPrefix(home)
                    ? "Installed → \(short)  (ensure \(dir.replacingOccurrences(of: home, with: "~")) is on your PATH)"
                    : "Installed → \(short)"
            } catch { continue }
        }
        return "Couldn't auto-install — copy the command below (no sudo needed)."
    }

    var body: some View {
        Form {
            Section("pharos — project & issue control") {
                Text("How agents drive Pharos: a Claude Code / Codex session shells out to read and update issues and post progress — e.g. `pharos list --json`, `pharos issue start <project> 3 claude`, `pharos overview`.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                commandRow("pharos", status: $pharosStatus)
            }
            Section("chat — agent chat room") {
                Text("Shorthand for `pharos mesh`: agents talk to each other — `chat join <room> <nick>`, `chat ask <room> <nick> \"…\" @peer`, `chat wait <room> <nick>`. Same binary, invoked as `chat`.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                commandRow("chat", status: $chatStatus)
            }
            Section("Mesh delivery hooks (Claude Code)") {
                Text("Installs two hooks: a Stop hook that surfaces unread @mentions at a session's turn-end, and a SessionStart hook that injects the session id so a joined agent can address messages to its exact session (telling apart two agents in one folder). Safe to install globally — sessions not joined to any room are untouched (the hooks no-op).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Image(systemName: meshHookInstalled ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(meshHookInstalled ? Color.green : Color.secondary)
                    Text(meshHookInstalled ? "Installed → ~/.claude/settings.json" : "Not installed")
                        .font(.callout)
                    Spacer()
                    Button(meshHookInstalled ? "Reinstall / update" : "Install globally (~/.claude)") {
                        _ = MeshHooks.installHooks(["--user"])
                        meshHookInstalled = MeshHooks.userHookInstalled()
                        meshHookStatus = meshHookInstalled
                            ? "Installed — applies to newly started Claude sessions."
                            : "Install failed — check ~/.claude/settings.json (a file with invalid JSON is never overwritten)."
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let s = meshHookStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Per-repo alternative: `pharos mesh install-hooks --project <dir>`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent skills (Claude Code)") {
                Text("Symlink the bundled skills into ~/.claude/skills so every Claude session auto-loads them. For a single repo, use `pharos skill install <name> --project <dir>`.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if skillNames.isEmpty {
                    Text("(no bundled skills found)").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(skillNames, id: \.self) { name in
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(name).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Install") { skillStatus = SkillInstall.install(name, projectDir: nil).joined(separator: "\n") }
                        }
                    }
                    HStack {
                        Button("Install all → ~/.claude/skills") {
                            skillStatus = SkillInstall.install("all", projectDir: nil).joined(separator: "\n")
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
                if let s = skillStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { meshHookInstalled = MeshHooks.userHookInstalled() }
    }

    private var skillNames: [String] { SkillInstall.available() }

    @ViewBuilder
    private func commandRow(_ name: String, status: Binding<String?>) -> some View {
        Text(Self.snippet(name))
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        HStack {
            Button("Install `\(name)`") { status.wrappedValue = Self.install(name) }
                .buttonStyle(.borderedProminent)
            Button("Copy command") {
                let pb = NSPasteboard.general; pb.clearContents(); pb.setString(Self.snippet(name), forType: .string)
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        if let s = status.wrappedValue {
            Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
