import XCTest
import PharosClientKit
import PharosMeshCore
import PharosMeshIroh
import PharosMeshIdentity
import PharosMeshProtocol
import PharosMeshReplica
@testable import Pharos
@testable import PharosRuntime

final class MeshHostSessionRPCTests: XCTestCase {
    func testPeerEventGapReloadsVisibleSessionHistory() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }
        let running = CanonicalTurn(turnId: "turn", sessionId: "session", turnNumber: 1, status: .inProgress)
        let completed = CanonicalTurn(turnId: "turn", sessionId: "session", turnNumber: 1, status: .completed)
        let service = MockPharosClientService(sessionHistories: ["session": [running]])
        let host = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: service)
        let fixture = TogglePeerGapFixture(host: harness.host.deviceID)
        let router = MeshReplicaRPCServer(store: harness.store, hostIdentity: harness.host,
            hostSessionQueryHandler: { try await host.handleQuery($0) },
            hostSessionEventsHandler: { await fixture.response($0) })
        await harness.hostEndpoint.startServing { request, endpoint in
            try await router.handle(request, remoteEndpointID: endpoint)
        }
        let client = MeshRemoteHostSessionClient(hostDeviceID: harness.host.deviceID, group: harness.group,
            membershipEpoch: 1, rpcClient: MeshReplicaRPCClient(transport: harness.transport), sessionIDPrefix: "peer:")
        let model = await MainActor.run {
            SessionConversationViewModel(sessionId: "peer:session", clientService: client)
        }
        await model.loadHistory()
        let initiallyRunning = await MainActor.run { model.isTurnInProgress }
        XCTAssertTrue(initiallyRunning)
        await service.setSessionHistory([completed], sessionId: "session")
        await fixture.triggerGap()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await MainActor.run(body: { model.turns.last?.status == .completed }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let finalState = await MainActor.run { (model.turns.last?.status, model.isTurnInProgress) }
        XCTAssertEqual(finalState.0, .completed)
        XCTAssertFalse(finalState.1)
    }

    func testPeerEventPollingDoesNotOverlap() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }
        let fixture = SlowPeerEventsFixture(host: harness.host.deviceID)
        let router = MeshReplicaRPCServer(store: harness.store, hostIdentity: harness.host,
            hostSessionEventsHandler: { try await fixture.response($0) })
        await harness.hostEndpoint.startServing { request, endpoint in
            try await router.handle(request, remoteEndpointID: endpoint)
        }
        let client = MeshRemoteHostSessionClient(hostDeviceID: harness.host.deviceID, group: harness.group,
            membershipEpoch: 1, rpcClient: MeshReplicaRPCClient(transport: harness.transport), sessionIDPrefix: "peer:")
        async let first: Void = client.pollEventsOnce()
        async let second: Void = client.pollEventsOnce()
        _ = await (first, second)
        let count = await fixture.count()
        XCTAssertEqual(count, 1)
    }

    func testPeerEventGapRecoversAfterDrainingAndReportsUndecodableEvents() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }
        let host = MeshHostSessionServer(hostDeviceID: harness.host.deviceID,
            service: MockPharosClientService(sessionHistories: ["session": []]))
        let fixture = PeerEventGapFixture(host: harness.host.deviceID)
        let router = MeshReplicaRPCServer(store: harness.store, hostIdentity: harness.host,
            hostSessionQueryHandler: { try await host.handleQuery($0) },
            hostSessionEventsHandler: { try await fixture.response($0) })
        await harness.hostEndpoint.startServing { request, endpoint in
            try await router.handle(request, remoteEndpointID: endpoint)
        }
        let client = MeshRemoteHostSessionClient(hostDeviceID: harness.host.deviceID, group: harness.group,
            membershipEpoch: 1, rpcClient: MeshReplicaRPCClient(transport: harness.transport), sessionIDPrefix: "peer:")
        _ = try await client.fetchSessionHistory(sessionId: "peer:session")
        let restored = expectation(description: "observed session is reloaded")
        let stream = client.events()
        let task = Task { () -> [String] in
            var received: [String] = []
            for await event in stream {
                switch event {
                case .backendError: received.append("error")
                case .turnCompleted: received.append("turn")
                case .sessionConnectionRestored(let id):
                    XCTAssertEqual(id, "peer:session")
                    received.append("reload")
                    restored.fulfill()
                    return received
                default: break
                }
            }
            return received
        }
        await fulfillment(of: [restored], timeout: 5)
        let received = await task.value
        XCTAssertEqual(received, ["error", "error", "turn", "reload"])
        let cursors = await fixture.cursors()
        XCTAssertEqual(Array(cursors.prefix(2)), [0, 1])
    }

    func testHostProjectCheckoutProviderReadsOnlyValidLocalPaths() throws {
        let domain = "me.pai.pharos.test.checkout.\(UUID().uuidString)"
        let previous = ProcessInfo.processInfo.environment["PHAROS_PREFERENCES_DOMAIN"]
        setenv("PHAROS_PREFERENCES_DOMAIN", domain, 1)
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            if let previous { setenv("PHAROS_PREFERENCES_DOMAIN", previous, 1) }
            else { unsetenv("PHAROS_PREFERENCES_DOMAIN") }
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        XCTAssertThrowsError(try HostProjectCheckoutProvider.read())
        let good = UUID(), invalid = UUID(), duplicate = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let raw = [good.uuidString: "/work/./project", invalid.uuidString: "relative/path",
                   duplicate.uuidString: "/one", duplicate.uuidString.lowercased(): "/two"]
        defaults.set(try JSONEncoder().encode(raw), forKey: HostProjectCheckoutProvider.key)
        let paths = try HostProjectCheckoutProvider.read()
        XCTAssertEqual(paths[good], "/work/project")
        XCTAssertNil(paths[invalid])
        XCTAssertNil(paths[duplicate])
    }
    func testBackgroundServiceForwardsSessionToTrustedIrohHost() async throws {
        let root = URL(fileURLWithPath: "/tmp/ph-peer-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try MeshLocalReplica.openIsolated(rootURL: root.appendingPathComponent("controller"))
        let group = try await controller.ensureActiveTrustGroup()
        let hostIdentity = MeshDeviceIdentity.generate()
        let hostStore = try DistributedMeshStore(databaseURL: root.appendingPathComponent("host.sqlite"))
        try await hostStore.setMembershipEpoch(1, for: group)
        let hostEndpoint = try await IrohEndpointRuntime.bind(secretKey: hostIdentity.irohSecretKeyBytes(), relayPolicy: .disabled, bindAddress: "127.0.0.1:0")
        let controllerEndpoint = try await IrohEndpointRuntime.bind(secretKey: controller.identity.irohSecretKeyBytes(), relayPolicy: .disabled, bindAddress: "127.0.0.1:0")
        let hostAddress = try await hostEndpoint.localAddress()
        let controllerAddress = try await controllerEndpoint.localAddress()
        func pair(_ inviter: MeshDeviceIdentity, store: DistributedMeshStore, invitee: MeshDeviceIdentity,
                  roles: Set<MeshDeviceRole>, inviterTicket: String, inviteeTicket: String) async throws {
            let pairing = MeshTrustPairingService(identity: inviter, invitationStore: store)
            let invite = try await pairing.issueInvitation(trustGroupID: group, membershipEpoch: 1,
                inviterAddressTicket: inviterTicket, requestedRoles: roles)
            let accept = try MeshTrustPairingService(identity: invitee, invitationStore: MeshMemoryInvitationUseStore())
                .createAcceptance(for: invite, acceptingAddressTicket: inviteeTicket, displayName: "fixture")
            _ = try await pairing.redeem(accept, for: invite)
        }
        try await pair(controller.identity, store: controller.store, invitee: hostIdentity, roles: [.host],
                       inviterTicket: controllerAddress.ticket, inviteeTicket: hostAddress.ticket)
        try await pair(hostIdentity, store: hostStore, invitee: controller.identity, roles: [.controller],
                       inviterTicket: hostAddress.ticket, inviteeTicket: controllerAddress.ticket)
        let sample = ClientSessionSummary(sessionId: "session", machineId: "fixture", agentType: "codex",
                                          workspacePath: "/tmp", title: "fixture", status: .idle, avatarSeed: "fixture")
        let hostService = MockPharosClientService(sessions: [sample])
        let projectID = UUID()
        await hostService.setHostProjectCheckouts([projectID: "/remote/checkout"])
        let host = MeshHostSessionServer(hostDeviceID: hostIdentity.deviceID, service: hostService)
        let router = MeshReplicaRPCServer(store: hostStore, hostIdentity: hostIdentity,
            hostSessionQueryHandler: { try await host.handleQuery($0) },
            hostSessionActionHandler: { try await host.handleAction($0) },
            hostSessionEventsHandler: { try await host.handleEvents($0) })
        await hostEndpoint.startServing { request, endpoint in try await router.handle(request, remoteEndpointID: endpoint) }
        let commands = DistributedMeshLocalRuntimeCommands(replica: controller, runtime: controllerEndpoint,
                                                            localAddress: controllerAddress, group: group)
        let localServer = try DistributedMeshLocalServiceServer(dataDirectory: controller.rootURL) { await commands.response(to: $0) }
        try localServer.start()
        defer { localServer.stop(); Task { try? await controllerEndpoint.close(); try? await hostEndpoint.close() } }
        let localClient = try DistributedMeshLocalServiceClient(dataDirectory: controller.rootURL)
        let transport = DistributedMeshBackgroundSessionTransport(client: localClient, peerDeviceID: hostIdentity.deviceID)
        let remote = MeshRemoteHostSessionClient(hostDeviceID: hostIdentity.deviceID, group: group,
            membershipEpoch: 1, rpcClient: MeshReplicaRPCClient(transport: transport), sessionIDPrefix: "peer:")
        try await remote.verifyEventProtocol()
        let sessions = try await remote.fetchSessions()
        XCTAssertEqual(sessions.map(\.sessionId), ["peer:session"])
        let checkouts = try await remote.fetchHostProjectCheckouts()
        XCTAssertEqual(checkouts[projectID], "/remote/checkout")
        let sent = try await remote.sendSessionMessage(sessionId: "peer:session", text: "fixture message")
        XCTAssertEqual(sent.sessionId, "peer:session")
        let history = try await hostService.fetchSessionHistory(sessionId: "session")
        XCTAssertEqual(history.count, 1)
        try await controller.store.setMembershipEpoch(2, for: group)
        do { _ = try await remote.fetchSessions(); XCTFail("A host from an old membership epoch must not be called") }
        catch { XCTAssertTrue(error is DistributedMeshLocalServiceError) }
    }
    func testRealHostLocalInventoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_HOST_LOCAL_INVENTORY_TEST"] == "1" else {
            throw XCTSkip("Set PHAROS_HOST_LOCAL_INVENTORY_TEST=1 for a read-only local CLI inventory")
        }
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }
        let service = HostLocalSessionService()
        let host = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: service)
        await host.start()
        let router = MeshReplicaRPCServer(store: harness.store, hostIdentity: harness.host,
            hostSessionQueryHandler: { try await host.handleQuery($0) },
            hostSessionActionHandler: { try await host.handleAction($0) },
            hostSessionEventsHandler: { try await host.handleEvents($0) })
        await harness.hostEndpoint.startServing { request, endpoint in try await router.handle(request, remoteEndpointID: endpoint) }
        let client = MeshRemoteHostSessionClient(hostDeviceID: harness.host.deviceID, group: harness.group,
            membershipEpoch: 1, rpcClient: MeshReplicaRPCClient(transport: harness.transport, requestTimeoutMilliseconds: 45_000),
            sessionIDPrefix: "peer:")
        let snapshot = try await client.fetchHostSessionInventorySnapshot()
        let sessions = snapshot.sessions
        let report = snapshot.status
        let directCheckouts = try? HostProjectCheckoutProvider.read()
        let peerCheckouts = try? await client.fetchHostProjectCheckouts()
        XCTAssertEqual(peerCheckouts, directCheckouts)
        print("Host project checkouts: count=\(peerCheckouts?.count ?? 0), unavailable=\(peerCheckouts == nil)")
        for kind in report.supportedAgents {
            print("Host inventory \(kind): count=\(sessions.filter { $0.agentType == kind }.count), unavailable=\(report.unavailableAgents.contains(kind))")
        }
        XCTAssertFalse(report.supportedAgents.isEmpty)
        XCTAssertFalse(report.unavailableAgents.count == report.supportedAgents.count)
    }

    /// Real dual-host inventory: mini product replica → local sync-serve session-rpc
    /// → Iroh → air `sync-serve --host` → HostLocalSessionService. Enable with
    /// `PHAROS_REAL_PEER_INVENTORY_TEST=<air-device-uuid>` while both serve.
    func testRealAirPeerInventoryWhenEnabled() async throws {
        guard let peerText = ProcessInfo.processInfo.environment["PHAROS_REAL_PEER_INVENTORY_TEST"],
              let peerUUID = UUID(uuidString: peerText) else {
            throw XCTSkip("Set PHAROS_REAL_PEER_INVENTORY_TEST=<paired-host-device-uuid>")
        }
        let peerID = MeshDeviceID(rawValue: peerUUID)
        let replica = try MeshLocalReplica.openDefault(headless: true)
        guard let group = try replica.activeTrustGroup(),
              let epoch = try await replica.store.membershipEpoch(for: group),
              try replica.activeRoles().contains(.controller) else {
            throw XCTSkip("Local product replica is not an active controller")
        }
        let peers = try await replica.store.trustedDevices(in: group, membershipEpoch: epoch)
        guard let peer = peers.first(where: {
            $0.descriptor.id == peerID && $0.descriptor.roles.contains(.host)
        }) else {
            throw XCTSkip("Peer \(peerText) is not a trusted host in the local trust group")
        }
        let localClient = try DistributedMeshLocalServiceClient(dataDirectory: replica.rootURL)
        let transport = DistributedMeshBackgroundSessionTransport(
            client: localClient, peerDeviceID: peerID
        )
        let prefix = "peer:\(peerUUID.uuidString.lowercased()):"
        let client = MeshRemoteHostSessionClient(
            hostDeviceID: peerID, group: group, membershipEpoch: epoch,
            rpcClient: MeshReplicaRPCClient(transport: transport, requestTimeoutMilliseconds: 45_000),
            sessionIDPrefix: prefix
        )
        try await client.verifyEventProtocol()
        let snapshot = try await client.fetchHostSessionInventorySnapshot()
        let sessions = snapshot.sessions
        let report = snapshot.status
        let checkouts = try await client.fetchHostProjectCheckouts()
        print("Real peer \(peer.descriptor.displayName) device=\(peerText)")
        print("Real peer project checkouts: count=\(checkouts.count), unavailable=false")
        for kind in report.supportedAgents {
            let count = sessions.filter { $0.agentType == kind }.count
            print("Real peer inventory \(kind): count=\(count), unavailable=\(report.unavailableAgents.contains(kind))")
        }
        XCTAssertFalse(report.supportedAgents.isEmpty)
        XCTAssertFalse(
            report.unavailableAgents.count == report.supportedAgents.count,
            "Every agent unavailable on real air Host"
        )
        XCTAssertTrue(sessions.allSatisfy { $0.sessionId.hasPrefix(prefix) })
        XCTAssertFalse(checkouts.isEmpty, "Peer Host project checkout map must not be empty")
        let checkoutPaths = Set(checkouts.values.map { ($0 as NSString).standardizingPath })
        let related = sessions.filter { session in
            let workspace = (session.workspacePath as NSString).standardizingPath
            guard !workspace.isEmpty else { return false }
            return checkoutPaths.contains(where: { workspace == $0 || workspace.hasPrefix($0 + "/") })
        }
        print("Real peer project↔session matches: \(related.count)")
        if let sample = checkouts.sorted(by: { $0.key.uuidString < $1.key.uuidString }).first {
            print("Real peer sample checkout: \(sample.key.uuidString.lowercased()) -> \(sample.value)")
        }
        if let match = related.first {
            print("Real peer sample related session: \(match.agentType) \(match.sessionId) workspace=\(match.workspacePath)")
        }
        XCTAssertFalse(related.isEmpty, "At least one Peer Session should sit under a Host checkout path")
    }

    /// Read-only Peer DSH `/goal` over real mini→air Host Session RPC.
    /// Enable with `PHAROS_REAL_PEER_DSH_GOAL_TEST=<air-device-uuid>`.
    func testRealAirPeerDshGoalReadWhenEnabled() async throws {
        guard let peerText = ProcessInfo.processInfo.environment["PHAROS_REAL_PEER_DSH_GOAL_TEST"],
              let peerUUID = UUID(uuidString: peerText) else {
            throw XCTSkip("Set PHAROS_REAL_PEER_DSH_GOAL_TEST=<paired-host-device-uuid>")
        }
        let peerID = MeshDeviceID(rawValue: peerUUID)
        let replica = try MeshLocalReplica.openDefault(headless: true)
        guard let group = try replica.activeTrustGroup(),
              let epoch = try await replica.store.membershipEpoch(for: group),
              try replica.activeRoles().contains(.controller) else {
            throw XCTSkip("Local product replica is not an active controller")
        }
        let peers = try await replica.store.trustedDevices(in: group, membershipEpoch: epoch)
        guard peers.contains(where: {
            $0.descriptor.id == peerID && $0.descriptor.roles.contains(.host)
        }) else {
            throw XCTSkip("Peer \(peerText) is not a trusted host")
        }
        let localClient = try DistributedMeshLocalServiceClient(dataDirectory: replica.rootURL)
        let transport = DistributedMeshBackgroundSessionTransport(
            client: localClient, peerDeviceID: peerID
        )
        let prefix = "peer:\(peerUUID.uuidString.lowercased()):"
        let client = MeshRemoteHostSessionClient(
            hostDeviceID: peerID, group: group, membershipEpoch: epoch,
            rpcClient: MeshReplicaRPCClient(transport: transport, requestTimeoutMilliseconds: 45_000),
            sessionIDPrefix: prefix
        )
        let snapshot = try await client.fetchHostSessionInventorySnapshot()
        let candidates = snapshot.sessions.filter {
            $0.agentType == "dsh" && $0.inventoryStale != true
                && $0.workspacePath.contains("pharos-msg-test")
        }
        guard let target = candidates.first ?? snapshot.sessions.first(where: {
            $0.agentType == "dsh" && $0.inventoryStale != true
        }) else {
            throw XCTSkip("No available DSH Session on air Peer Host")
        }
        print("Real peer DSH goal target: \(target.sessionId) workspace=\(target.workspacePath)")
        // Prefer read-only progress/history over executeCommand: air Host may not
        // hold a live DSH Web process for arbitrary inventory Sessions.
        let progress = try await client.fetchSessionProgress(sessionId: target.sessionId)
        print(
            "Real peer DSH progress available=\(progress != nil) " +
            "goal=\(progress?.goal != nil) todos=\(progress?.todos.count ?? 0)"
        )
        do {
            let history = try await client.fetchSessionHistory(sessionId: target.sessionId)
            print("Real peer DSH history turns=\(history.count)")
            if let command = try? await client.executeSessionCommand(
                sessionId: target.sessionId, line: "/goal"
            ) {
                print("Real peer DSH /goal bytes=\(command.text.utf8.count)")
            } else {
                print("Real peer DSH /goal not-tested: Host executeCommand unavailable for this Session")
            }
        } catch {
            throw XCTSkip(
                "Peer DSH Session open/history failed (\(error)); inventory works but Host lacks a live adapter for this Session"
            )
        }
    }

    /// Real mini→air Peer HITL with human=pharos-proxy via human-requests/.
    /// Enable with `PHAROS_REAL_PEER_HITL_TEST=<air-device-uuid>`.
    func testRealAirPeerHitlWithHumanProxyWhenEnabled() async throws {
        guard let peerText = ProcessInfo.processInfo.environment["PHAROS_REAL_PEER_HITL_TEST"],
              let peerUUID = UUID(uuidString: peerText) else {
            throw XCTSkip("Set PHAROS_REAL_PEER_HITL_TEST=<paired-host-device-uuid>")
        }
        let peerID = MeshDeviceID(rawValue: peerUUID)
        let replica = try MeshLocalReplica.openDefault(headless: true)
        guard let group = try replica.activeTrustGroup(),
              let epoch = try await replica.store.membershipEpoch(for: group),
              try replica.activeRoles().contains(.controller) else {
            throw XCTSkip("Local product replica is not an active controller")
        }
        let peers = try await replica.store.trustedDevices(in: group, membershipEpoch: epoch)
        guard peers.contains(where: {
            $0.descriptor.id == peerID && $0.descriptor.roles.contains(.host)
        }) else {
            throw XCTSkip("Peer \(peerText) is not a trusted host")
        }

        let work = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("personal/pharos-msg-test/peer-hitl/work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let requests = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("personal/pharos-msg-test/human-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)

        let destination = "mac-air"
        let hostLabel = "xiangs-macbook-air"
        let connection = try await Task.detached { try SharedSSHConnection(destination: destination) }.value
        let seed = try await Task.detached {
            try RemoteCodexTransport(destination: destination, hostID: hostLabel, connection: connection)
        }.value
        defer {
            seed.close()
            connection.close()
            _ = connection.waitUntilStopped()
        }
        let remotePrefix = RemoteCodexTransport.prefix(hostLabel)
        let start = try await seed.call(
            method: "thread/start",
            params: [
                "cwd": work.path,
                "approvalPolicy": "on-request",
                "sandbox": "read-only",
            ]
        )
        // thread/start returns a host-prefixed id through RemoteCodexTransport.
        let startedID = try XCTUnwrap((start["thread"] as? [String: Any])?["id"] as? String)
        let rawID = startedID.hasPrefix(remotePrefix)
            ? String(startedID.dropFirst(remotePrefix.count)) : startedID
        let remoteSessionID = remotePrefix + rawID
        print("Peer HITL Codex Session on air: \(rawID)")

        let seedEvents = seed.observeEvents()
        let seedListener = Task { () -> Bool in
            for await event in seedEvents {
                if event["method"] as? String == "turn/completed",
                   (event["params"] as? [String: Any])?["threadId"] as? String == remoteSessionID {
                    return true
                }
            }
            return false
        }
        _ = try await seed.call(
            method: "turn/start",
            params: [
                "threadId": remoteSessionID,
                "input": [[
                    "type": "text",
                    "text": "Reply PHAROS_PEER_HITL_SEED. Do not use tools or access files.",
                ]],
            ]
        )
        let seeded = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await seedListener.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(90))
                seedListener.cancel()
                return false
            }
            let value = await group.next() ?? false
            group.cancelAll()
            return value
        }
        print("Peer HITL seed completed=\(seeded)")
        if !seeded {
            throw XCTSkip("Isolated air Codex seed turn did not complete; Peer HITL not-tested")
        }

        let localClient = try DistributedMeshLocalServiceClient(dataDirectory: replica.rootURL)
        let transport = DistributedMeshBackgroundSessionTransport(
            client: localClient, peerDeviceID: peerID
        )
        let peerPrefix = "peer:\(peerUUID.uuidString.lowercased()):"
        let client = MeshRemoteHostSessionClient(
            hostDeviceID: peerID, group: group, membershipEpoch: epoch,
            rpcClient: MeshReplicaRPCClient(transport: transport, requestTimeoutMilliseconds: 60_000),
            sessionIDPrefix: peerPrefix
        )
        let peerSessionID = peerPrefix + rawID
        let snapshot = try await client.fetchHostSessionInventorySnapshot()
        let listed = snapshot.sessions.contains {
            $0.sessionId == peerSessionID || $0.sessionId.hasSuffix(rawID)
        }
        print("Peer HITL inventory lists Session=\(listed) total=\(snapshot.sessions.count)")

        let hitlPrompt =
            "In this disposable pharos-msg-test Session only, use exec_command to request " +
            "sandbox_permissions require_escalated for the harmless command " +
            "printf PHAROS_PEER_HITL_OK, with justification to test Peer HITL. " +
            "Do not access or modify files, use network services, or run any other command."

        // Prefer Peer Host send when the Session is inventory-visible; otherwise
        // start the HITL turn over the same SSH Codex tunnel (still air Host).
        var usedPeerSend = false
        if listed {
            do {
                _ = try await client.sendSessionMessage(sessionId: peerSessionID, text: hitlPrompt)
                usedPeerSend = true
            } catch {
                print("Peer HITL peer send failed, falling back to SSH Codex: \(error.localizedDescription)")
            }
        }
        if !usedPeerSend {
            _ = try await seed.call(
                method: "turn/start",
                params: [
                    "threadId": remoteSessionID,
                    "input": [["type": "text", "text": hitlPrompt]],
                ]
            )
        }
        print("Peer HITL prompt path peerSend=\(usedPeerSend)")

        let approvalDeadline = ContinuousClock.now.advanced(by: .seconds(120))
        var approval: CanonicalApprovalRequest?
        while ContinuousClock.now < approvalDeadline {
            if listed || usedPeerSend {
                approval = try? await client.fetchSessionApproval(sessionId: peerSessionID)
            }
            if approval != nil { break }
            // Peer Host may not yet own a live open Session; keep polling.
            approval = try? await client.fetchSessionApproval(sessionId: peerSessionID)
            if approval != nil { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let approval else {
            throw XCTSkip(
                "No Codex command approval visible over Peer Host RPC for msg-test Session " +
                "(listed=\(listed) peerSend=\(usedPeerSend)); Peer HITL not-tested"
            )
        }
        print("Peer HITL approval id=\(approval.approvalId) kind=\(String(describing: approval.kind))")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let slug = "peer-air-codex-hitl"
        let requestName = "\(stamp)_\(slug).md"
        let doneName = requestName.replacingOccurrences(of: ".md", with: ".done.md")
        let doneURL = requests.appendingPathComponent(doneName)
        let meshBin = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/pharos-mesh")
        let approveCommand =
            "\(meshBin.path) human-proxy resolve --peer \(peerText) --session \(peerSessionID) " +
            "--approval-id \(approval.approvalId) --decision allowedOnce --done \(doneURL.path)"
        let rejectCommand =
            "\(meshBin.path) human-proxy resolve --peer \(peerText) --session \(peerSessionID) " +
            "--approval-id \(approval.approvalId) --decision rejected --done \(doneURL.path)"
        let hitlRequest = HumanProxyChannel.HITLRequest(
            requestFileName: requestName,
            kind: "hitl",
            host: hostLabel,
            session: peerSessionID,
            approvalId: approval.approvalId,
            vendorSessionID: rawID,
            exactSafeCommand: "printf PHAROS_PEER_HITL_OK",
            approveCommand: approveCommand,
            rejectCommand: rejectCommand,
            timeoutMinutes: 45,
            peerDeviceID: peerText,
            notes: [
                "Resolve as allowedOnce only if the pending command exactly matches `printf PHAROS_PEER_HITL_OK`.",
                "Otherwise run the reject command.",
                "Webhook payload is wake-only; execute only the commands in this file.",
            ]
        )
        let published = try await HumanProxyChannel.publishHITLRequest(
            hitlRequest, directory: requests
        )
        switch published.notify {
        case .skippedMissingConfig:
            print("Peer HITL human-proxy webhook skipped (no ~/.config/pharos/human-proxy-webhook.env)")
        case .posted(let code):
            print("Peer HITL human-proxy webhook posted status=\(code)")
        case .failed(let detail):
            print("Peer HITL human-proxy webhook failed: \(detail)")
        }
        print("Peer HITL human-request written: \(published.file.path)")

        // Proxy polls every ~30 minutes; keep the request alive for at least 45 minutes.
        let proxyDeadline = ContinuousClock.now.advanced(by: .seconds(45 * 60))
        var doneText: String?
        while ContinuousClock.now < proxyDeadline {
            if let data = try? Data(contentsOf: doneURL),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                doneText = text
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        guard let doneText else {
            throw XCTSkip("human-proxy .done.md not received within 45m timeout; Peer HITL not-tested")
        }
        print("Peer HITL human-proxy done bytes=\(doneText.utf8.count)")
        XCTAssertTrue(doneText.lowercased().contains("pharos-proxy") || doneText.contains("decision="), doneText)

        let wantsAllow = doneText.lowercased().contains("decision=allowedonce")
            || doneText.lowercased().contains("allowedonce")
        let wantsReject = doneText.lowercased().contains("decision=rejected")
            || (doneText.lowercased().contains("rejected") && !wantsAllow)
        if try await client.fetchSessionApproval(sessionId: peerSessionID) != nil {
            // Prefer the proxy-run resolve command; fall back only if approval remains.
            let choice: ApprovalChoice = wantsReject ? .rejected : .allowedOnce
            try await client.resolveSessionApproval(
                sessionId: peerSessionID,
                approvalId: approval.approvalId,
                decision: .init(choice: choice)
            )
            print("Peer HITL applied decision via Peer RPC after proxy done: \(choice)")
        } else {
            print("Peer HITL approval already cleared before test apply (proxy may have resolved)")
        }

        let clearedDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        var cleared = false
        while ContinuousClock.now < clearedDeadline {
            if try await client.fetchSessionApproval(sessionId: peerSessionID) == nil {
                cleared = true
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(cleared, "Approval must be cleared after Peer HITL resolution")
        print(
            "Peer HITL E2E: session=\(rawID) listed=\(listed) wantsAllow=\(wantsAllow) " +
            "wantsReject=\(wantsReject) cleared=\(cleared) human=pharos-proxy"
        )
    }

    func testHostInventoryReportsUnavailableProviderAndKeepsStaleSessions() async throws {
        let inventory = HostInventoryFixture()
        let local = HostLocalSessionService(codex: LivePharosClientService(transport: CodexTransportFixture()),
            inventory: { kind in try await inventory.fetch(kind) })
        let first = try await local.fetchSessions()
        XCTAssertTrue(first.contains { $0.sessionId == "dsh:dsh-id" && $0.inventoryStale != true })
        await inventory.setDshUnavailable()
        let second = try await local.fetchSessions()
        let dsh = try XCTUnwrap(second.first { $0.sessionId == "dsh:dsh-id" })
        XCTAssertEqual(dsh.inventoryStale, true)
        let status = await local.inventoryStatus()
        XCTAssertEqual(status.unavailableAgents, ["dsh"])
        XCTAssertFalse(status.unavailableAgents.contains("agy"))
    }

    func testPeerInventorySnapshotKeepsSessionsAndAvailabilityTogether() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }
        let inventory = HostInventoryFixture()
        let local = HostLocalSessionService(codex: LivePharosClientService(transport: CodexTransportFixture()),
            inventory: { kind in try await inventory.fetch(kind) })
        let host = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: local)
        await host.start()
        let router = MeshReplicaRPCServer(store: harness.store, hostIdentity: harness.host,
            hostSessionQueryHandler: { try await host.handleQuery($0) })
        await harness.hostEndpoint.startServing { request, endpoint in
            try await router.handle(request, remoteEndpointID: endpoint)
        }
        let client = MeshRemoteHostSessionClient(hostDeviceID: harness.host.deviceID, group: harness.group,
            membershipEpoch: 1, rpcClient: MeshReplicaRPCClient(transport: harness.transport), sessionIDPrefix: "peer:")
        let first = try await client.fetchHostSessionInventorySnapshot()
        XCTAssertFalse(first.status.unavailableAgents.contains("dsh"))
        XCTAssertTrue(first.sessions.contains { $0.sessionId == "peer:dsh:dsh-id" && $0.inventoryStale != true })
        await inventory.setDshUnavailable()
        let second = try await client.fetchHostSessionInventorySnapshot()
        XCTAssertTrue(second.status.unavailableAgents.contains("dsh"))
        XCTAssertTrue(second.sessions.contains { $0.sessionId == "peer:dsh:dsh-id" && $0.inventoryStale == true })
        // A later refresh cannot change the already returned snapshot.
        XCTAssertFalse(first.status.unavailableAgents.contains("dsh"))
    }
    func testLocalProviderAdaptersThroughHostSessionRPC() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }
        let script = harness.directory.appendingPathComponent("acp.py")
        try #"""
        import json, sys
        def emit(v): print(json.dumps(v), flush=True)
        pending=None
        for line in sys.stdin:
            m=json.loads(line); method=m.get('method'); rid=m.get('id'); p=m.get('params', {})
            if method=='initialize': emit({'jsonrpc':'2.0','id':rid,'result':{'protocolVersion':1,'agentCapabilities':{'promptCapabilities':{'embeddedContext':True}}}})
            elif method=='session/load': emit({'jsonrpc':'2.0','id':rid,'result':{}})
            elif method=='session/prompt':
                resource=next(x['resource'] for x in p['prompt'] if x['type']=='resource')
                assert resource['text']=='known bytes' and resource['mimeType']=='text/plain'
                pending=rid
                emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'agy-id','update':{'sessionUpdate':'plan','entries':[{'content':'fixture plan','status':'in_progress'}]}}})
                emit({'jsonrpc':'2.0','id':'permission','method':'session/request_permission','params':{'sessionId':'agy-id','toolCall':{'title':'Read'},'options':[{'kind':'reject_once','optionId':'deny'}]}})
            elif 'result' in m and rid=='permission':
                assert m['result']['outcome']['optionId']=='deny'
                emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'agy-id','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'fixture reply'}}}})
                emit({'jsonrpc':'2.0','id':pending,'result':{'stopReason':'end_turn'}})
        """#.write(to: script, atomically: true, encoding: .utf8)
        let dsh = HostDshFixture()
        let projectID = UUID()
        let invalidProjectID = UUID()
        let codex = LivePharosClientService(transport: CodexTransportFixture(), machineID: "fixture-host")
        let local = HostLocalSessionService(codex: codex, dshHost: dsh,
            agyFactory: { AgyAcpProcessTransport(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path]) },
            machineID: "fixture-host", projectCheckouts: { [projectID: "/remote/project", invalidProjectID: "relative/path"] }, inventory: { kind in
                [.init(app: kind, id: kind + "-id", cwd: "/tmp", title: kind)]
            })
        let host = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: local)
        await host.start()
        let router = MeshReplicaRPCServer(store: harness.store, hostIdentity: harness.host,
            hostSessionQueryHandler: { try await host.handleQuery($0) },
            hostSessionActionHandler: { try await host.handleAction($0) },
            hostSessionEventsHandler: { try await host.handleEvents($0) })
        await harness.hostEndpoint.startServing { request, endpointID in
            try await router.handle(request, remoteEndpointID: endpointID)
        }
        let client = MeshRemoteHostSessionClient(hostDeviceID: harness.host.deviceID, group: harness.group,
            membershipEpoch: 1, rpcClient: MeshReplicaRPCClient(transport: harness.transport), sessionIDPrefix: "peer:")
        print("Host fixture: fetch inventory")
        let sessions = try await client.fetchSessions()
        XCTAssertEqual(Set(sessions.map(\.agentType)), Set(["codex", "dsh", "agy"]))
        let status = try await client.hostAgentInventory()
        XCTAssertEqual(Set(status.supportedAgents), Set(["codex", "dsh", "agy"]))
        XCTAssertTrue(status.unavailableAgents.isEmpty)
        let checkouts = try await client.fetchHostProjectCheckouts()
        XCTAssertEqual(checkouts[projectID], "/remote/project")
        XCTAssertNil(checkouts[invalidProjectID])
        _ = try await client.fetchSessionHistory(sessionId: "peer:dsh:dsh-id")
        print("Host fixture: DSH progress and approval")
        let progress = try await client.fetchSessionProgress(sessionId: "peer:dsh:dsh-id")
        XCTAssertEqual(progress?.goal?.objective, "fixture goal")
        XCTAssertEqual(progress?.todos.first?.text, "fixture todo")
        await dsh.emitInteraction(BackendWireEvent(["type": "waterfall", "event": "approval/request", "eventId": "permission-1",
            "agentId": "dsh-id", "request": ["toolName": "shell", "reason": "Confirm"]]))
        var approval: CanonicalApprovalRequest?
        for _ in 0..<100 {
            approval = try await client.fetchSessionApproval(sessionId: "peer:dsh:dsh-id")
            if approval != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let dshApproval = try XCTUnwrap(approval)
        XCTAssertEqual(dshApproval.approvalId, "peer:permission-1")
        try await client.resolveSessionApproval(sessionId: "peer:dsh:dsh-id", approvalId: dshApproval.approvalId,
                                                decision: .init(choice: .rejected))
        let outcomes = await dsh.outcomes
        let outcome = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(outcomes.first)) as? [String: Any])
        XCTAssertEqual(outcome["value"] as? String, "rejected")
        let dshTurn = try await client.sendSessionMessage(sessionId: "peer:dsh:dsh-id", text: "hello")
        XCTAssertEqual(dshTurn.sessionId, "peer:dsh:dsh-id")
        let prompts = await dsh.prompts
        XCTAssertEqual(prompts, ["hello"])
        _ = try await client.fetchSessionHistory(sessionId: "peer:agy:agy-id")
        print("Host fixture: Antigravity prompt and approval")
        let supportsText = await client.supportsSessionTextAttachments(sessionId: "peer:agy:agy-id")
        XCTAssertTrue(supportsText)
        let agyTurn = try await client.sendSessionMessage(sessionId: "peer:agy:agy-id", text: "hello",
            files: [.init(name: "fixture.txt", data: Data("known bytes".utf8))], requestId: "agy-turn")
        XCTAssertEqual(agyTurn.status, .inProgress)
        var agyApproval: CanonicalApprovalRequest?
        for _ in 0..<100 {
            agyApproval = try await client.fetchSessionApproval(sessionId: "peer:agy:agy-id")
            if agyApproval != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = try XCTUnwrap(agyApproval)
        print("Host fixture: Antigravity approval received")
        XCTAssertTrue(pending.approvalId.hasPrefix("peer:"))
        let agyProgress = try await client.fetchSessionProgress(sessionId: "peer:agy:agy-id")
        XCTAssertEqual(agyProgress?.todos.first?.text, "fixture plan")
        try await client.resolveSessionApproval(sessionId: "peer:agy:agy-id", approvalId: pending.approvalId,
                                                decision: .init(choice: .rejected))
        XCTAssertEqual(agyTurn.sessionId, "peer:agy:agy-id")
        var finalHistory: [CanonicalTurn] = []
        for _ in 0..<100 {
            finalHistory = try await client.fetchSessionHistory(sessionId: "peer:agy:agy-id")
            if finalHistory.contains(where: { $0.turnId == "agy-turn" && $0.status == .completed }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(finalHistory.contains { $0.turnId == "agy-turn" && $0.status == .completed })
    }
    func testActionJournalRejectsReplayAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-action-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("actions.json")
        let id = MeshDeviceID()
        let session = ClientSessionSummary(sessionId: "s", machineId: "m", agentType: "codex", workspacePath: "/tmp", title: "s", status: .idle, avatarSeed: "s")
        let service = MockPharosClientService(sessions: [session])
        let payload = try JSONEncoder().encode(MeshHostSendMessagePayload(text: "hello", requestId: "key"))
        let request = MeshHostSessionActionRequest(hostDeviceID: id, sessionID: "s", actionKind: "sendMessage", idempotencyKey: "key", payload: payload)
        let first = MeshHostSessionServer(hostDeviceID: id, service: service, actionJournalURL: journal)
        _ = try await first.handleAction(request)
        let restarted = MeshHostSessionServer(hostDeviceID: id, service: service, actionJournalURL: journal)
        do { _ = try await restarted.handleAction(request); XCTFail("Restart must not replay an uncertain action") }
        catch { XCTAssertEqual(error as? PharosClientError, .operationFailed("Previous action outcome is unknown; reconcile before retrying")) }
        let history = try await service.fetchSessionHistory(sessionId: "s")
        XCTAssertEqual(history.count, 1)
    }

    func testActionRetriesCoalesceAndRejectChangedPayload() async throws {
        let id = MeshDeviceID()
        let session = ClientSessionSummary(sessionId: "s", machineId: "m", agentType: "codex",
                                           workspacePath: "/tmp", title: "s", status: .idle, avatarSeed: "s")
        let service = MockPharosClientService(sessions: [session])
        let server = MeshHostSessionServer(hostDeviceID: id, service: service)
        let payload = try JSONEncoder().encode(MeshHostSendMessagePayload(text: "hello", requestId: "key"))
        let first = MeshHostSessionActionRequest(hostDeviceID: id, sessionID: "s", actionKind: "sendMessage", idempotencyKey: "key", payload: payload)
        let second = MeshHostSessionActionRequest(hostDeviceID: id, sessionID: "s", actionKind: "sendMessage", idempotencyKey: "key", payload: payload)
        async let a = server.handleAction(first)
        async let b = server.handleAction(second)
        let (one, two) = try await (a, b)
        XCTAssertEqual(one.actionID, first.actionID)
        XCTAssertEqual(two.actionID, second.actionID)
        XCTAssertEqual(one.payload, two.payload)
        let history = try await service.fetchSessionHistory(sessionId: "s")
        XCTAssertEqual(history.count, 1)
        let changed = MeshHostSessionActionRequest(hostDeviceID: id, sessionID: "s", actionKind: "sendMessage", idempotencyKey: "key", payload: Data("different".utf8))
        do { _ = try await server.handleAction(changed); XCTFail("Conflicting retry must fail") }
        catch { XCTAssertEqual(error as? PharosClientError, .operationFailed("Idempotency key conflict")) }
    }

    func testApprovalResolutionEventAndRestartGap() async throws {
        let id = MeshDeviceID()
        let service = LivePharosClientService()
        let server = MeshHostSessionServer(hostDeviceID: id, service: service)
        await server.start()
        await service.publishExternalEvent(.approvalWithdrawn(approvalId: "a"))
        var result = try await server.handleEvents(.init(hostDeviceID: id, afterCursor: 0))
        for _ in 0..<100 where result.events.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
            result = try await server.handleEvents(.init(hostDeviceID: id, afterCursor: 0))
        }
        XCTAssertEqual(result.events.first?.eventKind, "approvalWithdrawn")
        XCTAssertNoThrow(try result.validate())
        let restarted = MeshHostSessionServer(hostDeviceID: id, service: service)
        let resumed = try await restarted.handleEvents(.init(hostDeviceID: id, afterCursor: result.latestCursor, streamID: result.streamID))
        XCTAssertTrue(resumed.historyGap)
        XCTAssertNotEqual(resumed.streamID, result.streamID)
    }

    func testEventBufferOverflowSignalsGap() async throws {
        let id = MeshDeviceID()
        let service = LivePharosClientService()
        let server = MeshHostSessionServer(hostDeviceID: id, service: service)
        await server.start()
        for index in 0..<2050 {
            await service.publishExternalEvent(.sessionConfigurationUpdated(sessionId: "s\(index)"))
        }
        var response = try await server.handleEvents(.init(hostDeviceID: id, afterCursor: 0))
        for _ in 0..<200 where response.latestCursor < 2050 {
            try await Task.sleep(for: .milliseconds(5))
            response = try await server.handleEvents(.init(hostDeviceID: id, afterCursor: 0))
        }
        XCTAssertEqual(response.latestCursor, 2050)
        XCTAssertTrue(response.historyGap)
        XCTAssertEqual(response.events.first?.cursor, 3)
    }
    private struct IrohPairingHarness {
        let host: MeshDeviceIdentity
        let controller: MeshDeviceIdentity
        let group: MeshTrustGroupID
        let hostEndpoint: IrohEndpointRuntime
        let clientEndpoint: IrohEndpointRuntime
        let transport: IrohMeshTransport
        let store: DistributedMeshStore
        let directory: URL

        func cleanup() async {
            try? await clientEndpoint.close()
            try? await hostEndpoint.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func createHarness() async throws -> IrohPairingHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-session-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = MeshDeviceIdentity.generate()
        let controller = MeshDeviceIdentity.generate()
        let group = MeshTrustGroupID()
        let store = try DistributedMeshStore(databaseURL: directory.appendingPathComponent("mesh.sqlite"))
        try await store.setMembershipEpoch(1, for: group)
        let pairing = MeshTrustPairingService(identity: host, invitationStore: store)
        let invitation = try await pairing.issueInvitation(
            trustGroupID: group, membershipEpoch: 1, inviterAddressTicket: "host-ticket",
            requestedRoles: [.controller]
        )
        let acceptance = try MeshTrustPairingService(
            identity: controller, invitationStore: MeshMemoryInvitationUseStore()
        ).createAcceptance(for: invitation, acceptingAddressTicket: "controller-ticket", displayName: "Test")
        _ = try await pairing.redeem(acceptance, for: invitation)
        let hostEndpoint = try await IrohEndpointRuntime.bind(
            secretKey: host.irohSecretKeyBytes(), relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        let clientEndpoint = try await IrohEndpointRuntime.bind(
            secretKey: controller.irohSecretKeyBytes(), relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        let transport = IrohMeshTransport(runtime: clientEndpoint, remote: try await hostEndpoint.localAddress())
        return IrohPairingHarness(
            host: host, controller: controller, group: group,
            hostEndpoint: hostEndpoint, clientEndpoint: clientEndpoint,
            transport: transport, store: store, directory: directory
        )
    }

    func testHostSessionQueryRejectionForUnpairedOrNonController() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }

        let stranger = MeshDeviceIdentity.generate()
        let strangerEndpoint = try await IrohEndpointRuntime.bind(
            secretKey: stranger.irohSecretKeyBytes(), relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        defer { Task { try? await strangerEndpoint.close() } }

        let mockService = MockPharosClientService()
        let hostSessionServer = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: mockService)
        let router = MeshReplicaRPCServer(
            store: harness.store,
            hostIdentity: harness.host,
            hostSessionQueryHandler: { try await hostSessionServer.handleQuery($0) }
        )
        await harness.hostEndpoint.startServing { request, endpointID in
            try await router.handle(request, remoteEndpointID: endpointID)
        }

        let strangerTransport = IrohMeshTransport(runtime: strangerEndpoint, remote: try await harness.hostEndpoint.localAddress())
        let client = MeshReplicaRPCClient(transport: strangerTransport)
        let req = MeshHostSessionQueryRequest(hostDeviceID: harness.host.deviceID, queryKind: "listSessions")

        do {
            _ = try await client.hostSessionQuery(req, group: harness.group, membershipEpoch: 1)
            XCTFail("Unpaired peer must not query host sessions")
        } catch let error as MeshReplicaRPCError {
            XCTAssertEqual(error, .remoteFailure("peer-not-trusted"))
        }
    }

    func testHostSessionQueryListHistoryAndProgressOverIroh() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }

        let testTurn = CanonicalTurn(
            turnId: "turn-1", sessionId: "codex-session-1", turnNumber: 1,
            status: .completed, createdAt: Date(), completedAt: Date()
        )
        let testSummary = ClientSessionSummary(
            sessionId: "codex-session-1", machineId: "mac-host", agentType: "codex",
            workspacePath: "/Users/test/project", title: "Codex Feature", status: .idle,
            avatarSeed: "codex-session-1"
        )
        let mockService = MockPharosClientService(
            sessions: [testSummary],
            sessionHistories: ["codex-session-1": [testTurn]]
        )
        let hostSessionServer = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: mockService)

        let router = MeshReplicaRPCServer(
            store: harness.store,
            hostIdentity: harness.host,
            hostSessionQueryHandler: { try await hostSessionServer.handleQuery($0) }
        )
        await harness.hostEndpoint.startServing { request, endpointID in
            try await router.handle(request, remoteEndpointID: endpointID)
        }

        let client = MeshReplicaRPCClient(transport: harness.transport)

        // Query listSessions
        let listReq = MeshHostSessionQueryRequest(hostDeviceID: harness.host.deviceID, queryKind: "listSessions")
        let listResp = try await client.hostSessionQuery(listReq, group: harness.group, membershipEpoch: 1)
        XCTAssertEqual(listResp.hostDeviceID, harness.host.deviceID)
        XCTAssertEqual(listResp.queryKind, "listSessions")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summaries = try decoder.decode([ClientSessionSummary].self, from: listResp.payload)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.sessionId, "codex-session-1")
        XCTAssertEqual(summaries.first?.agentType, "codex")
        let sessionClient = MeshRemoteHostSessionClient(
            hostDeviceID: harness.host.deviceID, group: harness.group,
            membershipEpoch: 1, rpcClient: client, sessionIDPrefix: "peer:")
        do {
            try await sessionClient.verifyEventProtocol()
            XCTFail("Inventory-only hosts must not be selected for interactive sessions")
        } catch let error as MeshReplicaRPCError {
            XCTAssertEqual(error, .remoteFailure("host-unavailable"))
        }

        // Query sessionHistory
        let histReq = MeshHostSessionQueryRequest(
            hostDeviceID: harness.host.deviceID,
            queryKind: "sessionHistory",
            sessionID: "codex-session-1"
        )
        let histResp = try await client.hostSessionQuery(histReq, group: harness.group, membershipEpoch: 1)
        let turns = try decoder.decode([CanonicalTurn].self, from: histResp.payload)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.turnId, "turn-1")
        XCTAssertEqual(turns.first?.sessionId, "codex-session-1")
    }

    func testHostSessionActionSendMessageAndApprovalOverIroh() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }

        let testSession = ClientSessionSummary(
            sessionId: "session-abc", machineId: "mac-host", agentType: "codex",
            workspacePath: "/Users/test", title: "Test", status: .idle, avatarSeed: "session-abc"
        )
        let mockService = MockPharosClientService(sessions: [testSession])
        let hostSessionServer = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: mockService)

        let router = MeshReplicaRPCServer(
            store: harness.store,
            hostIdentity: harness.host,
            hostSessionActionHandler: { try await hostSessionServer.handleAction($0) }
        )
        await harness.hostEndpoint.startServing { request, endpointID in
            try await router.handle(request, remoteEndpointID: endpointID)
        }

        let client = MeshReplicaRPCClient(transport: harness.transport)
        let encoder = JSONEncoder()
        let payload = try encoder.encode(MeshHostSendMessagePayload(text: "Hello from controller", files: [], requestId: "req-123"))

        let actionReq = MeshHostSessionActionRequest(
            actionID: UUID(),
            hostDeviceID: harness.host.deviceID,
            sessionID: "session-abc",
            actionKind: "sendMessage",
            idempotencyKey: "idempotency-key-1",
            payload: payload
        )

        let actionResp = try await client.hostSessionAction(actionReq, group: harness.group, membershipEpoch: 1)
        XCTAssertEqual(actionResp.outcome, "success")
        XCTAssertEqual(actionResp.sessionID, "session-abc")
        guard let respPayload = actionResp.payload else { return XCTFail("Missing payload") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let turn = try decoder.decode(CanonicalTurn.self, from: respPayload)
        XCTAssertEqual(turn.sessionId, "session-abc")

        // Verify idempotency cache
        let repeatResp = try await client.hostSessionAction(actionReq, group: harness.group, membershipEpoch: 1)
        XCTAssertEqual(repeatResp.outcome, "success")
        XCTAssertEqual(repeatResp.actionID, actionReq.actionID)
        XCTAssertEqual(repeatResp.payload, actionResp.payload)
    }

    func testHostSessionEventsResumptionOverIroh() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }

        let mockService = LivePharosClientService()
        let hostSessionServer = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: mockService)
        await hostSessionServer.start()

        let router = MeshReplicaRPCServer(
            store: harness.store,
            hostIdentity: harness.host,
            hostSessionEventsHandler: { try await hostSessionServer.handleEvents($0) }
        )
        await harness.hostEndpoint.startServing { request, endpointID in
            try await router.handle(request, remoteEndpointID: endpointID)
        }

        let client = MeshReplicaRPCClient(transport: harness.transport)

        // Publish events via mock service
        let turn1 = CanonicalTurn(turnId: "t1", sessionId: "s1", turnNumber: 1, status: .inProgress)
        let turn2 = CanonicalTurn(turnId: "t1", sessionId: "s1", turnNumber: 1, status: .completed)
        await mockService.publishExternalEvent(.turnStarted(turn1))
        await mockService.publishExternalEvent(.turnCompleted(turn2))
        try await Task.sleep(for: .milliseconds(50))

        // First fetch: afterCursor = 0
        let req1 = MeshHostSessionEventsRequest(hostDeviceID: harness.host.deviceID, afterCursor: 0, limit: 100)
        let resp1 = try await client.hostSessionEvents(req1, group: harness.group, membershipEpoch: 1)
        XCTAssertEqual(resp1.events.count, 2)
        guard resp1.events.count == 2 else { return }
        XCTAssertEqual(resp1.events[0].cursor, 1)
        XCTAssertEqual(resp1.events[0].eventKind, "turnStarted")
        XCTAssertEqual(resp1.events[1].cursor, 2)
        XCTAssertEqual(resp1.events[1].eventKind, "turnCompleted")

        // Resumption: afterCursor = 1 -> should only get cursor 2
        let req2 = MeshHostSessionEventsRequest(hostDeviceID: harness.host.deviceID, afterCursor: 1, limit: 100)
        let resp2 = try await client.hostSessionEvents(req2, group: harness.group, membershipEpoch: 1)
        XCTAssertEqual(resp2.events.count, 1)
        XCTAssertEqual(resp2.events[0].cursor, 2)
    }

    func testMeshRemoteHostSessionClientEndToEndOverIroh() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }

        let testSummary = ClientSessionSummary(
            sessionId: "session-local-1", machineId: "host-box", agentType: "codex",
            workspacePath: "/Users/dev/pharos", title: "Mesh Session", status: .idle,
            avatarSeed: "session-local-1"
        )
        let mockService = MockPharosClientService(sessions: [testSummary])
        let hostSessionServer = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: mockService)
        await hostSessionServer.start()

        let router = MeshReplicaRPCServer(
            store: harness.store,
            hostIdentity: harness.host,
            hostSessionQueryHandler: { try await hostSessionServer.handleQuery($0) },
            hostSessionActionHandler: { try await hostSessionServer.handleAction($0) },
            hostSessionEventsHandler: { try await hostSessionServer.handleEvents($0) }
        )
        await harness.hostEndpoint.startServing { request, endpointID in
            try await router.handle(request, remoteEndpointID: endpointID)
        }

        let rpcClient = MeshReplicaRPCClient(transport: harness.transport)
        let prefix = "remote:mac-air:codex:"
        let client = MeshRemoteHostSessionClient(
            hostDeviceID: harness.host.deviceID,
            group: harness.group,
            membershipEpoch: 1,
            rpcClient: rpcClient,
            sessionIDPrefix: prefix
        )

        // 1. fetchSessions - should be prefixed
        let sessions = try await client.fetchSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, prefix + "session-local-1")

        // 2. sendSessionMessage - sends with prefixed ID, host executes with local ID
        let turn = try await client.sendSessionMessage(sessionId: prefix + "session-local-1", text: "Ping")
        XCTAssertEqual(turn.sessionId, prefix + "session-local-1")

        // 3. events - host publishes event with local session ID, client receives prefixed event
        let eventStream = client.events()
        let eventExpectation = expectation(description: "Prefixed event received")
        let task = Task {
            for await event in eventStream {
                if case .turnCompleted(let t) = event {
                    XCTAssertEqual(t.sessionId, prefix + "session-local-1")
                    eventExpectation.fulfill()
                    break
                }
            }
        }

        let completedTurn = CanonicalTurn(turnId: "t-done", sessionId: "session-local-1", turnNumber: 2, status: .completed)
        await mockService.emitEvent(.turnCompleted(completedTurn))
        try await Task.sleep(for: .milliseconds(50))
        await client.pollEventsOnce()

        await fulfillment(of: [eventExpectation], timeout: 3.0)
        task.cancel()
    }

    func testCodexVerticalSliceOverIroh() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }

        let transportFixture = CodexTransportFixture()
        let liveCodexService = LivePharosClientService(transport: transportFixture, machineID: "remote-mac-air")
        let hostSessionServer = MeshHostSessionServer(hostDeviceID: harness.host.deviceID, service: liveCodexService)
        await hostSessionServer.start()

        let router = MeshReplicaRPCServer(
            store: harness.store,
            hostIdentity: harness.host,
            hostSessionQueryHandler: { try await hostSessionServer.handleQuery($0) },
            hostSessionActionHandler: { try await hostSessionServer.handleAction($0) },
            hostSessionEventsHandler: { try await hostSessionServer.handleEvents($0) }
        )
        await harness.hostEndpoint.startServing { request, endpointID in
            try await router.handle(request, remoteEndpointID: endpointID)
        }

        let rpcClient = MeshReplicaRPCClient(transport: harness.transport)
        let prefix = "remote:remote-mac-air:codex:"
        let client = MeshRemoteHostSessionClient(
            hostDeviceID: harness.host.deviceID,
            group: harness.group,
            membershipEpoch: 1,
            rpcClient: rpcClient,
            sessionIDPrefix: prefix
        )

        // 1. Discover sessions through Host LivePharosClientService
        let sessions = try await client.fetchSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, prefix + "codex-session-abc")
        XCTAssertEqual(sessions.first?.agentType, "codex")

        // 2. Fetch session history through Host translator
        let history = try await client.fetchSessionHistory(sessionId: prefix + "codex-session-abc")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.sessionId, prefix + "codex-session-abc")
        XCTAssertEqual(history.first?.status, .completed)

        // 3. Send message across peer RPC into LivePharosClientService
        let turn = try await client.sendSessionMessage(sessionId: prefix + "codex-session-abc", text: "Run probe")
        XCTAssertEqual(turn.sessionId, prefix + "codex-session-abc")
        XCTAssertEqual(turn.turnId, "owned-turn-42")

        // 4. Approval request emitted on Codex daemon -> mapped by Host service -> received by client
        let eventStream = client.events()
        let listenerTask = Task<String, Never> {
            for await event in eventStream {
                if case .approvalRequired(let req) = event {
                    XCTAssertEqual(req.sessionId, prefix + "codex-session-abc")
                    return req.approvalId
                }
            }
            return ""
        }

        transportFixture.emit([
            "id": "approval-xyz",
            "method": "item/commandExecution/requestApproval",
            "params": [
                "threadId": "codex-session-abc",
                "turnId": "owned-turn-42",
                "command": "printf PROBE",
                "availableDecisions": ["accept", "cancel"]
            ]
        ])

        try await Task.sleep(for: .milliseconds(50))
        await client.pollEventsOnce()

        let approvalId = await listenerTask.value
        XCTAssertTrue(approvalId.hasPrefix(prefix))
        do {
            try await client.resolveSessionApproval(sessionId: prefix + "codex-session-abc",
                                                    approvalId: "another-host-approval", decision: .init(choice: .allowedOnce))
            XCTFail("An approval from another host must not be routed")
        } catch PharosClientError.operationFailed { }
        XCTAssertNil(transportFixture.lastDecision)

        // 5. Client resolves approval across peer RPC
        try await client.resolveSessionApproval(
            sessionId: prefix + "codex-session-abc",
            approvalId: approvalId,
            decision: .init(choice: .allowedOnce)
        )
        XCTAssertEqual(transportFixture.lastDecision, "accept")
    }

    func testPeerThreadBindingUsesHostOwnedInventoryAndRuntime() async throws {
        let harness = try await createHarness()
        defer { Task { await harness.cleanup() } }
        let runtime = PeerThreadRuntimeFixture()
        let sessions = [
            ClientSessionSummary(
                sessionId: "dsh:owned-1", machineId: "fixture-host", agentType: "dsh",
                workspacePath: "/tmp/pharos-msg-test", title: "owned",
                status: .idle, updatedAt: Date(timeIntervalSince1970: 1),
                avatarSeed: "dsh:owned-1"
            ),
        ]
        let binder = MeshHostThreadBinder(
            inventory: { sessions },
            runtime: { method, params in try runtime.handle(method, params) },
            driverID: "peer-thread-driver"
        )
        let host = MeshHostSessionServer(
            hostDeviceID: harness.host.deviceID,
            service: MockPharosClientService(),
            threadBinder: binder
        )
        await host.start()
        let router = MeshReplicaRPCServer(
            store: harness.store, hostIdentity: harness.host,
            hostSessionQueryHandler: { try await host.handleQuery($0) },
            hostSessionActionHandler: { try await host.handleAction($0) }
        )
        await harness.hostEndpoint.startServing { request, endpoint in
            try await router.handle(request, remoteEndpointID: endpoint)
        }
        let client = MeshRemoteHostSessionClient(
            hostDeviceID: harness.host.deviceID, group: harness.group,
            membershipEpoch: 1,
            rpcClient: MeshReplicaRPCClient(transport: harness.transport),
            sessionIDPrefix: "peer:"
        )

        let bound = try await client.bindThreadMember(
            sessionId: "peer:dsh:owned-1", agentKind: "dsh",
            idempotencyKey: "peer-bind-1"
        )
        XCTAssertEqual(bound.memberID, "owned-1")
        XCTAssertEqual(bound.vendorSessionID, "owned-1")
        XCTAssertEqual(bound.agentKind, "dsh")
        XCTAssertEqual(bound.hostSessionID, "dsh:owned-1")

        let inspected = try await client.inspectThreadBinding(
            memberID: bound.memberID, vendorSessionID: bound.vendorSessionID,
            agentKind: "dsh"
        )
        XCTAssertEqual(inspected, bound)

        let replay = try await client.bindThreadMember(
            sessionId: "peer:dsh:owned-1", agentKind: "dsh",
            idempotencyKey: "peer-bind-1"
        )
        XCTAssertEqual(replay, bound)
    }
}

private final class PeerThreadRuntimeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var conversations: [[String: Any]] = []

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
                "id": "peer-conv-" + UUID().uuidString.lowercased(),
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

private actor TogglePeerGapFixture {
    private let host: MeshDeviceID
    private let stream = UUID()
    private var pending = false
    init(host: MeshDeviceID) { self.host = host }
    func triggerGap() { pending = true }
    func response(_ request: MeshHostSessionEventsRequest) -> MeshHostSessionEventsResponse {
        let gap = pending
        pending = false
        return .init(hostDeviceID: host, events: [], latestCursor: 0,
                     hasMore: false, streamID: stream, historyGap: gap)
    }
}

private actor SlowPeerEventsFixture {
    private let host: MeshDeviceID
    private var requests = 0
    init(host: MeshDeviceID) { self.host = host }
    func count() -> Int { requests }
    func response(_ request: MeshHostSessionEventsRequest) async throws -> MeshHostSessionEventsResponse {
        requests += 1
        try await Task.sleep(for: .milliseconds(200))
        return .init(hostDeviceID: host, events: [], latestCursor: 0,
                     hasMore: false, streamID: UUID(), historyGap: false)
    }
}

private actor PeerEventGapFixture {
    private let host: MeshDeviceID
    private let stream = UUID()
    private var seen: [Int64] = []
    init(host: MeshDeviceID) { self.host = host }
    func cursors() -> [Int64] { seen }
    func response(_ request: MeshHostSessionEventsRequest) throws -> MeshHostSessionEventsResponse {
        seen.append(request.afterCursor)
        if request.afterCursor == 0 {
            let invalid = MeshHostSessionEventRecord(cursor: 1, sessionID: "session", eventKind: "futureEvent",
                timestampMilliseconds: 1, payload: Data("{}".utf8))
            return .init(hostDeviceID: host, events: [invalid], latestCursor: 2,
                         hasMore: true, streamID: stream, historyGap: true)
        }
        if request.afterCursor == 1 {
            let turn = CanonicalTurn(turnId: "turn", sessionId: "session", turnNumber: 1, status: .completed)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let record = MeshHostSessionEventRecord(cursor: 2, sessionID: "session", eventKind: "turnCompleted",
                timestampMilliseconds: 2, payload: try encoder.encode(PharosClientEvent.turnCompleted(turn)))
            return .init(hostDeviceID: host, events: [record], latestCursor: 2,
                         hasMore: false, streamID: stream, historyGap: false)
        }
        return .init(hostDeviceID: host, events: [], latestCursor: 2,
                     hasMore: false, streamID: stream, historyGap: false)
    }
}

private actor HostInventoryFixture {
    private var dshUnavailable = false
    func setDshUnavailable() { dshUnavailable = true }
    func fetch(_ kind: String) throws -> [LightSessionEntry] {
        if kind == "dsh", dshUnavailable { throw PharosClientError.backendUnreachable(backend: "dsh", reason: "offline") }
        return [.init(app: kind, id: kind + "-id", cwd: "/tmp", title: kind)]
    }
}

private actor HostDshFixture: DshSessionHosting, DshInteractionHosting {
    private(set) var prompts: [String] = []
    private(set) var outcomes: [Data] = []
    private var interaction: AsyncStream<BackendWireEvent>.Continuation?
    func history(sessionId: String) async throws -> [BackendWireEvent] {
        [BackendWireEvent(["type": "event", "event": ["seq": 1, "type": "goal/change", "data": ["goal": ["objective": "fixture goal", "phase": "active"]]]]),
         BackendWireEvent(["type": "event", "event": ["seq": 2, "type": "todo/write", "data": ["todos": [["content": "fixture todo", "status": "pending"]]]]])]
    }
    func follow(sessionId: String) async throws -> AsyncStream<BackendWireEvent> { AsyncStream { _ in } }
    func prompt(sessionId: String, text: String, mode: PromptMode) async throws { prompts.append(text) }
    func interactions() async throws -> (String, AsyncStream<BackendWireEvent>) {
        let (stream, continuation) = AsyncStream<BackendWireEvent>.makeStream()
        interaction = continuation
        return ("fixture", stream)
    }
    func emitInteraction(_ event: BackendWireEvent) { interaction?.yield(event) }
    func resolveInteraction(clientID: String, eventID: String, outcomeData: Data) async throws { outcomes.append(outcomeData) }
}

private final class CodexTransportFixture: CodexTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [AsyncStream<BackendWireEvent>.Continuation] = []
    private var responses = 0
    private var recordedDecision: String?
    private var epoch: UInt64 = 0
    var connectionGeneration: UInt64 { lock.withLock { epoch } }
    var lastDecision: String? { lock.withLock { recordedDecision } }

    func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "thread/list" {
            return ["data": [
                ["id": "codex-session-abc", "name": "Codex Bugfix", "cwd": "/repo", "status": ["type": "idle"]]
            ]]
        }
        if method == "turn/start" {
            return ["turn": ["id": "owned-turn-42"]]
        }
        if method == "thread/read" {
            return ["thread": ["id": "codex-session-abc", "turns": [
                ["id": "owned-turn-42", "status": "completed", "items": [
                    ["type": "userMessage", "text": "Hello Codex"],
                    ["type": "assistantResponse", "text": "Hello Controller!"]
                ]]
            ]]]
        }
        return [:]
    }

    func observeEvents() -> AsyncStream<BackendWireEvent> {
        AsyncStream { continuation in lock.withLock { listeners.append(continuation) } }
    }

    func emit(_ data: [String: Any]) {
        let targets = lock.withLock { listeners }
        for target in targets { target.yield(BackendWireEvent(data, connectionGeneration: connectionGeneration)) }
    }

    func respond(requestID: CodexRequestID, result: [String: Any]) async throws {
        lock.withLock {
            responses += 1
            recordedDecision = result["decision"] as? String
        }
        emit(["method": "serverRequest/resolved", "params": ["threadId": "codex-session-abc", "requestId": requestID.wireValue]])
    }

    func close() {}
}
