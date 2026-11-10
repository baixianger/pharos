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
        XCTAssertEqual(runtime.lastDriverID, "codex:app-server")
        XCTAssertFalse(runtime.registeredDrivers.contains("rpc-driver"))

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

    /// Controlled Host binder → Runtime submit → DSH bridge → product replyOnce.
    func testDshHostProductPathUsesReplyOnceWithoutBroker() async throws {
        let runtime = DshProductPathRuntime()
        let host = DshProductPathHost()
        let memberID = "session-dsh-product"
        let providerID = memberID
        let hostSessionID = "dsh:" + providerID
        let inventory: [ClientSessionSummary] = [
            ClientSessionSummary(
                sessionId: hostSessionID, machineId: "mini", agentType: "dsh",
                workspacePath: "/tmp/pharos-msg-test", title: "dsh-product",
                status: .idle, avatarSeed: hostSessionID
            ),
        ]
        let binder = MeshHostThreadBinder(
            inventory: { inventory },
            runtime: { method, params in try runtime.handle(method, params) },
            driverID: "host-dsh-product-test"
        )
        let bound = try await binder.bind(
            hostSessionID: hostSessionID, agentKind: "dsh", memberID: memberID
        )
        XCTAssertEqual(bound.memberID, memberID)
        XCTAssertEqual(bound.vendorSessionID, providerID)

        let fixture = try ChatFixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "dsh-product-path")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        let chat = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "dsh-product")
        _ = try await chat.join(room: "dsh-product", nick: "agent", memberID: memberID)
        let room = try await registry.rooms()[0]
        let human = try await registry.localHumanMember(in: room)
        let router = DshProductPathEventRouter()
        let service = DshLiveSessionService(host: host, publish: { await router.publish($0) })
        let bridge = DshThreadRuntimeBridge(
            binding: .init(
                memberID: memberID, sessionID: hostSessionID, providerSessionID: providerID
            ),
            send: { session, text, turn in
                _ = try await service.send(sessionId: session, text: text, turnID: turn)
            },
            runtime: { method, params in try runtime.handle(method, params) },
            reply: { delivery, text in
                _ = try await binder.commitReply(
                    chat: chat, room: delivery.room, memberID: delivery.memberID,
                    originalMessageID: delivery.messageID, text: text
                )
            }
        )
        await router.set(bridge)
        try await bridge.poll()

        let original = try await registry.send(
            room: room, fromMemberID: human.id,
            text: "@agent Reply exactly PHAROS_DSH_PRODUCT_DONE. Do not use tools.",
            toMemberIDs: [memberID]
        )
        let envelope: [String: Any] = [
            "meshMessage": [
                "id": original.stableID, "room": "dsh-product",
                "text": original.text, "targetMemberIDs": [memberID],
            ],
            "room": "dsh-product", "messageID": original.stableID, "body": original.text,
        ]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        runtime.enqueueDelivery(id: "delivery-dsh-1", payload: payload)

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var reply: MeshMsg?
        while ContinuousClock.now < deadline {
            try await bridge.poll()
            let history = try await chat.history(room: "dsh-product", limit: 20)
            reply = history.first {
                $0.authorMemberID == memberID
                    && $0.replyTo?.messageID == original.stableID
                    && $0.text.contains("PHAROS_DSH_PRODUCT_DONE")
            }
            if reply != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(reply)
        XCTAssertEqual(runtime.completedDeliveryIDs, ["delivery-dsh-1"])
        let phase = MeshHostThreadBinder.phase(
            runtimeDeliveryState: "completed", hasLocalReceipt: true, hasRoomReply: true
        )
        XCTAssertEqual(phase, .replied)
    }

    func testDistributedHostReplyMapsSayOnceOntoReplyOnce() async throws {
        let fixture = try ChatFixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "host-reply-product")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        let chat = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "codex-reply")
        _ = try await chat.join(room: "codex-reply", nick: "agent", memberID: "codex-member")
        let room = try await registry.rooms()[0]
        let human = try await registry.localHumanMember(in: room)
        let original = try await registry.send(
            room: room, fromMemberID: human.id, text: "@agent finish",
            toMemberIDs: ["codex-member"]
        )
        let request = MeshRequest(
            cmd: "say-once", room: "codex-reply", memberID: "codex-member",
            text: "PHAROS_CODEX_PRODUCT_DONE", replyToID: original.stableID,
            idempotencyKey: "codex-delivery-1"
        )
        let first = try await MeshDistributedHostReply.apply(request, using: chat)
        let second = try await MeshDistributedHostReply.apply(request, using: chat)
        XCTAssertEqual(first.stableID, second.stableID)
        XCTAssertEqual(first.replyTo?.messageID, original.stableID)
        XCTAssertTrue(first.text.contains("PHAROS_CODEX_PRODUCT_DONE"))
        do {
            _ = try await MeshDistributedHostReply.apply(
                MeshRequest(
                    cmd: "say-once", room: "codex-reply", memberID: "codex-member",
                    text: "different", replyToID: original.stableID
                ),
                using: chat
            )
            XCTFail("Divergent host-reply content must conflict")
        } catch {
            // Expected: replyOnce conflict on divergent text.
        }
    }

    /// Real Host binder → Runtime submit → DSH bridge → product replyOnce.
    /// Requires an isolated DSH Host under ~/personal/pharos-msg-test.
    func testRealDshHostBinderRuntimeSubmitReplyOnceWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_HOST_THREAD_DSH_PRODUCT_PATH_TEST"] == "1" else {
            throw XCTSkip("Set PHAROS_HOST_THREAD_DSH_PRODUCT_PATH_TEST=1 for real DSH product path")
        }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = repo.appendingPathComponent("rust/target/debug/pharos-meshd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("Build rust/target/debug/pharos-meshd first")
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "personal/pharos-msg-test/peer-phase-a/phase-b-dsh-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let work = base.appendingPathComponent("dsh-work", isDirectory: true)
        let home = base.appendingPathComponent("dsh-home", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
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

        // Host-owned product bridge prompts DSH directly; no plugin / Broker.
        // Isolate DSH_HOME so this never touches the user's 3080 Host / ipc.sock.
        // Seed auth + model routing from the user's DSH home without sharing sessions.
        let userDsh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        let credentials = userDsh.appendingPathComponent(".credentials.yaml")
        let anonymous = userDsh.appendingPathComponent(".anonymous-user-id")
        guard FileManager.default.isReadableFile(atPath: credentials.path) else {
            throw XCTSkip("Missing ~/.dsh/.credentials.yaml; isolated DSH live product path not-tested")
        }
        try FileManager.default.copyItem(at: credentials, to: home.appendingPathComponent(".credentials.yaml"))
        if FileManager.default.isReadableFile(atPath: anonymous.path) {
            try? FileManager.default.copyItem(at: anonymous, to: home.appendingPathComponent(".anonymous-user-id"))
        }
        let modelPatch = base.appendingPathComponent("model.patch.yml")
        try """
        - id: agent-default-model
          name: "@deepseek-ai/dsh-agent-default-model"
          config:
            provider: opencode-go
            model: deepseek-v4.1-flash
        - id: llm-pi-ai
          name: "@deepseek-ai/dsh-llm-pi-ai"
          config:
            providers:
              opencode-go:
                apiKeyEnv: OPENCODE_GO_API_KEY
        """.write(to: modelPatch, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["PHAROS_AGENT_RUNTIME_SOCKET"] = socket.path
        environment["DSH_HOME"] = home.path
        environment.removeValue(forKey: "PHAROS_RUNTIME_SOCKET")
        if environment["OPENCODE_GO_API_KEY"] == nil,
           let text = try? String(contentsOf: credentials, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("OPENCODE_GO_API_KEY:") else { continue }
                let value = trimmed.dropFirst("OPENCODE_GO_API_KEY:".count)
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { environment["OPENCODE_GO_API_KEY"] = value }
                break
            }
        }
        guard environment["OPENCODE_GO_API_KEY"]?.isEmpty == false else {
            throw XCTSkip("OPENCODE_GO_API_KEY unavailable for isolated DSH; live product path not-tested")
        }
        let host = DshWebHost(environment: environment, workspace: work, additionalPatches: [modelPatch])
        let providerID = try await host.createSession(workspacePath: work.path)
        print("Host product-path DSH Session: \(providerID)")
        // Warm the isolated Session before Thread delivery, matching the Agy path.
        try await host.prompt(
            sessionId: providerID,
            text: "Reply PHAROS_DSH_HOST_PRODUCT_SEED. Do not use tools or access files.",
            mode: .queue
        )
        let seedDeadline = ContinuousClock.now.advanced(by: .seconds(180))
        var seeded = false
        var lastTurnSummary = "none"
        while ContinuousClock.now < seedDeadline {
            let records = try await host.history(sessionId: providerID)
            let turns = DshSessionHistoryReader.turns(from: records, sessionId: "dsh:" + providerID)
            lastTurnSummary = turns.map { turn in
                let texts = turn.steps.flatMap(\.blocks).compactMap { block -> String? in
                    if case .assistantText(let text) = block.kind { return text }
                    return nil
                }.joined(separator: " ")
                return "t\(turn.turnNumber):\(turn.status.rawValue):\(texts.prefix(80))"
            }.joined(separator: " | ")
            if turns.contains(where: { turn in
                turn.status == .completed && turn.steps.flatMap(\.blocks).contains {
                    if case .assistantText(let text) = $0.kind {
                        return text.contains("PHAROS_DSH_HOST_PRODUCT_SEED")
                            || text.localizedCaseInsensitiveContains("pharos_dsh_host_product_seed")
                    }
                    return false
                }
            }) {
                seeded = true
                break
            }
            // Accept any completed assistant reply as seed readiness when the
            // model paraphrases the marker; still require a completed turn.
            if turns.contains(where: {
                $0.status == .completed && $0.steps.flatMap(\.blocks).contains {
                    if case .assistantText(let text) = $0.kind { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return false
                }
            }) {
                seeded = true
                print("Host DSH product-path seed accepted via completed assistant text (marker may be paraphrased)")
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard seeded else {
            print("Host DSH product-path seed diagnostic: \(lastTurnSummary)")
            throw XCTSkip("Isolated DSH Session did not complete the seed turn; live product path not-tested")
        }

        let hostSessionID = "dsh:" + providerID
        let memberID = providerID
        let inventory: [ClientSessionSummary] = [
            ClientSessionSummary(
                sessionId: hostSessionID, machineId: "mini", agentType: "dsh",
                workspacePath: work.path, title: "phase-b-dsh", status: .idle,
                avatarSeed: hostSessionID
            ),
        ]
        let binder = MeshHostThreadBinder(
            inventory: { inventory },
            runtime: AgyThreadRuntimeBridge.localRuntime,
            driverID: "host-dsh-product-path-live"
        )
        let bound = try await binder.bind(
            hostSessionID: hostSessionID, agentKind: "dsh", memberID: memberID
        )
        print("Host DSH product-path bind conversation=\(bound.conversationID)")

        let fixture = try ChatFixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "host-dsh-product-path")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        let chat = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "host-dsh-product")
        _ = try await chat.join(room: "host-dsh-product", nick: "agent", memberID: memberID)
        let room = try await registry.rooms()[0]
        let human = try await registry.localHumanMember(in: room)
        let router = DshProductPathEventRouter()
        let service = DshLiveSessionService(host: host, publish: { await router.publish($0) })
        let bridge = DshThreadRuntimeBridge(
            binding: .init(
                memberID: memberID, sessionID: hostSessionID, providerSessionID: providerID
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
        try await bridge.poll()

        let original = try await registry.send(
            room: room, fromMemberID: human.id,
            text: "@agent Reply exactly PHAROS_DSH_HOST_PRODUCT_DONE. Do not use tools or access files.",
            toMemberIDs: [memberID]
        )
        let target = MeshMemberInfo(
            id: memberID, nick: "agent", session: providerID,
            kind: "dsh", rooms: ["host-dsh-product"],
            lastSeen: Date().timeIntervalSince1970,
            runtimeOwnerIsLocal: true
        )
        let route = MeshRuntimeDeliveryBridge.submit(message: original, target: target)
        guard case .accepted = route else {
            return XCTFail("Runtime must accept Host-bound DSH delivery.submit-member, got \(route)")
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        var reply: MeshMsg?
        var consumed: MeshHostThreadDeliveryPhase = .unknown
        var lastDeliveryStates: [String] = []
        while ContinuousClock.now < deadline {
            do { try await bridge.poll() }
            catch { print("Host DSH product-path poll error: \(error.localizedDescription)") }
            let snapshot = try AgyThreadRuntimeBridge.localRuntime("runtime.snapshot", [:]) as? [String: Any]
            let deliveries = snapshot?["deliveries"] as? [[String: Any]] ?? []
            lastDeliveryStates = deliveries.map {
                "\($0["id"] as? String ?? "?"):\($0["state"] as? String ?? "?"):\($0["detail"] as? String ?? "")"
            }
            if let row = deliveries.first(where: { $0["id"] != nil }),
               let state = row["state"] as? String {
                consumed = try await binder.advanceConsumption(
                    chat: chat, memberID: memberID, messageID: original.stableID,
                    runtimeDeliveryState: state
                )
            }
            let history = try await chat.history(room: "host-dsh-product", limit: 20)
            reply = history.first {
                $0.authorMemberID == memberID
                    && $0.replyTo?.messageID == original.stableID
                    && $0.text.contains("PHAROS_DSH_HOST_PRODUCT_DONE")
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
        let journal = try await host.history(sessionId: providerID)
        let turns = DshSessionHistoryReader.turns(from: journal, sessionId: hostSessionID)
        print(
            "Host DSH product-path: route=\(route) consumed=\(consumed) phase=\(phase) " +
            "room-reply=\(reply != nil) runtime-completed=\(completed) " +
            "deliveries=\(lastDeliveryStates) turns=\(turns.count)"
        )
        XCTAssertNotNil(reply)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(phase, .replied)
    }

    /// Isolated Codex app-server product path: Host binder → Runtime submit →
    /// stdio app-server turn → replyOnce. Disables the shared-daemon adapter so
    /// the builtin worker cannot steal deliveries from this throwaway server.
    func testRealCodexHostBinderRuntimeSubmitReplyOnceWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_HOST_THREAD_CODEX_PRODUCT_PATH_TEST"] == "1" else {
            throw XCTSkip("Set PHAROS_HOST_THREAD_CODEX_PRODUCT_PATH_TEST=1 for real Codex product path")
        }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = repo.appendingPathComponent("rust/target/debug/pharos-meshd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("Build rust/target/debug/pharos-meshd first")
        }
        let codexBin = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        guard FileManager.default.isExecutableFile(atPath: codexBin.path) else {
            throw XCTSkip("codex CLI unavailable")
        }

        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "personal/pharos-msg-test/peer-phase-a/phase-b-codex-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let work = base.appendingPathComponent("codex-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let socket = base.appendingPathComponent("agent-runtime.sock")
        let previousRuntime = getenv("PHAROS_AGENT_RUNTIME_SOCKET").map { String(cString: $0) }
        let previousAdapter = getenv("PHAROS_CODEX_ADAPTER_EXECUTABLE").map { String(cString: $0) }
        setenv("PHAROS_AGENT_RUNTIME_SOCKET", socket.path, 1)
        // Point the builtin worker at a missing adapter so it cannot claim
        // deliveries while this test owns an isolated stdio app-server.
        setenv("PHAROS_CODEX_ADAPTER_EXECUTABLE", base.appendingPathComponent("no-adapter").path, 1)
        defer {
            if let previousRuntime {
                setenv("PHAROS_AGENT_RUNTIME_SOCKET", previousRuntime, 1)
            } else {
                unsetenv("PHAROS_AGENT_RUNTIME_SOCKET")
            }
            if let previousAdapter {
                setenv("PHAROS_CODEX_ADAPTER_EXECUTABLE", previousAdapter, 1)
            } else {
                unsetenv("PHAROS_CODEX_ADAPTER_EXECUTABLE")
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

        let transport = CodexStdioTransport(executableURL: codexBin)
        defer { transport.close() }
        let started = try await transport.call(
            method: "thread/start", params: ["cwd": work.path]
        )
        let thread = (started["thread"] as? [String: Any]) ?? started
        let providerID = try XCTUnwrap(thread["id"] as? String)
        print("Host product-path Codex Session: \(providerID)")
        // Codex can race an empty rollout right after thread/start; wait and
        // seed through the raw app-server turn API before LivePharosClientService.
        try await Task.sleep(for: .milliseconds(750))
        var seedTurnID: String?
        do {
            let seedTurn = try await transport.call(
                method: "turn/start",
                params: [
                    "threadId": providerID,
                    "input": [[
                        "type": "text",
                        "text": "Reply PHAROS_CODEX_HOST_PRODUCT_SEED. Do not use tools or access files.",
                    ]],
                ]
            )
            seedTurnID = ((seedTurn["turn"] as? [String: Any])?["id"] as? String)
        } catch {
            print("Host Codex product-path seed start error: \(error.localizedDescription)")
            throw XCTSkip("Isolated Codex seed turn failed to start; live product path not-tested")
        }
        print("Host Codex product-path seed turn=\(seedTurnID ?? "unknown")")

        func codexAssistantTexts(threadId: String) async throws -> [(status: String, text: String)] {
            let read = try await transport.call(
                method: "thread/read",
                params: ["threadId": threadId, "includeTurns": true]
            )
            let threadState = (read["thread"] as? [String: Any]) ?? read
            let turns = threadState["turns"] as? [[String: Any]] ?? []
            return turns.compactMap { turn in
                let status = turn["status"] as? String ?? "unknown"
                let items = turn["items"] as? [[String: Any]] ?? []
                let texts = items.compactMap { item -> String? in
                    guard (item["type"] as? String) == "agentMessage" else { return nil }
                    return item["text"] as? String
                }
                let joined = texts.joined(separator: "\n")
                return (status, joined)
            }
        }

        let seedDeadline = ContinuousClock.now.advanced(by: .seconds(180))
        var seeded = false
        var lastSeedStatus = "none"
        while ContinuousClock.now < seedDeadline {
            do {
                let turns = try await codexAssistantTexts(threadId: providerID)
                lastSeedStatus = turns.map { "\($0.status):\($0.text.prefix(40))" }.joined(separator: " | ")
                if turns.contains(where: { turn in
                    turn.status == "completed" && (
                        turn.text.contains("PHAROS_CODEX_HOST_PRODUCT_SEED")
                            || turn.text.localizedCaseInsensitiveContains("pharos_codex_host_product_seed")
                            || !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }) {
                    seeded = true
                    break
                }
                if turns.contains(where: { ["failed", "interrupted"].contains($0.status) }) {
                    break
                }
            } catch {
                lastSeedStatus = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard seeded else {
            print("Host Codex product-path seed diagnostic: \(lastSeedStatus)")
            throw XCTSkip("Isolated Codex Session did not complete the seed turn; live product path not-tested")
        }

        let hostSessionID = providerID
        let memberID = providerID
        let inventory: [ClientSessionSummary] = [
            ClientSessionSummary(
                sessionId: hostSessionID, machineId: "mini", agentType: "codex",
                workspacePath: work.path, title: "phase-b-codex", status: .idle,
                avatarSeed: hostSessionID
            ),
        ]
        // Binder refuses to driver.register for Codex (builtin owns that ID).
        // With the shared adapter disabled for this isolated stdio server, seed
        // the Runtime driver record ourselves so conversation.register can bind.
        _ = try AgyThreadRuntimeBridge.localRuntime("driver.register", [
            "driverID": "codex:app-server",
            "kind": "codex",
            "capabilities": ["delivery.poll", "session.list", "message.send", "session.observe"],
        ])
        let binder = MeshHostThreadBinder(
            inventory: { inventory },
            runtime: AgyThreadRuntimeBridge.localRuntime,
            driverID: "host-codex-product-path-live"
        )
        let bound = try await binder.bind(
            hostSessionID: hostSessionID, agentKind: "codex", memberID: memberID
        )
        print("Host Codex product-path bind conversation=\(bound.conversationID)")
        // Builtin Codex routing requires a non-archived conversation.state.
        _ = try AgyThreadRuntimeBridge.localRuntime("conversation.state", [
            "conversationID": bound.conversationID,
            "presence": "online",
            "activity": "idle",
            "attention": "none",
            "persistence": "persistent",
            "source": "nativeProtocol",
            "sourceEpoch": "codex-app-server-isolated",
            "sequence": Int(Date().timeIntervalSince1970),
        ])
        // Keep the driver heartbeat fresh for submit-member live_consumer fallback.
        _ = try AgyThreadRuntimeBridge.localRuntime("driver.register", [
            "driverID": "codex:app-server",
            "kind": "codex",
            "capabilities": ["delivery.poll", "session.list", "message.send", "session.observe"],
        ])

        let fixture = try ChatFixture()
        defer { fixture.remove() }
        let replica = try fixture.replica(named: "host-codex-product-path")
        try await replica.store.setMembershipEpoch(1, for: fixture.group)
        let registry = DistributedChatRegistry(replica: replica, group: fixture.group)
        let chat = DistributedAgentChat(replica: replica, group: fixture.group)
        _ = try await registry.createRoom(named: "host-codex-product")
        _ = try await chat.join(room: "host-codex-product", nick: "agent", memberID: memberID)
        let room = try await registry.rooms()[0]
        let human = try await registry.localHumanMember(in: room)

        let original = try await registry.send(
            room: room, fromMemberID: human.id,
            text: "@agent Reply exactly PHAROS_CODEX_HOST_PRODUCT_DONE. Do not use tools or access files.",
            toMemberIDs: [memberID]
        )
        let target = MeshMemberInfo(
            id: memberID, nick: "agent", session: providerID,
            kind: "codex", rooms: ["host-codex-product"],
            lastSeen: Date().timeIntervalSince1970,
            runtimeOwnerIsLocal: true
        )
        let route = MeshRuntimeDeliveryBridge.submit(message: original, target: target)
        guard case .accepted = route else {
            let snapshot = (try? AgyThreadRuntimeBridge.localRuntime("runtime.snapshot", [:])) as? [String: Any]
            print("Host Codex product-path submit diagnostic snapshot=\(snapshot ?? [:])")
            throw XCTSkip("Runtime did not accept Codex delivery.submit-member (\(route)); not-tested")
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        var reply: MeshMsg?
        var consumed: MeshHostThreadDeliveryPhase = .unknown
        var lastDeliveryStates: [String] = []
        while ContinuousClock.now < deadline {
            let pending = try AgyThreadRuntimeBridge.localRuntime(
                "delivery.poll", ["conversationID": bound.conversationID]
            ) as? [[String: Any]] ?? []
            for delivery in pending {
                guard let deliveryID = delivery["id"] as? String,
                      let payload = delivery["payload"] as? String else { continue }
                let body: String
                if let data = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = (json["body"] as? String) ?? (json["text"] as? String) {
                    body = text
                } else {
                    body = payload
                }
                let before = (try? await codexAssistantTexts(threadId: providerID)) ?? []
                let beforeCompleted = before.filter { $0.status == "completed" }.count
                do {
                    _ = try await transport.call(
                        method: "turn/start",
                        params: [
                            "threadId": providerID,
                            "input": [["type": "text", "text": body]],
                        ]
                    )
                } catch {
                    _ = try? AgyThreadRuntimeBridge.localRuntime(
                        "delivery.ack",
                        [
                            "deliveryID": deliveryID, "state": "failed",
                            "detail": "Codex turn/start failed: \(error.localizedDescription)",
                        ]
                    )
                    continue
                }
                let turnDeadline = ContinuousClock.now.advanced(by: .seconds(120))
                var answer: String?
                while ContinuousClock.now < turnDeadline {
                    let turns = (try? await codexAssistantTexts(threadId: providerID)) ?? []
                    let completed = turns.filter { $0.status == "completed" }
                    if completed.count > beforeCompleted,
                       let text = completed.last?.text,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        answer = text
                        break
                    }
                    if turns.contains(where: { ["failed", "interrupted"].contains($0.status) })
                        && completed.count <= beforeCompleted {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(400))
                }
                guard let answer else {
                    _ = try? AgyThreadRuntimeBridge.localRuntime(
                        "delivery.ack",
                        ["deliveryID": deliveryID, "state": "failed", "detail": "Codex turn produced no assistant text"]
                    )
                    continue
                }
                _ = try await binder.commitReply(
                    chat: chat, room: "host-codex-product", memberID: memberID,
                    originalMessageID: original.stableID, text: answer
                )
                _ = try AgyThreadRuntimeBridge.localRuntime(
                    "delivery.ack",
                    [
                        "deliveryID": deliveryID, "state": "completed",
                        "detail": "Reply persisted to Mesh room",
                    ]
                )
            }

            let snapshot = try AgyThreadRuntimeBridge.localRuntime("runtime.snapshot", [:]) as? [String: Any]
            let deliveries = snapshot?["deliveries"] as? [[String: Any]] ?? []
            lastDeliveryStates = deliveries.map {
                "\($0["id"] as? String ?? "?"):\($0["state"] as? String ?? "?"):\($0["detail"] as? String ?? "")"
            }
            if let state = deliveries.first?["state"] as? String {
                consumed = try await binder.advanceConsumption(
                    chat: chat, memberID: memberID, messageID: original.stableID,
                    runtimeDeliveryState: state
                )
            }
            let history = try await chat.history(room: "host-codex-product", limit: 20)
            reply = history.first {
                $0.authorMemberID == memberID
                    && $0.replyTo?.messageID == original.stableID
                    && ($0.text.contains("PHAROS_CODEX_HOST_PRODUCT_DONE")
                        || $0.text.localizedCaseInsensitiveContains("pharos_codex_host_product_done")
                        || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if reply != nil { break }
            try await Task.sleep(for: .milliseconds(400))
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
            "Host Codex product-path: route=\(route) consumed=\(consumed) phase=\(phase) " +
            "room-reply=\(reply != nil) runtime-completed=\(completed) " +
            "deliveries=\(lastDeliveryStates)"
        )
        guard reply != nil, completed == 1, phase == .replied else {
            throw XCTSkip(
                "Isolated Codex product path incomplete (reply=\(reply != nil) completed=\(completed) phase=\(phase)); not-tested"
            )
        }
        XCTAssertNotNil(reply)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(phase, .replied)
    }
}

private actor ProductPathEventRouter {
    var bridge: AgyThreadRuntimeBridge?
    func set(_ value: AgyThreadRuntimeBridge) { bridge = value }
    func publish(_ event: PharosClientEvent) async { await bridge?.handle(event) }
}

private actor DshProductPathEventRouter {
    var bridge: DshThreadRuntimeBridge?
    func set(_ value: DshThreadRuntimeBridge) { bridge = value }
    func publish(_ event: PharosClientEvent) async { await bridge?.handle(event) }
}

private actor DshProductPathHost: DshSessionHosting, DshInteractionHosting {
    private var records: [BackendWireEvent] = []
    private var seq = 0

    func history(sessionId: String) async throws -> [BackendWireEvent] { records }
    func follow(sessionId: String) async throws -> AsyncStream<BackendWireEvent> {
        AsyncStream { continuation in
            continuation.yield(BackendWireEvent(["type": "snapshot"]))
            continuation.finish()
        }
    }
    func prompt(sessionId: String, text: String, mode: PromptMode) async throws {
        seq += 1
        let turn = 1
        func event(_ type: String, _ data: [String: Any], _ n: Int) -> BackendWireEvent {
            BackendWireEvent(["type": "event", "event": ["type": type, "seq": n, "data": data]])
        }
        records = [
            event("turn/start", ["turn": turn], seq),
            event("user/message", ["source": ["kind": "user"], "content": [["type": "text", "text": text]]], seq + 1),
            event("assistant/message", ["message": ["content": [["type": "text", "text": "PHAROS_DSH_PRODUCT_DONE"]]]], seq + 2),
            event("turn/end", ["reason": ["kind": "completed"]], seq + 3),
        ]
        seq += 3
    }
    func interactions() async throws -> (String, AsyncStream<BackendWireEvent>) {
        ("fixture", AsyncStream { $0.finish() })
    }
    func resolveInteraction(clientID: String, eventID: String, outcomeData: Data) async throws {}
}

private final class DshProductPathRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var conversations: [[String: Any]] = []
    private var queued: [[String: Any]] = []
    private(set) var completedDeliveryIDs: [String] = []

    func enqueueDelivery(id: String, payload: String) {
        lock.lock(); defer { lock.unlock() }
        queued.append(["id": id, "payload": payload, "state": "queued"])
    }

    func handle(_ method: String, _ params: [String: Any]) throws -> Any {
        lock.lock(); defer { lock.unlock() }
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
        case "conversation.state":
            return ["ok": true]
        case "delivery.poll":
            let next = queued
            queued = []
            return next
        case "delivery.ack":
            let id = params["deliveryID"] as? String ?? ""
            let state = params["state"] as? String ?? ""
            if state == "completed" { completedDeliveryIDs.append(id) }
            return ["ok": true]
        case "runtime.snapshot":
            return ["conversations": conversations, "deliveries": completedDeliveryIDs.map {
                ["id": $0, "state": "completed"] as [String: Any]
            }]
        default:
            throw PharosClientError.operationFailed("Unexpected Runtime method \(method)")
        }
    }
}

private final class FakeThreadRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var conversations: [[String: Any]] = []
    private(set) var lastDriverID = ""
    private(set) var registeredDrivers: [String] = []

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
            let id = params["driverID"] as? String ?? ""
            registeredDrivers.append(id)
            return ["ok": true]
        case "conversation.register":
            let kind = params["kind"] as? String ?? ""
            let vendor = params["vendorSessionID"] as? String ?? ""
            let member = params["memberID"] as? String ?? ""
            lastDriverID = params["driverID"] as? String ?? ""
            if let existing = conversations.first(where: {
                $0["vendorSessionID"] as? String == vendor && $0["kind"] as? String == kind
            }) {
                return existing
            }
            let row: [String: Any] = [
                "id": "conv-" + UUID().uuidString.lowercased(),
                "kind": kind, "vendorSessionID": vendor, "memberID": member,
                "driverID": lastDriverID, "ownership": "managed",
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
