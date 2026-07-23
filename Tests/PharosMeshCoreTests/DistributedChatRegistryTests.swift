import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity
import PharosMeshProtocol
import PharosMeshReplica

final class DistributedChatRegistryTests: XCTestCase {
    func testHostSnapshotKeepsLastStructuredStateForBoundLiveSeat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "presence-last-known")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "pharos-dev")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await agent.join(
            room: "pharos-dev", nick: "builder", memberID: "session-live"
        )
        let observation: [String: Any] = [
            "version": 1,
            "sessions": [
                "session-live": [
                    "state": "busy", "updatedAt": 1.0,
                    "cwd": "/workspace", "kind": "codex",
                    "tmuxPane": "%1", "tmuxSocket": "/tmp/tmux-live",
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: observation, options: [.sortedKeys]
        ).write(
            to: replica.rootURL.appendingPathComponent(
                "agent-host-observations-v1.json"
            ),
            options: .atomic
        )

        let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
            replica: replica, group: fixture.group,
            nowMilliseconds: 1_000_000,
            seatInspector: PermissiveTmuxSeatInspector()
        )

        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records.first?.resourceID.rawValue, "session-live")
        XCTAssertEqual(snapshot.records.first?.state, .busy)
        XCTAssertEqual(snapshot.records.first?.observedAtMilliseconds, 1_000)
    }

    func testHostSnapshotPublishesEverySimultaneouslyBusyAgent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "presence-two-busy-agents")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "pharos-dev")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        for memberID in ["busy-session-a", "busy-session-b"] {
            _ = try await agent.join(
                room: "pharos-dev", nick: memberID, memberID: memberID
            )
        }
        let observation: [String: Any] = [
            "version": 1,
            "sessions": [
                "busy-session-a": [
                    "state": "busy", "updatedAt": 10.0,
                    "cwd": "/workspace/a", "kind": "codex",
                    "tmuxPane": "%1", "tmuxSocket": "/tmp/tmux-a",
                ],
                "busy-session-b": [
                    "state": "busy", "updatedAt": 11.0,
                    "cwd": "/workspace/b", "kind": "claude",
                    "tmuxPane": "%2", "tmuxSocket": "/tmp/tmux-b",
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: observation, options: [.sortedKeys]
        ).write(
            to: replica.rootURL.appendingPathComponent(
                "agent-host-observations-v1.json"
            ),
            options: .atomic
        )

        let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
            replica: replica, group: fixture.group,
            nowMilliseconds: 20_000,
            seatInspector: PermissiveTmuxSeatInspector()
        )

        XCTAssertEqual(
            snapshot.records.map(\.resourceID.rawValue),
            ["busy-session-a", "busy-session-b"]
        )
        XCTAssertEqual(snapshot.records.map(\.state), [.busy, .busy])
        XCTAssertEqual(snapshot.records.map(\.kind), ["codex", "claude"])
    }

    func testHostSnapshotExpiresStaleUnboundHookGhost() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "presence-unbound-expiry")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "pharos-dev")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await agent.join(
            room: "pharos-dev", nick: "builder", memberID: "session-ghost"
        )
        let observation: [String: Any] = [
            "version": 1,
            "sessions": [
                "session-ghost": [
                    "state": "busy", "updatedAt": 1.0,
                    "cwd": "/workspace", "kind": "codex",
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: observation, options: [.sortedKeys]
        ).write(
            to: replica.rootURL.appendingPathComponent(
                "agent-host-observations-v1.json"
            ), options: .atomic
        )

        let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
            replica: replica, group: fixture.group,
            nowMilliseconds: 1_000 + Int64(
                (DistributedHookCLI.unboundPresenceLeaseSeconds + 1) * 1_000
            )
        )

        XCTAssertTrue(snapshot.records.isEmpty)
        let resource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: try XCTUnwrap(MeshResourceID(rawValue: "session-ghost"))
        )
        XCTAssertEqual(resource?.state, .active)
    }

    func testHostSnapshotDoesNotPublishADeadBoundTmuxSeat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "presence-dead-bound-seat")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "pharos-dev")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        let memberID = "dead-bound-seat"
        _ = try await agent.join(
            room: "pharos-dev", nick: "dead", memberID: memberID
        )
        let observation: [String: Any] = [
            "version": 1,
            "sessions": [
                memberID: [
                    "state": "busy", "updatedAt": 1.0,
                    "tmuxPane": "%8", "tmuxSocket": "/tmp/tmux-dead",
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: observation, options: [.sortedKeys]
        ).write(
            to: replica.rootURL.appendingPathComponent(
                "agent-host-observations-v1.json"
            ),
            options: .atomic
        )

        let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
            replica: replica, group: fixture.group,
            nowMilliseconds: 10_000,
            seatInspector: FixedTmuxSeatInspector(seat: nil)
        )

        XCTAssertTrue(snapshot.records.isEmpty)
        let resource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: try XCTUnwrap(MeshResourceID(rawValue: memberID))
        )
        XCTAssertEqual(resource?.allowedActions, [.presence])
    }

    func testHostSnapshotRetiresOldOrphanResourceWithoutObservation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "presence-orphan-resource")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let resourceID = try XCTUnwrap(
            MeshResourceID(rawValue: "orphan-without-observation")
        )
        let freshResourceID = try XCTUnwrap(
            MeshResourceID(rawValue: "spawn-still-in-flight")
        )
        _ = try await replica.store.registerHostResource(
            in: fixture.group, on: replica.identity,
            resourceID: resourceID,
            allowedActions: [.presence, .poke, .stop],
            at: MeshHybridTimestamp(wallTimeMilliseconds: 1_000)
        )
        let snapshotTime = 1_000
            + DistributedHookCLI.orphanResourceGraceMilliseconds
        _ = try await replica.store.registerHostResource(
            in: fixture.group, on: replica.identity,
            resourceID: freshResourceID,
            allowedActions: [.presence],
            at: MeshHybridTimestamp(
                wallTimeMilliseconds: snapshotTime
                    - DistributedHookCLI.orphanResourceGraceMilliseconds + 1
            )
        )
        let bindings = DistributedHostResourceBindings(
            dataDirectory: replica.rootURL
        )
        try bindings.save(
            try DistributedHostResourceBinding(
                resourceID: resourceID, tmuxSession: "retired-test-ghost",
                tmuxSocket: "/tmp/pharos-test-tmux"
            ),
            for: resourceID
        )

        let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
            replica: replica, group: fixture.group,
            nowMilliseconds: snapshotTime
        )

        XCTAssertTrue(snapshot.records.isEmpty)
        let resource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        )
        XCTAssertEqual(resource?.state, .retired)
        let freshResource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: freshResourceID
        )
        XCTAssertEqual(
            freshResource?.state, .active,
            "the grace window must protect a join that is still publishing membership"
        )
        XCTAssertThrowsError(try bindings.load(resourceID))
    }

    func testHostSnapshotDowngradesUnverifiedLegacyControlResourceToPresence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "presence-capability-upgrade")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "pharos-dev")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        let memberID = "legacy-control-session"
        _ = try await agent.join(
            room: "pharos-dev", nick: "builder", memberID: memberID
        )
        let resourceID = try XCTUnwrap(MeshResourceID(rawValue: memberID))
        let initialResource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        )
        let initial = try XCTUnwrap(initialResource)
        _ = try await replica.store.replaceHostResource(
            in: fixture.group, on: replica.identity, resourceID: resourceID,
            allowedActions: [.poke, .stop],
            at: initial.updatedAt
        )
        let snapshotNow = initial.updatedAt.wallTimeMilliseconds + 1
        let observation: [String: Any] = [
            "version": 1,
            "sessions": [
                memberID: [
                    "state": "idle",
                    "updatedAt": Double(snapshotNow) / 1_000,
                    "cwd": "/workspace", "kind": "codex",
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: observation, options: [.sortedKeys]
        ).write(
            to: replica.rootURL.appendingPathComponent(
                "agent-host-observations-v1.json"
            ),
            options: .atomic
        )

        let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
            replica: replica, group: fixture.group,
            nowMilliseconds: snapshotNow
        )
        let upgraded = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        )

        XCTAssertEqual(snapshot.records.map(\.resourceID), [resourceID])
        XCTAssertEqual(upgraded?.allowedActions, [.presence])
        XCTAssertEqual(upgraded?.generation, 3)
    }

    func testLegacyPresenceOnlyAgentClaimsExactLiveTmuxSeat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "legacy-seat-claim")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "pharos-dev")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        let memberID = "legacy-presence-only"
        _ = try await agent.join(
            room: "pharos-dev", nick: "legacy", memberID: memberID
        )
        let presence = DistributedHookCLI.LocalAgentPresence(
            state: "idle", updatedAt: 10, cwd: "/workspace",
            tmuxPane: "%7", tmuxSocket: "/tmp/tmux-legacy",
            kind: "codex"
        )
        let seat = DistributedTmuxSeat(
            sessionName: "pharos-legacy-codex",
            socket: "/tmp/tmux-legacy", paneID: "%7",
            sessionID: "$3", sessionCreatedAt: 123, panePID: 456
        )
        let reconciler = DistributedAgentResourceReconciler(
            dataDirectory: replica.rootURL,
            seatInspector: FixedTmuxSeatInspector(seat: seat)
        )

        let result = try await reconciler.reconcile(
            memberID: memberID, presence: presence,
            seatIsConflicted: false, replica: replica, group: fixture.group,
            now: MeshHybridTimestamp(wallTimeMilliseconds: 10_000)
        )

        XCTAssertEqual(result.readiness, .managed)
        XCTAssertEqual(
            Set(result.resource.allowedActions),
            Set([MeshHostAction.presence, .poke, .stop])
        )
        let resourceID = try XCTUnwrap(MeshResourceID(rawValue: memberID))
        let binding = try DistributedHostResourceBindings(
            dataDirectory: replica.rootURL
        ).load(resourceID)
        XCTAssertTrue(binding.hasVerifiedRuntimeSeat)
        XCTAssertEqual(binding.tmuxPane, "%7")
        XCTAssertEqual(binding.tmuxSessionID, "$3")
        XCTAssertEqual(binding.panePID, 456)
    }

    func testConflictingSeatClaimsFailClosedAndRevokeControl() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "conflicting-seat-claim")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let memberID = "conflicted-agent"
        let resourceID = try XCTUnwrap(MeshResourceID(rawValue: memberID))
        _ = try await replica.store.registerHostResource(
            in: fixture.group, on: replica.identity,
            resourceID: resourceID,
            allowedActions: [.presence, .poke, .stop],
            at: MeshHybridTimestamp(wallTimeMilliseconds: 1)
        )
        let bindings = DistributedHostResourceBindings(
            dataDirectory: replica.rootURL
        )
        try bindings.save(
            try DistributedHostResourceBinding(
                resourceID: resourceID, tmuxSession: "pharos-conflict",
                tmuxSocket: "/tmp/tmux-conflict", tmuxPane: "%2",
                tmuxSessionID: "$1", tmuxSessionCreatedAt: 2, panePID: 3
            ),
            for: resourceID
        )
        let reconciler = DistributedAgentResourceReconciler(
            dataDirectory: replica.rootURL,
            seatInspector: FixedTmuxSeatInspector(seat: nil)
        )
        let result = try await reconciler.reconcile(
            memberID: memberID,
            presence: .init(
                state: "busy", updatedAt: 4,
                tmuxPane: "%2", tmuxSocket: "/tmp/tmux-conflict"
            ),
            seatIsConflicted: true, replica: replica, group: fixture.group,
            now: MeshHybridTimestamp(wallTimeMilliseconds: 5)
        )

        XCTAssertEqual(result.readiness, .conflicted)
        XCTAssertEqual(result.resource.allowedActions, [.presence])
        XCTAssertThrowsError(try bindings.load(resourceID))
    }

    func testVersionOneBindingCannotExecuteWithoutRuntimeProof() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pharos-binding-v1-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceID = try XCTUnwrap(MeshResourceID(rawValue: "legacy-v1"))
        let bindings = DistributedHostResourceBindings(dataDirectory: root)
        try FileManager.default.createDirectory(
            at: bindings.directory, withIntermediateDirectories: true
        )
        let filename = resourceID.rawValue.utf8
            .map { String(format: "%02x", $0) }.joined() + ".json"
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "resourceID": resourceID.rawValue,
            "tmuxSession": "pharos-legacy",
            "tmuxSocket": NSNull(),
        ])
        try data.write(to: bindings.directory.appendingPathComponent(filename))

        let binding = try bindings.load(resourceID)
        XCTAssertFalse(binding.hasVerifiedRuntimeSeat)
        XCTAssertThrowsError(
            try FixedTmuxSeatInspector(seat: nil).verify(binding)
        ) { error in
            XCTAssertEqual(
                (error as? DistributedHostExecutorError)?.failureCode,
                "unverified-host-binding"
            )
        }
    }

    func testHostSnapshotRetiresLegacyObservationWithoutMembership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "presence-orphan-cleanup")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        let memberID = "orphan-session"
        let resourceID = try XCTUnwrap(MeshResourceID(rawValue: memberID))
        try await agent.ensureLocalPresenceAuthority(memberID: memberID)
        let observation: [String: Any] = [
            "version": 1,
            "sessions": [
                memberID: [
                    "state": "gone", "updatedAt": 1.0,
                    "cwd": "/workspace", "kind": "codex",
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: observation, options: [.sortedKeys]
        ).write(
            to: replica.rootURL.appendingPathComponent(
                "agent-host-observations-v1.json"
            ),
            options: .atomic
        )

        let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
            replica: replica, group: fixture.group
        )
        let resource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        )

        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertEqual(resource?.state, .retired)
        XCTAssertNil(DistributedHookCLI.localAgentPresence(
            rootURL: replica.rootURL
        )[memberID])
    }

    func testAgentDeliveryUsesStableMembershipAndDeviceLocalExactOnceReceipts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "agent-delivery")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "pharos-dev")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await agent.join(
            room: "pharos-dev", nick: "builder", memberID: "session-stable"
        )
        let presenceResource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: try XCTUnwrap(MeshResourceID(rawValue: "session-stable"))
        )
        XCTAssertEqual(presenceResource?.state, .active)
        XCTAssertEqual(presenceResource?.allowedActions, [.presence])
        let room = try await agent.room(named: "pharos-dev")
        let human = try await registry.localHumanMember(in: room)

        _ = try await agent.say(
            room: "pharos-dev", memberID: human.id, text: "direct",
            targets: ["builder"]
        )
        _ = try await agent.say(
            room: "pharos-dev", memberID: human.id, text: "ambient"
        )

        let first = try await agent.receive(memberID: "session-stable")
        XCTAssertEqual(first.map(\.text), ["direct"])
        let second = try await agent.receive(memberID: "session-stable")
        XCTAssertTrue(second.isEmpty)

        // Reopening proves the cursor is persisted beside this replica rather
        // than held in one process or replicated as shared mutable truth.
        let reopened = DistributedAgentChat(replica: replica, group: fixture.group)
        let afterReopen = try await reopened.receive(memberID: "session-stable")
        XCTAssertTrue(afterReopen.isEmpty)
        let receipt = replica.rootURL.appendingPathComponent("agent-delivery-v1.json")
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: receipt.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testFinalRoomLeaveRetiresPresenceAuthorityAndRemovesLocalObservation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "agent-final-leave")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "first")
        _ = try await registry.createRoom(named: "second")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        let memberID = "session-final-leave"
        _ = try await agent.join(room: "first", nick: "builder", memberID: memberID)
        _ = try await agent.join(room: "second", nick: "builder", memberID: memberID)
        let resourceID = try XCTUnwrap(MeshResourceID(rawValue: memberID))
        let observationURL = replica.rootURL.appendingPathComponent(
            "agent-host-observations-v1.json"
        )
        let observation: [String: Any] = [
            "version": 1,
            "sessions": [
                memberID: [
                    "state": "busy", "updatedAt": 1.0,
                    "cwd": "/workspace", "kind": "codex",
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: observation, options: [.sortedKeys]
        ).write(to: observationURL, options: .atomic)

        try await agent.leave(room: "first", memberID: memberID)
        let stillActive = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        )
        XCTAssertEqual(stillActive?.state, .active)
        XCTAssertNotNil(DistributedHookCLI.localAgentPresence(
            rootURL: replica.rootURL
        )[memberID])

        try await agent.leave(room: "second", memberID: memberID)
        let retired = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        )
        XCTAssertEqual(retired?.state, .retired)
        XCTAssertNil(DistributedHookCLI.localAgentPresence(
            rootURL: replica.rootURL
        )[memberID])
        let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
            replica: replica, group: fixture.group
        )
        XCTAssertFalse(snapshot.records.contains { $0.resourceID == resourceID })
    }

    func testVerifiedSessionRebindMovesMembershipAndPendingDelivery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "agent-rebind")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "pharos-dev")
        let agent = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await agent.join(
            room: "pharos-dev", nick: "builder", memberID: "session-old"
        )
        let room = try await agent.room(named: "pharos-dev")
        let human = try await registry.localHumanMember(in: room)
        _ = try await agent.say(
            room: "pharos-dev", memberID: human.id, text: "before clear",
            targets: ["builder"]
        )
        let oldResourceID = try XCTUnwrap(MeshResourceID(rawValue: "session-old"))
        let newResourceID = try XCTUnwrap(MeshResourceID(rawValue: "session-new"))
        let bindings = DistributedHostResourceBindings(dataDirectory: replica.rootURL)
        try bindings.save(
            try DistributedHostResourceBinding(
                resourceID: oldResourceID, tmuxSession: "pharos-builder",
                tmuxSocket: "/tmp/pharos-tmux"
            ),
            for: oldResourceID
        )
        _ = try await replica.store.replaceHostResource(
            in: fixture.group, on: replica.identity, resourceID: oldResourceID,
            allowedActions: [.presence, .poke, .stop],
            at: MeshHybridTimestamp(
                wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        )

        let rebound = try await agent.rebindMember(
            from: "session-old", to: "session-new"
        )
        XCTAssertTrue(rebound)
        let members = try await registry.members(in: room)
        XCTAssertNil(members.first(where: { $0.id == "session-old" }))
        XCTAssertEqual(
            members.first(where: { $0.id == "session-new" })?.nick, "builder"
        )
        XCTAssertEqual(try bindings.load(newResourceID).tmuxSession, "pharos-builder")
        let retiredResource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: oldResourceID
        )
        XCTAssertEqual(retiredResource?.state, .retired)
        let activeResource = try await replica.store.hostResource(
            in: fixture.group, hostDeviceID: replica.identity.deviceID,
            resourceID: newResourceID
        )
        XCTAssertEqual(activeResource?.state, .active)
        let delivered = try await agent.receive(memberID: "session-new")
        XCTAssertEqual(delivered.map(\.text), ["before clear"])
        let repeated = try await agent.receive(memberID: "session-new")
        XCTAssertTrue(repeated.isEmpty)
    }

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
        let human = try await chat.localHumanMember(in: created)
        let first = try await chat.send(
            room: created, fromMemberID: human.id, text: "ship it",
            toMemberIDs: ["session-1"], sentAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertNotNil(created.replicaID)
        XCTAssertNotNil(first.id)
        XCTAssertEqual(first.authorMemberID, human.id)
        XCTAssertEqual(first.targetMemberIDs, ["session-1"])
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

    func testDuplicateNickAliasesExpandToStableMemberIDsWithoutCollapsing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "duplicate-alias")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let chat = DistributedChatRegistry(replica: replica, group: fixture.group)
        let room = try await chat.createRoom(named: "identity")
        try await chat.join(room: room, nick: "builder", memberID: "session-a")
        try await chat.join(room: room, nick: "builder", memberID: "session-b")
        let human = try await chat.localHumanMember(in: room)

        let targetIDs = try await chat.memberIDs(in: room, matching: ["builder"])
        XCTAssertEqual(targetIDs, ["session-a", "session-b"])
        let message = try await chat.send(
            room: room, fromMemberID: human.id, text: "both builders",
            toMemberIDs: targetIDs
        )
        XCTAssertEqual(message.authorMemberID, human.id)
        XCTAssertEqual(message.targetMemberIDs, ["session-a", "session-b"])
        XCTAssertEqual(message.to, ["builder", "builder"])

        try await chat.renameMember(room: room, memberID: "session-a", to: "reviewer")
        let members = try await chat.members(in: room)
        XCTAssertEqual(Set(members.map(\.id)), Set([human.id, "session-a", "session-b"]))
        let history = try await chat.messages(in: room)
        XCTAssertEqual(history.first?.to, ["builder", "builder"])
        XCTAssertEqual(history.first?.targetMemberIDs, ["session-a", "session-b"])
    }

    func testReadsVersionOneMessagePayloadWithoutInventingIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "v1-message")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let chat = DistributedChatRegistry(replica: replica, group: fixture.group)
        let room = try await chat.createRoom(named: "legacy-room")
        let entity = try XCTUnwrap(MeshEntityReference(type: .message, id: "legacy-v1"))
        let payload = Data(
            #"{"attachments":[],"from":"legacy-agent","roomID":"\#(room.replicaID!)","roomName":"legacy-room","targets":["builder"],"text":"old payload","timestamp":42,"version":1}"#.utf8
        )
        _ = try await MeshLocalEventAuthor(
            replica: replica, trustGroupID: fixture.group
        ).putImmutable(payload, on: entity)

        let messages = try await chat.messages(in: room)
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.from, "legacy-agent")
        XCTAssertNil(message.authorMemberID)
        XCTAssertEqual(message.to, ["builder"])
        XCTAssertTrue(message.targetMemberIDs.isEmpty)
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
        let firstHuman = try await firstChat.localHumanMember(in: created)
        _ = try await firstChat.send(
            room: created, fromMemberID: firstHuman.id, text: "from first",
            sentAt: Date(timeIntervalSince1970: 11)
        )
        try await copyEvents(from: first, to: second, group: fixture.group)

        let initialSecondRooms = try await secondChat.rooms()
        let secondRoom = try XCTUnwrap(initialSecondRooms.first)
        try await secondChat.renameRoom(secondRoom, to: "converged")
        try await secondChat.join(
            room: secondRoom, nick: "agent-b", memberID: "session-b"
        )
        _ = try await secondChat.send(
            room: secondRoom, fromMemberID: "session-b", text: "from second",
            sentAt: Date(timeIntervalSince1970: 13)
        )
        try await firstChat.join(
            room: created, nick: "agent-a", memberID: "session-a"
        )
        _ = try await firstChat.send(
            room: created, fromMemberID: "session-a", text: "first offline",
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

    func testAttachmentMetadataReplicatesAndBlobFetchVerifiesBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.replica(named: "blob-source")
        let destination = try fixture.replica(named: "blob-destination")
        try await pair(source, destination, group: fixture.group)
        let sourceAttachments = DistributedAttachmentRegistry(
            replica: source, group: fixture.group
        )
        let destinationAttachments = DistributedAttachmentRegistry(
            replica: destination, group: fixture.group
        )
        let bytes = Data(repeating: 0x5a, count: MeshBlobManifest.defaultChunkSize + 137)

        let authored = try await sourceAttachments.put(
            data: bytes, name: "proof.bin", mediaType: "application/octet-stream"
        )
        try await copyEvents(from: source, to: destination, group: fixture.group)
        let replicatedValue = try await destinationAttachments.metadata(id: authored.id)
        let replicated = try XCTUnwrap(replicatedValue)
        XCTAssertEqual(replicated, authored)
        let beforeFetch = try await destinationAttachments.localData(for: replicated)
        XCTAssertNil(beforeFetch)

        let transport = AttachmentRPCTransport(
            server: MeshReplicaRPCServer(store: source.store),
            remoteEndpointID: try destination.identity.endpointID()
        )
        let fetched = try await MeshBlobFetchSession(
            store: destination.store,
            client: MeshReplicaRPCClient(transport: transport)
        ).fetch(
            try DistributedAttachmentRegistry.digest(for: replicated),
            group: fixture.group, membershipEpoch: 1
        )

        XCTAssertEqual(fetched, bytes)
        let cached = try await destinationAttachments.localData(for: replicated)
        XCTAssertEqual(cached, bytes)
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

private struct FixedTmuxSeatInspector: DistributedTmuxSeatInspecting {
    let seat: DistributedTmuxSeat?

    func resolve(socket: String?, pane: String) throws -> DistributedTmuxSeat {
        guard let seat else {
            throw DistributedHostExecutorError.runtimeSeatMismatch
        }
        return seat
    }
}

private struct PermissiveTmuxSeatInspector: DistributedTmuxSeatInspecting {
    func resolve(socket: String?, pane: String) throws -> DistributedTmuxSeat {
        let number = Int32(pane.dropFirst()) ?? 1
        return DistributedTmuxSeat(
            sessionName: "test-session-\(number)",
            socket: socket, paneID: pane,
            sessionID: "$\(number)", sessionCreatedAt: Int64(number + 1),
            panePID: number + 100
        )
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

private struct AttachmentRPCTransport: MeshTransport, Sendable {
    let server: MeshReplicaRPCServer
    let remoteEndpointID: MeshEndpointID

    var path: MeshTransportPath { get async { .local } }

    func exchange(
        _ request: MeshTransportRequest
    ) async throws -> MeshTransportResponse {
        try await server.handle(request, remoteEndpointID: remoteEndpointID)
    }
}
