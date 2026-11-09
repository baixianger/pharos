import Foundation
import XCTest
@testable import PharosRuntime
import PharosClientKit
import PharosMeshCore
import PharosMeshIdentity
import PharosMeshProtocol
import PharosMeshReplica

final class MeshHostThreadBindingTests: XCTestCase {
    func testBindRegistersUniqueConversationAndRejectsAmbiguity() async throws {
        let runtime = FakeThreadRuntime()
        let sessions = [
            ClientSessionSummary(
                sessionId: "dsh:session-owned", machineId: "mini", agentType: "dsh",
                workspacePath: "/tmp/pharos-msg-test", title: "owned",
                status: .idle, updatedAt: Date(timeIntervalSince1970: 1),
                avatarSeed: "dsh:session-owned"
            ),
        ]
        let binder = MeshHostThreadBinder(
            inventory: { sessions },
            runtime: { method, params in try runtime.handle(method, params) },
            driverID: "test-driver"
        )

        let bound = try await binder.bind(
            hostSessionID: "dsh:session-owned", agentKind: "dsh"
        )
        XCTAssertEqual(bound.memberID, "session-owned")
        XCTAssertEqual(bound.vendorSessionID, "session-owned")
        XCTAssertEqual(bound.agentKind, "dsh")
        XCTAssertEqual(bound.hostSessionID, "dsh:session-owned")
        XCTAssertFalse(bound.conversationID.isEmpty)

        let inspected = try await binder.inspect(
            memberID: bound.memberID, vendorSessionID: bound.vendorSessionID, agentKind: "dsh"
        )
        XCTAssertEqual(inspected, bound)

        runtime.seedConversation(
            id: "other", kind: "dsh", vendorSessionID: "session-owned", memberID: "other-member"
        )
        do {
            _ = try await binder.bind(hostSessionID: "dsh:session-owned", agentKind: "dsh")
            XCTFail("Ambiguous vendor Session claims must fail closed")
        } catch let error as PharosClientError {
            guard case .operationFailed(let message) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("ambiguous") || message.contains("claims"), message)
        }
    }

    func testBindRejectsMissingOrStaleInventorySessions() async throws {
        let runtime = FakeThreadRuntime()
        let binder = MeshHostThreadBinder(
            inventory: {
                [
                    ClientSessionSummary(
                        sessionId: "agy:stale", machineId: "mini", agentType: "agy",
                        workspacePath: "/tmp", title: "stale", status: .idle,
                        updatedAt: Date(timeIntervalSince1970: 1), avatarSeed: "agy:stale",
                        inventoryStale: true
                    ),
                ]
            },
            runtime: { method, params in try runtime.handle(method, params) }
        )
        do {
            _ = try await binder.bind(hostSessionID: "agy:missing", agentKind: "agy")
            XCTFail("Missing inventory Session must fail")
        } catch let error as PharosClientError {
            guard case .operationFailed(let message) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("does not own"), message)
        }
        do {
            _ = try await binder.bind(hostSessionID: "agy:stale", agentKind: "agy")
            XCTFail("Stale inventory Session must fail")
        } catch let error as PharosClientError {
            guard case .operationFailed(let message) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("stale"), message)
        }
    }

    func testConsumptionAndReplyPhasesUseDirectedReceiptsWithoutLegacyWakeup() async throws {
        let fixture = try ChatFixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "host-thread-phases")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        let chat = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "work")
        _ = try await chat.join(room: "work", nick: "agent", memberID: "member-a")
        let room = try await registry.rooms()[0]
        let human = try await registry.localHumanMember(in: room)
        let original = try await registry.send(
            room: room, fromMemberID: human.id, text: "task",
            toMemberIDs: ["member-a"]
        )

        let runtime = FakeThreadRuntime()
        let binder = MeshHostThreadBinder(
            inventory: {
                [
                    ClientSessionSummary(
                        sessionId: "agy:provider", machineId: "mini", agentType: "agy",
                        workspacePath: "/tmp", title: "provider", status: .idle,
                        updatedAt: Date(timeIntervalSince1970: 1), avatarSeed: "agy:provider"
                    ),
                ]
            },
            runtime: { method, params in try runtime.handle(method, params) }
        )
        let queued = try await binder.advanceConsumption(
            chat: chat, memberID: "member-a", messageID: original.stableID,
            runtimeDeliveryState: "queued"
        )
        XCTAssertEqual(queued, .queued)
        let consumed = try await binder.advanceConsumption(
            chat: chat, memberID: "member-a", messageID: original.stableID,
            runtimeDeliveryState: "injected"
        )
        XCTAssertEqual(consumed, .consumed)
        let consumedAgain = try await binder.advanceConsumption(
            chat: chat, memberID: "member-a", messageID: original.stableID,
            runtimeDeliveryState: "injected"
        )
        XCTAssertEqual(consumedAgain, .consumed)
        let pending = try await chat.peek(memberID: "member-a")
        XCTAssertEqual(pending.map(\.stableID), [])
        XCTAssertEqual(
            MeshHostThreadBinder.phase(
                runtimeDeliveryState: "injected", hasLocalReceipt: true, hasRoomReply: false
            ),
            .consumed
        )

        let (phase, reply) = try await binder.commitReply(
            chat: chat, room: "work", memberID: "member-a",
            originalMessageID: original.stableID, text: "done"
        )
        XCTAssertEqual(phase, .replied)
        XCTAssertEqual(reply.replyTo?.messageID, original.stableID)
        XCTAssertEqual(
            MeshHostThreadBinder.phase(
                runtimeDeliveryState: "completed", hasLocalReceipt: true, hasRoomReply: true
            ),
            .replied
        )
        XCTAssertEqual(
            MeshHostThreadBinder.phase(
                runtimeDeliveryState: "mystery", hasLocalReceipt: false, hasRoomReply: false
            ),
            .unknown
        )
    }

    func testHostSessionRPCBindAndInspectRoundTrip() async throws {
        let runtime = FakeThreadRuntime()
        let sessions = [
            ClientSessionSummary(
                sessionId: "codex-thread-1", machineId: "mini", agentType: "codex",
                workspacePath: "/tmp", title: "codex", status: .idle,
                updatedAt: Date(timeIntervalSince1970: 1), avatarSeed: "codex-thread-1"
            ),
        ]
        let binder = MeshHostThreadBinder(
            inventory: { sessions },
            runtime: { method, params in try runtime.handle(method, params) },
            driverID: "rpc-driver"
        )
        let hostID = MeshDeviceID()
        let host = MeshHostSessionServer(
            hostDeviceID: hostID,
            service: MockPharosClientService(),
            threadBinder: binder
        )
        let bindPayload = try JSONEncoder().encode(
            MeshHostThreadBindPayload(agentKind: "codex", memberID: nil)
        )
        let action = try await host.handleAction(
            MeshHostSessionActionRequest(
                hostDeviceID: hostID, sessionID: "codex-thread-1",
                actionKind: "bindThreadMember", idempotencyKey: "bind-1",
                payload: bindPayload
            )
        )
        XCTAssertEqual(action.outcome, "success")
        let bound = try JSONDecoder().decode(
            MeshHostThreadBindingRecord.self, from: try XCTUnwrap(action.payload)
        )
        XCTAssertEqual(bound.memberID, "codex-thread-1")
        XCTAssertEqual(bound.vendorSessionID, "codex-thread-1")

        let inspect = try await host.handleQuery(
            MeshHostSessionQueryRequest(
                hostDeviceID: hostID, queryKind: "threadBindingInspect",
                sessionID: "codex-thread-1", agentKind: "codex",
                options: try JSONEncoder().encode(
                    MeshHostThreadInspectPayload(
                        memberID: bound.memberID, vendorSessionID: bound.vendorSessionID
                    )
                )
            )
        )
        let inspected = try JSONDecoder().decode(
            MeshHostThreadBindingRecord.self, from: inspect.payload
        )
        XCTAssertEqual(inspected, bound)

        let missingBinder = MeshHostSessionServer(
            hostDeviceID: hostID, service: MockPharosClientService()
        )
        do {
            _ = try await missingBinder.handleAction(
                MeshHostSessionActionRequest(
                    hostDeviceID: hostID, sessionID: "codex-thread-1",
                    actionKind: "bindThreadMember", idempotencyKey: "bind-2",
                    payload: bindPayload
                )
            )
            XCTFail("Host without Thread binder must reject bindThreadMember")
        } catch let error as PharosClientError {
            guard case .operationFailed(let message) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("unavailable"), message)
        }
    }

    /// Real Host binder → Runtime submit → product `replyOnce` (not Broker say-once).
    /// Requires `PHAROS_HOST_THREAD_PRODUCT_PATH_TEST=1` and `rust/target/debug/pharos-meshd`.
    func testRealHostBinderRuntimeSubmitReplyOnceWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_HOST_THREAD_PRODUCT_PATH_TEST"] == "1" else {
            throw XCTSkip("Set PHAROS_HOST_THREAD_PRODUCT_PATH_TEST=1 for Host binder → Runtime → replyOnce")
        }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = repo.appendingPathComponent("rust/target/debug/pharos-meshd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("Build rust/target/debug/pharos-meshd first")
        }

        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "personal/pharos-msg-test/peer-phase-a/phase-b-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let work = base.appendingPathComponent("agy-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let socket = base.appendingPathComponent("agent-runtime.sock")
        let previousRuntime = getenv("PHAROS_AGENT_RUNTIME_SOCKET").map { String(cString: $0) }
        setenv("PHAROS_AGENT_RUNTIME_SOCKET", socket.path, 1)
        defer {
            if let previousRuntime {
                setenv("PHAROS_AGENT_RUNTIME_SOCKET", previousRuntime, 1)
            } else {
                unsetenv("PHAROS_AGENT_RUNTIME_SOCKET")
            }
            try? FileManager.default.removeItem(at: base)
        }

        let runtime = Process()
        runtime.executableURL = binary
        runtime.arguments = [
            "--socket", socket.path,
            "--data-dir", base.appendingPathComponent("runtime").path,
        ]
        runtime.standardOutput = FileHandle.nullDevice
        runtime.standardError = FileHandle.nullDevice
        try runtime.run()
        defer {
            if runtime.isRunning {
                runtime.terminate()
                runtime.waitUntilExit()
            }
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))

        let creator = AgyAcpProcessTransport()
        _ = try await creator.sendRequest(
            method: "initialize",
            params: ["protocolVersion": 1, "clientCapabilities": [String: Any]()]
        )
        let created = try await creator.sendRequest(
            method: "session/new",
            params: ["cwd": work.path, "mcpServers": []]
        )
        let providerID = try XCTUnwrap(created["sessionId"] as? String)
        print("Host product-path Agy Session: \(providerID)")
        _ = try await creator.sendRequest(
            method: "session/prompt",
            params: [
                "sessionId": providerID,
                "prompt": [[
                    "type": "text",
                    "text": "Reply PHAROS_HOST_PRODUCT_SEED. Do not use tools or access files.",
                ]],
            ]
        )
        creator.close()

        let hostSessionID = "agy:" + providerID
        let memberID = "member-" + UUID().uuidString.lowercased().prefix(8)
        let inventory: [ClientSessionSummary] = [
            ClientSessionSummary(
                sessionId: hostSessionID, machineId: "mini", agentType: "agy",
                workspacePath: work.path, title: "phase-b", status: .idle,
                avatarSeed: hostSessionID
            ),
        ]
        let binder = MeshHostThreadBinder(
            inventory: { inventory },
            runtime: AgyThreadRuntimeBridge.localRuntime,
            driverID: "host-product-path-test"
        )
        let bound = try await binder.bind(
            hostSessionID: hostSessionID, agentKind: "agy", memberID: String(memberID)
        )
        XCTAssertEqual(bound.memberID, String(memberID))
        XCTAssertEqual(bound.vendorSessionID, providerID)
        print("Host product-path bind conversation=\(bound.conversationID)")

        let fixture = try ChatFixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "host-product-path")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        let chat = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "host-product")
        _ = try await chat.join(room: "host-product", nick: "agent", memberID: String(memberID))
        let room = try await registry.rooms()[0]
        let human = try await registry.localHumanMember(in: room)
        let router = ProductPathEventRouter()
        let service = AgyLiveSessionService(publish: { await router.publish($0) })
        _ = try await service.load(sessionId: providerID, workspace: work.path)
        let bridge = AgyThreadRuntimeBridge(
            binding: .init(
                memberID: String(memberID), sessionID: hostSessionID, providerSessionID: providerID
            ),
            send: { session, text, turn in
                _ = try await service.send(sessionId: session, text: text, turnID: turn)
            },
            reply: { delivery, text in
                _ = try await binder.commitReply(
                    chat: chat, room: delivery.room, memberID: delivery.memberID,
                    originalMessageID: delivery.messageID, text: text
                )
            }
        )
        await router.set(bridge)
        // submit-member only routes to conversations with a live delivery.poll
        // driver and recent conversation.state; poll once before enqueue.
        try await bridge.poll()

        let original = try await registry.send(
            room: room, fromMemberID: human.id,
            text: "@agent Reply exactly PHAROS_HOST_PRODUCT_DONE. Do not use tools or access files.",
            toMemberIDs: [String(memberID)]
        )

        // host must be absent or match LightSelfHost; a localized display name
        // would force .forward even when runtimeOwnerIsLocal is true.
        let target = MeshMemberInfo(
            id: String(memberID), nick: "agent", session: providerID,
            kind: "agy", rooms: ["host-product"],
            lastSeen: Date().timeIntervalSince1970,
            runtimeOwnerIsLocal: true
        )
        let route = MeshRuntimeDeliveryBridge.submit(message: original, target: target)
        guard case .accepted = route else {
            return XCTFail("Runtime must accept Host-bound delivery.submit-member, got \(route)")
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        var reply: MeshMsg?
        var consumed: MeshHostThreadDeliveryPhase = .unknown
        while ContinuousClock.now < deadline {
            try await bridge.poll()
            let snapshot = try AgyThreadRuntimeBridge.localRuntime("runtime.snapshot", [:]) as? [String: Any]
            let deliveries = snapshot?["deliveries"] as? [[String: Any]] ?? []
            if let row = deliveries.first(where: { $0["id"] != nil }),
               let state = row["state"] as? String {
                consumed = try await binder.advanceConsumption(
                    chat: chat, memberID: String(memberID), messageID: original.stableID,
                    runtimeDeliveryState: state
                )
            }
            let history = try await chat.history(room: "host-product", limit: 20)
            reply = history.first {
                $0.authorMemberID == String(memberID)
                    && $0.replyTo?.messageID == original.stableID
                    && $0.text.contains("PHAROS_HOST_PRODUCT_DONE")
            }
            if reply != nil { break }
            try await Task.sleep(for: .milliseconds(500))
        }

        let snapshot = try XCTUnwrap(
            AgyThreadRuntimeBridge.localRuntime("runtime.snapshot", [:]) as? [String: Any]
        )
        let deliveries = try XCTUnwrap(snapshot["deliveries"] as? [[String: Any]])
        let completed = deliveries.filter { $0["state"] as? String == "completed" }.count
        let phase = MeshHostThreadBinder.phase(
            runtimeDeliveryState: deliveries.first?["state"] as? String,
            hasLocalReceipt: consumed == .consumed || consumed == .replied,
            hasRoomReply: reply != nil
        )
        print(
            "Host product-path: route=\(route) consumed=\(consumed) phase=\(phase) " +
            "room-reply=\(reply != nil) runtime-completed=\(completed)"
        )
        XCTAssertNotNil(reply)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(phase, .replied)
        let history = try await chat.history(room: "host-product", limit: 20)
        XCTAssertEqual(history.filter { $0.authorMemberID == String(memberID) }.count, 1)
    }
}

