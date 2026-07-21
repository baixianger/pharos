import Crypto
import Foundation
import XCTest
@testable import PharosMeshIdentity

final class MeshDeviceIdentityTests: XCTestCase {
    func testMemoryRepositoryCreatesStableRedactedSigningIdentity() throws {
        let storage = MeshMemoryIdentityStorage()
        let repository = MeshDeviceIdentityRepository(storage: storage)
        let first = try repository.loadOrCreate(now: Date(timeIntervalSince1970: 100))
        let restored = try repository.loadOrCreate(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(restored, first)
        XCTAssertEqual(first.irohSecretKeyBytes().count, 32)
        XCTAssertEqual(try first.signingPublicKeyBytes().count, 32)
        XCTAssertFalse(first.description.contains(first.irohSecretKeyBytes().base64EncodedString()))
        XCTAssertTrue(first.description.contains("<redacted>"))
        XCTAssertTrue(String(reflecting: first).contains("<redacted>"))
        XCTAssertFalse(
            String(reflecting: first).contains(first.irohSecretKeyBytes().base64EncodedString())
        )

        let payload = Data("pairing-proof".utf8)
        let signature = try first.signature(for: payload)
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: first.signingPublicKeyBytes()
        )
        XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
    }

    func testRepositoryRejectsCorruptOrOversizedStorage() throws {
        let corrupt = MeshDeviceIdentityRepository(
            storage: MeshMemoryIdentityStorage(data: Data("{}".utf8))
        )
        XCTAssertThrowsError(try corrupt.load()) {
            XCTAssertEqual($0 as? MeshDeviceIdentityError, .corruptStorage)
        }

        let oversized = MeshDeviceIdentityRepository(
            storage: MeshMemoryIdentityStorage(data: Data(repeating: 0, count: 4_097))
        )
        XCTAssertThrowsError(try oversized.load()) {
            XCTAssertEqual($0 as? MeshDeviceIdentityError, .oversizedStorage)
        }
    }

    func testMode0600FileStorePersistsStableIdentityInPrivateDirectory() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("private/device-identity.json")
        let repository = MeshDeviceIdentityRepository(
            storage: MeshFileIdentityStorage(fileURL: file)
        )

        let first = try repository.loadOrCreate(now: Date(timeIntervalSince1970: 100))
        let restored = try repository.loadOrCreate(now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(restored, first)

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: file.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    func testFileStoreRejectsPermissiveParentAndSymlinkIdentity() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }

        let permissive = fixture.root.appendingPathComponent("permissive", isDirectory: true)
        try FileManager.default.createDirectory(at: permissive, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: permissive.path
        )
        let permissiveStore = MeshFileIdentityStorage(
            fileURL: permissive.appendingPathComponent("identity.json")
        )
        XCTAssertThrowsError(try permissiveStore.insertIfAbsent(Data("x".utf8))) {
            XCTAssertEqual(
                $0 as? MeshFileIdentityStorageError,
                .insecureDirectoryPermissions(0o755)
            )
        }
        let permissiveFile = permissive.appendingPathComponent("identity.json")
        try Data("secret".utf8).write(to: permissiveFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: permissiveFile.path
        )
        XCTAssertThrowsError(try permissiveStore.load()) {
            XCTAssertEqual(
                $0 as? MeshFileIdentityStorageError,
                .insecureDirectoryPermissions(0o755)
            )
        }

        let privateDirectory = fixture.root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let target = privateDirectory.appendingPathComponent("target")
        try Data("secret".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: target.path
        )
        let link = privateDirectory.appendingPathComponent("identity.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try MeshFileIdentityStorage(fileURL: link).load()) {
            XCTAssertEqual($0 as? MeshFileIdentityStorageError, .notRegularFile)
        }
    }

    func testConcurrentFileCreationSelectsOneStableIdentity() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("private/device-identity.json")
        let repository = MeshDeviceIdentityRepository(
            storage: MeshFileIdentityStorage(fileURL: file)
        )

        let identities = try await withThrowingTaskGroup(
            of: MeshDeviceIdentity.self, returning: [MeshDeviceIdentity].self
        ) { group in
            for _ in 0..<16 {
                group.addTask { try repository.loadOrCreate() }
            }
            var values: [MeshDeviceIdentity] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(identities.map(\.deviceID)).count, 1)
        XCTAssertEqual(Set(identities.map { $0.irohSecretKeyBytes() }).count, 1)
    }

#if os(macOS)
    func testExplicitHeadlessMirrorNeverFallsThroughToKeychain() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let mirrorURL = directory.appendingPathComponent("headless.json")
        let storage = MeshMirroredIdentityStorage(
            keychain: MeshKeychainIdentityStorage(
                service: "me.pai.pharos.tests.\(UUID().uuidString)",
                account: "must-not-be-read"
            ),
            mirrorURL: mirrorURL, headlessOnly: true
        )

        XCTAssertThrowsError(try storage.load()) {
            XCTAssertEqual(
                $0 as? MeshMirroredIdentityStorageError,
                .headlessBootstrapRequired
            )
        }

        let expected = Data("protected-mirror".utf8)
        XCTAssertTrue(try MeshFileIdentityStorage(
            fileURL: mirrorURL
        ).insertIfAbsent(expected))
        XCTAssertEqual(try storage.load(), expected)
    }
#endif

    private final class FileFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pharos-identity-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
