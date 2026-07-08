import AppKit
import SwiftUI

/// A small "?" that reveals an explanation on hover, so section chrome can stay
/// terse instead of carrying a paragraph of caption text.
struct HelpBadge: View {
    let text: String
    var body: some View {
        Image(systemName: "questionmark.circle")
            .foregroundStyle(.secondary)
            .help(text)
    }
}

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
            MachinesSettingsTab()
                .tabItem { Label("Machines", systemImage: "macbook.and.iphone") }
        }
        .frame(width: 520, height: 480)
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
            Section("New projects default to") {
                Toggle("yolo", isOn: $store.defaultYolo)
                Toggle("tmux", isOn: $store.defaultTmux)
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

private struct MachinesSettingsTab: View {
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
            Section {
                Toggle(isOn: Binding(
                    get: { store.hostMesh },
                    set: { on in store.hostMesh = on; Task.detached { MeshHosting.apply(hosting: on) } }
                )) {
                    HStack(spacing: 6) {
                        Text("Host the chat mesh for other Macs")
                        HelpBadge(text: "Turn ON for ONE always-on Mac (the hub): it binds this Mac's chat broker to your Tailscale address so your other Macs can pair to it and share the same rooms. Leave OFF on your other Macs — they use “Pair a Mac” below to connect to the hub.")
                    }
                }
            } header: { Text("Host mesh") }
            PairingView()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Pairing

/// Pair this Mac with another over Tailscale for cross-host chat rooms.
/// Discovers the tailnet's Macs, then validates SSH + Tailscale + mesh broker
/// (starting the peer's broker if needed). Stores the peer in `peerHost`.
private struct PairingView: View {
    @Environment(ProjectStore.self) private var store
    @State private var peers: [PairingService.Peer] = []
    @State private var testing = false
    @State private var result: PairingService.Result?

    var body: some View {
        @Bindable var store = store
        Section("Pair a Mac") {
            HStack {
                Text("Pair with")
                Spacer()
                Menu(store.peerHost.isEmpty ? "Choose a Mac…" : store.peerHost) {
                    if peers.isEmpty {
                        Text("No other Macs found on your tailnet").disabled(true)
                    } else {
                        ForEach(peers) { p in
                            Button("\(p.name)  ·  \(p.ip)") { store.peerHost = p.ip; result = nil }
                        }
                    }
                    Divider()
                    Button("Refresh") { Task { await refresh() } }
                }
                .frame(maxWidth: 240)
            }
            LabeledContent("SSH host / IP") {
                TextField("home-ts or 100.x.y.z", text: $store.peerHost)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .onChange(of: store.peerHost) { _, _ in result = nil }
            }
            HStack {
                Button(testing ? "Testing…" : "Test & pair") { Task { await test() } }
                    .disabled(testing || store.peerHost.isEmpty)
                if testing { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
                if let r = result {
                    Label(r.ok ? "Paired" : "Not connected",
                          systemImage: r.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.ok ? Color.green : Color.orange)
                        .font(.caption)
                }
            }
            if let r = result {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(r.steps) { s in
                        Label(s.label, systemImage: s.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(s.ok ? Color.green : Color.red)
                            .font(.caption)
                    }
                }
            }
            Text("Pairs over Tailscale for cross-host chat rooms. The peer needs Pharos in /Applications; its broker is started automatically.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        peers = await Task.detached { PairingService.discoverPeers() }.value
    }

    private func test() async {
        testing = true
        let host = store.peerHost
        let r = await Task.detached { PairingService.pair(host: host) }.value
        result = r
        testing = false
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
            Section {
                commandRow("pharos", status: $pharosStatus)
            } header: {
                HStack(spacing: 6) {
                    Text("pharos — project & issue control")
                    HelpBadge(text: "How agents drive Pharos: a Claude Code / Codex session shells out to read and update issues and post progress — e.g. `pharos list --json`, `pharos issue start <project> 3 claude`, `pharos overview`.")
                }
            }
            Section {
                commandRow("chat", status: $chatStatus)
            } header: {
                HStack(spacing: 6) {
                    Text("chat — agent chat room")
                    HelpBadge(text: "Shorthand for `pharos mesh`: agents talk to each other — `chat join <room> <nick>`, `chat ask <room> <nick> \"…\" @peer`, `chat wait <room> <nick>`. Same binary, invoked as `chat`.")
                }
            }
            Section {
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
            } header: {
                HStack(spacing: 6) {
                    Text("Mesh delivery hooks (Claude Code)")
                    HelpBadge(text: "Installs two Claude Code hooks: a Stop hook that surfaces unread @mentions at a session's turn-end, and a SessionStart hook that injects the session id so a joined agent can address messages to its exact session (telling apart two agents in one folder). Per-repo alternative: `pharos mesh install-hooks --project <dir>`. Safe to install globally — un-joined sessions no-op.")
                }
            }
            Section {
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
            } header: {
                HStack(spacing: 6) {
                    Text("Agent skills (Claude Code)")
                    HelpBadge(text: "Symlink the bundled skills into ~/.claude/skills so every Claude session auto-loads them. For a single repo, use `pharos skill install <name> --project <dir>`.")
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
