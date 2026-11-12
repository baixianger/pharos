import AppKit
import SwiftUI
import PharosClientKit

/// A small "?" that reveals an explanation — click for a popover (reliable and
/// discoverable), plus a hover tooltip as a bonus — so section chrome can stay
/// terse instead of carrying a paragraph of caption text.
struct HelpBadge: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Text(.init(text))                       // renders the `code` backticks
                .font(.callout)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

struct SettingsView: View {
    var initialTab: Int? = nil
    @State private var tab: Int

    private let destinations: [(title: String, icon: String)] = [
        ("General", "slider.horizontal.3"),
        ("Launch", "play.square.stack"),
        ("Projects", "folder"),
        ("Agents & CLI", "terminal"),
        ("Machines", "macbook.and.iphone")
    ]

    init(initialTab: Int? = nil) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab ?? SnapshotMode.settingsTab ?? 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("Pharos")
                        .font(.title2.weight(.semibold))
                    Text("Control center")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 18)

                VStack(spacing: 4) {
                    ForEach(destinations.indices, id: \.self) { index in
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) { tab = index }
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: destinations[index].icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 19)
                                Text(destinations[index].title)
                                    .font(.system(size: 13, weight: tab == index ? .semibold : .medium))
                                Spacer()
                            }
                            .foregroundStyle(tab == index ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background {
                                if tab == index {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(.white.opacity(0.09))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                Spacer()

                Text("Settings are local to this Pharos client. Session/Thread state lives in the Rust daemon.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
            }
            .frame(width: 196)
            .background(.black.opacity(0.12))

            Divider().opacity(0.45)

            VStack(spacing: 0) {
                HStack {
                    Text(destinations[tab].title)
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)

                Divider().opacity(0.35)

                Group {
                    switch tab {
                    case 0: GeneralSettingsTab()
                    case 1: LaunchSettingsTab()
                    case 2: ProjectsSettingsTab()
                    case 3: CLISettingsTab()
                    default: MachinesSettingsTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 600)
        .background(.regularMaterial)
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

// MARK: - Agents & CLI

private struct CLISettingsTab: View {
    @State private var installStatus: String?

    var body: some View {
        Form {
            Section("Rust CLI") {
                Text("Mesh/Runtime CLI commands moved to the Rust `pharos` binary. Install helpers from the app package Contents/Helpers when packaging.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("API base URL") {
                    Text(PharosClientBackend.configuration.baseURL.absoluteString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section("Local CLI installer") {
                Button("Install `pharos` symlink…") {
                    installStatus = CLIInstaller.install("pharos")
                }
                if let installStatus {
                    Text(installStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Machines

private struct MachinesSettingsTab: View {
    @Environment(ProjectStore.self) private var store
    @State private var backendCheck: String?
    @State private var isCheckingBackend = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Rust backend") {
                Text("This Mac is a SwiftUI + WebKit client. Mesh sync, Runtime, and Thread/Session ownership live in `pharos-meshd` / `pharos-web`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("API base URL") {
                    HStack(spacing: 6) {
                        Text(PharosClientBackend.configuration.baseURL.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        HelpBadge(text: "Port 8787 is a shared local default and may belong to another app. Set `PHAROS_API_BASE_URL` to reach a different `pharos-web` instance.")
                    }
                }
                LabeledContent("Client backend") {
                    Text("rust-api")
                }
                HStack(spacing: 10) {
                    Button(isCheckingBackend ? "Checking…" : "Check backend") {
                        Task { await checkBackend() }
                    }
                    .disabled(isCheckingBackend)
                    if let backendCheck {
                        Text(backendCheck)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Registry sync") {
                    switch store.registrySyncStatus {
                    case .synced: Text("Local projects.json")
                    case .connecting: Text("Loading…")
                    case .pending: Text("Saving…")
                    case .offline(let message): Text(message)
                    case .conflict(let path): Text("Conflict at \(path)")
                    }
                }
                Button("Reload local registry") { store.syncRegistryNow() }
            }
            HostsSettingsSection()
        }
        .formStyle(.grouped)
    }

    /// Probe the configured endpoint and report either the honest reachable
    /// service identity or the actionable guidance (wrong app on port 8787,
    /// unreachable, unhealthy, contract mismatch).
    @MainActor
    private func checkBackend() async {
        isCheckingBackend = true
        defer { isCheckingBackend = false }
        let configuration = PharosClientBackend.configuration
        let probe = await PharosClientBackend.makeHTTPClient(configuration: configuration).probeBackend()
        if let guidance = PharosBackendDiagnostics.guidance(baseURL: configuration.baseURL, probe: probe) {
            backendCheck = guidance
        } else if case .reachable(let health) = probe {
            backendCheck = "Reachable · \(health.service) · contracts \(health.contractsVersion)"
        } else {
            backendCheck = "Unreachable"
        }
    }
}

private struct HostsSettingsSection: View {
    @Environment(ProjectStore.self) private var store
    @State private var draftName = ""
    @State private var draftSSH = ""
    @State private var status: String?

    var body: some View {
        @Bindable var store = store
        Section("SSH hosts (optional attach)") {
            if store.executionHosts.isEmpty {
                Text("No hosts configured.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.executionHosts) { host in
                HStack {
                    VStack(alignment: .leading) {
                        Text(host.name.isEmpty ? host.sshHost : host.name)
                        Text(host.sshHost)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        store.removeExecutionHost(id: host.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            TextField("Display name", text: $draftName)
            TextField("SSH host", text: $draftSSH)
            Button("Add host") {
                let ssh = draftSSH.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ssh.isEmpty else { return }
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                store.upsertExecutionHost(
                    ExecutionHostProfile(name: name.isEmpty ? ssh : name, sshHost: ssh)
                )
                draftName = ""
                draftSSH = ""
                status = "Added \(ssh)"
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text("SSH remains an optional attach path. Peer mesh routing is owned by the Rust daemon.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
