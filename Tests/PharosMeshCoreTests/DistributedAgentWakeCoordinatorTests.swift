import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity
import PharosMeshProtocol
import PharosMeshReplica

final class DistributedAgentWakeCoordinatorTests: XCTestCase {
    func testWakesOnlyIdleAgentOncePerNewestMessageWithFixedPrompt()
        async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recorder = PokeRecorder()
        let messages = PendingMessages([
            .init(stableID: "message-1", room: "zeta"),
            .init(stableID: "message-2", room: "alpha"),
        ])
        let coordinator = DistributedAgentWakeCoordinator(
            presenceProvider: { _ in
                [
                    "idle-session": .init(
                        state: "idle", updatedAt: 100, kind: "codex"
                    ),
                    "busy-session": .init(
                        state: "busy", updatedAt: 100, kind: "claude"
                    ),
                ]
            },
            pendingMessageProvider: { memberID, _, _ in
                memberID == "idle-session"
                    ? await messages.snapshot()
                    : [.init(stableID: "busy-message", room: "alpha")]
            },
            pokeProvider: { resourceID, prompt, _ in
                await recorder.record(resourceID: resourceID, prompt: prompt)
                return true
            }
        )

        let firstDelivery = await coordinator.wakeEligibleAgents(
            replica: fixture.replica, group: fixture.group
        )
        XCTAssertEqual(firstDelivery, 1)
        let duplicateDelivery = await coordinator.wakeEligibleAgents(
            replica: fixture.replica, group: fixture.group
        )
        XCTAssertEqual(duplicateDelivery, 0)
        await messages.append(
            .init(stableID: "message-3", room: "zeta")
        )
        let nextDelivery = await coordinator.wakeEligibleAgents(
            replica: fixture.replica, group: fixture.group
        )
        XCTAssertEqual(nextDelivery, 1)

        let pokes = await recorder.snapshot()
        XCTAssertEqual(pokes.count, 2)
        XCTAssertTrue(pokes.allSatisfy {
            $0.resourceID == "idle-session"
        })
        XCTAssertEqual(
            pokes.first?.prompt,
            "You have new Pharos mesh messages in alpha, zeta. " +
                "Run `pharos mesh recv --member idle-session` now, " +
                "reply where needed, then return to the idle composer."
        )
        XCTAssertFalse(pokes.first?.prompt.contains("message-") ?? true)
    }

    func testFailedPokeIsRetriedAndNotMarkedDelivered() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let attempts = PokeAttempts()
        let coordinator = DistributedAgentWakeCoordinator(
            presenceProvider: { _ in
                [
                    "idle-session": .init(
                        state: "stopped", updatedAt: 100, kind: "codex"
                    ),
                ]
            },
            pendingMessageProvider: { _, _, _ in
                [.init(stableID: "message-1", room: "misc")]
            },
            pokeProvider: { _, _, _ in await attempts.nextResult() }
        )

        let failedDelivery = await coordinator.wakeEligibleAgents(
            replica: fixture.replica, group: fixture.group
        )
        XCTAssertEqual(failedDelivery, 0)
        let retriedDelivery = await coordinator.wakeEligibleAgents(
            replica: fixture.replica, group: fixture.group
        )
        XCTAssertEqual(retriedDelivery, 1)
        let attemptCount = await attempts.count()
        XCTAssertEqual(attemptCount, 2)
    }

    private final class Fixture {
        let root: URL
        let replica: MeshLocalReplica
        let group = MeshTrustGroupID()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "pharos-wake-\(UUID().uuidString)",
                    isDirectory: true
                )
            replica = try MeshLocalReplica.open(
                rootURL: root,
                identityStorage: MeshMemoryIdentityStorage()
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private actor PendingMessages {
    private var values: [DistributedAgentWakeCoordinator.PendingMessage]

    init(_ values: [DistributedAgentWakeCoordinator.PendingMessage]) {
        self.values = values
    }

    func snapshot() -> [DistributedAgentWakeCoordinator.PendingMessage] {
        values
    }

    func append(
        _ value: DistributedAgentWakeCoordinator.PendingMessage
    ) {
        values.append(value)
    }
}

private actor PokeRecorder {
    struct Poke: Sendable {
        let resourceID: String
        let prompt: String
    }

    private var values: [Poke] = []

    func record(resourceID: MeshResourceID, prompt: String) {
        values.append(.init(
            resourceID: resourceID.rawValue, prompt: prompt
        ))
    }

    func snapshot() -> [Poke] {
        values
    }
}

private actor PokeAttempts {
    private var value = 0

    func nextResult() -> Bool {
        value += 1
        return value > 1
    }

    func count() -> Int {
        value
    }
}
