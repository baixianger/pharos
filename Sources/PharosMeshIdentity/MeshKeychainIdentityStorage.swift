import Foundation

#if canImport(Security)
import Security

public enum MeshKeychainIdentityStorageError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidReturnedData
}

/// Apple device identity storage. Items are device-only, non-synchronizing,
/// and available after first unlock so foreground/background reconnects can use
/// the same endpoint without copying key material into preferences or files.
public struct MeshKeychainIdentityStorage: MeshIdentityStorage, Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String = "me.pai.pharos.mesh.identity",
        account: String = "device-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> Data? {
        var query = baseQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = kCFBooleanTrue
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw MeshKeychainIdentityStorageError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw MeshKeychainIdentityStorageError.invalidReturnedData
        }
        return data
    }

    public func insertIfAbsent(_ data: Data) throws -> Bool {
        var attributes = baseQuery
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else {
            throw MeshKeychainIdentityStorageError.unexpectedStatus(status)
        }
        return true
    }

    /// Explicitly forgets this installation identity. Normal lifecycle code
    /// never calls this: it is reserved for a user-confirmed full device reset.
    public func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeshKeychainIdentityStorageError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [CFString: Any] {
        var value: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
#if os(macOS)
        // The legacy file Keychain can block indefinitely when a GUI launch is
        // initiated from SSH/tmux. Pharos targets macOS 26, so use the modern
        // device-local Data Protection Keychain just like iOS.
        value[kSecUseDataProtectionKeychain] = kCFBooleanTrue
#endif
        if let accessGroup { value[kSecAttrAccessGroup] = accessGroup }
        return value
    }
}

#if os(macOS)
public enum MeshMirroredIdentityStorageError: LocalizedError, Equatable, Sendable {
    case headlessBootstrapRequired
    case identityMismatch

    public var errorDescription: String? {
        switch self {
        case .headlessBootstrapRequired:
            "Run `pharos identity bootstrap` once (or open Pharos) to create this Mac's protected device identity."
        case .identityMismatch:
            "The protected headless identity does not match Keychain. Restore the device identity backup before continuing."
        }
    }
}

/// Keeps Keychain as the authority for first creation while making the same
/// device identity usable by SSH/tmux hooks. The mirror is a private,
/// no-follow, insert-only 0600 file; it has a distinct name from isolated test
/// identities so an accidental `--data-dir` invocation cannot replace it.
public struct MeshMirroredIdentityStorage: MeshIdentityStorage, Sendable {
    public let keychain: MeshKeychainIdentityStorage
    public let mirror: MeshFileIdentityStorage
    public let headlessOnly: Bool

    public init(
        keychain: MeshKeychainIdentityStorage, mirrorURL: URL,
        headlessOnly: Bool = false
    ) {
        self.keychain = keychain
        mirror = MeshFileIdentityStorage(fileURL: mirrorURL)
        self.headlessOnly = headlessOnly
    }

    public func load() throws -> Data? {
        if headlessOnly {
            guard let mirrored = try mirror.load() else {
                throw MeshMirroredIdentityStorageError.headlessBootstrapRequired
            }
            return mirrored
        }
        let mirrored = try mirror.load()
        if let authoritative = try keychain.load() {
            if let mirrored, mirrored != authoritative {
                throw MeshMirroredIdentityStorageError.identityMismatch
            }
            _ = try mirror.insertIfAbsent(authoritative)
            return authoritative
        }
        if let mirrored {
            _ = try keychain.insertIfAbsent(mirrored)
            return mirrored
        }
        return nil
    }

    public func insertIfAbsent(_ data: Data) throws -> Bool {
        let inserted = try keychain.insertIfAbsent(data)
        guard let authoritative = try keychain.load() else {
            throw MeshKeychainIdentityStorageError.invalidReturnedData
        }
        _ = try mirror.insertIfAbsent(authoritative)
        return inserted
    }
}
#endif
#endif
