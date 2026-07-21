import SwiftUI

struct SettingsView: View {
    var showsDoneButton = false
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(PairingCoordinator.self) private var pairing
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Environment(\.dismiss) private var dismiss
    @State private var meshHost = ""
    @State private var meshPort = "47800"
    @State private var showHostEditor = false
    @State private var showsPairingScanner = false
    @State private var brokerStatus: MobileBrokerConnectionStatus = .unchecked
    private let meshClient = MeshTCPClient()

    var body: some View {
        NavigationStack {
            List {
                if isDistributed {
                    distributedDevicesSection
                } else {
                    brokerSection
                }

                Section("Hosts") {
                    ForEach(settings.sshHosts) { profile in
                        NavigationLink {
                            SSHHostEditor(profile: profile)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(profile.displayName)
                                Text("\(profile.username)@\(profile.sshHost):\(profile.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                settings.removeSSHHost(id: profile.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    Button("Add Host", systemImage: "plus") { showHostEditor = true }
                }

                Section {
                    if identities.identities.isEmpty {
                        Button("Generate Ed25519 identity") { _ = try? identities.generate() }
                    }
                    ForEach(identities.identities) { identity in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(identity.label).font(.headline)
                            Text(identity.publicKeyOpenSSH).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy public key") { UIPasteboard.general.string = identity.publicKeyOpenSSH }
                                .font(.caption)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                try? identities.delete(identity)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Device SSH identity")
                } footer: {
                    Text(isDistributed
                         ? "Private keys are device-local in Keychain and never uploaded to iCloud. Hosts use SSH only for agent execution; replicated Mesh data travels directly between trusted devices."
                         : "Private keys are device-local in Keychain and never uploaded to iCloud. Hosts use SSH to launch, attach, and stop agents; Mesh traffic goes directly to the Broker.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Runtime limits") {
                    if isDistributed {
                        Label("Signed device-to-device replica sync", systemImage: "point.3.connected.trianglepath.dotted")
                        Label("Background sync pauses when iOS suspends Pharos", systemImage: "moon.zzz")
                    } else {
                        Label("Live Broker events with reconnect sync", systemImage: "bolt.horizontal.circle")
                        Label("Background delivery requires a future APNs relay", systemImage: "bell.slash")
                    }
                }
            }
            .pharosPlainList()
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .sheet(isPresented: $showHostEditor) { NavigationStack { SSHHostEditor(profile: nil) } }
            .sheet(isPresented: $showsPairingScanner) {
                PairingScannerSheet { value in
                    showsPairingScanner = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        pairing.receive(value)
                    }
                }
            }
            .onAppear { load() }
            .onChange(of: settings.mesh) { load() }
            .task {
                if !isDistributed { await testBroker() }
            }
        }
    }

    private var isDistributed: Bool {
        PharosMeshRuntimeMode.usesDistributedMesh
    }

    @ViewBuilder
    private var distributedDevicesSection: some View {
        Section {
            Button("Pair a trusted device", systemImage: "qrcode.viewfinder") {
                showsPairingScanner = true
            }
            distributedStateView
            if distributedMesh.connections.isEmpty {
                Text("No peer connection has been observed yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    distributedMesh.connections.values.sorted {
                        $0.peer.rawValue < $1.peer.rawValue
                    }, id: \.peer
                ) { connection in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            abbreviated(connection.peer.rawValue.uuidString),
                            systemImage: connection.connected
                                ? "checkmark.circle.fill" : "circle.dashed"
                        )
                        .foregroundStyle(connection.connected ? .green : .secondary)
                        Text(String(describing: connection.path))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let lastSyncError = distributedMesh.lastSyncError {
                Text(lastSyncError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                Task { _ = await distributedMesh.synchronizeOnce() }
            }
        } header: {
            Text("Trusted devices").textCase(nil)
        } footer: {
            Text("Every device stores its own signed replica. No Broker is the source of truth; concurrent field edits converge deterministically after devices reconnect.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var distributedStateView: some View {
        switch distributedMesh.state {
        case .disabled:
            Label("Private mesh disabled", systemImage: "network.slash")
                .foregroundStyle(.secondary)
        case .opening:
            HStack { ProgressView(); Text("Opening private mesh…") }
        case .ready(let deviceID, _):
            LabeledContent("This iPhone") {
                Text(abbreviated(deviceID.rawValue.uuidString))
                    .font(.caption.monospaced())
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var brokerSection: some View {
        Section {
            Button("Set up Mesh Broker…", systemImage: "wand.and.stars") {
                pairing.showsSetupGuide = true
            }
            Button("Pair with another Broker", systemImage: "qrcode.viewfinder") {
                showsPairingScanner = true
            }
            brokerStatusView
            HStack {
                Text(brokerTarget)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Test again") { Task { await testBroker() } }
                    .disabled(brokerStatus.isChecking || !hasValidBrokerTarget)
            }
            LabeledContent("Host") {
                TextField("Tailscale IP or MagicDNS", text: $meshHost)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("Port") {
                TextField("47800", text: $meshPort)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }
            Button("Save connection") {
                saveMesh()
                Task { await testBroker() }
            }
        } header: {
            Text("Mesh Broker").textCase(nil)
        } footer: {
            Text("The Broker is the single source of truth for projects, issues, logs, rooms, messages, and attachments. This iPhone keeps only a local cache; Hosts execute agents separately.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func abbreviated(_ value: String) -> String {
        value.count > 16 ? "\(value.prefix(8))…\(value.suffix(8))" : value
    }

    private var hasValidBrokerTarget: Bool {
        !meshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && UInt16(meshPort) != nil
    }

    private var brokerTarget: String {
        guard hasValidBrokerTarget else { return "No valid Broker endpoint" }
        return "\(meshHost.trimmingCharacters(in: .whitespacesAndNewlines)):\(meshPort)"
    }

    @ViewBuilder
    private var brokerStatusView: some View {
        switch brokerStatus {
        case .unchecked:
            Label("Not tested yet", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
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
            }
        case .invalidEndpoint:
            Label("Enter a valid Broker host and port.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func capabilitySummary(_ capabilities: [String]) -> String {
        var labels: [String] = []
        if capabilities.contains("mesh-v2") { labels.append("Mesh v2") }
        if capabilities.contains("reply-v1") { labels.append("Replies") }
        if capabilities.contains("attachment-v1") { labels.append("Attachments") }
        if capabilities.contains("headless-v1") { labels.append("Headless") }
        return labels.isEmpty ? "Broker responded" : labels.joined(separator: " · ")
    }

    @MainActor
    private func testBroker() async {
        let host = meshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = UInt16(meshPort) else {
            brokerStatus = .invalidEndpoint
            return
        }
        brokerStatus = .checking
        let started = ContinuousClock.now
        do {
            let response = try await meshClient.send(MeshRequest(cmd: "capabilities"), host: host, port: port)
            let duration = started.duration(to: .now)
            let latencyMS = max(0, Int(duration.components.seconds * 1_000
                + duration.components.attoseconds / 1_000_000_000_000_000))
            guard let capabilities = response.capabilities,
                  capabilities.contains("mesh-v2") else {
                brokerStatus = .unavailable("The server responded, but it is not a compatible Pharos Mesh Broker.")
                return
            }
            brokerStatus = .connected(latencyMS: latencyMS, capabilities: capabilities)
        } catch {
            brokerStatus = .unavailable(error.localizedDescription)
        }
    }

    private func load() {
        meshHost = settings.mesh.host
        meshPort = String(settings.mesh.port)
    }

    private func saveMesh() {
        guard let port = UInt16(meshPort) else { return }
        settings.updateMesh(host: meshHost, port: port)
    }
}

private enum MobileBrokerConnectionStatus: Equatable {
    case unchecked
    case checking
    case connected(latencyMS: Int, capabilities: [String])
    case unavailable(String)
    case invalidEndpoint

    var isChecking: Bool { self == .checking }
}

private struct SSHHostEditor: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private enum HostChoice: Hashable { case pick(String), custom }
    @State private var value: SSHHostProfile
    @State private var portText: String
    @State private var hostChoice: HostChoice = .custom
    @State private var lastAutoIP = ""
    @State private var password = ""
    @State private var installing = false
    @State private var installNote: String?
    @State private var installOK = false
    private let service = RemoteAgentService()

    init(profile: SSHHostProfile?) {
        let initial = profile ?? SSHHostProfile(meshHost: "", sshHost: "", username: "user")
        _value = State(initialValue: initial)
        _portText = State(initialValue: String(initial.port))
    }

    /// Distinct, non-empty host names reported by members in the live roster.
    private var knownHosts: [String] {
        Array(Set(store.members.values.compactMap { m in
            let h = m.host?.trimmingCharacters(in: .whitespaces)
            return (h?.isEmpty == false) ? h : nil
        })).sorted()
    }

    /// Roster hosts, plus the currently-set host if it isn't online right now
    /// (so editing an offline mapping still shows its value).
    private var hostOptions: [String] {
        var opts = knownHosts
        let cur = value.meshHost.trimmingCharacters(in: .whitespaces)
        if !cur.isEmpty, !opts.contains(cur) { opts.insert(cur, at: 0) }
        return opts
    }

    /// The Tailscale IP a member on `host` reported at join (nil if unknown).
    private func reportedIP(for host: String) -> String? {
        store.members.values.first {
            $0.host == host && ($0.tailscaleIP?.isEmpty == false)
        }?.tailscaleIP
    }

    var body: some View {
        Form {
            Section {
                if hostOptions.isEmpty {
                    TextField("Host identity", text: $value.meshHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Picker("Host identity", selection: $hostChoice) {
                        ForEach(hostOptions, id: \.self) { Text($0).tag(HostChoice.pick($0)) }
                        Text("Custom…").tag(HostChoice.custom)
                    }
                    if hostChoice == .custom {
                        TextField("Host identity", text: $value.meshHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                TextField("Tailscale SSH host", text: $value.sshHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username", text: $value.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("SSH port", text: $portText).keyboardType(.numberPad)
                Picker("Identity", selection: $value.identityID) {
                    Text("None").tag(UUID?.none)
                    ForEach(identities.identities) { Text($0.label).tag(Optional($0.id)) }
                }
            } header: {
                Text("Host")
            } footer: {
                Text("Host identity is picked from members currently registered with the Broker, so attach and stop actions route to the correct SSH machine. Choose Custom… for an offline Host.")
            }

            Section {
                Toggle("I accept unpinned host keys", isOn: $value.acceptsUnverifiedHostKey)
            } footer: {
                Text("Citadel currently uses accept-any host-key validation here. Only enable this for a host reached through your private Tailscale network.")
            }

            Section {
                SecureField("Host login password (used once)", text: $password)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    installKey()
                } label: {
                    HStack {
                        Label(installing ? "Installing…" : "Install this device's key", systemImage: "key.horizontal")
                        if installing { Spacer(); ProgressView() }
                    }
                }
                .disabled(!canInstall)
                if let installNote {
                    Label(installNote, systemImage: installOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(installOK ? .green : .red)
                }
            } header: {
                Text("Install key on host")
            } footer: {
                Text(identities.identities.isEmpty
                     ? "Generate a device SSH identity first (in the previous screen), then enter the host's login password once. Pharos appends the key to ~/.ssh/authorized_keys and verifies key login — the password is never stored. The Mac needs Remote Login on (System Settings → General → Sharing)."
                     : "Enter the host's login password once. Pharos appends the selected key to ~/.ssh/authorized_keys and verifies key login — the password is never stored. The Mac needs Remote Login on (System Settings → General → Sharing).")
            }

            Section {
                Button("Save") {
                    guard let port = UInt16(portText) else { return }
                    value.port = port
                    settings.upsertSSHHost(value)
                    dismiss()
                }
            }
        }
        .pharosPlainList()
        .navigationTitle("Host")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: hostChoice) {
            guard case .pick(let h) = hostChoice else { return }
            value.meshHost = h
            // Auto-fill the SSH host from the member's reported Tailscale IP, but
            // never clobber a value the user typed themselves — only overwrite an
            // empty field or one we auto-filled for the previous pick.
            if let ip = reportedIP(for: h),
               value.sshHost.trimmingCharacters(in: .whitespaces).isEmpty || value.sshHost == lastAutoIP {
                value.sshHost = ip
                lastAutoIP = ip
            }
        }
        .onAppear {
            let cur = value.meshHost.trimmingCharacters(in: .whitespaces)
            if !cur.isEmpty {
                hostChoice = .pick(cur)
            } else if let first = knownHosts.first {
                hostChoice = .pick(first)
                value.meshHost = first
            } else {
                hostChoice = .custom
            }
        }
    }

    private var canInstall: Bool {
        value.identityID != nil
            && !value.sshHost.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && UInt16(portText) != nil
            && !installing
    }

    private func installKey() {
        guard let idID = value.identityID,
              let identity = identities.identities.first(where: { $0.id == idID }),
              let port = UInt16(portText) else { return }
        installing = true
        installNote = nil
        Task {
            do {
                let priv = try identities.privateKey(for: idID)
                let outcome = try await service.installAuthorizedKey(
                    publicKeyOpenSSH: identity.publicKeyOpenSSH,
                    host: value.sshHost.trimmingCharacters(in: .whitespaces),
                    port: port,
                    username: value.username.trimmingCharacters(in: .whitespaces),
                    password: password, privateKey: priv)
                value.port = port
                value.acceptsUnverifiedHostKey = true
                settings.upsertSSHHost(value)
                password = ""
                installOK = true
                installNote = outcome == .added
                    ? "Key installed and verified — key login works. Host saved."
                    : "Key already present — verified key login works. Host saved."
            } catch {
                installOK = false
                installNote = "Install failed: \(error.localizedDescription)"
            }
            installing = false
        }
    }
}
