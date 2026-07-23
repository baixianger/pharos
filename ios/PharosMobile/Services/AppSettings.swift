import Foundation
import Observation

struct MeshProfile: Codable, Equatable, Sendable {
    var host = ""
    var port: UInt16 = 47_800
    var controlToken = ""
}

struct SSHHostProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var meshHost: String
    /// Stable P2P Host identity. `meshHost` remains the human-readable label
    /// and legacy migration fallback; routing must prefer this device ID.
    var meshDeviceID: String? = nil
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
    private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            // Non-routable placeholder. Demo RoomStore never performs a request,
            // and skipping load() prevents saved personal settings from entering
            // the screenshot process at all.
            mesh = MeshProfile(host: "demo.invalid", port: 47_800, controlToken: "")
        } else {
            load()
        }
    }

    func updateMesh(host: String, port: UInt16, controlToken: String? = nil) {
        mesh = MeshProfile(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                           controlToken: controlToken ?? mesh.controlToken)
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
        return SSHHostResolver.profile(forHost: meshHost, tailscaleIP: nil, in: sshHosts)
    }

    func sshHost(for member: MeshMember) -> SSHHostProfile? {
        SSHHostResolver.profile(forHost: member.host, tailscaleIP: member.tailscaleIP, in: sshHosts)
    }

    func sshHost(forDeviceID deviceID: String, displayName: String) -> SSHHostProfile? {
        SSHHostResolver.profile(
            forDeviceID: deviceID, host: displayName,
            tailscaleIP: nil, in: sshHosts
        )
    }

    private func load() {
        let source = UserDefaults.standard.data(forKey: Self.storageKey)
        if let source, let decoded = try? JSONDecoder().decode(SyncedConfiguration.self, from: source) {
            mesh = decoded.mesh
            sshHosts = decoded.sshHosts
        }
        // Debug/testing override: point at a Broker via launch arguments
        // (`--mesh-host <ip> --mesh-port <n>`). Never passed in normal use, so
        // production behavior is unchanged.
        if let host = PharosLaunchOptions.value(after: "--mesh-host"), !host.isEmpty {
            let port = PharosLaunchOptions.value(after: "--mesh-port").flatMap { UInt16($0) } ?? mesh.port
            mesh = MeshProfile(host: host, port: port, controlToken: mesh.controlToken)
        }
    }

    private func save() {
        guard !isDemo else { return }
        let value = SyncedConfiguration(mesh: mesh, sshHosts: sshHosts)
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

enum SSHHostResolver {
    static func profile(forHost host: String?, tailscaleIP: String?,
                        in profiles: [SSHHostProfile]) -> SSHHostProfile? {
        profile(
            forDeviceID: nil, host: host,
            tailscaleIP: tailscaleIP, in: profiles
        )
    }

    static func profile(forDeviceID deviceID: String? = nil,
                        host: String?, tailscaleIP: String?,
                        in profiles: [SSHHostProfile]) -> SSHHostProfile? {
        if let deviceID = canonical(deviceID),
           let exact = uniqueMatch(in: profiles, where: {
               canonical($0.meshDeviceID) == deviceID
           }) {
            return exact
        }

        let host = canonical(host)
        let tailscaleIP = canonical(tailscaleIP)

        // A Tailscale address is the route identity when the member reports
        // one. Computer names remain display labels and a legacy fallback.
        if let tailscaleIP,
           let exact = uniqueMatch(in: profiles, where: {
               canonical($0.meshHost) == tailscaleIP || canonical($0.sshHost) == tailscaleIP
           }) {
            return exact
        }

        if let host, let exact = uniqueMatch(in: profiles, where: { canonical($0.meshHost) == host }) {
            return exact
        }

        // Older/manual iOS configurations often put the Tailscale IP or
        // MagicDNS endpoint into Host identity. Accept those aliases too: the
        // connection still uses the profile's sshHost, never member input.
        let aliases = Set([host, tailscaleIP].compactMap { $0 })
        guard !aliases.isEmpty else { return nil }
        return uniqueMatch(in: profiles) { profile in
            let configured = [canonical(profile.meshHost), canonical(profile.sshHost)].compactMap { $0 }
            return configured.contains { aliases.contains($0) }
        }
    }

    private static func canonical(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        while value.last == "." { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    private static func uniqueMatch(in profiles: [SSHHostProfile],
                                    where predicate: (SSHHostProfile) -> Bool) -> SSHHostProfile? {
        let matches = profiles.filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }
}
