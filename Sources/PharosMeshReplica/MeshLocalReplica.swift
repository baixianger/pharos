import Foundation
import PharosMeshIdentity
import PharosMeshProtocol

public enum MeshLocalReplicaError: Error, Equatable, Sendable {
    case missingApplicationSupportDirectory
    case invalidDataDirectory
    case corruptActiveTrustGroup
}

/// The one local replica factory used by macOS, iOS, and the headless CLI.
/// Its v1 directory is separate from every legacy Broker path, so opening it
/// cannot connect to, lock, or mutate a running legacy Mesh installation.
public struct MeshLocalReplica: Sendable {
    public let identity: MeshDeviceIdentity
    public let store: DistributedMeshStore
    public let rootURL: URL

    public init(identity: MeshDeviceIdentity, store: DistributedMeshStore,
                rootURL: URL) {
        self.identity = identity
        self.store = store
        self.rootURL = rootURL
    }

    /// `headless` is explicit because tmux servers routinely outlive and drop
    /// SSH environment variables. CLI/hooks must never guess that they are a
    /// GUI process and block on an unavailable login Keychain.
    public static func openDefault(headless: Bool = false) throws -> MeshLocalReplica {
        let root = try defaultRootURL()
#if canImport(Security)
#if os(macOS)
        // macOS agents must use the same identity from GUI, SSH, tmux, and
        // launchd. A Keychain item plus a plaintext mirror only duplicates the
        // secret and makes locked-login sessions unreliable, so the protected
        // 0600 file is the single authority on Mac. iOS remains Keychain-only.
        let storage = MeshFileIdentityStorage(
            fileURL: root.appendingPathComponent("headless-device-identity-v1.json")
        )
        if headless, try storage.load() == nil {
            throw MeshMirroredIdentityStorageError.headlessBootstrapRequired
        }
#else
        let storage = MeshKeychainIdentityStorage(
            service: "me.pai.pharos.mesh.identity", account: "device-v1"
        )
#endif
        return try open(rootURL: root, identityStorage: storage)
#else
        let storage = MeshFileIdentityStorage(
            fileURL: root.appendingPathComponent("identity-v1.json")
        )
        return try open(rootURL: root, identityStorage: storage)
#endif
    }

    /// Explicit test/development entry point. Both identity and database stay
    /// under the supplied root; it never consults Keychain or default paths.
    public static func openIsolated(rootURL: URL) throws -> MeshLocalReplica {
        let root = rootURL.standardizedFileURL
        return try open(
            rootURL: root,
            identityStorage: MeshFileIdentityStorage(
                fileURL: root.appendingPathComponent("identity-v1.json")
            )
        )
    }

    public static func open(
        rootURL: URL, identityStorage: any MeshIdentityStorage
    ) throws -> MeshLocalReplica {
        let root = rootURL.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw MeshLocalReplicaError.invalidDataDirectory
        }
        try ensurePrivateDirectory(root)
        let identity = try MeshDeviceIdentityRepository(
            storage: identityStorage
        ).loadOrCreate()
        let store = try DistributedMeshStore(
            databaseURL: root.appendingPathComponent("replica-v1.sqlite")
        )
        return MeshLocalReplica(identity: identity, store: store, rootURL: root)
    }

    public static func defaultRootURL() throws -> URL {
#if os(Linux)
        let environment = ProcessInfo.processInfo.environment
        let base: URL
        if let configured = environment["XDG_DATA_HOME"], configured.hasPrefix("/") {
            base = URL(fileURLWithPath: configured, isDirectory: true)
        } else if let userDirectory = environment["HOME"], userDirectory.hasPrefix("/") {
            base = URL(fileURLWithPath: userDirectory, isDirectory: true)
                .appendingPathComponent(".local/share", isDirectory: true)
        } else {
            throw MeshLocalReplicaError.missingApplicationSupportDirectory
        }
        return base.appendingPathComponent("pharos/distributed-mesh/v1", isDirectory: true)
#else
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { throw MeshLocalReplicaError.missingApplicationSupportDirectory }
        return base.appendingPathComponent(
            "Pharos/DistributedMesh/v1", isDirectory: true
        )
#endif
    }

    public func activeTrustGroup() throws -> MeshTrustGroupID? {
        let storage = MeshFileIdentityStorage(
            fileURL: rootURL.appendingPathComponent("active-trust-group-v1.json")
        )
        guard let data = try storage.load() else { return nil }
        guard let profile = try? JSONDecoder().decode(
            ActiveTrustGroupProfile.self, from: data
        ), profile.version == 1 else {
            throw MeshLocalReplicaError.corruptActiveTrustGroup
        }
        return profile.trustGroupID
    }

    /// Creates the first personal trust group exactly once across concurrent
    /// app/CLI launches. Joining an existing group uses pairing and must never
    /// overwrite this selection implicitly.
    public func ensureActiveTrustGroup() async throws -> MeshTrustGroupID {
        if let existing = try activeTrustGroup() {
            if try await store.membershipEpoch(for: existing) == nil {
                try await store.setMembershipEpoch(1, for: existing)
            }
            return existing
        }
        let candidate = MeshTrustGroupID()
        let profile = ActiveTrustGroupProfile(
            version: 1, trustGroupID: candidate
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let storage = MeshFileIdentityStorage(
            fileURL: rootURL.appendingPathComponent("active-trust-group-v1.json")
        )
        _ = try storage.insertIfAbsent(try encoder.encode(profile))
        guard let winner = try activeTrustGroup() else {
            throw MeshLocalReplicaError.corruptActiveTrustGroup
        }
        if try await store.membershipEpoch(for: winner) == nil {
            try await store.setMembershipEpoch(1, for: winner)
        }
        return winner
    }

    /// Selects a group learned through pairing. Existing selection is never
    /// overwritten implicitly, preventing an unrelated QR scan from silently
    /// moving the device into another trust domain.
    public func adoptActiveTrustGroup(
        _ group: MeshTrustGroupID, replacingExisting: Bool = false
    ) throws {
        let profile = ActiveTrustGroupProfile(version: 1, trustGroupID: group)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let storage = MeshFileIdentityStorage(
            fileURL: rootURL.appendingPathComponent("active-trust-group-v1.json")
        )
        let encoded = try encoder.encode(profile)
        if replacingExisting, let existing = try activeTrustGroup(), existing != group {
            try storage.replace(encoded)
        } else {
            _ = try storage.insertIfAbsent(encoded)
        }
        guard try activeTrustGroup() == group else {
            throw MeshLocalReplicaError.corruptActiveTrustGroup
        }
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw MeshLocalReplicaError.invalidDataDirectory
            }
        } else {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
    }

    private struct ActiveTrustGroupProfile: Codable {
        var version: Int
        var trustGroupID: MeshTrustGroupID
    }
}
