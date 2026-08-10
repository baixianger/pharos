import Foundation
import XCTest
import PharosMeshCore

final class MeshNodeRuntimeLockTests: XCTestCase {
    func testSecondOwnerIsRejectedWithCurrentOwnerMetadata() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try MeshNodeRuntimeLock.acquire(
            runtimeDirectory: directory,
            owner: "node-a",
            buildID: "build-1"
        )
        defer { first.release() }

        XCTAssertThrowsError(
            try MeshNodeRuntimeLock.acquire(
                runtimeDirectory: directory,
                owner: "node-b"
            )
        ) { error in
            guard case MeshNodeRuntimeLockError.alreadyOwned(let owner) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(owner?.contains("node-a") == true)
            XCTAssertTrue(owner?.contains("build-1") == true)
        }
    }

    func testReleasedLockCanBeAcquiredAgain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try MeshNodeRuntimeLock.acquire(
            runtimeDirectory: directory,
            owner: "node-a"
        )
        XCTAssertEqual(
            MeshNodeRuntimeLock.currentMetadata(runtimeDirectory: directory)?.owner,
            "node-a"
        )
        first.release()
        XCTAssertNil(MeshNodeRuntimeLock.currentMetadata(runtimeDirectory: directory))

        let second = try MeshNodeRuntimeLock.acquire(
            runtimeDirectory: directory,
            owner: "node-b"
        )
        XCTAssertEqual(second.metadata.owner, "node-b")
        second.release()
    }

    func testRuntimeDirectoryAndLockPermissionsArePrivate() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeLock = try MeshNodeRuntimeLock.acquire(
            runtimeDirectory: directory,
            owner: "node-a"
        )
        defer { runtimeLock.release() }

        let directoryMode = try permissions(at: directory)
        let lockMode = try permissions(at: runtimeLock.fileURL)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(lockMode & 0o777, 0o600)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "pharos-node-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}

final class MeshNodeShutdownLatchTests: XCTestCase {
    func testRequestIsVisibleAcrossConcurrentReaders() async {
        let latch = MeshNodeShutdownLatch()
        XCTAssertFalse(latch.isRequested())

        await Task.detached { latch.request() }.value

        XCTAssertTrue(latch.isRequested())
    }
}
