import Foundation
import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

private final class FakeLink: LightBrokerLink, @unchecked Sendable {
    let lock = NSLock()
    var nodes: [LightMeshNode]?
    var enqueued: [(String, MeshLightCommandPayload)] = []
    var canceled: [String] = []
    /// Answer for each enqueued command; nil leaves it queued (unclaimed).
    var answer: ((MeshLightCommandPayload) -> MeshLightCommandResult?)?
    private var commands: [String: MeshNodeCommand] = [:]

    init(nodes: [LightMeshNode]?) { self.nodes = nodes }

    func roster() -> [LightMeshNode]? { nodes }

    func enqueue(nodeID: String, payload: MeshLightCommandPayload, deadline: Date, key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        enqueued.append((nodeID, payload))
        let id = "c\(enqueued.count)"
        var command = MeshNodeCommand(id: id, nodeID: nodeID, action: .light, payload: nil, idempotencyKey: key,
                                      deadline: deadline.timeIntervalSince1970)
        if let result = answer?(payload) {
            command.state = .succeeded
            command.result = String(data: try! JSONEncoder().encode(result), encoding: .utf8)
        }
        commands[id] = command
        return id
    }

    func command(id: String) -> MeshNodeCommand? {
        lock.lock(); defer { lock.unlock() }
        return commands[id]
    }

    func cancel(id: String, nodeID: String) {
        lock.lock(); defer { lock.unlock() }
        canceled.append(id)
        commands[id]?.state = .canceled
    }
}

private final class RecordingRunner: LightProcessRunning, @unchecked Sendable {
    let lock = NSLock()
    var outputs: [LightProcessOutput]
    var invocations: [LightInvocation] = []
    init(_ outputs: [LightProcessOutput]) { self.outputs = outputs }
    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        lock.lock(); defer { lock.unlock() }
        invocations.append(invocation)
        return outputs.isEmpty ? LightProcessOutput(status: 255, stdout: "", stderr: "ssh: no route") : outputs.removeFirst()
    }
}

private final class StepClock: @unchecked Sendable {
    let lock = NSLock()
    var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

private struct FixedNodes: LightNodeRouting {
    var answer: LightNodeRun?
    var calls: CallLog
    func directory() -> LightHostDirectory? { nil }
    func run(_ label: String, argv: [String], timeout: TimeInterval) -> LightNodeRun? {
        calls.append(label, argv)
        return answer
    }
}

private final class CallLog: @unchecked Sendable {
    let lock = NSLock()
    var calls: [(String, [String])] = []
    func append(_ label: String, _ argv: [String]) { lock.lock(); calls.append((label, argv)); lock.unlock() }
}

private final class SwitchDriver: LightSessionDriver, @unchecked Sendable {
    let lock = NSLock()
    var state: LightDriveResult.State = .offline
    var delivered: [String] = []
    var reply: String?
    func deliver(member: LightMember, body: String) -> LightDriveResult {
        lock.lock(); defer { lock.unlock() }
        if state == .delivered { delivered.append(member.name) }
        return LightDriveResult(state: state, route: state == .delivered ? "web" : nil, fallback: false,
                                liveVerified: false, detail: state == .offline ? "Pharos node offline" : "ok",
                                via: state == .offline ? "queued" : "mesh")
    }
    func readReply(member: LightMember, since: Date) -> String? {
        lock.lock(); defer { lock.unlock() }
        return reply
    }
}

final class LightNodeRoutingTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        dirs.append(url)
        return url
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func roster(airOnline: Bool = true) -> [LightMeshNode] {
        [
            LightMeshNode(id: "node-mini", host: "Xiangs-Mac-mini.local", tailscaleIP: "100.1.1.1",
                          lastSeen: t0, brokerLocal: true),
            LightMeshNode(id: "node-air", host: "Xiangs-MacBook-Air.local", tailscaleIP: "100.2.2.2",
                          lastSeen: airOnline ? t0 : t0.addingTimeInterval(-600)),
        ]
    }

    // MARK: Hosts

