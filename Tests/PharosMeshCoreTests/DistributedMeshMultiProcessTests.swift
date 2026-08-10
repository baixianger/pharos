import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity
import PharosMeshReplica

final class DistributedMeshMultiProcessTests: XCTestCase {
    func testTwoReplicaConnectionsConcurrentlyAuthorWithoutChainLoss()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pharos-multiprocess-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let identityStorage = MeshMemoryIdentityStorage()
        let appReplica = try MeshLocalReplica.open(
            rootURL: root, identityStorage: identityStorage
        )
        let serviceReplica = try MeshLocalReplica.open(
            rootURL: root, identityStorage: identityStorage
        )
        let group = try await appReplica.ensureActiveTrustGroup()
        let registry = DistributedChatRegistry(
            replica: appReplica, group: group
        )
        _ = try await registry.createRoom(named: "concurrent")
        let app = DistributedAgentChat(
            replica: appReplica, group: group
        )
        try await app.ensureLocalPresenceAuthority(
            memberID: "shared-session"
        )
        _ = try await app.join(
            room: "concurrent",
            nick: "writer",
            memberID: "shared-session"
        )
        let service = DistributedAgentChat(
            replica: serviceReplica, group: group
        )

        async let appWrite = app.say(
            room: "concurrent",
            memberID: "shared-session",
            text: "from-app"
        )
        async let serviceWrite = service.say(
            room: "concurrent",
            memberID: "shared-session",
            text: "from-service"
        )
        _ = try await (appWrite, serviceWrite)

        let history = try await app.history(room: "concurrent")
        XCTAssertEqual(
            Set(history.map(\.text)),
            ["from-app", "from-service"]
        )
        XCTAssertEqual(Set(history.map(\.stableID)).count, 2)
        let heads = try await appReplica.store.authorHeads(for: group)
        XCTAssertEqual(heads.count, 1)
        XCTAssertGreaterThanOrEqual(heads[0].sequence, 4)
    }
}
