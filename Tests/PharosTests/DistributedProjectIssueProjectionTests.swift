import Foundation
import XCTest
@testable import Pharos
import PharosMeshCore
import PharosMeshIdentity

final class DistributedProjectIssueProjectionTests: XCTestCase {
    func testProjectAndIssueFieldsRoundTripWithoutHostLocalRuntimeState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let attachmentReference = MeshAttachment(
            id: "distributed-attachment", name: "proof.txt",
            mimeType: "text/plain", byteSize: 5,
            sha256: String(repeating: "ab", count: 32)
        )
        let issue = Issue(
            number: 7, title: "Move registry", status: .inProgress,
            priority: .high, body: "Use signed fields",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            activeSession: "pharos-secret-session",
            activeSessionHost: "private-host", worktreePath: "/private/worktree",
            attachments: [IssueAttachment(
                storedName: "proof.txt", originalName: "proof.txt",
                isImage: false, byteSize: 5,
                meshAttachment: attachmentReference
            )], labels: ["mesh"], sortOrder: 2.5
        )
        let project = Project(
            name: "Distributed Pharos", localPath: "/private/checkout",
            githubRemote: "https://example.invalid/pharos.git",
            tags: ["Core"], yolo: false, tmux: true,
            addedAt: Date(timeIntervalSince1970: 1),
            notes: "Portable settings", issues: [issue]
        )

