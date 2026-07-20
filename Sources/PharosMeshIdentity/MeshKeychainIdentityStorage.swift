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

    private var baseQuery: [CFString: Any] {
        var value: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if let accessGroup { value[kSecAttrAccessGroup] = accessGroup }
        return value
    }
}
#endif
