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
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"Pharos","path":"/src/pharos"}]}"#),
            output(0, #"{"ok":true,"created":true,"route":"desktop","session":{"sessionId":"sess-9"}}"#),
        ])
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
        let argv = try XCTUnwrap(runner.invocations.last?.argv)
        XCTAssertEqual(argv, ["/tmp/achat", "codex", "new", "--host", "local", "--json", "--project", "Pharos", "hello there"])
        XCTAssertEqual(prober.calls.map(\.1), [4403])
    }

    func testDryRunDoesNotRegisterOrLaunch() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(0, #"{"ok":true,"dryRun":true,"route":"web","projects":[{"name":"pharos"}]}"#),
        ])
        let relay = try makeRelay()
        let service = makeService(relay: relay, runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: [
            "new", "--here", "--host", "mini", "--app", "dsh", "--workspace", "pharos", "--dry-run", "--launch",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertTrue(result.text.contains("dry-run"))
        XCTAssertTrue(relay.listMembers().isEmpty)
        XCTAssertEqual(runner.invocations.map { $0.argv.contains("--dry-run") }, [false, true])
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
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
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
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(3, #"{"ok":false,"error":{"code":"not-found","message":"no dsh workspace named pharos"}}"#),
        ])
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

    func testProjectAddCapability() {
        XCTAssertEqual(LightProjectAdd.plan(app: "codex", probe: .runningWithoutDebug).addable, .api)
        XCTAssertTrue(LightProjectAdd.plan(app: "codex", probe: .absent).callAchat)
        XCTAssertEqual(LightProjectAdd.plan(app: "dsh", probe: .ready), LightProjectPlan(addable: .ui, callAchat: true, message: nil))
        XCTAssertEqual(LightProjectAdd.plan(app: "dsh", probe: .absent).addable, .api)
        let held = LightProjectAdd.plan(app: "dsh", probe: .runningWithoutDebug)
        XCTAssertEqual(held.addable, .restart)
        XCTAssertFalse(held.callAchat)
        XCTAssertTrue(held.message?.contains("Add workspace") == true)
        XCTAssertFalse(LightProjectAdd.plan(app: "dsh", probe: .portHeldByOther).callAchat)
        XCTAssertEqual(LightProjectAdd.plan(app: "ag", probe: .ready).addable, .ui)
        let blocked = LightProjectAdd.plan(app: "ag", probe: .absent)
        XCTAssertFalse(blocked.callAchat)
        XCTAssertTrue(blocked.message?.contains("Create New Project") == true)
        XCTAssertTrue(blocked.message?.contains("Nothing was written") == true)
    }

    func testProjectAddChecksThePathThenCallsAchat() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"other","path":"/other"}]}"#),
            output(0, #"{"ok":true,"status":"added","name":"pharos","path":"/src/pharos","addable":"api"}"#),
        ])
        let prober = ScriptProber([.ready])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: prober)
        let result = service.executeProject(arguments: [
            "add", "--here", "--app", "codex", "--path", "/src/pharos/", "--name", "pharos",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        let object = try XCTUnwrap(json(result.text))
        XCTAssertEqual(object["status"] as? String, "added")
        XCTAssertEqual(object["addable"] as? String, "api")
        XCTAssertTrue(prober.calls.isEmpty)
        XCTAssertEqual(runner.invocations.first?.argv, ["/tmp/achat", "codex", "workspace", "list", "--host", "local", "--json"])
        XCTAssertEqual(runner.invocations.last?.argv, [
            "/tmp/achat", "codex", "workspace", "add", "/src/pharos/", "--host", "local", "--json", "--name", "pharos",
        ])
    }

    func testProjectAddIsANoOpWhenThePathIsRegistered() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
        ])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([.ready]))
        let result = service.executeProject(arguments: [
            "add", "--here", "--app", "codex", "--path", "/src/pharos", "--dry-run",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertEqual(json(result.text)?["status"] as? String, "already")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertFalse(runner.invocations.contains { $0.argv.contains("add") })
    }

    func testDesktopAddRefusesInsteadOfWritingFiles() throws {
        let dsh = ScriptedSessionRunner([])
        let dshService = makeService(relay: try makeRelay(), runner: dsh, prober: ScriptProber([.runningWithoutDebug]))
        let refused = dshService.executeProject(arguments: ["add", "--here", "--app", "dsh", "--path", "/src/pharos"])
        XCTAssertEqual(refused.exitCode, 1, refused.text)
        XCTAssertEqual(json(refused.text)?["status"] as? String, "needs_user_action")
        XCTAssertEqual(json(refused.text)?["addable"] as? String, "restart")
        XCTAssertTrue(refused.text.contains("Add workspace"))
        XCTAssertTrue(refused.text.contains("Nothing was written"))
        XCTAssertTrue(dsh.invocations.isEmpty)

        let ag = ScriptedSessionRunner([])
        let agService = makeService(relay: try makeRelay(), runner: ag, prober: ScriptProber([.absent]))
        let blocked = agService.executeProject(arguments: ["add", "--here", "--app", "ag", "--path", "/src/pharos"])
        XCTAssertEqual(json(blocked.text)?["status"] as? String, "needs_user_action")
        XCTAssertEqual(json(blocked.text)?["addable"] as? String, "ui")
        XCTAssertTrue(blocked.text.contains("Create New Project"))
        XCTAssertTrue(ag.invocations.isEmpty)

        let missing = LightSessionService(relay: try makeRelay(), runner: ScriptedSessionRunner([]), prober: ScriptProber([.ready]),
                                          ports: LightDebugPorts(dsh: 4401, ag: nil, codex: 4403), apps: bins(), launchPolls: 1)
        let unconfigured = missing.executeProject(arguments: ["add", "--here", "--app", "ag", "--path", "/src/pharos"])
        XCTAssertEqual(json(unconfigured.text)?["status"] as? String, "needs_user_action")
        XCTAssertTrue(unconfigured.text.contains("debug port is not configured"))

        let ui = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[]}"#),
            output(0, #"{"ok":true,"status":"added","name":"pharos","path":"/src/pharos","addable":"ui"}"#),
        ])
        let ready = makeService(relay: try makeRelay(), runner: ui, prober: ScriptProber([.ready]))
        let added = ready.executeProject(arguments: ["add", "--here", "--app", "dsh", "--path", "/src/pharos", "--name", "pharos"])
        XCTAssertEqual(json(added.text)?["status"] as? String, "added")
        XCTAssertEqual(json(added.text)?["addable"] as? String, "ui")
        XCTAssertEqual(ui.invocations.last?.argv.prefix(4).map { $0 }, ["/tmp/achat", "dsh", "workspace", "add"])
    }

    func testProjectListAndAddStayOnTheTargetNode() throws {
        let relay = try makeRelay()
        _ = try relay.heartbeat(node: "mini")
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"status":"listed","projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(255, "", "ssh: connect to host mini: No route to host"),
        ])
        let prober = ScriptProber([.ready])
        let service = makeService(relay: relay, runner: runner, prober: prober)
        let listed = service.executeProject(arguments: ["list", "--host", "mini", "--app", "codex"])
        XCTAssertEqual(listed.exitCode, 0, listed.text)
        XCTAssertTrue(listed.text.contains("pharos"))
        XCTAssertTrue(listed.text.contains("/src/pharos"))
        let remote = try XCTUnwrap(runner.invocations.first?.argv)
        XCTAssertEqual(remote.first, "ssh")
        XCTAssertFalse(remote.contains("achat"))
        XCTAssertFalse(remote.contains("--host"))
        let command = try XCTUnwrap(remote.last)
        XCTAssertTrue(command.contains("'project'"))
        XCTAssertTrue(command.contains("'list'"))
        XCTAssertTrue(command.contains("'--here'"))
        XCTAssertTrue(command.contains("'codex'"))
        XCTAssertTrue(prober.calls.isEmpty)

        let queued = service.executeProject(arguments: ["add", "--host", "mini", "--app", "dsh", "--path", "/src/pharos", "--name", "pharos"])
        XCTAssertEqual(queued.exitCode, 0, queued.text)
        XCTAssertTrue(queued.text.contains("queued "))
        XCTAssertTrue(queued.text.contains("node offline"))
        XCTAssertFalse(queued.text.lowercased().contains("unreachable"))
        XCTAssertFalse(queued.text.contains("No route"))
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(runner.invocations.last?.argv.first, "ssh")
        let id = queued.text.split(separator: "\n").first.map { String($0.split(separator: " ").last ?? "") } ?? ""
        let jobs = try relay.pull(node: "mini")
        XCTAssertEqual(jobs.map(\.kind), ["project-add"])
        XCTAssertEqual(jobs.map(\.id), [id])
        let done = service.complete(id: id, result: #"{"ok":true,"status":"added","name":"pharos","path":"/src/pharos"}"#)
        XCTAssertEqual(done.exitCode, 0, done.text)
        XCTAssertTrue(relay.listMembers().isEmpty)

        let clock = SessionClock()
        let offline = try makeRelay(now: clock.now)
        _ = try offline.heartbeat(node: "mini")
        clock.advance(80)
        let quiet = ScriptedSessionRunner([])
        let failing = makeService(relay: offline, runner: quiet, prober: ScriptProber([]))
        let stopped = failing.executeProject(arguments: [
            "add", "--host", "mini", "--app", "ag", "--path", "/src/pharos", "--no-queue",
        ])
        XCTAssertEqual(stopped.exitCode, 1)
        XCTAssertTrue(stopped.text.contains("node offline"))
        XCTAssertTrue(quiet.invocations.isEmpty)
    }

    func testSessionNewFailsWhenTheProjectIsNotRegistered() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"other","path":"/other"}]}"#),
            output(0, #"{"ok":true,"created":true,"session":{"sessionId":"sess-should-not"}}"#),
        ])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: ["new", "--here", "--app", "dsh", "--workspace", "pharos"])
        XCTAssertEqual(result.exitCode, 1, result.text)
        XCTAssertTrue(result.text.contains("project is not registered"), result.text)
        XCTAssertFalse(runner.invocations.contains { $0.argv.contains("new") })
    }

    func testSessionNewAddProjectRunsAddFirst() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[]}"#),
            output(0, #"{"ok":true,"status":"added","name":"pharos","path":"/src/pharos","addable":"api"}"#),
            output(0, #"{"ok":true,"created":true,"route":"web","session":{"sessionId":"sess-9"}}"#),
        ])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: [
            "new", "--here", "--app", "codex", "--workspace", "pharos", "--add-project", "/src/pharos", "--title", "hello",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertEqual(json(result.text)?["sessionId"] as? String, "sess-9")
        XCTAssertEqual(runner.invocations.map(\.argv), [
            ["/tmp/achat", "codex", "workspace", "list", "--host", "local", "--json"],
            ["/tmp/achat", "codex", "workspace", "add", "/src/pharos", "--host", "local", "--json", "--name", "pharos"],
            ["/tmp/achat", "codex", "new", "--host", "local", "--json", "--project", "pharos", "hello"],
        ])

        let relay = try makeRelay()
        _ = try relay.heartbeat(node: "mini")
        let forward = ScriptedSessionRunner([
            output(0, #"{"ok":true,"status":"created","sessionId":"sess-forward","route":"web","dryRun":false,"projects":[]}"#),
        ])
        let caller = makeService(relay: relay, runner: forward, prober: ScriptProber([]))
        let sent = caller.execute(arguments: [
            "new", "--host", "mini", "--app", "codex", "--workspace", "pharos", "--add-project", "/src/pharos",
        ])
        XCTAssertEqual(sent.exitCode, 0, sent.text)
        XCTAssertEqual(relay.member(named: "codex-mini-pharos")?.sessionID, "sess-forward")
        let remote = forward.invocations.first?.argv.dropFirst(7).joined(separator: " ") ?? ""
        XCTAssertTrue(remote.contains("'--add-project'"))
        XCTAssertTrue(remote.contains("'/src/pharos'"))
        XCTAssertFalse(remote.contains("--host"))
        XCTAssertEqual(forward.invocations.first?.argv.first, "ssh")
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
