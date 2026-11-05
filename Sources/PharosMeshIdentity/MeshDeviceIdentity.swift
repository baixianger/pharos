import Crypto
import Foundation
import PharosMeshProtocol

public enum MeshDeviceIdentityError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidSecretKey
    case oversizedStorage
    case corruptStorage
    case identityCreationRace
}

/// Device-local identity material. The same 32-byte Ed25519 secret is passed to
/// Iroh for the stable Endpoint ID and signs Pharos envelopes. It deliberately
/// does not conform to Codable and its description never includes key bytes.
public struct MeshDeviceIdentity: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public static let version = 1

    public let deviceID: MeshDeviceID
    public let createdAtMilliseconds: Int64
    private let secretKey: Data

    public init(
        deviceID: MeshDeviceID = MeshDeviceID(),
        secretKey: Data,
        createdAtMilliseconds: Int64
    ) throws {
        guard secretKey.count == 32,
              (try? Curve25519.Signing.PrivateKey(rawRepresentation: secretKey)) != nil else {
            throw MeshDeviceIdentityError.invalidSecretKey
        }
        self.deviceID = deviceID
        self.secretKey = secretKey
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    public static func generate(now: Date = Date()) -> MeshDeviceIdentity {
        let key = Curve25519.Signing.PrivateKey()
        return try! MeshDeviceIdentity(
            secretKey: key.rawRepresentation,
            createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        )
    }

    /// Used only to initialize the local Iroh endpoint. Callers must not log,
    /// replicate, or place this value in diagnostics.
    public func irohSecretKeyBytes() -> Data { secretKey }

    public func signingPublicKeyBytes() throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: secretKey)
            .publicKey.rawRepresentation
    }

    public func endpointID() throws -> MeshEndpointID {
        let value = try signingPublicKeyBytes()
            .map { String(format: "%02x", $0) }
            .joined()
        guard let endpoint = MeshEndpointID(rawValue: value) else {
            throw MeshDeviceIdentityError.invalidSecretKey
        }
        return endpoint
    }

    public func signature(for data: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: secretKey).signature(for: data)
    }

    public var description: String {
        "MeshDeviceIdentity(deviceID: \(deviceID.rawValue.uuidString), key: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Minimal atomic storage contract. `insertIfAbsent` is intentionally distinct
/// from an overwrite so two processes starting together cannot silently rotate
/// the installation identity.
public protocol MeshIdentityStorage: Sendable {
    func load() throws -> Data?
    func insertIfAbsent(_ data: Data) throws -> Bool
}

public struct MeshDeviceIdentityRepository: Sendable {
    private static let maximumStoredBytes = 4 * 1024
    private let storage: any MeshIdentityStorage

    public init(storage: any MeshIdentityStorage) {
        self.storage = storage
    }

    public func load() throws -> MeshDeviceIdentity? {
        guard let data = try storage.load() else { return nil }
        return try Self.decode(data)
    }

    public func loadOrCreate(now: Date = Date()) throws -> MeshDeviceIdentity {
        if let existing = try load() { return existing }
        let candidate = MeshDeviceIdentity.generate(now: now)
        let encoded = try Self.encode(candidate)
        if try storage.insertIfAbsent(encoded) { return candidate }
        guard let winner = try load() else {
            throw MeshDeviceIdentityError.identityCreationRace
        }
        return winner
    }

    private static func encode(_ identity: MeshDeviceIdentity) throws -> Data {
        let stored = StoredIdentity(
            version: MeshDeviceIdentity.version,
            deviceID: identity.deviceID,
            secretKey: identity.irohSecretKeyBytes(),
            createdAtMilliseconds: identity.createdAtMilliseconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(stored)
        guard data.count <= maximumStoredBytes else {
            throw MeshDeviceIdentityError.oversizedStorage
        }
        return data
    }

    private static func decode(_ data: Data) throws -> MeshDeviceIdentity {
        guard data.count <= maximumStoredBytes else {
            throw MeshDeviceIdentityError.oversizedStorage
        }
        let stored: StoredIdentity
        do { stored = try JSONDecoder().decode(StoredIdentity.self, from: data) }
        catch { throw MeshDeviceIdentityError.corruptStorage }
        guard stored.version == MeshDeviceIdentity.version else {
            throw MeshDeviceIdentityError.unsupportedVersion(stored.version)
        }
        do {
            return try MeshDeviceIdentity(
                deviceID: stored.deviceID,
                secretKey: stored.secretKey,
                createdAtMilliseconds: stored.createdAtMilliseconds
            )
        } catch {
            throw MeshDeviceIdentityError.corruptStorage
        }
    }

    private struct StoredIdentity: Codable {
        var version: Int
        var deviceID: MeshDeviceID
        var secretKey: Data
        var createdAtMilliseconds: Int64
    }
}

/// Useful for previews and isolated tests. Production Apple and Linux callers
/// use Keychain and mode-0600 file storage respectively.
public final class MeshMemoryIdentityStorage: MeshIdentityStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init(data: Data? = nil) { self.data = data }

    public func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    public func insertIfAbsent(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.data == nil else { return false }
        self.data = data
        return true
    }
}
