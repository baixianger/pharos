import SwiftUI

struct SettingsView: View {
    var showsDoneButton = false
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(\.dismiss) private var dismiss
    @State private var meshHost = ""
    @State private var meshPort = "47800"
    @State private var showHostEditor = false
    @State private var brokerStatus: MobileBrokerConnectionStatus = .unchecked
    private let meshClient = MeshTCPClient()

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                    HStack {
                        Button("Save connection") {
                            saveMesh()
                            Task { await testBroker() }
                        }
                        Spacer()
                        Button("Refresh iCloud") { settings.refreshFromICloud(); load() }
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Mesh Broker").textCase(nil)
                } footer: {
                    Text("Configuration may sync through iCloud. Messages travel directly over Tailscale TCP.")
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
                    }
                } header: {
                    Text("Device SSH identity")
                } footer: {
                    Text("Private keys are device-local in Keychain and never uploaded to iCloud.")
                }

                Section("SSH host mappings") {
                    ForEach(settings.sshHosts) { profile in
                        NavigationLink {
                            SSHHostEditor(profile: profile)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(profile.meshHost)
                                Text("\(profile.username)@\(profile.sshHost):\(profile.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Add SSH host mapping", systemImage: "plus") { showHostEditor = true }
                }

                Section("Runtime limits") {
                    Label("Foreground polling every 2 seconds", systemImage: "arrow.triangle.2.circlepath")
                    Label("Background delivery requires a future APNs relay", systemImage: "bell.slash")
                }
            }
            .pharosPlainList()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .sheet(isPresented: $showHostEditor) { NavigationStack { SSHHostEditor(profile: nil) } }
            .onAppear { load() }
            .task { await testBroker() }
        }
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
                    TextField("Mesh host identity", text: $value.meshHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Picker("Mesh host", selection: $hostChoice) {
                        ForEach(hostOptions, id: \.self) { Text($0).tag(HostChoice.pick($0)) }
                        Text("Custom…").tag(HostChoice.custom)
                    }
                    if hostChoice == .custom {
                        TextField("Mesh host identity", text: $value.meshHost)
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
                Text("Mesh host is picked from members currently in your rooms, so it matches exactly. Choose Custom… to type one that isn't online.")
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
        .navigationTitle("SSH host")
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
