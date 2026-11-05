import Foundation
import XCTest
@testable import PharosMeshCore

final class DistributedMeshRuntimeLockTests: XCTestCase {
    func testShutdownLatchIsMonotonicAcrossThreads() async {
        let latch = DistributedMeshShutdownLatch()
        XCTAssertFalse(latch.isRequested())

        await Task.detached {
            latch.request()
        }.value

        XCTAssertTrue(latch.isRequested())
        latch.request()
        XCTAssertTrue(latch.isRequested())
    }

    func testSecondRuntimeCannotAcquireSameEndpointOwnership() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try DistributedMeshRuntimeLock.acquire(
            dataDirectory: directory, owner: "test-app", buildID: "one"
        )
        defer { first.release() }

        XCTAssertThrowsError(try DistributedMeshRuntimeLock.acquire(
            dataDirectory: directory, owner: "test-service", buildID: "two"
        )) { error in
            guard case DistributedMeshRuntimeLockError.alreadyOwned(let owner) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(owner, "test-app (pid \(getpid())), build one")
        }
    }

    func testReleasedRuntimeCanBeReacquiredWithoutRemovingLockFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try DistributedMeshRuntimeLock.acquire(
            dataDirectory: directory, owner: "test-app"
        )
        let fileURL = first.fileURL
        first.release()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(
            DistributedMeshRuntimeLock.currentMetadata(
                dataDirectory: directory
            )
        )
        let second = try DistributedMeshRuntimeLock.acquire(
            dataDirectory: directory, owner: "test-service"
        )
        defer { second.release() }
        XCTAssertEqual(
            DistributedMeshRuntimeLock.currentMetadata(dataDirectory: directory),
            second.metadata
        )
    }

    func testLockMetadataFileIsPrivate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try DistributedMeshRuntimeLock.acquire(
            dataDirectory: directory, owner: "test-service"
        )
        defer { runtime.release() }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: runtime.fileURL.path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pharos-runtime-lock-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
