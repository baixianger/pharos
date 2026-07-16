import Foundation
import Observation

struct MeshProfile: Codable, Equatable, Sendable {
    var host = ""
    var port: UInt16 = 47_800
}

struct SSHHostProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var meshHost: String
    var sshHost: String
    var port: UInt16 = 22
    var username: String
    var identityID: UUID?
    var acceptsUnverifiedHostKey = false

    var displayName: String {
        let value = meshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? sshHost : value
    }
}

private struct SyncedConfiguration: Codable, Equatable, Sendable {
    var mesh = MeshProfile()
    var sshHosts: [SSHHostProfile] = []
}

@Observable
@MainActor
final class AppSettings {
    private static let storageKey = "pharos.mobile.configuration.v1"
    private(set) var mesh = MeshProfile()
    private(set) var sshHosts: [SSHHostProfile] = []

    init() { load() }

    func updateMesh(host: String, port: UInt16) {
        mesh = MeshProfile(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
        save()
    }

    func upsertSSHHost(_ profile: SSHHostProfile) {
        if let index = sshHosts.firstIndex(where: { $0.id == profile.id }) {
            sshHosts[index] = profile
        } else {
            sshHosts.append(profile)
        }
        save()
    }

    func removeSSHHost(id: UUID) {
        sshHosts.removeAll { $0.id == id }
        save()
    }

    func sshHost(for meshHost: String?) -> SSHHostProfile? {
        guard let meshHost else { return nil }
        return sshHosts.first { $0.meshHost == meshHost }
    }

    private func load() {
        let source = UserDefaults.standard.data(forKey: Self.storageKey)
        guard let source, let decoded = try? JSONDecoder().decode(SyncedConfiguration.self, from: source) else { return }
        mesh = decoded.mesh
        sshHosts = decoded.sshHosts
    }

    private func save() {
        let value = SyncedConfiguration(mesh: mesh, sshHosts: sshHosts)
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
