import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity

final class DistributedChatRegistryTests: XCTestCase {
    func testRoomLifecycleKeepsImmutableHistoryAcrossRename() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "local")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let chat = DistributedChatRegistry(
            replica: replica, group: fixture.group,
            nowMilliseconds: fixture.clock(startingAt: 1_000)
        )

        let created = try await chat.createRoom(named: "pharos-dev")
        try await chat.join(room: created, nick: "builder", memberID: "session-1")
        let first = try await chat.send(
            room: created, from: "human", text: "ship it",
            to: ["builder"], sentAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertNotNil(created.replicaID)
        XCTAssertNotNil(first.id)
        let joinedRooms = try await chat.rooms()
        XCTAssertEqual(joinedRooms.first?.members, ["builder", "human"])

        try await chat.renameMember(
            room: created, memberID: "session-1", to: "reviewer"
        )
        try await chat.renameRoom(created, to: "release-room")
        let renamedRooms = try await chat.rooms()
        let renamed = try XCTUnwrap(renamedRooms.first)
        let history = try await chat.messages(in: renamed)

        XCTAssertEqual(renamed.name, "release-room")
        XCTAssertEqual(renamed.replicaID, created.replicaID)
        XCTAssertEqual(renamed.members, ["human", "reviewer"])
        XCTAssertEqual(history.map(\.text), ["ship it"])
        XCTAssertEqual(history.first?.room, "release-room")

        try await chat.leave(room: renamed, memberID: "session-1")
        let leftRooms = try await chat.rooms()
        XCTAssertEqual(leftRooms.first?.members, ["human"])
        try await chat.deleteRoom(renamed)
        let deletedRooms = try await chat.rooms()
        XCTAssertTrue(deletedRooms.isEmpty)
    }

    func testTwoOfflineWritersConvergeRoomRenameAndAppendOnlyMessages() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.replica(named: "first")
        let second = try fixture.replica(named: "second")
        try await pair(first, second, group: fixture.group)
        let firstChat = DistributedChatRegistry(
            replica: first, group: fixture.group,
            nowMilliseconds: fixture.clock(startingAt: 1_000)
        )
        let secondChat = DistributedChatRegistry(
            replica: second, group: fixture.group,
            nowMilliseconds: fixture.clock(startingAt: 2_000)
        )

        let created = try await firstChat.createRoom(named: "draft")
        _ = try await firstChat.send(
            room: created, from: "human", text: "from first",
            sentAt: Date(timeIntervalSince1970: 11)
        )
        try await copyEvents(from: first, to: second, group: fixture.group)

        let initialSecondRooms = try await secondChat.rooms()
        let secondRoom = try XCTUnwrap(initialSecondRooms.first)
        try await secondChat.renameRoom(secondRoom, to: "converged")
        _ = try await secondChat.send(
            room: secondRoom, from: "agent-b", text: "from second",
            sentAt: Date(timeIntervalSince1970: 13)
        )
        _ = try await firstChat.send(
            room: created, from: "agent-a", text: "first offline",
            sentAt: Date(timeIntervalSince1970: 12)
        )

        try await copyEvents(from: first, to: second, group: fixture.group)
        try await copyEvents(from: second, to: first, group: fixture.group)
        try await copyEvents(from: first, to: second, group: fixture.group)

        let finalFirstRooms = try await firstChat.rooms()
        let finalSecondRooms = try await secondChat.rooms()
        let firstRoom = try XCTUnwrap(finalFirstRooms.first)
        let finalSecondRoom = try XCTUnwrap(finalSecondRooms.first)
        XCTAssertEqual(firstRoom.name, "converged")
        XCTAssertEqual(firstRoom, finalSecondRoom)
        let firstMessages = try await firstChat.messages(in: firstRoom)
        let secondMessages = try await secondChat.messages(in: finalSecondRoom)
        XCTAssertEqual(firstMessages.map(\.text), [
            "from first", "first offline", "from second",
        ])
        XCTAssertEqual(secondMessages, firstMessages)
    }

    private func pair(
        _ first: MeshLocalReplica, _ second: MeshLocalReplica,
        group: MeshTrustGroupID
    ) async throws {
        try await first.store.setMembershipEpoch(1, for: group)
        try await second.store.setMembershipEpoch(1, for: group)
        let invitation = try await MeshTrustPairingService(
            identity: first.identity, invitationStore: first.store
        ).issueInvitation(
            trustGroupID: group, membershipEpoch: 1,
            inviterAddressTicket: "first-ticket",
            requestedRoles: [.controller, .replica]
        )
        let acceptance = try await MeshTrustPairingService(
            identity: second.identity, invitationStore: second.store
        ).acceptAndTrustInviter(
            invitation, acceptingAddressTicket: "second-ticket",
            displayName: "Second", inviterDisplayName: "First"
        )
        _ = try await MeshTrustPairingService(
            identity: first.identity, invitationStore: first.store
        ).redeem(acceptance, for: invitation)
    }

    private func copyEvents(
        from source: MeshLocalReplica, to destination: MeshLocalReplica,
        group: MeshTrustGroupID
    ) async throws {
        for head in try await source.store.authorHeads(for: group) {
            let events = try await source.store.events(
                for: group, author: head.endpointID,
                after: 0, limit: Int(head.sequence)
            )
            let key = try XCTUnwrap(Self.publicKey(from: head.endpointID))
            for event in events {
                _ = try await destination.store.insert(
                    event, authorPublicKey: key
                )
            }
        }
    }

    private static func publicKey(from endpoint: MeshEndpointID) -> Data? {
        let text = endpoint.rawValue
        guard text.utf8.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = text.startIndex
        for _ in 0..<32 {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private final class Fixture {
        let root: URL
        let group = MeshTrustGroupID()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pharos-chat-registry-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
        }

        func replica(named name: String) throws -> MeshLocalReplica {
            try MeshLocalReplica.open(
                rootURL: root.appendingPathComponent(name, isDirectory: true),
                identityStorage: MeshMemoryIdentityStorage()
            )
        }

        func clock(startingAt initial: Int64) -> @Sendable () -> Int64 {
            let clock = TestClock(value: initial)
            return { clock.next() }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(value: Int64) { self.value = value }

    func next() -> Int64 {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