        try await fixture.projection.publish(projects: [project])
        let restored = try await fixture.projection.materializedProjects()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].name, project.name)
        XCTAssertEqual(restored[0].githubRemote, project.githubRemote)
        XCTAssertEqual(restored[0].tags, project.tags)
        XCTAssertEqual(restored[0].yolo, project.yolo)
        XCTAssertEqual(restored[0].tmux, project.tmux)
        XCTAssertNil(restored[0].localPath)
        XCTAssertEqual(restored[0].issues.count, 1)
        XCTAssertEqual(restored[0].issues[0].title, issue.title)
        XCTAssertEqual(restored[0].issues[0].status, issue.status)
        XCTAssertEqual(
            restored[0].issues[0].attachments.first?.meshAttachment,
            attachmentReference
        )
        XCTAssertNil(restored[0].issues[0].activeSession)
        XCTAssertNil(restored[0].issues[0].activeSessionHost)
        XCTAssertNil(restored[0].issues[0].worktreePath)
    }

    func testIndependentOfflineFieldEditsConvergeWithoutWholeRegistryConflict() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var project = Project(
            name: "Before", addedAt: Date(timeIntervalSince1970: 1),
            notes: "Before notes",
            issues: [Issue(number: 1, title: "Before issue")]
        )
        try await fixture.projection.publish(projects: [project])

        project.name = "Renamed"
        project.issues[0].title = "Edited issue"
        try await fixture.projection.publish(projects: [project])
        let restored = try await fixture.projection.materializedProjects()

        XCTAssertEqual(restored[0].name, "Renamed")
        XCTAssertEqual(restored[0].notes, "Before notes")
        XCTAssertEqual(restored[0].issues[0].title, "Edited issue")
    }

    func testTwoOfflineReplicasMergeDifferentProjectAndIssueFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pharos-project-two-replicas-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let group = MeshTrustGroupID()
        let replicaA = try MeshLocalReplica.openIsolated(
            rootURL: root.appendingPathComponent("a")
        )
        let replicaB = try MeshLocalReplica.openIsolated(
            rootURL: root.appendingPathComponent("b")
        )
        try await replicaA.store.setMembershipEpoch(1, for: group)
        try await replicaB.store.setMembershipEpoch(1, for: group)
        let projectionA = DistributedProjectIssueProjection(
            replica: replicaA, group: group, nowMilliseconds: { 1_000 }
        )
        let projectionB = DistributedProjectIssueProjection(
            replica: replicaB, group: group, nowMilliseconds: { 1_000 }
        )
        let initial = Project(
            name: "Before", addedAt: Date(timeIntervalSince1970: 1),
            notes: "Keep me",
            issues: [Issue(number: 1, title: "Before issue")]
        )
        try await projectionA.publish(projects: [initial])
        try await copyEvents(from: replicaA, to: replicaB, in: group)

        let projectsA = try await projectionA.materializedProjects()
        var editA = try XCTUnwrap(projectsA.first)
        editA.name = "Renamed on A"
        try await projectionA.publish(projects: [editA])

        let projectsB = try await projectionB.materializedProjects()
        var editB = try XCTUnwrap(projectsB.first)
        editB.issues[0].title = "Issue edited on B"
        try await projectionB.publish(projects: [editB])

        try await copyEvents(from: replicaA, to: replicaB, in: group)
        try await copyEvents(from: replicaB, to: replicaA, in: group)
        let resultA = try await projectionA.materializedProjects()
        let resultB = try await projectionB.materializedProjects()

        XCTAssertEqual(resultA, resultB)
        XCTAssertEqual(resultA[0].name, "Renamed on A")
        XCTAssertEqual(resultA[0].notes, "Keep me")
        XCTAssertEqual(resultA[0].issues[0].title, "Issue edited on B")
    }

    func testDeletionAndRestoreUseExplicitReplicatedMarker() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let project = Project(
            name: "Recoverable", addedAt: Date(timeIntervalSince1970: 1)
        )
        try await fixture.projection.publish(projects: [project])
        try await fixture.projection.publish(projects: [])
        let deleted = try await fixture.projection.materializedProjects()
        XCTAssertTrue(deleted.isEmpty)

        try await fixture.projection.publish(projects: [project])
        let restored = try await fixture.projection.materializedProjects()
        XCTAssertEqual(restored.map(\.name), ["Recoverable"])
    }

    @MainActor
    func testProjectStoreDistributedModeWritesReplicaWithoutTouchingLegacyRegistry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pharos-project-store-product-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("projects.json")
        let legacyBytes = Data("legacy-must-remain-untouched".utf8)
        try legacyBytes.write(to: legacyURL)
        setenv("PHAROS_DISTRIBUTED", "1", 1)
        setenv("PHAROS_REGISTRY", legacyURL.path, 1)
        setenv("PHAROS_DISABLE_NOTIFICATIONS", "1", 1)
        setenv("PHAROS_DISABLE_BACKGROUND_TASKS", "1", 1)
        defer {
            unsetenv("PHAROS_DISTRIBUTED")
            unsetenv("PHAROS_REGISTRY")
            unsetenv("PHAROS_DISABLE_NOTIFICATIONS")
            unsetenv("PHAROS_DISABLE_BACKGROUND_TASKS")
        }

        let replica = try MeshLocalReplica.openIsolated(
            rootURL: root.appendingPathComponent("replica")
        )
        let group = try await replica.ensureActiveTrustGroup()
        let store = ProjectStore()
        await store.activateDistributedRegistry(replica: replica, group: group)
        let project = Project(
            name: "Product path", localPath: "/host-only/checkout",
            addedAt: Date(timeIntervalSince1970: 1)
        )
        store.add(project)
        store.addIssue(project.id, title: "Replicated issue")

        for _ in 0..<100 where store.registrySyncStatus != .synced {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.registrySyncStatus, .synced)
        let projection = DistributedProjectIssueProjection(
            replica: replica, group: group
        )
        let materialized = try await projection.materializedProjects()

        XCTAssertEqual(materialized.map(\.name), ["Product path"])
        XCTAssertEqual(materialized[0].issues.map(\.title), ["Replicated issue"])
        XCTAssertNil(materialized[0].localPath)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyBytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "distributed-project-cache.json"
            ).path
        ))
    }

    private final class Fixture {
        let root: URL
        let group = MeshTrustGroupID()
        let projection: DistributedProjectIssueProjection

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pharos-project-projection-\(UUID().uuidString)", isDirectory: true
            )
            let replica = try MeshLocalReplica.open(
                rootURL: root, identityStorage: MeshMemoryIdentityStorage()
            )
            try await replica.store.setMembershipEpoch(1, for: group)
            projection = DistributedProjectIssueProjection(
                replica: replica, group: group, nowMilliseconds: { 1_000 }
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func copyEvents(
        from source: MeshLocalReplica, to destination: MeshLocalReplica,
        in group: MeshTrustGroupID
    ) async throws {
        let endpoint = try source.identity.endpointID()
        let destinationVector = try await destination.store.syncVector(for: group)
        let events = try await source.store.events(
            for: group, author: endpoint,
            after: destinationVector.sequence(for: endpoint), limit: 1_024
        )
        let publicKey = try source.identity.signingPublicKeyBytes()
        for event in events {
            _ = try await destination.store.insert(
                event, authorPublicKey: publicKey
            )
        }
    }
}
