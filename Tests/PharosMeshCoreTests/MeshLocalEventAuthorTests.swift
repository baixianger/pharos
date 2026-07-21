import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity

final class MeshLocalEventAuthorTests: XCTestCase {
    func testAuthorContinuesChainAcrossRestartAndClockRegression() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let storage = MeshMemoryIdentityStorage()
        let firstReplica = try MeshLocalReplica.open(
            rootURL: fixture.root, identityStorage: storage
        )
        try await firstReplica.store.setMembershipEpoch(1, for: fixture.group)
        let entity = MeshEntityReference(type: .project, id: "project-1")!
        let firstAuthor = MeshLocalEventAuthor(
            replica: firstReplica, trustGroupID: fixture.group,
            nowMilliseconds: { 2_000 }
        )
        let first = try await firstAuthor.setField(
            "name", value: Data("Pharos".utf8), on: entity
        )

        let reopened = try MeshLocalReplica.open(
            rootURL: fixture.root, identityStorage: storage
        )
        let restartedAuthor = MeshLocalEventAuthor(
            replica: reopened, trustGroupID: fixture.group,
            nowMilliseconds: { 1_000 }
        )
        let second = try await restartedAuthor.setField(
            "notes", value: Data("Local first".utf8), on: entity
        )

        XCTAssertEqual(first.authorSequence, 1)
        XCTAssertEqual(second.authorSequence, 2)
        XCTAssertEqual(second.previousEventHash, try DistributedMeshCrypto.digest(first))
        XCTAssertGreaterThan(second.hybridTimestamp, first.hybridTimestamp)
        let fields = try await reopened.store.materializedFields(
            for: entity, in: fixture.group
        )
        XCTAssertEqual(fields.map(\.field), ["name", "notes"])
    }

    func testTwoProcessesSharingIdentityRetryTheCommittedHead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let storage = MeshMemoryIdentityStorage()
        let firstReplica = try MeshLocalReplica.open(
            rootURL: fixture.root, identityStorage: storage
        )
        let secondReplica = try MeshLocalReplica.open(
            rootURL: fixture.root, identityStorage: storage
        )
        try await firstReplica.store.setMembershipEpoch(1, for: fixture.group)
        let firstAuthor = MeshLocalEventAuthor(
            replica: firstReplica, trustGroupID: fixture.group,
            nowMilliseconds: { 3_000 }
        )
        let secondAuthor = MeshLocalEventAuthor(
            replica: secondReplica, trustGroupID: fixture.group,
            nowMilliseconds: { 3_000 }
        )
        let entity = MeshEntityReference(type: .issue, id: "issue-1")!

        async let title = firstAuthor.setField(
            "title", value: Data("One".utf8), on: entity
        )
        async let status = secondAuthor.setField(
            "status", value: Data("todo".utf8), on: entity
        )
        let events = try await [title, status]

        XCTAssertEqual(Set(events.map(\.authorSequence)), Set([1, 2]))
        let fields = try await firstReplica.store.materializedFields(
            for: entity, in: fixture.group
        )
        XCTAssertEqual(Set(fields.map(\.field)), Set(["status", "title"]))
    }

    func testConcurrentFirstLaunchChoosesOnePersistentTrustGroup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let storage = MeshMemoryIdentityStorage()
        let first = try MeshLocalReplica.open(
            rootURL: fixture.root, identityStorage: storage
        )
        let second = try MeshLocalReplica.open(
            rootURL: fixture.root, identityStorage: storage
        )

        async let firstGroup = first.ensureActiveTrustGroup()
        async let secondGroup = second.ensureActiveTrustGroup()
        let groups = try await [firstGroup, secondGroup]
        let epoch = try await first.store.membershipEpoch(for: groups[0])
        let storedGroups = try await first.store.trustGroupIDs()

        XCTAssertEqual(groups[0], groups[1])
        XCTAssertEqual(try first.activeTrustGroup(), groups[0])
        XCTAssertEqual(epoch, 1)
        XCTAssertEqual(storedGroups, [groups[0]])
    }

    func testPairingGroupAdoptionCannotOverwriteExistingGroup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try MeshLocalReplica.open(
            rootURL: fixture.root,
            identityStorage: MeshMemoryIdentityStorage()
        )
        try replica.adoptActiveTrustGroup(fixture.group)
        XCTAssertEqual(try replica.activeTrustGroup(), fixture.group)

        XCTAssertThrowsError(
            try replica.adoptActiveTrustGroup(MeshTrustGroupID())
        ) {
            XCTAssertEqual(
                $0 as? MeshLocalReplicaError, .corruptActiveTrustGroup
            )
        }
    }

    func testExplicitPairingCanReplaceExistingGroupWithoutDeletingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let storage = MeshMemoryIdentityStorage()
        let replica = try MeshLocalReplica.open(
            rootURL: fixture.root, identityStorage: storage
        )
        try replica.adoptActiveTrustGroup(fixture.group)
        try await replica.store.setMembershipEpoch(4, for: fixture.group)
        let replacement = MeshTrustGroupID()

        try replica.adoptActiveTrustGroup(
            replacement, replacingExisting: true
        )

        XCTAssertEqual(try replica.activeTrustGroup(), replacement)
        let originalEpoch = try await replica.store.membershipEpoch(
            for: fixture.group
        )
        XCTAssertEqual(originalEpoch, 4)
        let reopened = try MeshLocalReplica.open(
            rootURL: fixture.root, identityStorage: storage
        )
        XCTAssertEqual(try reopened.activeTrustGroup(), replacement)
    }

    private final class Fixture {
        let root: URL
        let group = MeshTrustGroupID()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pharos-local-author-\(UUID().uuidString)", isDirectory: true
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
