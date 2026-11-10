import XCTest
import AppKit
import SwiftUI
import WebKit
import PharosClientKit
import PharosMeshCore
import PharosMeshProtocol
@testable import PharosRuntime
@testable import Pharos

private actor RetainedDshHostFixture: DshSessionHosting, DshInteractionHosting {
    private(set) var reads = 0
    func history(sessionId: String) async throws -> [BackendWireEvent] { reads += 1; return [] }
    func follow(sessionId: String) async throws -> AsyncStream<BackendWireEvent> {
        AsyncStream { _ in }
    }
    func prompt(sessionId: String, text: String, mode: PromptMode) async throws {}
    func interactions() async throws -> (String, AsyncStream<BackendWireEvent>) {
        ("fixture", AsyncStream { _ in })
    }
    func resolveInteraction(clientID: String, eventID: String, outcomeData: Data) async throws {}
}

private func waitForOwnedFixtureWorker(_ semaphore: DispatchSemaphore) {
    _ = semaphore.wait(timeout: .now() + 7)
}

private final class FixtureGatewayBehavior: @unchecked Sendable {
    private let lock = NSLock()
    private var supportsInspection = false
    func setInspection(_ value: Bool) { lock.withLock { supportsInspection = value } }
    var inspectionEnabled: Bool { lock.withLock { supportsInspection } }
}

final class DesktopPharosClientServiceTests: XCTestCase {
    @MainActor
    func testPeerSessionRemainsBoundToPeerWhenInventoryDisconnects() async throws {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/peer-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let domain = "me.pai.pharos.test.peer-route.\(UUID().uuidString)"
        let hosts = base.appendingPathComponent("hosts.json")
        let values = ["PHAROS_HOSTS_FILE": hosts.path, "PHAROS_PREFERENCES_DOMAIN": domain,
                      "PHAROS_REGISTRY": base.appendingPathComponent("projects.json").path,
                      "PHAROS_MESH_DIR": base.appendingPathComponent("mesh").path,
                      "PHAROS_MESH_DATA_DIR": base.appendingPathComponent("data").path,
                      "PHAROS_LEGACY_BROKER": "1", "PHAROS_DISABLE_NOTIFICATIONS": "1",
                      "PHAROS_DISABLE_BACKGROUND_TASKS": "1"]
        var previous: [String: String] = [:]
        for (key, value) in values { if let old = getenv(key) { previous[key] = String(cString: old) }; setenv(key, value, 1) }
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            for key in values.keys { if let old = previous[key] { setenv(key, old, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: base)
        }
        let deviceID = UUID()
        try LightHostsFile(url: hosts).save(.init(ssh: ["remote-test": "-disabled"],
            peerDeviceIDs: ["remote-test": deviceID.uuidString]))
        let id = "peer:\(deviceID.uuidString.lowercased()):codex:session"
        let session = ClientSessionSummary(sessionId: id, machineId: "host", agentType: "codex",
                                           workspacePath: "/remote", title: "test", status: .idle, avatarSeed: "test")
        let dshID = "peer:\(deviceID.uuidString.lowercased()):codex:dsh:session"
        let dshSession = ClientSessionSummary(sessionId: dshID, machineId: "host", agentType: "dsh",
                                              workspacePath: "/remote", title: "dsh", status: .idle, avatarSeed: "dsh")
        let turn = CanonicalTurn(turnId: "turn", sessionId: id, turnNumber: 1, status: .completed)
        let peer = MockPharosClientService(sessions: [session, dshSession], sessionHistories: [id: [turn]])
        let projectID = UUID()
        await peer.setHostProjectCheckouts([projectID: "/remote"])
        await peer.setHostAgentInventory(.init(supportedAgents: ["codex", "dsh", "agy"], unavailableAgents: []))
        let service = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport(),
            peerServiceFactory: { target, prefix in
                XCTAssertEqual(target.rawValue, deviceID)
                XCTAssertEqual(prefix, "peer:\(deviceID.uuidString.lowercased()):codex:")
                return peer
            })
        await service.refreshRemoteSessionsIfNeeded(force: true)
        XCTAssertEqual(service.peerSnapshots["remote-test"]?.count, 2)
        XCTAssertTrue(service.peerSnapshots["remote-test"]?.allSatisfy { $0.connectionRoute == "peer" } == true)
        XCTAssertEqual(service.remoteProjectPaths["remote-test"]?[projectID], "/remote")
        let history = try await service.fetchSessionHistory(sessionId: id)
        XCTAssertEqual(history.first?.turnId, "turn")
        try LightHostsFile(url: hosts).save(.init(peerDeviceIDs: ["remote-test": deviceID.uuidString]))
        await peer.setHostAgentInventory(.init(supportedAgents: ["codex", "dsh", "agy"], unavailableAgents: ["dsh"]))
        await service.refreshRemoteSessionsIfNeeded(force: true)
        XCTAssertEqual(service.remoteProjectPaths["remote-test"]?[projectID], "/remote")
        let dshStale = service.peerSnapshots["remote-test"]?.first { $0.sessionId == dshID }
        let codexFresh = service.peerSnapshots["remote-test"]?.first { $0.sessionId == id }
        XCTAssertEqual(dshStale?.inventoryStale, true)
        XCTAssertEqual(codexFresh?.inventoryStale, false)
        let providerIssues = await service.fetchSessionInventoryIssues()
        XCTAssertTrue(providerIssues.contains { $0.host == "remote-test" && $0.agent == "DSH via Peer" })
        await peer.setBackendFailure(backend: "peer", reason: "offline")
        await service.refreshRemoteSessionsIfNeeded(force: true)
        XCTAssertEqual(service.remoteProjectPaths["remote-test"]?[projectID], "/remote", "Project discovery must not depend on agent inventory")
        XCTAssertEqual(service.peerSnapshots["remote-test"]?.first?.inventoryStale, true)
        XCTAssertEqual(service.peerSnapshots["remote-test"]?.first?.status, .unknown)
        let offlineIssues = await service.fetchSessionInventoryIssues()
        XCTAssertTrue(offlineIssues.contains { $0.host == "remote-test" && $0.agent == "Peer" })
        await peer.setHostProjectCheckouts(nil)
        await service.refreshRemoteSessionsIfNeeded(force: true)
        XCTAssertNil(service.remoteProjectPaths["remote-test"])
        XCTAssertTrue(service.remoteProjectPathsUnavailable.contains("remote-test"))
        do { _ = try await service.sendSessionMessage(sessionId: id, text: "do not replay"); XCTFail("offline peer must fail") }
        catch { XCTAssertEqual(error as? PharosClientError, .backendUnreachable(backend: "peer", reason: "offline")) }
    }

