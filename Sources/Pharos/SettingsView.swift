import AppKit
import SwiftUI

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
    // Seeded by SnapshotMode (screenshot runs open a specific tab); defaults to General.
    @State private var tab: Int

    init(initialTab: Int? = nil) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab ?? SnapshotMode.settingsTab ?? 0)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            LaunchSettingsTab()
                .tabItem { Label("Launch", systemImage: "paperplane.fill") }.tag(1)
            ProjectsSettingsTab()
                .tabItem { Label("Projects", systemImage: "folder") }.tag(2)
            CLISettingsTab()
                .tabItem { Label("CLI", systemImage: "terminal") }.tag(3)
            MachinesSettingsTab()
                .tabItem { Label("Machines", systemImage: "macbook.and.iphone") }.tag(4)
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
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @State private var brokerStatus: BrokerConnectionStatus = .unchecked
    @State private var advertisedEndpoint: String?
    @State private var showsPairingAssistant = false
    @State private var deviceToRevoke: MeshPairedDevice?
    @State private var revokeError: String?

    var body: some View {
        @Bindable var store = store
        Form {
            if distributedMesh.isProductModeEnabled {
                distributedProjectDataSection
                distributedDevicesSection
            } else {
                legacyProjectDataSection
                legacyBrokerSection
            }
            HostsSettingsSection()
        }
        .formStyle(.grouped)
        .task(id: store.meshServerEndpoint) {
            if distributedMesh.isProductModeEnabled {
                store.syncRegistryNow()
                return
            }
            let configuredEndpoint = store.validMeshServerEndpoint
            advertisedEndpoint = await Task.detached {
                if let configuredEndpoint { return configuredEndpoint }
                return PairingService.selfTailscaleIP().map { "\($0):47800" }
            }.value
            await checkBroker()
            reconcileLoginServices()
            if !brokerTargetIsInvalid { store.syncRegistryNow() }
        }
        .sheet(isPresented: $showsPairingAssistant) {
            if distributedMesh.isProductModeEnabled {
                PairDeviceSheet(endpoint: "")
            } else if let advertisedEndpoint {
                PairDeviceSheet(endpoint: advertisedEndpoint)
            }
        }
        .alert(
            "Remove trusted device?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }
            ),
            presenting: deviceToRevoke
        ) { device in
            Button("Cancel", role: .cancel) { deviceToRevoke = nil }
            Button("Remove", role: .destructive) {
                deviceToRevoke = nil
                Task {
                    do { try await distributedMesh.revokeDevice(device) }
                    catch { revokeError = error.localizedDescription }
                }
            }
        } message: { device in
            Text("\(device.descriptor.displayName) will immediately lose access after the signed membership update reaches your other devices. Use this when a device is lost or being replaced.")
        }
    }

    @ViewBuilder
    private var distributedProjectDataSection: some View {
        Section("Replicated data") {
            registrySyncStatusView
            LabeledContent("Local replica") {
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
            Button("Sync now") {
                Task {
                    _ = await distributedMesh.synchronizeOnce()
                    store.syncRegistryNow()
                }
            }
            .controlSize(.small)
            Text("Projects, issues, rooms, messages, and attachments are signed into a local replica on every trusted device. Concurrent edits merge field by field; no device is a central source of truth.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var distributedDevicesSection: some View {
        Section("Trusted devices") {
            distributedStateView
            if distributedMesh.trustedDevices.isEmpty {
                Text("No peer devices yet. Pair another Mac or iPhone to replicate your data.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(distributedMesh.trustedDevices, id: \.descriptor.id) { device in
                    let connection = distributedMesh.connections[device.descriptor.id]
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            device.descriptor.displayName,
                            systemImage: connection?.connected == true
                                ? "checkmark.circle.fill" : "circle.dashed"
                        )
                        .foregroundStyle(connection?.connected == true ? .green : .primary)
                        Text([
                            device.descriptor.roles.map(\.rawValue).sorted().joined(separator: ", "),
                            connection.map { String(describing: $0.path) } ?? "not connected yet",
                            abbreviated(device.descriptor.id.rawValue.uuidString),
                        ].joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Remove trusted device", role: .destructive) {
                            deviceToRevoke = device
                        }
                    }
                }
            }
            if let error = distributedMesh.lastSyncError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let revokeError {
                Text(revokeError).font(.caption).foregroundStyle(.red)
            }
            Button("Pair a device…", systemImage: "qrcode") {
                showsPairingAssistant = true
            }
            .disabled(distributedMesh.localAddress == nil)
            Text("Pairing codes expire after five minutes and work once. Device identity is its signing key—not an IP address—so direct and relay paths can change without changing trust.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var distributedStateView: some View {
        switch distributedMesh.state {
        case .opening:
            HStack { ProgressView().controlSize(.small); Text("Opening private Mesh…") }
        case .ready(let deviceID, _):
            Label("This Mac is ready", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text(abbreviated(deviceID.rawValue.uuidString))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var legacyProjectDataSection: some View {
        Section("Project data") {
            registrySyncStatusView
            LabeledContent("Offline cache") {
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
            Button("Sync now") { store.syncRegistryNow() }.controlSize(.small)
            Text("The legacy Broker is the single source of truth. This diagnostic mode is retained only for migration and rollback testing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var legacyBrokerSection: some View {
        Section("Legacy Mesh Broker") {
            brokerStatusView
            Toggle("Launch legacy Mesh at Login", isOn: Binding(
                get: { store.launchMeshAtLogin },
                set: {
                    store.launchMeshAtLogin = $0
                    reconcileLoginServices()
                }
            ))
            HStack {
                Text(brokerTarget)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("Test again") { Task { await checkBroker() } }
                    .controlSize(.small)
                    .disabled(brokerStatus.isChecking || brokerTargetIsInvalid)
            }
            Button("Pair legacy client…", systemImage: "qrcode") {
                showsPairingAssistant = true
            }
            .disabled(advertisedEndpoint == nil || brokerStatus.isChecking)
        }
    }

    private func abbreviated(_ value: String) -> String {
        value.count > 16 ? "\(value.prefix(8))…\(value.suffix(8))" : value
    }

    private func reconcileLoginServices() {
        let enabled = store.launchMeshAtLogin
        let remote = store.validMeshServerEndpoint
        let broker = store.isMeshHub ? advertisedEndpoint : nil
        let node = remote ?? broker
        Task.detached {
            MeshNodeBootstrap.reconcile(enabled: enabled, brokerEndpoint: broker, nodeEndpoint: node)
        }
    }

    private var brokerTargetIsInvalid: Bool {
        !store.meshServerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.validMeshServerEndpoint == nil
    }

    private var brokerTarget: String {
        if brokerTargetIsInvalid { return "Invalid endpoint" }
        return advertisedEndpoint ?? "Connect Tailscale to pair another device"
    }

    @ViewBuilder
    private var registrySyncStatusView: some View {
        switch store.registrySyncStatus {
        case .connecting:
            Label("Connecting to project registry…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .synced:
            Label(distributedMesh.isProductModeEnabled ? "Local replica ready" : "Broker registry synced",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .pending:
            Label(distributedMesh.isProductModeEnabled ? "Writing signed changes…" : "Saving to Broker…",
                  systemImage: "arrow.up.circle")
                .foregroundStyle(.secondary)
        case .offline(let message):
            VStack(alignment: .leading, spacing: 3) {
                Label("Offline cache", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case .conflict(let path):
            VStack(alignment: .leading, spacing: 3) {
                Label("Conflict preserved", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(.orange)
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var brokerStatusView: some View {
        switch brokerStatus {
        case .unchecked:
            Label("Not tested yet", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Broker…")
            }
        case .connected(let latencyMS, let capabilities):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(latencyMS) ms · \(capabilitySummary(capabilities))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Not connected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .invalidEndpoint:
            Label("Enter a valid endpoint before testing.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func capabilitySummary(_ capabilities: [String]) -> String {
        var labels: [String] = []
        if capabilities.contains("mesh-v2") { labels.append("Mesh v2") }
        if capabilities.contains("reply-v1") { labels.append("Replies") }
        if capabilities.contains("attachment-v1") { labels.append("Attachments") }
        if capabilities.contains("headless-v1") { labels.append("Headless") }
        if capabilities.contains("registry-cas-v1") { labels.append("Project data") }
        return labels.isEmpty ? "Broker responded" : labels.joined(separator: " · ")
    }

    @MainActor
    private func checkBroker() async {
        if brokerTargetIsInvalid {
            brokerStatus = .invalidEndpoint
            return
        }
        brokerStatus = .checking
        let endpoint = store.validMeshServerEndpoint
        let started = ContinuousClock.now
        let response = await Task.detached {
            let request = MeshRequest(cmd: "capabilities")
            if let endpoint {
                return MeshClient.send(request, to: endpoint)
            }
            return MeshClient.send(request)
        }.value
        guard !Task.isCancelled else { return }
        let duration = started.duration(to: .now)
        let latencyMS = max(0, Int(duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000))
        if response.ok, let capabilities = response.capabilities {
            brokerStatus = .connected(latencyMS: latencyMS, capabilities: capabilities)
        } else {
            brokerStatus = .unavailable(response.error ?? "The Broker did not complete the Mesh handshake.")
        }
    }
}

private enum BrokerConnectionStatus: Equatable {
    case unchecked
    case checking
    case connected(latencyMS: Int, capabilities: [String])
    case unavailable(String)
    case invalidEndpoint

    var isChecking: Bool { self == .checking }
}

// MARK: - Execution hosts

/// SSH is the current control plane for execution Hosts. It installs/drives
/// Pharos, tmux, and coding agents; it is not the Mesh message transport.
private struct HostsSettingsSection: View {
    @Environment(ProjectStore.self) private var store
    @State private var peers: [PairingService.Peer] = []
    @State private var testing = false
    @State private var result: PairingService.Result?
    @State private var draftName = ""
    @State private var draftSSHHost = ""

    var body: some View {
        Section("Hosts") {
            LabeledContent {
                Text("Local").font(.caption).foregroundStyle(.secondary)
            } label: {
                Label(HostIdentity.current, systemImage: "desktopcomputer")
            }
            ForEach(store.executionHosts) { host in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(host.displayName, systemImage: "server.rack")
                        Text(host.sshHost).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { store.removeExecutionHost(id: host.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove Host")
                }
            }
            Divider()
            HStack {
                Text("Discover")
                Spacer()
                Menu("Choose a tailnet Mac…") {
                    if peers.isEmpty {
                        Text("No other Macs found on your tailnet").disabled(true)
                    } else {
                        ForEach(peers) { p in
                            Button("\(p.name)  ·  \(p.ip)") {
                                draftName = p.name
                                draftSSHHost = p.ip
                                result = nil
                            }
                        }
                    }
                    Divider()
                    Button("Refresh") { Task { await refresh() } }
                }
                .frame(maxWidth: 240)
            }
            LabeledContent("Name") {
                TextField("home-ts or build server", text: $draftName)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            }
            LabeledContent("SSH host / IP") {
                TextField("alias, user@host, or 100.x.y.z", text: $draftSSHHost)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .onChange(of: draftSSHHost) { _, _ in result = nil }
            }
            HStack {
                Button(testing ? "Validating…" : "Validate & add Host") { Task { await testAndAdd() } }
                    .disabled(testing || draftSSHHost.trimmingCharacters(in: .whitespaces).isEmpty)
                if testing { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
                if let r = result {
                    Label(r.ok ? "Host added" : "Host unavailable",
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
            Text("Hosts execute agents through SSH and tmux. They may be macOS or Linux and do not need to run the Mesh Broker. Pharos validates the exact Host identity so Dashboard attach and stop actions route safely.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        peers = await Task.detached { PairingService.discoverPeers() }.value
    }

    private func testAndAdd() async {
        testing = true
        let host = draftSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = await Task.detached { PairingService.pair(host: host) }.value
        result = r
        testing = false
        guard r.ok else { return }
        let identity = r.hostIdentity
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.upsertExecutionHost(ExecutionHostProfile(
            name: name.isEmpty ? (identity ?? host) : name,
            sshHost: host,
            meshHostID: identity
        ))
        draftName = ""
        draftSSHHost = ""
    }
}

// MARK: - CLI

private struct CLISettingsTab: View {
    @State private var pharosStatus: String?
    @State private var chatStatus: String?
    @State private var skillStatus: String?
    @State private var meshHookInstalled = false
    @State private var meshHookStatus: String?
    @State private var codexHookInstalled = false
    @State private var codexHookStatus: String?

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

    private enum SubTab: String, CaseIterable, Identifiable {
        case cli = "CLI", claude = "Claude", codex = "Codex"
        var id: String { rawValue }
    }
    // Snapshot mode can open a specific sub-tab (e.g. settings:cli:codex).
    @State private var subtab: SubTab = SubTab(rawValue: (SnapshotMode.settingsSubTab ?? "").capitalized) ?? .cli

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $subtab) {
                ForEach(SubTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.top, 12)
            Form {
                switch subtab {
                case .cli:    cliSection
                case .claude: claudeSection
                case .codex:  codexSection
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            meshHookInstalled = MeshHooks.userHookInstalled()
            codexHookInstalled = MeshHooks.codexHookInstalled()
        }
    }

    // MARK: CLI — symlink the pharos/chat binaries onto PATH

    @ViewBuilder private var cliSection: some View {
        Section("pharos — project & issue control") {
            commandRow("pharos", status: $pharosStatus,
                       help: "How agents drive Pharos: a Claude Code / Codex session shells out to read and update issues and post progress — e.g. `pharos list --json`, `pharos issue start <project> 3 claude`, `pharos overview`.")
        }
        Section("chat — agent chat room") {
            commandRow("chat", status: $chatStatus,
                       help: "Shorthand for `pharos mesh`: agents talk to each other — `chat join <room> <nick>`, `chat say <room> <nick> \"…\" @peer`. Same binary, invoked as `chat`.")
        }
    }

    // MARK: Claude — mesh hooks + agent skills

    @ViewBuilder private var claudeSection: some View {
        Section("Mesh delivery hooks (Claude Code)") {
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
                HelpBadge(text: "Installs the Claude Code hooks that power the agent mesh: Stop surfaces unread @mentions as normal hook feedback, SessionStart injects the session id, and structured lifecycle hooks report busy / blocked / idle / stopped / gone without reading terminal text. Permission, elicitation completion, tool failure, and API failure are tracked explicitly. Per-repo alternative: `pharos mesh install-hooks --project <dir>`. Safe globally — un-joined sessions no-op.")
            }
            if let s = meshHookStatus {
                Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Section("Agent skills (Claude Code)") {
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
                    HelpBadge(text: "Symlink the bundled skills into ~/.claude/skills so every Claude session auto-loads them. For a single repo, use `pharos skill install <name> --project <dir>`.")
                }
            }
            if let s = skillStatus {
                Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Codex — mesh hooks (skills TBD)

    @ViewBuilder private var codexSection: some View {
        Section("Mesh delivery hooks (Codex)") {
            HStack {
                Image(systemName: codexHookInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(codexHookInstalled ? Color.green : Color.secondary)
                Text(codexHookInstalled ? "Installed → ~/.codex/hooks.json" : "Not installed")
                    .font(.callout)
                Spacer()
                Button(codexHookInstalled ? "Reinstall / update" : "Install (~/.codex)") {
                    _ = MeshHooks.installHooks(["--codex"])
                    codexHookInstalled = MeshHooks.codexHookInstalled()
                    codexHookStatus = codexHookInstalled
                        ? "Installed → ~/.codex/hooks.json. First run: Codex prompts to trust hooks — start it with --dangerously-bypass-hook-trust, or approve once."
                        : "Install failed — check ~/.codex/hooks.json (invalid JSON is never overwritten)."
                }
                .buttonStyle(.borderedProminent)
                HelpBadge(text: "Codex ships structured lifecycle hooks: Stop handles unread + stopped, SessionStart records identity, UserPromptSubmit / PostToolUse report busy, and PermissionRequest reports blocked. Empty PostToolUse hooks stay silent. Codex still lacks Notification/SessionEnd, so idle is unavailable and Host-local liveness owns gone. Needs a recent Codex build (older ones only have `notify`).")
            }
            if let s = codexHookStatus {
                Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Section("Agent skills (Codex)") {
            Text("Codex skill install isn't wired yet (tracked as Pharos#2 — write into AGENTS.md). Use the Claude tab for now.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var skillNames: [String] { SkillInstall.available() }

    @ViewBuilder
    private func commandRow(_ name: String, status: Binding<String?>, help: String) -> some View {
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
            HelpBadge(text: help)
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
