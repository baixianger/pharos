import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

final class LightSessionTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores {
            try? FileManager.default.removeItem(at: store)
        }
        stores.removeAll()
        super.tearDown()
    }

    func testDebugPortsComeFromTheEnvironment() {
        XCTAssertNil(LightDebugPorts.fromEnvironment([:]).dsh)
        XCTAssertNil(LightDebugPorts.fromEnvironment([:]).codex)
        XCTAssertNil(LightDebugPorts.fromEnvironment([:]).ag)
        XCTAssertEqual(LightDebugPorts.fromEnvironment(["PHAROS_DSH_CDP_PORT": "4401"]).dsh, 4401)
        XCTAssertEqual(LightAppBins.fromEnvironment([:]).achat, "achat")
        XCTAssertNil(LightAppBins.fromEnvironment([:]).codex)
    }

    func testNewMapsArgumentsAndRegistersTheMember() throws {
        let runner = ScriptedSessionRunner([output(0, #"{"ok":true,"status":"created","sessionId":"sess-1","route":"web","dryRun":false,"projects":[]}"#)])
        let relay = try makeRelay()
        _ = try relay.heartbeat(node: "mini")
        let service = makeService(relay: relay, runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: [
            "new", "--host", "mini", "--app", "dsh", "--workspace", "pharos",
            "--title", "Hello", "--name", "custom-bot", "--launch",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertTrue(result.text.contains("registered custom-bot"))
        XCTAssertTrue(result.text.contains("session sess-1"))
        XCTAssertEqual(relay.member(named: "custom-bot")?.sessionID, "sess-1")
        XCTAssertEqual(relay.member(named: "custom-bot")?.host, "mini")
        XCTAssertEqual(relay.member(named: "custom-bot")?.app, "dsh")
        let argv = try XCTUnwrap(runner.invocations.first?.argv)
        XCTAssertEqual(Array(argv.prefix(6)), ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "--"])
        XCTAssertEqual(argv.dropFirst(6).first, "mini")
        XCTAssertFalse(argv.contains("-L"))
        XCTAssertFalse(argv.contains("-R"))
        let remote = argv.dropFirst(7).joined(separator: " ")
        XCTAssertTrue(remote.contains("'--here'"))
        XCTAssertTrue(remote.contains("'dsh'"))
        XCTAssertTrue(remote.contains("'pharos'"))
        XCTAssertTrue(remote.contains("'Hello'"))
        XCTAssertTrue(remote.contains("'custom-bot'"))
        XCTAssertTrue(remote.contains("'--launch'"))
        XCTAssertFalse(remote.contains("--host"))
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertFalse(argv.contains("achat"))
    }

    func testDefaultNameAndAchatJsonOnTheTarget() throws {
        let runner = ScriptedSessionRunner([output(0, #"{"ok":true,"created":true,"route":"desktop","session":{"sessionId":"sess-9"}}"#)])
        let relay = try makeRelay()
        let prober = ScriptProber([.ready])
        let service = makeService(relay: relay, runner: runner, prober: prober)
        let result = service.execute(arguments: [
            "new", "--here", "--host", "mini", "--app", "codex", "--workspace", "Pharos", "--title", "hello there",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        let object = try XCTUnwrap(json(result.text))
        XCTAssertEqual(object["sessionId"] as? String, "sess-9")
        XCTAssertEqual(object["route"] as? String, "desktop")
        XCTAssertNil(relay.member(named: "codex-mini-pharos"))
        let argv = try XCTUnwrap(runner.invocations.first?.argv)
        XCTAssertEqual(argv, ["/tmp/achat", "codex", "new", "--host", "local", "--json", "--project", "Pharos", "hello there"])
        XCTAssertEqual(prober.calls.map(\.1), [4403])
    }

    func testDryRunDoesNotRegisterOrLaunch() throws {
        let runner = ScriptedSessionRunner([output(0, #"{"ok":true,"dryRun":true,"route":"web","projects":[{"name":"pharos"}]}"#)])
        let relay = try makeRelay()
        let service = makeService(relay: relay, runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: [
            "new", "--here", "--host", "mini", "--app", "dsh", "--workspace", "pharos", "--dry-run", "--launch",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertTrue(result.text.contains("dry-run"))
        XCTAssertTrue(relay.listMembers().isEmpty)
        XCTAssertEqual(runner.invocations.map { $0.argv.contains("--dry-run") }, [true])
        XCTAssertFalse(runner.invocations.contains { $0.argv.contains("--remote-debugging-address=127.0.0.1") })
    }

    func testLaunchDecisionTable() throws {
        let refuse: [(LightAppProbe, String)] = [
            (.runningWithoutDebug, "quit it and relaunch"),
            (.portHeldByOther, "held by something else"),
            (.absent, "app not running"),
        ]
        for (probe, needle) in refuse {
            let runner = ScriptedSessionRunner([])
            let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([probe]))
            let launch = probe == .absent ? [] : ["--launch"]
            let result = service.execute(arguments: ["new", "--here", "--app", "dsh", "--workspace", "pharos"] + launch)
            XCTAssertEqual(result.exitCode, 1, result.text)
            XCTAssertTrue(result.text.contains(needle), result.text)
            XCTAssertTrue(runner.invocations.isEmpty)
        }

        let runner = ScriptedSessionRunner([
            output(0, ""),
            output(0, #"{"ok":true,"created":true,"route":"desktop","threadId":"thr-1"}"#),
        ])
        let prober = ScriptProber([.absent, .ready])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: prober)
        let result = service.execute(arguments: ["new", "--here", "--app", "ag", "--workspace", "pharos", "--launch"])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertTrue(result.text.contains("thr-1"))
        let launch = try XCTUnwrap(runner.invocations.first?.argv)
        XCTAssertTrue(launch.contains("--remote-debugging-address=127.0.0.1"))
        XCTAssertTrue(launch.contains("--remote-debugging-port=4402"))
        XCTAssertFalse(launch.joined(separator: " ").contains("0.0.0.0"))
        XCTAssertEqual(runner.invocations.last?.argv.prefix(3).map { $0 }, ["/tmp/achat", "ag", "new"])
    }

    func testMissingPortDoesNotGuess() throws {
        var ports = LightDebugPorts(dsh: 4401, ag: 4402, codex: 4403)
        ports.dsh = nil
        let runner = ScriptedSessionRunner([])
        let relay = try makeRelay()
        let service = LightSessionService(relay: relay, runner: runner, prober: ScriptProber([.ready]),
                                          ports: ports, apps: bins(), launchPolls: 1)
        let result = service.execute(arguments: ["new", "--here", "--app", "dsh", "--workspace", "pharos", "--launch"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.text.contains("debug port is not configured"))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testAchatErrorIsSurfaced() throws {
        let runner = ScriptedSessionRunner([output(3, #"{"ok":false,"error":{"code":"not-found","message":"no dsh workspace named pharos"}}"#)])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: ["new", "--here", "--app", "dsh", "--workspace", "pharos"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.text.contains("not-found: no dsh workspace named pharos"), result.text)
    }

    func testWorkspacesList() throws {
        let runner = ScriptedSessionRunner([output(0, #"{"ok":true,"projects":[{"name":"pharos","sessions":[]},{"name":"notes","sessions":[]}]}"#)])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: ["workspaces", "--here", "--app", "codex"])
        XCTAssertEqual(result.exitCode, 0, result.text)
        let object = try XCTUnwrap(json(result.text))
        XCTAssertEqual(object["projects"] as? [String], ["pharos", "notes"])
        XCTAssertEqual(runner.invocations.first?.argv, ["/tmp/achat", "codex", "list", "--host", "local", "--json"])
    }

    func testOfflineNodeQueuesAndDoesNotFallBack() throws {
        let runner = ScriptedSessionRunner([output(255, "", "ssh: connect to host mini: No route to host")])
        let clock = SessionClock()
        let relay = try makeRelay(now: clock.now)
        _ = try relay.heartbeat(node: "mini")
        let service = makeService(relay: relay, runner: runner, prober: ScriptProber([.ready]))
        let failed = service.execute(arguments: ["new", "--host", "mini", "--app", "dsh", "--workspace", "pharos"])
        XCTAssertEqual(failed.exitCode, 0, failed.text)
        XCTAssertTrue(failed.text.contains("queued "))
        XCTAssertTrue(failed.text.contains("node offline"))
        XCTAssertFalse(failed.text.lowercased().contains("unreachable"))
        XCTAssertFalse(failed.text.contains("No route"))
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.argv.first, "ssh")
        let id = failed.text.split(separator: "\n").first.map { String($0.split(separator: " ").last ?? "") } ?? ""
        let jobs = try relay.pull(node: "mini")
        XCTAssertEqual(jobs.map(\.id), [id])
        XCTAssertEqual(jobs.first?.kind, "session-new")

        let done = service.complete(id: id, result: #"{"ok":true,"status":"created","sessionId":"sess-queued","route":"web"}"#)
        XCTAssertEqual(done.exitCode, 0, done.text)
        XCTAssertEqual(relay.member(named: "dsh-mini-pharos")?.sessionID, "sess-queued")
        let again = service.complete(id: id, result: #"{"ok":true,"status":"created","sessionId":"sess-other","route":"web"}"#)
        XCTAssertEqual(again.exitCode, 0)
        XCTAssertTrue(again.text.contains("duplicate ignored"))
        XCTAssertEqual(relay.member(named: "dsh-mini-pharos")?.sessionID, "sess-queued")
        XCTAssertTrue(try relay.pull(node: "mini").isEmpty)

        _ = try relay.enqueueNodeJob(id: "n_expire002", node: "mini", kind: "session-new", payload: "{}")
        clock.advance(73 * 60 * 60)
        XCTAssertEqual(relay.sweep().expiredInbox, 1)
        XCTAssertNil(relay.nodeJob("n_expire002"))
    }

    func testNoQueueFailsImmediatelyWhenTheNodeIsOffline() throws {
        let runner = ScriptedSessionRunner([])
        let clock = SessionClock()
        let relay = try makeRelay(now: clock.now)
        _ = try relay.heartbeat(node: "mini")
        clock.advance(80)
        let service = makeService(relay: relay, runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: [
            "new", "--host", "mini", "--app", "ag", "--workspace", "pharos", "--no-queue",
        ])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.text.contains("node offline"))
        XCTAssertTrue(result.text.contains("last-seen"))
        XCTAssertFalse(result.text.lowercased().contains("unreachable"))
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(try relay.pull(node: "mini").isEmpty)
    }

    func testNameCollisionDoesNotReplaceTheMember() throws {
        let runner = ScriptedSessionRunner([output(0, #"{"ok":true,"status":"created","sessionId":"sess-new","route":"desktop","dryRun":false,"projects":[]}"#)])
        let relay = try makeRelay()
        _ = try relay.heartbeat(node: "mini")
        _ = try relay.register(LightMember(name: "custom-bot", host: "mini", app: "dsh", project: "pharos",
                                           sessionID: "sess-old", routes: []))
        let service = makeService(relay: relay, runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: [
            "new", "--host", "mini", "--app", "dsh", "--workspace", "pharos", "--name", "custom-bot",
        ])
        XCTAssertEqual(result.exitCode, 1, result.text)
        XCTAssertTrue(result.text.contains("already registered"))
        XCTAssertEqual(relay.member(named: "custom-bot")?.sessionID, "sess-old")
    }

    private func makeRelay(now: (@Sendable () -> Date)? = nil) throws -> LightRelay {
        if let now {
            return try LightRelay(store: freshStore(), now: now, driver: IdleLightDriver())
        }
        return try LightRelay(store: freshStore(), driver: IdleLightDriver())
    }

    private func makeService(relay: LightRelay, runner: ScriptedSessionRunner, prober: ScriptProber) -> LightSessionService {
        LightSessionService(relay: relay, runner: runner, prober: prober, ports: LightDebugPorts(dsh: 4401, ag: 4402, codex: 4403),
                            apps: bins(), launchPolls: 2)
    }

    private func bins() -> LightAppBins {
        LightAppBins(achat: "/tmp/achat", dsh: "/tmp/bin/dsh", ag: "/tmp/bin/ag", codex: "/tmp/bin/codex")
    }

    private func freshStore() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-session-\(UUID().uuidString)", isDirectory: true)
        stores.append(url)
        return url
    }

    private func output(_ status: Int32, _ stdout: String, _ stderr: String = "") -> LightProcessOutput {
        LightProcessOutput(status: status, stdout: stdout, stderr: stderr)
    }

    private func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private final class SessionClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { current }
    func advance(_ interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}

private final class ScriptProber: LightAppProbing, @unchecked Sendable {
    var script: [LightAppProbe]
    var calls: [(String, Int)] = []
    init(_ script: [LightAppProbe]) { self.script = script }
    func probe(app: String, port: Int) -> LightAppProbe {
        calls.append((app, port))
        if script.isEmpty { return .absent }
        return script.removeFirst()
    }
}

private final class ScriptedSessionRunner: LightProcessRunning, @unchecked Sendable {
    var results: [LightProcessOutput]
    var invocations: [LightInvocation] = []
    init(_ results: [LightProcessOutput]) { self.results = results }
    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        var copy = invocation
        copy.stdin = stdin
        invocations.append(copy)
        if results.isEmpty { return LightProcessOutput(status: 1, stdout: "", stderr: "none") }
        return results.removeFirst()
    }
}
