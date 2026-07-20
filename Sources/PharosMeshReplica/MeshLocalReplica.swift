import Foundation
import PharosMeshIdentity

public enum MeshLocalReplicaError: Error, Equatable, Sendable {
    case missingApplicationSupportDirectory
    case invalidDataDirectory
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

    public static func openDefault() throws -> MeshLocalReplica {
        let root = try defaultRootURL()
#if canImport(Security)
        let storage = MeshKeychainIdentityStorage(
            service: "me.pai.pharos.mesh.identity", account: "device-v1"
        )
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
}