    func testHostDirectoryResolvesAliasesNamesIPsAndSSHNames() throws {
        var directory = LightHostDirectory(nodes: roster(), config: LightHostsConfig())
        XCTAssertEqual(directory.roster.map(\.name).sorted(), ["xiangs-mac-mini", "xiangs-macbook-air"])
        XCTAssertEqual(directory.hub?.name, "xiangs-mac-mini")
        XCTAssertThrowsError(try directory.alias(node: "pro", as: "pro")) { error in
            XCTAssertTrue(error.localizedDescription.contains("no Pharos node named pro"))
        }
        let config = try directory.alias(node: "Xiangs-MacBook-Air", as: "Air", ssh: "mac-air")
        XCTAssertEqual(config.aliases["air"], "xiangs-macbook-air")
        directory = LightHostDirectory(nodes: roster(), config: config)
        XCTAssertEqual(directory.canonical("air"), "xiangs-macbook-air")
        XCTAssertEqual(directory.canonical("100.2.2.2"), "xiangs-macbook-air")
        XCTAssertEqual(directory.canonical("mac-air"), "xiangs-macbook-air")
        XCTAssertEqual(directory.canonical("node-air"), "xiangs-macbook-air")
        XCTAssertEqual(directory.aliases(of: "xiangs-macbook-air"), ["air"])
        XCTAssertEqual(directory.sshDestination(for: "air"), "mac-air")
        XCTAssertThrowsError(try directory.alias(node: "air", as: "Bad Alias!"))
        let removed = try directory.unalias("air")
        XCTAssertNil(removed.aliases["air"])
        XCTAssertThrowsError(try LightHostDirectory(nodes: roster(), config: removed).unalias("air"))
    }

    func testHostsFileRoundTrips() throws {
        let file = temp("hosts").appendingPathComponent("hosts.json")
        let store = LightHostsFile.standard(["PHAROS_HOSTS_FILE": file.path])
        XCTAssertEqual(store.load(), LightHostsConfig())
        let config = LightHostsConfig(aliases: ["mini": "xiangs-mac-mini"], ssh: ["xiangs-mac-mini": "mac-mini"])
        try store.save(config)
        XCTAssertEqual(store.load(), config)
    }

    // MARK: Router

    func testRouterUsesTheMeshWhenTheNodeIsOnline() {
        let link = FakeLink(nodes: roster())
        link.answer = { payload in MeshLightCommandResult(exitCode: 0, stdout: "ran \(payload.argv.joined(separator: " "))", stderr: "") }
        let runner = RecordingRunner([])
        let clock = StepClock()
        let router = LightMeshRouter(link: link, hosts: LightHostsConfig(aliases: ["air": "xiangs-macbook-air"]),
                                     ssh: LightSSHRoute(runner: runner), now: { clock.now() }, pause: { clock.advance($0) })
        let run = router.run("air", argv: ["session", "new", "--here"], timeout: 30)
        XCTAssertEqual(run?.path, .mesh)
        XCTAssertEqual(run?.stdout, "ran session new --here")
        XCTAssertEqual(run?.node, "xiangs-macbook-air")
        XCTAssertEqual(link.enqueued.first?.0, "node-air")
        XCTAssertTrue(runner.invocations.isEmpty, "mesh first: no SSH when the node answers")
    }

    func testRouterFallsBackToSSHThenNil() {
        let link = FakeLink(nodes: roster(airOnline: false))
        let runner = RecordingRunner([LightProcessOutput(status: 0, stdout: "{\"ok\":true}", stderr: "")])
        let clock = StepClock()
        let router = LightMeshRouter(link: link, hosts: LightHostsConfig(aliases: ["air": "xiangs-macbook-air"],
                                                                         ssh: ["xiangs-macbook-air": "mac-air"]),
                                     ssh: LightSSHRoute(runner: runner), now: { clock.now() }, pause: { clock.advance($0) })
        let run = router.run("air", argv: ["node-deliver", "--payload", "x"], timeout: 30)
        XCTAssertEqual(run?.path, .ssh)
        XCTAssertTrue(link.enqueued.isEmpty, "an offline node gets no mesh command")
        XCTAssertEqual(runner.invocations.first?.argv.dropLast().last, "mac-air")
        XCTAssertTrue(runner.invocations.first?.argv.last?.hasPrefix("PHAROS_LIGHT_DIRECT=1 pharos 'node-deliver'") == true)
        XCTAssertNil(router.run("air", argv: ["node-deliver"], timeout: 30), "ssh exit 255 means the node was not reached")
    }

