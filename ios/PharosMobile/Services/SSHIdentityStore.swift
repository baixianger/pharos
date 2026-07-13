import Crypto
import Foundation
import Observation
import Security

struct SSHIdentity: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var label: String
    var publicKeyOpenSSH: String
    var createdAt: Date
}

enum SSHIdentityError: LocalizedError {
    case missingPrivateKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingPrivateKey: "The private SSH key is missing from this device."
        case .keychain(let status): "Keychain error \(status)."
        }
    }
}

@Observable
@MainActor
final class SSHIdentityStore {
    private static let service = "me.pai.pharos.mobile.ssh"
    private static let indexKey = "pharos.mobile.ssh-identities.v1"
    private(set) var identities: [SSHIdentity]

    init() {
        identities = (UserDefaults.standard.data(forKey: Self.indexKey))
            .flatMap { try? JSONDecoder().decode([SSHIdentity].self, from: $0) } ?? []
    }

    @discardableResult
    func generate(label: String = "Pharos iOS") throws -> SSHIdentity {
        let key = Curve25519.Signing.PrivateKey()
        let identity = SSHIdentity(
            id: UUID(), label: label,
            publicKeyOpenSSH: Self.openSSH(publicKey: key.publicKey.rawRepresentation, comment: label),
            createdAt: Date()
        )
        try Self.writePrivateKey(key.rawRepresentation, id: identity.id)
        identities.append(identity)
        persistIndex()
        return identity
    }

    func privateKey(for id: UUID) throws -> Curve25519.Signing.PrivateKey {
        guard let raw = try Self.readPrivateKey(id: id) else { throw SSHIdentityError.missingPrivateKey }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    func delete(_ identity: SSHIdentity) throws {
        let status = SecItemDelete(Self.query(id: identity.id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SSHIdentityError.keychain(status) }
        identities.removeAll { $0.id == identity.id }
        persistIndex()
    }

    private func persistIndex() {
        UserDefaults.standard.set(try? JSONEncoder().encode(identities), forKey: Self.indexKey)
    }

    private static func query(id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    private static func writePrivateKey(_ data: Data, id: UUID) throws {
        var add = query(id: id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHIdentityError.keychain(status) }
    }

    private static func readPrivateKey(id: UUID) throws -> Data? {
        var q = query(id: id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SSHIdentityError.keychain(status) }
        return item as? Data
    }

    private static func openSSH(publicKey: Data, comment: String) -> String {
        let algorithm = Data("ssh-ed25519".utf8)
        func field(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + data
        }
        return "ssh-ed25519 \((field(algorithm) + field(publicKey)).base64EncodedString()) \(comment)"
    }
}