private actor ProductPathEventRouter {
    var bridge: AgyThreadRuntimeBridge?
    func set(_ value: AgyThreadRuntimeBridge) { bridge = value }
    func publish(_ event: PharosClientEvent) async { await bridge?.handle(event) }
}

private final class FakeThreadRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var conversations: [[String: Any]] = []

    func seedConversation(
        id: String, kind: String, vendorSessionID: String, memberID: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        conversations.append([
            "id": id, "kind": kind, "vendorSessionID": vendorSessionID,
            "memberID": memberID, "driverID": "seed", "ownership": "managed",
        ])
    }

    func handle(_ method: String, _ params: [String: Any]) throws -> Any {
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "driver.register":
            return ["ok": true]
        case "conversation.register":
            let kind = params["kind"] as? String ?? ""
            let vendor = params["vendorSessionID"] as? String ?? ""
            let member = params["memberID"] as? String ?? ""
            if let existing = conversations.first(where: {
                $0["vendorSessionID"] as? String == vendor && $0["kind"] as? String == kind
            }) {
                return existing
            }
            let row: [String: Any] = [
                "id": "conv-" + UUID().uuidString.lowercased(),
                "kind": kind, "vendorSessionID": vendor, "memberID": member,
                "driverID": params["driverID"] as? String ?? "", "ownership": "managed",
            ]
            conversations.append(row)
            return row
        case "runtime.snapshot":
            return ["conversations": conversations]
        default:
            throw PharosClientError.operationFailed("Unexpected Runtime method \(method)")
        }
    }
}

private final class ChatFixture {
    let root: URL
    let group = MeshTrustGroupID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pharos-host-thread-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func replica(named name: String) throws -> MeshLocalReplica {
        try MeshLocalReplica.open(
            rootURL: root.appendingPathComponent(name, isDirectory: true),
            identityStorage: MeshMemoryIdentityStorage()
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