    func testUnclaimedMeshCommandIsCanceledAndTheBackupRuns() {
        let link = FakeLink(nodes: roster())
        let runner = RecordingRunner([LightProcessOutput(status: 0, stdout: "via ssh", stderr: "")])
        let clock = StepClock()
        let router = LightMeshRouter(link: link, hosts: LightHostsConfig(ssh: ["xiangs-macbook-air": "mac-air"]),
                                     ssh: LightSSHRoute(runner: runner), claimTimeout: 2,
                                     now: { clock.now() }, pause: { clock.advance($0) })
        let run = router.run("xiangs-macbook-air", argv: ["read", "r_x"], timeout: 30)
        XCTAssertEqual(link.canceled, ["c1"])
        XCTAssertEqual(run?.path, .ssh)
        XCTAssertEqual(run?.stdout, "via ssh")
    }

    // MARK: Driver

    func testRemoteMemberIsDeliveredByItsOwnNodeOrParked() {
        let member = LightMember(name: "codex-air", host: "air", app: "codex", project: "p", sessionID: "s1",
                                 routes: LightRouteCatalog.defaults(for: "codex"))
        let envelope = LightEnvelope(replyId: "r_1", threadId: "t_1", from: "a", to: "codex-air", cc: [], intent: "ask",
                                     text: "hi", hop: 1, hopLimit: 4, expectsReply: true, replyCommand: nil, prompt: "hi")
        let log = CallLog()
        let offline = ExternalLightDriver(allowLive: true, runner: RecordingRunner([]),
                                          selfHost: LightSelfHost(names: ["local"]),
                                          nodes: FixedNodes(answer: nil, calls: log))
        let parked = offline.deliver(member: member, envelope: envelope)
        XCTAssertEqual(parked.state, .offline)
        XCTAssertEqual(parked.via, "queued")
        XCTAssertTrue(parked.detail.contains("Pharos node offline"))
        XCTAssertFalse(parked.detail.lowercased().contains("unreachable"))
        XCTAssertEqual(log.calls.first?.1.first, "node-deliver")
        let sent = log.calls.first?.1.last.flatMap { LightNodeExec.decode(LightNodeDelivery.self, $0) }
        XCTAssertEqual(sent?.envelope, envelope)

        let reached = ExternalLightDriver(allowLive: true, runner: RecordingRunner([]),
                                          selfHost: LightSelfHost(names: ["local"]),
                                          nodes: FixedNodes(answer: LightNodeRun(
                                            path: .mesh, status: 0,
                                            stdout: #"{"ok":true,"state":"delivered","route":"desktop","fallback":false,"detail":""}"#,
                                            stderr: "", node: "xiangs-macbook-air"), calls: CallLog()))
        let done = reached.deliver(member: member, envelope: envelope)
        XCTAssertEqual(done.state, .delivered)
        XCTAssertEqual(done.route, "desktop")
        XCTAssertEqual(done.via, "mesh")
    }

    func testRemoteHarvestReadsThroughTheNode() {
        let member = LightMember(name: "codex-air", host: "air", app: "codex", project: "p", sessionID: "s1", routes: [])
        let driver = ExternalLightDriver(allowLive: true, runner: RecordingRunner([]), selfHost: LightSelfHost(names: ["local"]),
                                         nodes: FixedNodes(answer: LightNodeRun(path: .ssh, status: 0, stdout: #"{"ok":true,"text":" READY \n"}"#,
                                                                                stderr: "", node: "air"), calls: CallLog()))
        XCTAssertEqual(driver.readReply(member: member, since: t0), "READY")
    }