    @MainActor
    func testThreadUncertainReceiptSurvivesDesktopHistoryReload() async throws {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/uncertain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let values = ["PHAROS_MESH_DIR": base.appendingPathComponent("mesh").path,
                      "PHAROS_MESH_DATA_DIR": base.appendingPathComponent("data").path,
                      "PHAROS_REGISTRY": base.appendingPathComponent("projects.json").path,
                      "PHAROS_PREFERENCES_DOMAIN": "me.pai.pharos.test.\(UUID().uuidString)",
                      "PHAROS_LEGACY_BROKER": "1", "PHAROS_DISABLE_NOTIFICATIONS": "1",
                      "PHAROS_DISABLE_BACKGROUND_TASKS": "1"]
        var old: [String: String] = [:]
        for key in values.keys { if let value = getenv(key) { old[key] = String(cString: value) } }
        for (key, value) in values { setenv(key, value, 1) }
        defer {
            for key in values.keys { if let value = old[key] { setenv(key, value, 1) } else { unsetenv(key) } }
            UserDefaults(suiteName: values["PHAROS_PREFERENCES_DOMAIN"]!)?.removePersistentDomain(forName: values["PHAROS_PREFERENCES_DOMAIN"]!)
            try? FileManager.default.removeItem(at: base)
        }
        let broker = MeshBroker(runtimeDeliverySink: { _, _ in .uncertain })
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "uncertain", nick: "agent", session: "agent-1", kind: "dsh")).ok)
        let service = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport(), brokerRequest: { broker.process($0) })
        let rooms = try await service.fetchThreads()
        let room = try XCTUnwrap(rooms.first { $0.title == "uncertain" })
        let sent = try await service.sendThreadMessage(threadId: room.id, text: "@agent hello")
        XCTAssertEqual(sent.receipt, .deliveryUncertain)
        let history = try await service.fetchThreadMessages(threadId: room.id)
        XCTAssertEqual(history.first?.id, sent.id)
        XCTAssertEqual(history.first?.receipt, .deliveryUncertain)
        XCTAssertTrue((broker.process(MeshRequest(cmd: "recv", memberID: "agent-1", limit: 10)).messages ?? []).isEmpty)
    }

    @MainActor
    func testRemoteInventoryRefreshesEarlyAfterSharedConnectionCloses() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(DesktopPharosClientService.shouldRefreshRemoteInventory(isRefreshing: false, lastRefresh: now,
                                                                                now: now.addingTimeInterval(2), hasClosedConnection: false))
        XCTAssertTrue(DesktopPharosClientService.shouldRefreshRemoteInventory(isRefreshing: false, lastRefresh: now,
                                                                               now: now.addingTimeInterval(2), hasClosedConnection: true))
        XCTAssertFalse(DesktopPharosClientService.shouldRefreshRemoteInventory(isRefreshing: true, lastRefresh: now,
                                                                                now: now.addingTimeInterval(2), hasClosedConnection: true))
        XCTAssertTrue(DesktopPharosClientService.shouldRefreshRemoteInventory(isRefreshing: false, lastRefresh: now,
                                                                               now: now.addingTimeInterval(61), hasClosedConnection: false))
    }

    @MainActor
    func testRemoteDshInventoryFailureRetainsOpenServiceUntilSuccessfulRefresh() async throws {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/dsh-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let domain = "me.pai.pharos.test.dsh-retention.\(UUID().uuidString)"
        let overrides = ["PHAROS_PREFERENCES_DOMAIN": domain, "PHAROS_REGISTRY": base.appendingPathComponent("projects.json").path,
                         "PHAROS_MESH_DIR": base.appendingPathComponent("mesh").path,
                         "PHAROS_MESH_DATA_DIR": base.appendingPathComponent("mesh-data").path,
                         "PHAROS_LEGACY_BROKER": "1", "PHAROS_DISABLE_NOTIFICATIONS": "1", "PHAROS_DISABLE_BACKGROUND_TASKS": "1"]
        var previous: [String: String] = [:]
        for (key, value) in overrides { if let old = getenv(key) { previous[key] = String(cString: old) }; setenv(key, value, 1) }
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            for key in overrides.keys { if let old = previous[key] { setenv(key, old, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: base)
        }
        let host = RetainedDshHostFixture()
        let service = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport())
        let id = RemoteCodexTransport.prefix("test-host").replacingOccurrences(of: ":codex:", with: ":dsh:") + "session-one"
        service.applyRemoteDshInventory(host: "test-host", destination: "host-a", result: .success([.init(app: "dsh", id: "session-one")])) { host }
        _ = try await service.fetchSessionHistory(sessionId: id)
        service.applyRemoteDshInventory(host: "test-host", destination: "host-a", result: .failure(NSError(domain: "PharosACP", code: 1))) {
            XCTFail("Failure should not create another Host"); return host
        }
        _ = try await service.fetchSessionHistory(sessionId: id)
        XCTAssertEqual(service.remoteDshSnapshots["test-host"]?.first?.inventoryStale, true)
        let reads = await host.reads
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(service.remoteDshInventoryDiagnostics["test-host"]?.hasPrefix("error-PharosACP-1") == true)
        service.applyRemoteDshInventory(host: "test-host", destination: "host-a", result: .success([.init(app: "dsh", id: "session-one")])) {
            XCTFail("Recovery should reuse the open Host"); return host
        }
        XCTAssertNil(service.remoteDshSnapshots["test-host"]?.first?.inventoryStale)
        _ = try await service.fetchSessionHistory(sessionId: id)
        let recoveredReads = await host.reads
        XCTAssertEqual(recoveredReads, 3)
        service.applyRemoteDshInventory(host: "test-host", destination: "host-a", result: .success([])) { host }
        XCTAssertTrue(service.remoteDshSnapshots["test-host"]?.isEmpty == true)
        do { _ = try await service.fetchSessionHistory(sessionId: id); XCTFail("Successful empty inventory must remove old binding") }
        catch PharosClientError.backendUnreachable { }
        service.applyRemoteDshInventory(host: "test-host", destination: "host-a", result: .success([.init(app: "dsh", id: "session-one")])) { host }
        XCTAssertNil(service.remoteDshSnapshots["test-host"]?.first?.inventoryStale)
        service.applyRemoteDshInventory(host: "test-host", destination: "host-b", result: .failure(NSError(domain: "PharosACP", code: 1))) { host }
        do { _ = try await service.fetchSessionHistory(sessionId: id); XCTFail("Changed destination must not retain old binding") }
        catch PharosClientError.backendUnreachable { }
    }

    @MainActor
    func testRealRemoteDshRetainedAfterInventoryFailureWhenEnabled() async throws {
        guard let destination = ProcessInfo.processInfo.environment["PHAROS_REMOTE_DSH_UI_TODO_TEST"],
              let rawID = ProcessInfo.processInfo.environment["PHAROS_DSH_UI_TODO_SESSION"] else {
            throw XCTSkip("Set the remote Host and retained DSH test Session")
        }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/dsh-retention-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let domain = "me.pai.pharos.test.dsh-retention.\(UUID().uuidString)"
        let overrides = ["PHAROS_PREFERENCES_DOMAIN": domain, "PHAROS_REGISTRY": base.appendingPathComponent("projects.json").path,
                         "PHAROS_MESH_DIR": base.appendingPathComponent("mesh").path,
                         "PHAROS_MESH_DATA_DIR": base.appendingPathComponent("mesh-data").path,
                         "PHAROS_LEGACY_BROKER": "1", "PHAROS_DISABLE_NOTIFICATIONS": "1", "PHAROS_DISABLE_BACKGROUND_TASKS": "1"]
        var previous: [String: String] = [:]
        for (key, value) in overrides { if let old = getenv(key) { previous[key] = String(cString: old) }; setenv(key, value, 1) }
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            for key in overrides.keys { if let old = previous[key] { setenv(key, old, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: base)
        }
        let service = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport())
        let sessionID = RemoteCodexTransport.prefix("remote-test").replacingOccurrences(of: ":codex:", with: ":dsh:") + rawID
        service.applyRemoteDshInventory(host: "remote-test", destination: destination, result: .success([.init(app: "dsh", id: rawID)])) {
            DshWebHost(remoteHost: destination)
        }
        let before: [CanonicalTurn]
        do { before = try await service.fetchSessionHistory(sessionId: sessionID) }
        catch { return XCTFail("Initial remote history failed: \(String(reflecting: type(of: error))) code=\((error as NSError).code)") }
        XCTAssertTrue(before.contains { $0.status == .completed })
        service.applyRemoteDshInventory(host: "remote-test", destination: destination, result: .failure(NSError(domain: "PharosACP", code: 1))) {
            XCTFail("The existing remote Host must be retained"); return DshWebHost(remoteHost: destination)
        }
        XCTAssertEqual(service.remoteDshSnapshots["remote-test"]?.first?.inventoryStale, true)
        let after: [CanonicalTurn]
        do { after = try await service.fetchSessionHistory(sessionId: sessionID) }
        catch { return XCTFail("Retained remote history failed: \(String(reflecting: type(of: error))) code=\((error as NSError).code)") }
        XCTAssertTrue(after.contains { $0.status == .completed })
        print("Real remote DSH inventory failure: history-before=\(before.count) history-after=\(after.count) cached-stale=true")
    }

    @MainActor
    func testRealDesktopReopensClosedSharedDshConnectionWhenEnabled() async throws {
        guard let destination = ProcessInfo.processInfo.environment["PHAROS_REMOTE_DSH_UI_TODO_TEST"] else {
            throw XCTSkip("Set the configured remote Host")
        }
        let agent = ProcessInfo.processInfo.environment["PHAROS_REMOTE_RECONNECT_AGENT"] ?? "dsh"
        let rawID = ProcessInfo.processInfo.environment["PHAROS_DSH_UI_TODO_SESSION"]
        let configured = LightHostsFile.standard().load().ssh
        guard let label = configured.first(where: { $0.key == destination || $0.value == destination })?.key else {
            throw XCTSkip("The remote Host is not configured")
        }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/dsh-reconnect-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let domain = "me.pai.pharos.test.dsh-reconnect.\(UUID().uuidString)"
        let overrides = ["PHAROS_PREFERENCES_DOMAIN": domain, "PHAROS_REGISTRY": base.appendingPathComponent("projects.json").path,
                         "PHAROS_MESH_DIR": base.appendingPathComponent("mesh").path,
                         "PHAROS_MESH_DATA_DIR": base.appendingPathComponent("mesh-data").path,
                         "PHAROS_LEGACY_BROKER": "1", "PHAROS_DISABLE_NOTIFICATIONS": "1", "PHAROS_DISABLE_BACKGROUND_TASKS": "1"]
        var previous: [String: String] = [:]
        for (key, value) in overrides { if let old = getenv(key) { previous[key] = String(cString: old) }; setenv(key, value, 1) }
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            for key in overrides.keys { if let old = previous[key] { setenv(key, old, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: base)
        }
        let service = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport())
        let before = try await service.fetchSessions()
        var target: ClientSessionSummary?
        for candidate in before where candidate.machineId == label && candidate.agentType == agent {
            if agent == "dsh", let rawID, !candidate.id.hasSuffix(rawID) { continue }
            if let turns = try? await service.fetchSessionHistory(sessionId: candidate.id), !turns.isEmpty {
                target = candidate; break
            }
        }
        guard let target else { throw XCTSkip("No remote \(agent) Session with readable history found") }
        let viewModel = SessionConversationViewModel(sessionId: target.id, clientService: service)
        await viewModel.loadHistory()
        let history = viewModel.turns
        XCTAssertFalse(history.isEmpty)
        func historyRequests() -> Int {
            agent == "dsh" ? service.remoteDshHistoryRequestCounts[target.id, default: 0]
                           : service.remoteCodexHistoryRequestCounts[target.id, default: 0]
        }
        let beforeRequests = historyRequests()
        let original = try XCTUnwrap(service.remoteConnections[label])
        original.close()
        let refreshed = try await service.fetchSessions()
        let replacement = try XCTUnwrap(service.remoteConnections[label], "A new shared connection should be installed")
        XCTAssertFalse(original === replacement)
        XCTAssertTrue(replacement.isRunning)
        XCTAssertTrue(refreshed.contains { $0.id == target.id && $0.inventoryStale != true })
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if historyRequests() > beforeRequests && !viewModel.isLoadingHistory { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(historyRequests(), beforeRequests,
                             "The open Session must automatically request history after reconnecting")
        XCTAssertFalse(viewModel.isLoadingHistory)
        XCTAssertEqual(viewModel.turns.count, history.count)
        XCTAssertNil(viewModel.activeError)
        print("Desktop shared SSH recovery: agent=\(agent) prior=\(history.count) reloaded=\(viewModel.turns.count) automatic=true fresh=true")
    }

    @MainActor
    func testRemoteDshNodeRequiresExactFreshIdentityAndRemoteOrigin() {
        let id = UUID().uuidString.lowercased()
        let identity = RemoteMeshIdentity.Identity(nodeID: id, host: "Remote-Mac.local")
        let now = Date(timeIntervalSince1970: 1000)
        let node = MeshNodeInfo(id: id, host: "remote-mac.local.", tailscaleIP: nil, lastSeen: 995, brokerLocal: nil)
        XCTAssertEqual(DesktopPharosClientService.matchedRemoteDshNode(identity: identity, nodes: [node], now: now)?.id, id)
        XCTAssertNil(DesktopPharosClientService.matchedRemoteDshNode(identity: identity, nodes: [node, node], now: now))
        var changed = node; changed.host = "other"
        XCTAssertNil(DesktopPharosClientService.matchedRemoteDshNode(identity: identity, nodes: [changed], now: now))
        changed = node; changed.brokerLocal = true
        XCTAssertNil(DesktopPharosClientService.matchedRemoteDshNode(identity: identity, nodes: [changed], now: now))
        changed = node; changed.lastSeen = 929
        XCTAssertNil(DesktopPharosClientService.matchedRemoteDshNode(identity: identity, nodes: [changed], now: now))
        changed = node; changed.lastSeen = 1006
        XCTAssertNil(DesktopPharosClientService.matchedRemoteDshNode(identity: identity, nodes: [changed], now: now))
    }

    func testRemoteMeshIdentityRejectsMalformedOrUnboundedValues() throws {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["nodeID": id, "host": "example.local"])
        let value = try RemoteMeshIdentity.decode(data)
        XCTAssertEqual(value.nodeID, id.lowercased())
        XCTAssertEqual(value.host, "example.local")
        for payload in [["nodeID": "not-a-uuid", "host": "example.local"],
                        ["nodeID": id, "host": "example\nother"],
                        ["nodeID": id, "host": String(repeating: "x", count: 256)]] {
            XCTAssertThrowsError(try RemoteMeshIdentity.decode(JSONSerialization.data(withJSONObject: payload)))
        }
    }

    @MainActor
    func testRemoteDshInspectionRejectsWrongIdentityOrInvalidPayload() {
        let good = #"{"jsonrpc":"2.0","id":"rpc","result":{"eligible":[true,false]}}"#
        XCTAssertEqual(DesktopPharosClientService.decodeRemoteDshInspection(good, expectedID: "rpc", count: 2), [true, false])
        XCTAssertNil(DesktopPharosClientService.decodeRemoteDshInspection(good, expectedID: "other", count: 2))
        XCTAssertNil(DesktopPharosClientService.decodeRemoteDshInspection(good, expectedID: "rpc", count: 1))
        XCTAssertNil(DesktopPharosClientService.decodeRemoteDshInspection(#"{"jsonrpc":"2.0","id":"rpc","result":{"eligible":[1,0]}}"#, expectedID: "rpc", count: 2))
        XCTAssertNil(DesktopPharosClientService.decodeRemoteDshInspection(#"{"jsonrpc":"2.0","id":"rpc","error":{"code":-32601}}"#, expectedID: "rpc", count: 2))
    }

    func testRealRemoteMeshIdentityWhenEnabled() async throws {
        guard let host = ProcessInfo.processInfo.environment["PHAROS_REMOTE_MESH_IDENTITY_TEST"], !host.isEmpty else {
            throw XCTSkip("Set PHAROS_REMOTE_MESH_IDENTITY_TEST to read an existing node identity")
        }
        let connection = try await Task.detached { try SharedSSHConnection(destination: host) }.value
        defer { connection.close() }
        let identity = try await Task.detached { try RemoteMeshIdentity.read(connection: connection) }.value
        XCTAssertNotNil(UUID(uuidString: identity.nodeID))
        XCTAssertFalse(identity.host.isEmpty)
        print("Remote Mesh identity: valid-node-id=true hostname-present=true")
    }

    @MainActor
    func testRemoteDshBindingWithOwnedNodeFixtureWhenEnabled() async throws {
        guard let destination = ProcessInfo.processInfo.environment["PHAROS_REMOTE_DSH_BIND_FIXTURE"], !destination.isEmpty else {
            throw XCTSkip("Set PHAROS_REMOTE_DSH_BIND_FIXTURE to an SSH host for an isolated routing fixture")
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/remote-dsh-bind-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = "me.pai.pharos.test.remote-dsh-bind.\(UUID().uuidString)"
        let socket = root.appendingPathComponent("runtime.sock")
        let overrides = ["PHAROS_PREFERENCES_DOMAIN": domain, "PHAROS_REGISTRY": root.appendingPathComponent("projects.json").path,
            "PHAROS_HOSTS_FILE": root.appendingPathComponent("hosts.json").path, "PHAROS_MESH_DIR": root.appendingPathComponent("mesh").path,
            "PHAROS_MESH_DATA_DIR": root.appendingPathComponent("mesh-data").path, "PHAROS_AGENT_RUNTIME_SOCKET": socket.path,
            "PHAROS_LEGACY_BROKER": "1", "PHAROS_DISABLE_NOTIFICATIONS": "1", "PHAROS_DISABLE_BACKGROUND_TASKS": "1"]
        var old: [String: String] = [:]
        for (key, value) in overrides { if let prior = getenv(key) { old[key] = String(cString: prior) }; setenv(key, value, 1) }
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            for key in overrides.keys { if let prior = old[key] { setenv(key, prior, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: root)
        }
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("rust/target/debug/pharos-meshd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build pharos-meshd first") }
        let process = Process(); process.executableURL = binary
        process.arguments = ["--socket", socket.path, "--data-dir", root.appendingPathComponent("runtime-data").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: socket.path) { break }; try await Task.sleep(for: .milliseconds(50)) }
        let label = "pharos-remote-dsh-fixture"
        try LightHostsFile(url: root.appendingPathComponent("hosts.json")).save(LightHostsConfig(ssh: [label: destination]))
        let token = String(repeating: "f", count: 64)
        try FileManager.default.createDirectory(at: MeshPaths.dataDirectory, withIntermediateDirectories: true)
        try token.write(to: MeshPaths.brokerControlTokenFile, atomically: true, encoding: .utf8)
        let broker = MeshBroker(runtimeDeliverySink: MeshRuntimeDeliveryBridge.submit)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "create", room: "remote-fixture")).ok)
        let service = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport(), brokerRequest: { broker.process($0) })
        _ = try await service.fetchSessions()
        let connection = try XCTUnwrap(service.remoteConnections[label])
        let identity = try await Task.detached { try RemoteMeshIdentity.read(connection: connection) }.value
        XCTAssertTrue(broker.process(MeshRequest(cmd: "node-heartbeat", memberID: identity.nodeID, host: identity.host, authToken: token), trustedLocal: false).ok)
        let session = "session-fixture-" + UUID().uuidString
        let runtimeID = UUID().uuidString
        func runtime(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": runtimeID, "method": method, "params": params])
            let reply = try AgentRuntimeClient.sendLocalDriverRequest(String(decoding: data, as: UTF8.self))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            return try XCTUnwrap(json["result"] as? [String: Any])
        }
        _ = try runtime("driver.register", ["driverID": "fixture-dsh", "kind": "dsh", "capabilities": ["delivery.poll", "mesh.reply-once-v1"]])
        let registered = try runtime("conversation.register", ["driverID": "fixture-dsh", "kind": "dsh", "vendorSessionID": session, "memberID": session])
        let conversation = try XCTUnwrap(registered["id"] as? String)
        _ = try runtime("conversation.state", ["conversationID": conversation, "presence": "online", "activity": "idle", "attention": "none", "persistence": "persistent", "source": "nativeProtocol", "sequence": 1])
        service.applyRemoteDshInventory(host: label, destination: destination, result: .success([.init(app: "dsh", id: session, cwd: "/tmp")])) { RetainedDshHostFixture() }
        let behavior = FixtureGatewayBehavior()
        let workerStopped = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            defer { workerStopped.signal() }
            var nextHeartbeat = Date.distantPast
            while !Task.isCancelled {
                if Date() >= nextHeartbeat {
                    let beat = #"{"jsonrpc":"2.0","id":"beat","method":"driver.heartbeat","params":{"driverID":"fixture-dsh"}}"#
                    _ = try? AgentRuntimeClient.sendLocalDriverRequest(beat)
                    _ = broker.process(MeshRequest(cmd: "node-heartbeat", memberID: identity.nodeID, host: identity.host, authToken: token), trustedLocal: false)
                    nextHeartbeat = Date().addingTimeInterval(3)
                }
                if let command = broker.process(MeshRequest(cmd: "node-command-next", nodeID: identity.nodeID)).command,
                   command.action == .agentRPC, let payload = command.payload {
                    let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
                    let oldNode = object?["method"] as? String == "delivery.inspect-dsh-bindings" && !behavior.inspectionEnabled
                    let result = oldNode ? nil : try? AgentRuntimeClient.send(payload)
                    _ = broker.process(MeshRequest(cmd: "node-command-update", state: result == nil ? "failed" : "succeeded",
                        payload: result, nodeID: identity.nodeID, commandID: command.id))
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        defer { worker.cancel(); waitForOwnedFixtureWorker(workerStopped) }
        let sessionID = RemoteCodexTransport.prefix(label).replacingOccurrences(of: ":codex:", with: ":dsh:") + session
        let oldNodeCandidates = await service.threadSessionBindingCandidates()
        XCTAssertFalse(oldNodeCandidates.contains { $0.id == sessionID }, "An older node must not expose an unverified binding")
        behavior.setInspection(true)
        let candidates = await service.threadSessionBindingCandidates()
        XCTAssertTrue(candidates.contains { $0.id == sessionID })
        _ = try runtime("conversation.state", ["conversationID": conversation, "presence": "offline", "activity": "idle", "attention": "none", "persistence": "persistent", "source": "nativeProtocol", "sequence": 2])
        do {
            try await service.bindThreadSession(threadId: "remote-fixture", sessionId: sessionID, nickname: "agent")
            XCTFail("An offline Session must not be bound")
        } catch { }
        XCTAssertFalse((broker.process(MeshRequest(cmd: "who", room: "remote-fixture")).members ?? []).contains { $0.nick == "agent" })
        _ = try runtime("driver.register", ["driverID": "fixture-dsh", "kind": "dsh", "capabilities": ["delivery.poll", "mesh.reply-once-v1"]])
        _ = try runtime("conversation.state", ["conversationID": conversation, "presence": "online", "activity": "idle", "attention": "none", "persistence": "persistent", "source": "nativeProtocol", "sequence": 3])
        _ = NSApplication.shared
        let view = NSHostingView(rootView: PharosMainShellView(clientService: service))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 200, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        func webView(_ value: NSView) -> WKWebView? {
            if let web = value as? WKWebView { return web }
            return value.subviews.lazy.compactMap(webView).first
        }
        let web = try XCTUnwrap(webView(view))
        let quoted = String(decoding: try JSONSerialization.data(withJSONObject: [sessionID]), as: UTF8.self)
        let deadline = ContinuousClock.now.advanced(by: .seconds(35))
        var submitted = false
        while ContinuousClock.now < deadline {
            let value = try? await web.evaluateJavaScript("""
                (() => { const tab = document.querySelector('[data-tab=threads]'); if (!tab) return false;
                  if (tab.getAttribute('aria-selected') !== 'true') { tab.click(); return false; }
                  const row = [...document.querySelectorAll('[data-select]')].find(x => x.dataset.select === 'remote-fixture');
                  if (!row) return false; if (row.getAttribute('aria-current') !== 'true') { row.click(); return false; }
                  if (document.querySelector('.gb-app').classList.contains('gb-no-details')) { document.querySelector('[data-action=details]').click(); return false; }
                  const select = document.querySelector('[data-action=threadBindingSession]'), name = document.querySelector('[data-action=threadBindingNickname]'), button = document.querySelector('[data-action=bindThreadSession]');
                  if (!select || !name || !button || ![...select.options].some(x => x.value === \(quoted)[0])) return false;
                  select.value = \(quoted)[0]; select.dispatchEvent(new Event('change', {bubbles:true})); name.value = 'agent'; name.dispatchEvent(new Event('input', {bubbles:true})); button.click(); return true; })()
                """)
            if value as? Bool == true { submitted = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(submitted, "The remote fixture Session must be offered in the Thread panel")
        while submitted && ContinuousClock.now < deadline {
            if (broker.process(MeshRequest(cmd: "who", room: "remote-fixture")).members ?? []).contains(where: { $0.nick == "agent" }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let member = try XCTUnwrap(broker.process(MeshRequest(cmd: "who", room: "remote-fixture")).members?.first { $0.nick == "agent" })
        XCTAssertEqual(member.nodeID, identity.nodeID)
        XCTAssertEqual(member.host, identity.host)
        XCTAssertEqual(member.session, session)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "remote-fixture", nick: "human", memberID: "human", session: "human", kind: "human")).ok)
        let sent = await Task.detached { broker.process(MeshRequest(cmd: "say", room: "remote-fixture", nick: "human", memberID: "human", text: "@agent fixture", to: ["agent"])) }.value
        XCTAssertTrue(sent.ok)
        let pollData = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "poll", "method": "delivery.poll", "params": ["conversationID": conversation]])
        let pollRaw = try AgentRuntimeClient.sendLocalDriverRequest(String(decoding: pollData, as: UTF8.self))
        let poll = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(pollRaw.utf8)) as? [String: Any])
        let deliveries = try XCTUnwrap(poll["result"] as? [[String: Any]])
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertTrue((deliveries.first?["payload"] as? String)?.contains("@agent fixture") == true)
        XCTAssertTrue((broker.process(MeshRequest(cmd: "recv", memberID: session, limit: 10)).messages ?? []).isEmpty)
        print("Remote DSH binding fixture: real-ssh-identity=true simulated-node=true old-node-hidden=true offline-rejected=true ui-submitted=\(submitted) bound=true runtime-delivery-count=\(deliveries.count)")
    }

    @MainActor
    func testDshBindingRequiresExactLiveReplyCapableRoute() {
        let good: [String: Any] = ["memberID": "session-one", "vendorSessionID": "session-one", "kind": "dsh", "eligible": true, "replyCapable": true]
        XCTAssertEqual(DesktopPharosClientService.availableDshBindingID(good), "session-one")
        var route = good; route["eligible"] = false
        XCTAssertNil(DesktopPharosClientService.availableDshBindingID(route))
        route = good; route["replyCapable"] = false
        XCTAssertNil(DesktopPharosClientService.availableDshBindingID(route))
        route = good; route["vendorSessionID"] = "different"
        XCTAssertNil(DesktopPharosClientService.availableDshBindingID(route))
        route = good; route["kind"] = "codex"
        XCTAssertNil(DesktopPharosClientService.availableDshBindingID(route))
    }

    @MainActor
    func testCodexThreadBindingRejectsAmbiguousRuntimeOwnership() throws {
        XCTAssertTrue(DesktopPharosClientService.supportsCodexThreadBinding(status: ["transport": "rust-runtime"], hello: ["capabilities": ["codex-thread-id-v1"]]))
        XCTAssertFalse(DesktopPharosClientService.supportsCodexThreadBinding(status: ["transport": "rust-runtime"], hello: ["capabilities": []]))
        XCTAssertFalse(DesktopPharosClientService.supportsCodexThreadBinding(status: ["transport": "swift-runtime"], hello: ["capabilities": ["codex-thread-id-v1"]]))
        let managed: [String: Any] = ["id": "conversation", "vendorSessionID": "fork", "kind": "codex",
                                      "driverID": "codex:app-server", "ownership": "managed", "memberID": NSNull()]
        try DesktopPharosClientService.validateCodexRuntimeBeforeBinding([managed], providerID: "fork")
        XCTAssertEqual(try DesktopPharosClientService.verifiedCodexRuntimeMember([managed], providerID: "fork"), "fork")
        var explicit = managed; explicit["memberID"] = "existing-member"
        XCTAssertEqual(try DesktopPharosClientService.verifiedCodexRuntimeMember([explicit], providerID: "fork"), "existing-member")
        var otherOwner = managed; otherOwner["driverID"] = "another-driver"
        XCTAssertThrowsError(try DesktopPharosClientService.validateCodexRuntimeBeforeBinding([otherOwner], providerID: "fork"))
        XCTAssertThrowsError(try DesktopPharosClientService.validateCodexRuntimeBeforeBinding([managed, managed], providerID: "fork"))
        let conflict: [String: Any] = ["id": "other", "vendorSessionID": "other", "kind": "dsh", "memberID": "existing-member"]
        XCTAssertThrowsError(try DesktopPharosClientService.verifiedCodexRuntimeMember([explicit, conflict], providerID: "fork"))
        var missingID = managed; missingID.removeValue(forKey: "id")
        XCTAssertThrowsError(try DesktopPharosClientService.verifiedCodexRuntimeMember([missingID], providerID: "fork"))
    }

    @MainActor
    func testThreadBindingRequiresBrokerCapability() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/agy-capability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = "me.pai.pharos.test.agy-capability.\(UUID().uuidString)"
        let overrides = ["PHAROS_PREFERENCES_DOMAIN": domain, "PHAROS_MESH_DIR": root.path,
                         "PHAROS_MESH_DATA_DIR": root.appendingPathComponent("data").path,
                         "PHAROS_REGISTRY": root.appendingPathComponent("projects.json").path,
                         "PHAROS_HOSTS_FILE": root.appendingPathComponent("hosts.json").path,
                         "PHAROS_LEGACY_BROKER": "1", "PHAROS_DISABLE_NOTIFICATIONS": "1", "PHAROS_DISABLE_BACKGROUND_TASKS": "1"]
        var previous: [String: String] = [:]
        for (key, value) in overrides { if let prior = getenv(key) { previous[key] = String(cString: prior) }; setenv(key, value, 1) }
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            for key in overrides.keys { if let prior = previous[key] { setenv(key, prior, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: root)
        }
        let old = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport(),
                                             brokerRequest: { _ in MeshResponse(ok: true, capabilities: ["mesh-v2"]) })
        let broker = MeshBroker()
        let current = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport(), brokerRequest: { broker.process($0) })
        let oldSupport = await old.supportsThreadSessionBinding()
        let currentSupport = await current.supportsThreadSessionBinding()
        XCTAssertFalse(oldSupport)
        XCTAssertTrue(currentSupport)
    }

    @MainActor
    func testBrokerRetainsExplicitDistinctAgyMemberAndSessionBinding() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/agy-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = getenv("PHAROS_MESH_DIR").map { String(cString: $0) }
        let previousData = getenv("PHAROS_MESH_DATA_DIR").map { String(cString: $0) }
        setenv("PHAROS_MESH_DIR", root.path, 1)
        setenv("PHAROS_MESH_DATA_DIR", root.appendingPathComponent("data").path, 1)
        defer {
            if let previous { setenv("PHAROS_MESH_DIR", previous, 1) } else { unsetenv("PHAROS_MESH_DIR") }
            if let previousData { setenv("PHAROS_MESH_DATA_DIR", previousData, 1) } else { unsetenv("PHAROS_MESH_DATA_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        let broker = MeshBroker(loadPersistentState: true)
        XCTAssertEqual(broker.process(MeshRequest(cmd: "capabilities")).capabilities?.contains("thread-session-binding-v1"), true)
        let joined = broker.process(MeshRequest(cmd: "join", room: "room", nick: "agent", memberID: "member-uuid",
                                                session: "provider-id", host: "local", kind: "agy"))
        XCTAssertTrue(joined.ok)
        let member = try XCTUnwrap(broker.process(MeshRequest(cmd: "who", room: "room")).members?.first)
        XCTAssertEqual(member.id, "member-uuid")
        XCTAssertEqual(member.session, "provider-id")
        let rebind = broker.process(MeshRequest(cmd: "join", room: "room", nick: "agent", memberID: "member-uuid",
                                                session: "different-provider", host: "local", kind: "agy"))
        XCTAssertFalse(rebind.ok)
        let unchanged = try XCTUnwrap(broker.process(MeshRequest(cmd: "who", room: "room")).members?.first)
        XCTAssertEqual(unchanged.session, "provider-id")
        let reopened = MeshBroker(loadPersistentState: true)
        let restored = try XCTUnwrap(reopened.process(MeshRequest(cmd: "who", room: "room")).members?.first)
        XCTAssertEqual(restored.id, "member-uuid")
        XCTAssertEqual(restored.session, "provider-id")
        XCTAssertTrue(broker.process(MeshRequest(cmd: "create", room: "second")).ok)
        let unauthorized = broker.process(MeshRequest(cmd: "join-session", room: "second", nick: "agent", memberID: "member-uuid",
                                                      session: "provider-id", host: "local", kind: "agy"), trustedLocal: false)
        XCTAssertFalse(unauthorized.ok)
        XCTAssertFalse(broker.process(MeshRequest(cmd: "join-session", room: "second", nick: "agent", memberID: "member-uuid",
                                                  session: "provider-id", kind: "agy")).ok)
        XCTAssertFalse(broker.process(MeshRequest(cmd: "join-session", room: "second", nick: "agent", memberID: "member-uuid",
                                                  session: "provider-id", host: "local", kind: "unsupported")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join-session", room: "second", nick: "agent", memberID: "member-uuid",
                                                 session: "provider-id", host: "local", kind: "agy")).ok)
        let conflict = broker.process(MeshRequest(cmd: "join-session", room: "second", nick: "other", memberID: "other-member",
                                                  session: "provider-id", host: "local", kind: "agy"))
        XCTAssertFalse(conflict.ok)
        let collision = broker.process(MeshRequest(cmd: "join-session", room: "second", nick: "agent", memberID: "another",
                                                   session: "different-provider", host: "local", kind: "agy"))
        XCTAssertFalse(collision.ok)
        let secondIDs = Set((broker.process(MeshRequest(cmd: "who")).members ?? []).filter { $0.rooms.contains("second") }.map(\.id))
        XCTAssertEqual(secondIDs, ["member-uuid"])
        XCTAssertFalse(broker.process(MeshRequest(cmd: "join-session", room: "unknown", nick: "agent", memberID: "member-uuid",
                                                  session: "provider-id", host: "local", kind: "agy")).ok)
        try FileManager.default.createDirectory(at: MeshPaths.transcriptDir, withIntermediateDirectories: true)
        try Data().write(to: MeshPaths.transcript("history-only"))
        let emptyBroker = MeshBroker()
        XCTAssertTrue((emptyBroker.process(MeshRequest(cmd: "list")).rooms ?? []).contains { $0.name == "history-only" })
        XCTAssertTrue(emptyBroker.process(MeshRequest(cmd: "join-session", room: "history-only", nick: "agent", memberID: "member-x",
                                                      session: "provider-x", host: "local", kind: "agy")).ok)
    }

    @MainActor
    func testAgyThreadBindingRequiresExactLocalSessionAndMember() {
        let session = ClientSessionSummary(sessionId: "agy:provider-1", machineId: "local", agentType: "agy",
            workspacePath: "/work", title: "Agent", status: .unknown, avatarSeed: "x")
        let local = LightSelfHost(names: ["local"])
        func matching(_ member: MeshMemberInfo, _ session: ClientSessionSummary = session) -> Bool {
            !DesktopPharosClientService.explicitLocalAgyThreadBindings([session], members: ["provider-1": member], local: local).isEmpty
        }
        var member = MeshMemberInfo(id: "provider-1", nick: "agent", session: "provider-1", host: "local",
                                    kind: "agy", rooms: ["room"], lastSeen: 0)
        XCTAssertTrue(matching(member))
        member.host = "remote"; XCTAssertFalse(matching(member)); member.host = "local"
        member.session = "different"; XCTAssertFalse(matching(member)); member.session = "provider-1"
        member.kind = "dsh"; XCTAssertFalse(matching(member)); member.kind = "agy"
        member.rooms = []; XCTAssertFalse(matching(member)); member.rooms = ["room"]
        member.id = "other"; XCTAssertFalse(matching(member)); member.id = "provider-1"
        let remote = ClientSessionSummary(sessionId: "remote:a:agy:provider-1", machineId: "remote", agentType: "agy",
            workspacePath: "/work", title: "Agent", status: .unknown, avatarSeed: "x")
        XCTAssertFalse(matching(member, remote))
        let missingWorkspace = ClientSessionSummary(sessionId: "agy:provider-1", machineId: "local", agentType: "agy",
            workspacePath: "", title: "Agent", status: .unknown, avatarSeed: "x")
        XCTAssertFalse(matching(member, missingWorkspace))
        let independent = MeshMemberInfo(id: "member-uuid", nick: "agent", session: "provider-1", host: "local",
                                         kind: "agy", rooms: ["room"], lastSeen: 0)
        let explicit = DesktopPharosClientService.explicitLocalAgyThreadBindings([session], members: ["member-uuid": independent], local: local)
        XCTAssertEqual(explicit.count, 1)
        XCTAssertEqual(explicit.first?.memberID, "member-uuid")
        let ambiguous = DesktopPharosClientService.explicitLocalAgyThreadBindings([session], members: ["member-uuid": independent, "provider-1": member], local: local)
        XCTAssertTrue(ambiguous.isEmpty, "Two local members cannot both own one ACP Session")
    }

    @MainActor
    func testDshThreadBindingRequiresExactLocalSessionAndMember() {
        let session = ClientSessionSummary(sessionId: "dsh:session-1", machineId: "local", agentType: "dsh",
            workspacePath: "/work", title: "Agent", status: .unknown, avatarSeed: "x")
        let local = LightSelfHost(names: ["local"])
        func matching(_ member: MeshMemberInfo, _ session: ClientSessionSummary = session) -> Bool {
            !DesktopPharosClientService.explicitLocalDshThreadBindings([session], members: [member.id: member], local: local).isEmpty
        }
        var member = MeshMemberInfo(id: "session-1", nick: "agent", session: "session-1", host: "local",
                                    kind: "dsh", rooms: ["room"], lastSeen: 0)
        XCTAssertTrue(matching(member))
        member.host = "remote"; XCTAssertFalse(matching(member)); member.host = "local"
        member.session = "different"; member.id = "other"; XCTAssertFalse(matching(member))
        member.session = "session-1"; member.id = "session-1"
        member.kind = "agy"; XCTAssertFalse(matching(member)); member.kind = "dsh"
        member.rooms = []; XCTAssertFalse(matching(member)); member.rooms = ["room"]
        let ambiguous = DesktopPharosClientService.explicitLocalDshThreadBindings(
            [session],
            members: [
                "session-1": member,
                "also": MeshMemberInfo(id: "also", nick: "agent", session: "session-1", host: "local",
                                       kind: "dsh", rooms: ["room"], lastSeen: 0),
            ],
            local: local
        )
        XCTAssertTrue(ambiguous.isEmpty, "Two local members cannot both own one DSH Session")
    }

    func testRemoteProjectPathMapRejectsInvalidAndAmbiguousEntries() throws {
        let valid = UUID()
        let ambiguous = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let invalid = UUID()
        let payload: [String: Any] = ["paths": [
            valid.uuidString: "/work/a/../checkout",
            ambiguous.uuidString: "/one",
            ambiguous.uuidString.lowercased(): "/two",
            invalid.uuidString: "relative/path",
            "not-a-uuid": "/other"
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try RemoteProjectPaths.decode(data)
        XCTAssertEqual(decoded[valid], "/work/checkout")
        XCTAssertNil(decoded[ambiguous])
        XCTAssertNil(decoded[invalid])
        XCTAssertThrowsError(try RemoteProjectPaths.decode(Data(#"{"paths":[]}"#.utf8)))
    }
    @MainActor
    func testRemoteProjectAssociationWhenEnabled() async throws {
        guard let host = ProcessInfo.processInfo.environment["PHAROS_REMOTE_PROJECT_TEST"], !host.isEmpty else {
            throw XCTSkip("Set PHAROS_REMOTE_PROJECT_TEST to a configured remote Mac")
        }
        let paths = try await Task.detached { try RemoteProjectPaths.read(destination: host) }.value
        let configured = LightHostsFile.standard().load().ssh
        guard let label = configured.first(where: { $0.key == host || $0.value == host })?.key else {
            throw XCTSkip("The requested SSH host is not in the desktop host configuration")
        }
        let store = ProjectStore()
        let service = DesktopPharosClientService(store: store, mesh: DistributedMeshSupport())
        let sessions = try await service.fetchSessions()
        let remoteCount = sessions.filter { $0.machineId == label }.count
        let absoluteCount = sessions.filter { $0.machineId == label && $0.workspacePath.hasPrefix("/") }.count
        print("Remote project diagnostic: path-count=\(paths.count) remote-sessions=\(remoteCount) absolute-workspaces=\(absoluteCount)")
        var match: (UUID, ClientSessionSummary)?
        for session in sessions where session.machineId == label && session.workspacePath.hasPrefix("/") {
            let path = (session.workspacePath as NSString).standardizingPath
            for (id, root) in paths where path == root || path.hasPrefix(root == "/" ? "/" : root + "/") {
                match = (id, session)
                break
            }
            if match != nil { break }
        }
        guard let (projectID, session) = match else { throw XCTSkip("No discovered remote Session matched a known remote checkout") }
        store.projects = [Project(id: projectID, name: "Remote inventory probe")]
        let projects = try await service.fetchProjects()
        let project = try XCTUnwrap(projects.first)
        XCTAssertTrue(project.trackedDevices.contains(label))
        XCTAssertTrue(project.relatedSessionIds?.contains(session.id) == true)
        print("Remote project inventory: host-map-readable=true remote-session-matched=true")
    }
    @MainActor
    func testProjectAssociationWithRealSessionInventoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_PROJECT_LIVE_TEST"] == "1" else {
            throw XCTSkip("Run with an isolated registry and live local sessions")
        }
        let store = ProjectStore()
        let service = DesktopPharosClientService(store: store, mesh: DistributedMeshSupport())
        let initial = try await service.fetchSessions()
        let local = LightSelfHost.fromEnvironment()
        let requestedAgent = ProcessInfo.processInfo.environment["PHAROS_PROJECT_LIVE_AGENT"]?.lowercased()
        guard let sample = initial.first(where: { local.matches($0.machineId) && $0.workspacePath.hasPrefix("/") && $0.workspacePath != "/"
            && (requestedAgent == nil || $0.agentType.lowercased() == requestedAgent) }) else {
            throw XCTSkip("No matching local session with an absolute workspace was found")
        }
        let project = Project(name: "Inventory probe", localPath: sample.workspacePath)
        store.projects = [project]
        let summaries = try await service.fetchProjects()
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.id, project.id.uuidString)
        XCTAssertTrue(summary.relatedSessionIds?.contains(sample.id) == true)
        let related = Set(summary.relatedSessionIds ?? [])
        XCTAssertTrue(initial.filter { related.contains($0.id) }.allSatisfy { local.matches($0.machineId) })
        print("Project real inventory: agent=\(sample.agentType) local-session-matched=true related-count=\(related.count)")
    }
    @MainActor
    func testProjectAssociationsRespectHostPathBoundariesAndStableIDs() {
        let root = Project(name: "Root", localPath: "/work/app")
        let nested = Project(name: "Nested", localPath: "/work/app/sub")
        let ambiguousA = Project(name: "Duplicate A", localPath: "/work/dup")
        let ambiguousB = Project(name: "Duplicate B", localPath: "/work/dup")
        func session(_ id: String, _ host: String, _ path: String, _ status: SessionActivityStatus) -> ClientSessionSummary {
            .init(sessionId: id, machineId: host, agentType: "dsh", workspacePath: path,
                  title: id, status: status, avatarSeed: id)
        }
        let sessions = [session("root", "local-host", "/work/app", .unknown),
                        session("child", "local-host", "/work/app/src", .working),
                        session("nested", "local-host", "/work/app/sub/src", .needsHuman),
                        session("sibling", "local-host", "/work/application", .working),
                        session("remote", "remote-host", "/work/app", .working),
                        session("ambiguous", "local-host", "/work/dup", .working)]
        let projects = [root, nested, ambiguousA, ambiguousB]
        let summaries = DesktopPharosClientService.projectSummaries(projects: projects, sessions: sessions,
            localHost: LightSelfHost(names: ["local-host"]), localMachine: "local-host")
        XCTAssertEqual(summaries[0].id, root.id.uuidString)
        XCTAssertEqual(summaries[0].relatedSessionIds, ["root", "child"])
        XCTAssertEqual(summaries[0].activeSessionsCount, 1)
        XCTAssertEqual(summaries[1].relatedSessionIds, ["nested"])
        XCTAssertEqual(summaries[1].activeSessionsCount, 1)
        XCTAssertEqual(summaries[2].relatedSessionIds, [])
        XCTAssertEqual(summaries[3].relatedSessionIds, [])
        let unloaded = DesktopPharosClientService.projectSummaries(projects: [root], sessions: nil,
            localHost: .all, localMachine: "local-host")
        XCTAssertNil(unloaded[0].relatedSessionIds)
        var moved = root
        moved.localPath = "/another/checkout"
        let movedSummary = DesktopPharosClientService.projectSummaries(projects: [moved], sessions: [],
            localHost: .all, localMachine: "local-host")
        XCTAssertEqual(movedSummary[0].id, root.id.uuidString)
        let remoteOnly = Project(name: "Remote only")
        let remoteSessions = [session("remote-match", "remote-host", "/remote/app/sub", .unknown),
                              session("wrong-host", "other-host", "/remote/app/sub", .working),
                              session("remote-only", "remote-host", "/remote/only", .idle),
                              session("local-collision", "remote-host", "/work/app", .working)]
        let remoteSummaries = DesktopPharosClientService.projectSummaries(projects: [root, remoteOnly], sessions: remoteSessions,
            localHost: LightSelfHost(names: ["local-host"]), localMachine: "local-host",
            remotePaths: ["remote-host": [root.id: "/remote/app", remoteOnly.id: "/remote/only"]])
        XCTAssertEqual(remoteSummaries[0].relatedSessionIds, ["remote-match"])
        XCTAssertEqual(remoteSummaries[0].trackedDevices, ["local-host", "remote-host"])
        XCTAssertEqual(remoteSummaries[1].relatedSessionIds, ["remote-only"])
        XCTAssertEqual(remoteSummaries[1].trackedDevices, ["remote-host"])
        let incomplete = DesktopPharosClientService.projectSummaries(projects: [root], sessions: remoteSessions,
            localHost: LightSelfHost(names: ["local-host"]), localMachine: "local-host",
            remotePaths: ["remote-host": [root.id: "/remote/app"]], unavailableHosts: ["offline"])
        XCTAssertEqual(incomplete[0].relatedSessionIds, ["remote-match"], "Known associations must remain usable")
        XCTAssertEqual(incomplete[0].checkoutUnavailableHosts, ["offline"])
        XCTAssertNil(remoteSummaries[0].checkoutUnavailableHosts, "Successful discovery must not report an outage")
    }

    @MainActor
    func testRemoteAgyDesktopRoutesACPWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_DESKTOP_SERVICE_TEST"] == "1" else {
            throw XCTSkip("Run with an isolated registry and broker directory")
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/pharos/agy-remote-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "me.pai.pharos.test.agy-inventory.\(UUID().uuidString)"
        let overrides = ["PHAROS_PREFERENCES_DOMAIN": domain, "PHAROS_REGISTRY": directory.appendingPathComponent("projects.json").path,
                         "PHAROS_HOSTS_FILE": directory.appendingPathComponent("hosts.json").path,
                         "PHAROS_MESH_DIR": directory.appendingPathComponent("mesh").path,
                         "PHAROS_MESH_DATA_DIR": directory.appendingPathComponent("mesh-data").path,
                         "PHAROS_LEGACY_BROKER": "1", "PHAROS_DISABLE_NOTIFICATIONS": "1", "PHAROS_DISABLE_BACKGROUND_TASKS": "1"]
        var previous: [String: String] = [:]
        for (key, value) in overrides { if let old = getenv(key) { previous[key] = String(cString: old) }; setenv(key, value, 1) }
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            for key in overrides.keys { if let old = previous[key] { setenv(key, old, 1) } else { unsetenv(key) } }
        }
        let script = directory.appendingPathComponent("server.py")
        try #"""
        import json, sys
        def emit(value): print(json.dumps(value), flush=True)
        prompt_id = None
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            request_id = message.get("id")
            if method == "initialize":
                emit({"jsonrpc":"2.0","id":request_id,"result":{"protocolVersion":1}})
            elif method == "session/load":
                assert message["params"]["sessionId"] == "same-id"
                assert message["params"]["cwd"] == "/remote/work"
                emit({"jsonrpc":"2.0","id":request_id,"result":{}})
            elif method == "session/prompt":
                prompt_id = request_id
                emit({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"same-id","update":{"sessionUpdate":"plan","entries":[{"content":"Inspect","status":"in_progress"}]}}})
                emit({"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"same-id","toolCall":{"title":"Read"},"options":[{"kind":"reject_once","optionId":"deny"}]}})
            elif "result" in message:
                assert message["id"] == 99 and message["result"]["outcome"]["optionId"] == "deny"
                emit({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"same-id","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Finished"}}}})
                emit({"jsonrpc":"2.0","id":prompt_id,"result":{"stopReason":"end_turn"}})
        """#.write(to: script, atomically: true, encoding: .utf8)
        let projectStore = ProjectStore()
        projectStore.projects = [Project(name: "Mapping probe")]
        let service = DesktopPharosClientService(store: projectStore, mesh: DistributedMeshSupport())
        service.markRemoteAgyInventoryFailed(host: "test-host", destination: "-invalid", error: NSError(domain: "PharosACP", code: 1))
        XCTAssertNil(service.remoteAgySnapshots["test-host"])
        let firstIssues = await service.fetchSessionInventoryIssues()
        XCTAssertEqual(firstIssues, [.init(host: "test-host", agent: "Antigravity")])
        service.registerRemoteAgy(host: "test-host", entries: [.init(app: "agy", id: "same-id", cwd: "/remote/work")]) {
            AgyAcpProcessTransport(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path])
        }
        let afterRecoveryIssues = await service.fetchSessionInventoryIssues()
        XCTAssertTrue(afterRecoveryIssues.isEmpty)
        let session = RemoteCodexTransport.prefix("test-host").replacingOccurrences(of: ":codex:", with: ":agy:") + "same-id"
        let events = service.events()
        let listener = Task { () throws -> (Bool, CanonicalTurn?) in
            var sawTodo = false
            for await event in events {
                switch event {
                case .sessionTodosUpdated(let id, let todos) where id == session:
                    sawTodo = todos.first?.text == "Inspect"
                case .approvalRequired(let request) where request.sessionId == session:
                    let pending = try await service.fetchSessionApproval(sessionId: session)
                    XCTAssertEqual(pending?.id, request.id)
                    try await service.resolveSessionApproval(sessionId: session, approvalId: request.id, decision: .init(choice: .rejected))
                case .turnCompleted(let turn) where turn.sessionId == session: return (sawTodo, turn)
                default: break
                }
            }
            return (sawTodo, nil)
        }
        _ = try await service.fetchSessionHistory(sessionId: session)
        service.markRemoteAgyInventoryFailed(host: "test-host", destination: "-invalid", error: NSError(domain: "PharosACP", code: 1))
        XCTAssertEqual(service.remoteAgySnapshots["test-host"]?.first?.inventoryStale, true)
        XCTAssertEqual(service.remoteAgyInventoryDiagnostics["test-host"], "error-PharosACP-1")
        _ = try await service.sendSessionMessage(sessionId: session, text: "Continue")
        let result = try await withThrowingTaskGroup(of: (Bool, CanonicalTurn?).self) { group in
            group.addTask { try await listener.value }
            group.addTask { try await Task.sleep(for: .seconds(5)); listener.cancel(); return (false, nil) }
            let first = try await group.next() ?? (false, nil)
            group.cancelAll()
            return first
        }
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1?.status, .completed)
        XCTAssertEqual(result.1?.sessionId, session)
        let progress = try await service.fetchSessionProgress(sessionId: session)
        XCTAssertEqual(progress?.todos.first?.text, "Inspect")
        service.registerRemoteAgy(host: "test-host", entries: [.init(app: "agy", id: "same-id", cwd: "/remote/work")]) {
            XCTFail("The connected ACP service should be retained")
            return AgyAcpProcessTransport(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        }
        XCTAssertNil(service.remoteAgySnapshots["test-host"]?.first?.inventoryStale)
        service.registerRemoteAgy(host: "test-host", entries: []) {
            XCTFail("The existing ACP service should be retained")
            return AgyAcpProcessTransport(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        }
        XCTAssertTrue(service.remoteAgySnapshots["test-host"]?.isEmpty == true)
        do { _ = try await service.fetchSessionHistory(sessionId: session); XCTFail("A successful empty inventory must remove the binding") }
        catch PharosClientError.backendUnreachable { }
        service.registerRemoteAgy(host: "test-host", entries: [.init(app: "agy", id: "same-id", cwd: "/remote/work")]) {
            XCTFail("The existing ACP service should be retained")
            return AgyAcpProcessTransport(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        }
        let hostsFile = LightHostsFile(url: directory.appendingPathComponent("hosts.json"))
        try hostsFile.save(LightHostsConfig(ssh: ["test-host": "-invalid", "empty-host": "-invalid"]))
        let refreshed = try await service.fetchSessions()
        XCTAssertTrue(refreshed.contains { $0.id == session && $0.inventoryStale == true }, "SSH setup failure must retain the marked cached row")
        let projects = try await service.fetchProjects()
        XCTAssertEqual(projects.first?.checkoutUnavailableHosts, ["empty-host", "test-host"], "Failed remote checkout discovery must remain visible even without cached mappings")
        let failedIssues = await service.fetchSessionInventoryIssues()
        XCTAssertTrue(failedIssues.contains(.init(host: "empty-host", agent: "Antigravity")), "Initial failure without a snapshot must be reported")
        do { _ = try await service.fetchSessionHistory(sessionId: session); XCTFail("The unavailable SSH connection must not be reported as usable") }
        catch PharosClientError.backendUnreachable { }
        service.markRemoteAgyInventoryFailed(host: "test-host", destination: "host-b", error: NSError(domain: "PharosACP", code: 1))
        XCTAssertNil(service.remoteAgySnapshots["test-host"], "A changed destination must not expose the old host's Session")
        do { _ = try await service.fetchSessionHistory(sessionId: session); XCTFail("Changed host must not route to the previous ACP") }
        catch PharosClientError.backendUnreachable { }
    }

    @MainActor
    func testRemoteSessionRoutingWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_REMOTE_DESKTOP_TEST"] == "1" else {
            throw XCTSkip("Set PHAROS_REMOTE_DESKTOP_TEST=1 with a configured live remote host")
        }
        let service = DesktopPharosClientService(store: ProjectStore(), mesh: DistributedMeshSupport())
        let sessions = try await service.fetchSessions()
        let remote = try XCTUnwrap(sessions.first(where: { $0.id.hasPrefix("remote:") }))
        XCTAssertNotEqual(remote.machineId, ProcessInfo.processInfo.hostName)
        let history = try await service.fetchSessionHistory(sessionId: remote.id)
        XCTAssertTrue(history.allSatisfy { $0.sessionId == remote.id })
        print("Desktop remote service loaded a remote Session with \(history.count) turns")
        let candidates = sessions.filter { $0.id.hasPrefix("remote:") && $0.agentType == "dsh" }
        XCTAssertFalse(candidates.isEmpty)
        var dshHistory: [CanonicalTurn] = []
        var selected = ""
        for dsh in candidates.prefix(15) {
            dshHistory = try await service.fetchSessionHistory(sessionId: dsh.id)
            selected = dsh.id
            if !dshHistory.isEmpty { break }
        }
        XCTAssertFalse(dshHistory.isEmpty)
        XCTAssertTrue(dshHistory.allSatisfy { $0.sessionId == selected })
        print("Desktop remote service loaded a remote DSH Session with \(dshHistory.count) turns")
    }
    @MainActor
    func testDesktopUsesBrokerAndProjectStore() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_DESKTOP_SERVICE_TEST"] == "1" else {
            throw XCTSkip("Run with an isolated registry and broker directory")
        }
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "test-room", nick: "agent", session: "agent-1", host: "test-host", kind: "codex")).ok)
        let store = ProjectStore()
        store.projects = [Project(name: "Demo", localPath: "/tmp/pharos-demo")]
        let service = DesktopPharosClientService(store: store, mesh: DistributedMeshSupport(), brokerRequest: { broker.process($0) })
        let projects = try await service.fetchProjects()
        XCTAssertEqual(projects.map(\.name), ["Demo"])
        let rooms = try await service.fetchThreads()
        XCTAssertEqual(rooms.map(\.title), ["test-room"])
        let member = try await service.fetchMemberDetail(name: try XCTUnwrap(rooms.first?.memberIds.first))
        XCTAssertEqual(member.name, "agent")
        XCTAssertEqual(member.machine, "test-host")
        let vm = ThreadConversationViewModel(threadId: try XCTUnwrap(rooms.first?.id), clientService: service)
        await vm.loadThreadData()
        XCTAssertEqual(vm.rosterMembers.first?.status, "unknown")
        XCTAssertTrue(broker.process(MeshRequest(cmd: "mark", session: "agent-1", state: "busy")).ok)
        for _ in 0..<50 {
            if vm.rosterMembers.first?.status == "busy" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(vm.rosterMembers.first?.status, "busy")
        XCTAssertTrue(broker.process(MeshRequest(cmd: "mark", session: "agent-1", state: "blocked")).ok)
        try await vm.refreshRoster()
        XCTAssertEqual(vm.rosterMembers.first?.status, "blocked")
        let sent = try await service.sendThreadMessage(threadId: try XCTUnwrap(rooms.first?.id), text: "@agent test message")
        let history = try await service.fetchThreadMessages(threadId: try XCTUnwrap(rooms.first?.id))
        XCTAssertEqual(history.map(\.text), ["@agent test message"])
        XCTAssertEqual(sent.id, history.first?.id)
        XCTAssertEqual(sent.receipt, .unverifiedFallback)
        XCTAssertEqual(history.first?.receipt, .unverifiedFallback)
        XCTAssertEqual(broker.process(MeshRequest(cmd: "recv", memberID: "agent-1", limit: 10)).messages?.first?.text, "@agent test message")
        let afterReceive = try await service.fetchThreadMessages(threadId: try XCTUnwrap(rooms.first?.id))
        XCTAssertEqual(afterReceive.first?.receipt, .unverifiedFallback)
    }
}
