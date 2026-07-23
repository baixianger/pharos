import SwiftUI
import PharosMeshIdentity
import PharosMeshProtocol

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
    @State private var showsInviteDevice = false
    @State private var showsLeaveOptions = false
    @State private var brokerStatus: MobileBrokerConnectionStatus = .unchecked
    @State private var deviceToRevoke: MeshPairedDevice?
    @State private var revokeError: String?
    @State private var lifecycleError: String?
    @State private var isChangingMeshMembership = false
    @State private var showsResetDeviceConfirmation = false
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
                PairingScannerSheet(allowsLegacyBrokerLinks: !isDistributed) { value in
                    showsPairingScanner = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        pairing.receive(value)
                    }
                }
            }
            .sheet(isPresented: $showsInviteDevice) {
                InviteDeviceSheet().environment(distributedMesh)
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
                Text("\(device.descriptor.displayName) will lose Mesh access. Use this for a lost or replaced device.")
            }
            .confirmationDialog(
                "Leave this personal Mesh?",
                isPresented: $showsLeaveOptions,
                titleVisibility: .visible
            ) {
                Button("Remove this device from Mesh", role: .destructive) {
                    leaveMesh()
                }
                Button("Disconnect and archive locally") {
                    archiveMeshLocally()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leaving publishes a signed self-removal and requires another online Mesh admin device. Disconnecting only archives this iPhone locally; revoke it later from another admin device.")
            }
            .confirmationDialog(
                "Reset this iPhone as a new Mesh device?",
                isPresented: $showsResetDeviceConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Local Mesh Data and Identity", role: .destructive) {
                    resetAsNewMeshDevice()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes every local Mesh replica and creates a new device identity. Other devices keep their data and may still list the old iPhone until you remove it there.")
            }
            .alert(
                "Couldn’t Leave Mesh",
                isPresented: Binding(
                    get: { lifecycleError != nil },
                    set: { if !$0 { lifecycleError = nil } }
                )
            ) {
                Button("Archive on This iPhone") { archiveMeshLocally() }
                Button("Keep Connected", role: .cancel) { lifecycleError = nil }
            } message: {
                Text(lifecycleError ?? "The leave request could not be completed.")
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
            if distributedMesh.activeTrustGroupID != nil {
                Button("Invite a device", systemImage: "person.badge.plus") {
                    showsInviteDevice = true
                }
                .disabled(!distributedMesh.isLocalMeshAdmin)
            }
            Button("Join another Mesh", systemImage: "qrcode.viewfinder") {
                showsPairingScanner = true
            }
            distributedStateView
            LabeledContent("Mesh admins") {
                Text("\(distributedMesh.meshAdminCount)")
                    .font(.caption.monospaced())
            }
            if distributedMesh.trustedDevices.isEmpty {
                ContentUnavailableView {
                    Label("No trusted peers yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("On a Mac, choose Settings → Machines → Pair a device, then scan its QR code here.")
                }
            } else {
                ForEach(distributedMesh.trustedDevices, id: \.descriptor.id) { device in
                    trustedDeviceRow(device)
                        .swipeActions(edge: .trailing) {
                            if distributedMesh.isLocalMeshAdmin {
                            Button(role: .destructive) {
                                deviceToRevoke = device
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            }
                        }
                }
            }
            if !distributedMesh.membershipAudit.isEmpty {
                LabeledContent("Membership audit") {
                    Text("\(distributedMesh.membershipAudit.count)")
                        .font(.caption.monospaced())
                }
                ForEach(Array(distributedMesh.membershipAudit.suffix(3).reversed())) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.removedDevices.isEmpty
                             ? "Roster updated"
                             : "Removed " + entry.removedDevices.map {
                                $0.descriptor.displayName
                             }.joined(separator: ", "))
                        Text(
                            "epoch \(entry.previousEpoch)→\(entry.nextEpoch) · " +
                            "admin \(entry.authorDeviceID.rawValue.uuidString.prefix(8)) · " +
                            "sha256 \(entry.transitionSHA256.prefix(12))…"
                        )
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if !distributedMesh.trustedDevices.isEmpty,
               distributedMesh.connections.values.allSatisfy({ !$0.connected }) {
                Text("Trusted peers are offline. Changes stay on this iPhone and merge when any peer reconnects.")
                    .foregroundStyle(.secondary)
            }
            if let lastSyncError = distributedMesh.lastSyncError {
                Text(lastSyncError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let revokeError {
                Text(revokeError).font(.caption).foregroundStyle(.red)
            }
            if distributedMesh.activeTrustGroupID != nil {
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { _ = await distributedMesh.synchronizeOnce() }
                }
                Button("Leave this Mesh", systemImage: "rectangle.portrait.and.arrow.right") {
                    lifecycleError = nil
                    showsLeaveOptions = true
                }
                .foregroundStyle(.red)
                .disabled(isChangingMeshMembership)
            } else {
                Text("This iPhone is not joined to a Mesh. Reset it if you want a completely new device identity before scanning an invitation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset as New Mesh Device", systemImage: "arrow.counterclockwise.circle", role: .destructive) {
                    showsResetDeviceConfirmation = true
                }
                .disabled(isChangingMeshMembership)
            }
            if isChangingMeshMembership {
                HStack {
                    ProgressView()
                    Text("Updating Mesh membership…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let lifecycleError {
                Text(lifecycleError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Trusted devices").textCase(nil)
        } footer: {
            Text("Every device stores its own signed replica. No Broker is the source of truth; concurrent field edits converge deterministically after devices reconnect.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trustedDeviceRow(_ device: MeshPairedDevice) -> some View {
        let connection = distributedMesh.connections[device.descriptor.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(
                    device.descriptor.displayName,
                    systemImage: connection?.connected == true
                        ? "checkmark.circle.fill" : "circle.dashed"
                )
                .foregroundStyle(connection?.connected == true ? .green : .primary)
                if device.descriptor.roles.contains(.controller) {
                    Text("Mesh Admin")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.12), in: Capsule())
                }
                if localDeviceID == device.descriptor.id {
                    Text("This iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text([
                deviceAccessSummary(device.descriptor.roles),
                connection.map { String(describing: $0.path) } ?? "not connected yet",
                abbreviated(device.descriptor.id.rawValue.uuidString),
            ].joined(separator: " · "))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private var localDeviceID: MeshDeviceID? {
        guard case .ready(let deviceID, _) = distributedMesh.state else { return nil }
        return deviceID
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
                HStack(spacing: 6) {
                    if distributedMesh.isLocalMeshAdmin {
                        Text("Mesh Admin")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                    Text(abbreviated(deviceID.rawValue.uuidString))
                        .font(.caption.monospaced())
                }
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

    private func leaveMesh() {
        lifecycleError = nil
        isChangingMeshMembership = true
        Task {
            defer { isChangingMeshMembership = false }
            do {
                _ = try await distributedMesh.leaveCurrentMesh(
                    displayName: UIDevice.current.name
                )
                pairing.showsSetupGuide = true
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    private func archiveMeshLocally() {
        lifecycleError = nil
        isChangingMeshMembership = true
        Task {
            defer { isChangingMeshMembership = false }
            do {
                _ = try await distributedMesh.archiveCurrentMesh()
                pairing.showsSetupGuide = true
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    private func resetAsNewMeshDevice() {
        lifecycleError = nil
        isChangingMeshMembership = true
        Task {
            defer { isChangingMeshMembership = false }
            do {
                try await distributedMesh.resetAsNewMeshDevice()
                pairing.showsSetupGuide = true
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    private func deviceAccessSummary(_ roles: Set<MeshDeviceRole>) -> String {
        if roles.contains(.controller), roles.contains(.replica) {
            return "data sync + agent control"
        }
        if roles.contains(.controller) { return "agent control" }
        if roles.contains(.replica) { return "data sync" }
        return "trusted device"
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
    @Environment(DistributedMeshSupport.self) private var distributedMesh
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

    /// Trusted P2P Host devices are authoritative. Live roster names are kept
    /// only as a migration fallback for legacy Broker profiles.
    private var trustedHosts: [(id: String, name: String)] {
        distributedMesh.trustedDevices
            .filter { $0.descriptor.roles.contains(.host) }
            .map {
                (
                    $0.descriptor.id.rawValue.uuidString,
                    $0.descriptor.displayName
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var knownLegacyHosts: [String] {
        Array(Set(store.members.values.compactMap { m in
            let h = m.host?.trimmingCharacters(in: .whitespaces)
            return (h?.isEmpty == false) ? h : nil
        })).sorted()
    }

    private var legacyHostOptions: [String] {
        var options = knownLegacyHosts
        let current = value.meshHost.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty,
           !options.contains(where: {
               $0.caseInsensitiveCompare(current) == .orderedSame
           }),
           !trustedHosts.contains(where: {
               $0.name.caseInsensitiveCompare(current) == .orderedSame
           }) {
            options.insert(current, at: 0)
        }
        return options
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
                if trustedHosts.isEmpty && legacyHostOptions.isEmpty {
                    TextField("Host identity", text: $value.meshHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Picker("Host identity", selection: $hostChoice) {
                        ForEach(trustedHosts, id: \.id) { host in
                            Text(host.name).tag(HostChoice.pick(host.id))
                        }
                        ForEach(legacyHostOptions.filter { legacy in
                            !trustedHosts.contains { $0.name == legacy }
                        }, id: \.self) { legacy in
                            Text(legacy).tag(HostChoice.pick("legacy:\(legacy)"))
                        }
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
                Text("Choose the trusted Mesh Host that owns the agents. Pharos stores its stable Device ID, so SSH and tmux routing survives display-name changes. Choose Custom… only for a legacy or offline Host.")
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
            guard case .pick(let selection) = hostChoice else {
                value.meshDeviceID = nil
                return
            }
            let h: String
            if selection.hasPrefix("legacy:") {
                h = String(selection.dropFirst("legacy:".count))
                value.meshDeviceID = nil
            } else if let trusted = trustedHosts.first(where: { $0.id == selection }) {
                h = trusted.name
                value.meshDeviceID = trusted.id
            } else {
                return
            }
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
            if let deviceID = value.meshDeviceID,
               trustedHosts.contains(where: { $0.id == deviceID }) {
                hostChoice = .pick(deviceID)
            } else if let exact = trustedHosts.first(where: {
                $0.name.caseInsensitiveCompare(cur) == .orderedSame
            }) {
                hostChoice = .pick(exact.id)
                value.meshDeviceID = exact.id
                value.meshHost = exact.name
            } else if !cur.isEmpty {
                hostChoice = .pick("legacy:\(cur)")
            } else if let first = trustedHosts.first {
                hostChoice = .pick(first.id)
                value.meshDeviceID = first.id
                value.meshHost = first.name
            } else if let first = legacyHostOptions.first {
                hostChoice = .pick("legacy:\(first)")
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