    func testNodeExecDeliversLocallyAndReportsJSON() {
        let driver = SwitchDriver()
        driver.state = .delivered
        driver.reply = "answer text"
        let member = LightMember(name: "m", host: "local", app: "codex", project: "p", sessionID: "s", routes: [])
        let envelope = LightEnvelope(replyId: "r", threadId: "t", from: "a", to: "m", cc: [], intent: "ask", text: "x",
                                     hop: 1, hopLimit: 2, expectsReply: true, replyCommand: nil, prompt: "x")
        let delivered = LightNodeExec.execute(command: "node-deliver",
                                              arguments: ["--payload", LightNodeExec.encode(LightNodeDelivery(member: member, envelope: envelope))],
                                              driver: driver)
        XCTAssertEqual(delivered.exitCode, 0)
        XCTAssertTrue(delivered.text.contains(#""state":"delivered""#), delivered.text)
        let harvested = LightNodeExec.execute(command: "node-harvest",
                                              arguments: ["--payload", LightNodeExec.encode(LightNodeHarvest(member: member, since: t0))],
                                              driver: driver)
        XCTAssertTrue(harvested.text.contains("answer text"))
        XCTAssertEqual(LightNodeExec.execute(command: "node-deliver", arguments: [], driver: driver).exitCode, 2)
        XCTAssertFalse(LightNodeExec.allowed.contains("light-tick"))
        XCTAssertFalse(LightNodeExec.allowed.contains("webhook"))
    }

    func testDshSendsDetachAndOthersDoNot() {
        let dsh = ExternalLightDriver.achatSendArgv(bin: "achat", app: "dsh", session: "s", text: "hi", detach: true)
        XCTAssertEqual(Array(dsh.suffix(4)), ["--detach", "--timeout", "8", "hi"])
        let codex = ExternalLightDriver.achatSendArgv(bin: "achat", app: "codex", session: "s", text: "hi")
        XCTAssertFalse(codex.contains("--detach"))
        XCTAssertEqual(ExternalLightDriver.detachedSendApps, ["dsh"])
    }

    // MARK: Relay

    func testOfflineDeliveryIsParkedAndRedeliveredWhenTheNodeIsBack() throws {
        let driver = SwitchDriver()
        let relay = try LightRelay(store: temp("relay"), driver: driver)
        _ = try relay.register(LightMember(name: "sender", host: "local", app: "webhook", project: "p", sessionID: "w", routes: []))
        _ = try relay.register(LightMember(name: "codex-air", host: "air", app: "codex", project: "p", sessionID: "s",
                                           routes: LightRouteCatalog.defaults(for: "codex")))
        let sent = try relay.send(from: "sender", to: ["codex-air"], text: "hello")
        let delivery = try XCTUnwrap(sent.deliveries.first)
        XCTAssertEqual(delivery.state, .queued)
        XCTAssertEqual(delivery.via, "queued")
        XCTAssertEqual(relay.inboxNodes(), ["air"])
        let jobs = try relay.pull(node: "air")
        XCTAssertEqual(jobs.map(\.kind), ["deliver"])
        XCTAssertEqual(relay.pendingHarvest(maxAge: 1800, limit: 8), [delivery.replyID])

        driver.state = .delivered
        let again = relay.redeliverParked(jobs[0])
        XCTAssertEqual(again?.state, .delivered)
        XCTAssertEqual(driver.delivered, ["codex-air"])
        XCTAssertTrue(relay.inboxNodes().isEmpty)

        _ = try relay.reply(delivery.replyID, text: "done")
        XCTAssertTrue(relay.pendingHarvest(maxAge: 1800, limit: 8).isEmpty)
    }

    func testNodePulledOnceDeliversAfterHeartbeatWindowWhenBrokerRosterShowsItOnline() throws {
        let clock = StepClock()
        let driver = SwitchDriver()
        driver.state = .delivered
        let link = FakeLink(nodes: [])
        let router = LightMeshRouter(link: link, hosts: LightHostsConfig(), ssh: nil, now: clock.now)
        let relay = try LightRelay(store: temp("relay"), now: clock.now, driver: driver, liveness: router)

        _ = try relay.register(LightMember(name: "sender", host: "local", app: "webhook", project: "p", sessionID: "w", routes: []))
        _ = try relay.register(LightMember(name: "codex-air", host: "air", app: "codex", project: "p", sessionID: "s",
                                           routes: LightRouteCatalog.defaults(for: "codex")))

        // 1. Node pulled once at T
        _ = try relay.pull(node: "air")

        // 2. Advance time past the 70s heartbeat window (T + 80s)
        clock.advance(80)

        // 3. Broker roster/heartbeat says the node is online (fresh heartbeat 5s ago)
        link.nodes = [LightMeshNode(id: "n-air", host: "air", lastSeen: clock.now().addingTimeInterval(-5))]
        XCTAssertTrue(relay.nodeStatus("air").online)

        // 4. Send to that node: must deliver (not be parked as offline)
        let sent = try relay.send(from: "sender", to: ["codex-air"], text: "hello")
        let delivery = try XCTUnwrap(sent.deliveries.first)
        XCTAssertEqual(delivery.state, .delivered)
        XCTAssertEqual(driver.delivered, ["codex-air"])
        XCTAssertEqual(relay.inboxNodes(), [])
    }

    func testNodeGenuinelyOfflinePerBrokerRosterIsParked() throws {
        let clock = StepClock()
        let driver = SwitchDriver()
        driver.state = .delivered
        let link = FakeLink(nodes: [])
        let router = LightMeshRouter(link: link, hosts: LightHostsConfig(), ssh: nil, now: clock.now)
        let relay = try LightRelay(store: temp("relay"), now: clock.now, driver: driver, liveness: router)

        _ = try relay.register(LightMember(name: "sender", host: "local", app: "webhook", project: "p", sessionID: "w", routes: []))
        _ = try relay.register(LightMember(name: "codex-air", host: "air", app: "codex", project: "p", sessionID: "s",
                                           routes: LightRouteCatalog.defaults(for: "codex")))

        // Broker roster says node was last seen 80s ago (offline)
        link.nodes = [LightMeshNode(id: "n-air", host: "air", lastSeen: clock.now().addingTimeInterval(-80))]
        XCTAssertFalse(relay.nodeStatus("air").online)

        let sent = try relay.send(from: "sender", to: ["codex-air"], text: "hello")
        let delivery = try XCTUnwrap(sent.deliveries.first)
        XCTAssertEqual(delivery.state, .queued)
        XCTAssertTrue(delivery.detail.contains("node offline"))
        XCTAssertEqual(driver.delivered, [])
        XCTAssertEqual(relay.inboxNodes(), ["air"])
    }

    func testNodeLivenessFallsBackToPullTimestampWhenNoBrokerRosterAvailable() throws {
        let clock = StepClock()
        let driver = SwitchDriver()
        driver.state = .delivered
        let link = FakeLink(nodes: nil) // No Broker roster
        let router = LightMeshRouter(link: link, hosts: LightHostsConfig(), ssh: nil, now: clock.now)
        let relay = try LightRelay(store: temp("relay"), now: clock.now, driver: driver, liveness: router)

        _ = try relay.register(LightMember(name: "sender", host: "local", app: "webhook", project: "p", sessionID: "w", routes: []))
        _ = try relay.register(LightMember(name: "codex-air", host: "air", app: "codex", project: "p", sessionID: "s",
                                           routes: LightRouteCatalog.defaults(for: "codex")))

        // Pulled at T0
        _ = try relay.pull(node: "air")

        // 10s later: still within heartbeat window -> delivers
        clock.advance(10)
        let first = try relay.send(from: "sender", to: ["codex-air"], text: "first")
        XCTAssertEqual(first.deliveries.first?.state, .delivered)

        // 80s later (> 70s since last pull) -> parked as offline
        clock.advance(80)
        let second = try relay.send(from: "sender", to: ["codex-air"], text: "second")
        XCTAssertEqual(second.deliveries.first?.state, .queued)
        XCTAssertTrue(second.deliveries.first?.detail.contains("node offline") == true)
    }

    func testFailedDeliveryShowsWhy() throws {
        let driver = SwitchDriver()
        driver.state = .failed
        let relay = try LightRelay(store: temp("relay"), driver: driver)
        _ = try relay.register(LightMember(name: "a", host: "local", app: "webhook", project: "p", sessionID: "w", routes: []))
        _ = try relay.register(LightMember(name: "b", host: "local", app: "dsh", project: "p", sessionID: "s", routes: []))
        let out = LightCommands.execute(command: "send", arguments: ["--from", "a", "--to", "b", "--", "q"], relay: relay,
                                        routesForApp: { _ in [] })
        XCTAssertTrue(out.text.contains("failed\tb"), out.text)
        XCTAssertTrue(out.text.contains("  ok"), out.text)
    }

    func testHeaderTellsTheAgentToStayQuietAfterReplying() throws {
        let driver = SwitchDriver()
        driver.state = .delivered
        let relay = try LightRelay(store: temp("relay"), driver: driver)
        _ = try relay.register(LightMember(name: "a", host: "local", app: "webhook", project: "p", sessionID: "w", routes: []))
        _ = try relay.register(LightMember(name: "b", host: "local", app: "codex", project: "p", sessionID: "s", routes: []))
        let sent = try relay.send(from: "a", to: ["b"], text: "q")
        let header = try XCTUnwrap(sent.deliveries.first?.header)
        XCTAssertTrue(header.contains("say nothing about it in your own chat"), header)
    }

    func testTwoProcessesShareOneStoreWithoutLosingUpdates() throws {
        let store = temp("relay")
        let first = try LightRelay(store: store, driver: SwitchDriver())
        let second = try LightRelay(store: store, driver: SwitchDriver())
        _ = try first.register(LightMember(name: "one", host: "local", app: "codex", project: "p", sessionID: "1", routes: []))
        _ = try second.register(LightMember(name: "two", host: "local", app: "codex", project: "p", sessionID: "2", routes: []))
        XCTAssertEqual(Set(first.listMembers().map(\.name)), ["one", "two"])
        XCTAssertEqual(Set(second.listMembers().map(\.name)), ["one", "two"])
    }

    func testStoreWritabilityProbe() throws {
        let store = temp("relay")
        XCTAssertTrue(LightRelay.storeIsWritable(store))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
        XCTAssertFalse(LightRelay.storeIsWritable(store))
    }

    // MARK: Spool

    func testSpoolWritesAtomicallyAndDrains() {
        let blocked = URL(fileURLWithPath: "/nonexistent-root-\(UUID().uuidString)/spool")
        let dir = temp("spool")
        let spool = LightReplySpool(directories: [blocked, dir])
        let file = spool.write(argv: ["reply", "r_1", "--", "hi"], now: t0)
        XCTAssertEqual(file?.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(spool.pending().count, 1)
        var seen: [[String]] = []
        XCTAssertEqual(spool.drain(now: t0) { seen.append($0); return false }, 0)
        XCTAssertEqual(spool.pending().count, 1, "a failed hand-off stays for the next tick")
        XCTAssertEqual(spool.drain(now: t0) { seen.append($0); return true }, 1)
        XCTAssertEqual(seen.last, ["reply", "r_1", "--", "hi"])
        XCTAssertTrue(spool.pending().isEmpty)
        XCTAssertEqual(LightReplySpool.standard(["PHAROS_LIGHT_SPOOL": "/x/y"]).directories.map(\.path), ["/x/y"])
    }

    // MARK: Broker

    func testBrokerRosterKeepsOfflineNodesAndMarksTheLocalOne() throws {
        let info = MeshNodeInfo(id: "n1", host: "Xiangs-Mac-mini.local", tailscaleIP: nil, lastSeen: t0.timeIntervalSince1970,
                                brokerLocal: true)
        let node = LightMeshNode(info)
        XCTAssertTrue(node.brokerLocal)
        XCTAssertEqual(node.name, "xiangs-mac-mini")
        XCTAssertTrue(node.online(at: t0.addingTimeInterval(60)))
        XCTAssertFalse(node.online(at: t0.addingTimeInterval(71)))
        XCTAssertEqual(LightHostDirectory.nodeName("Xiangs-MacBook-Air.local"), "xiangs-macbook-air")
    }
}
