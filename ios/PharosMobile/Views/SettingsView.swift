import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(\.dismiss) private var dismiss
    @State private var meshHost = ""
    @State private var meshPort = "47800"
    @State private var showHostEditor = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tailscale IP or MagicDNS name", text: $meshHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $meshPort).keyboardType(.numberPad)
                    Button("Save Mesh connection") { saveMesh() }
                    Button("Refresh from iCloud") { settings.refreshFromICloud(); load() }
                } header: {
                    Text("Mesh over Tailscale")
                } footer: {
                    Text("Only non-sensitive host mappings sync through iCloud. Live messages use Tailscale TCP.")
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
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showHostEditor) { NavigationStack { SSHHostEditor(profile: nil) } }
            .onAppear { load() }
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

private struct SSHHostEditor: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(\.dismiss) private var dismiss
    @State private var value: SSHHostProfile
    @State private var portText: String

    init(profile: SSHHostProfile?) {
        let initial = profile ?? SSHHostProfile(meshHost: "", sshHost: "", username: "user")
        _value = State(initialValue: initial)
        _portText = State(initialValue: String(initial.port))
    }

    var body: some View {
        Form {
            TextField("Mesh host identity", text: $value.meshHost).textInputAutocapitalization(.never)
            TextField("Tailscale SSH host", text: $value.sshHost).textInputAutocapitalization(.never)
            TextField("Username", text: $value.username).textInputAutocapitalization(.never)
            TextField("SSH port", text: $portText).keyboardType(.numberPad)
            Picker("Identity", selection: $value.identityID) {
                Text("None").tag(UUID?.none)
                ForEach(identities.identities) { Text($0.label).tag(Optional($0.id)) }
            }
            Toggle("I accept unpinned host keys", isOn: $value.acceptsUnverifiedHostKey)
            Text("Citadel currently uses accept-any host-key validation here. Only enable this for a host reached through your private Tailscale network.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Save") {
                guard let port = UInt16(portText) else { return }
                value.port = port
                settings.upsertSSHHost(value)
                dismiss()
            }
        }
        .navigationTitle("SSH host")
        .navigationBarTitleDisplayMode(.inline)
    }
}
