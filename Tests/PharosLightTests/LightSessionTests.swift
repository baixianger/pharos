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
        let defaults = LightDebugPorts.fromEnvironment([:])
        XCTAssertEqual(defaults.dsh, LightDebugPorts.dshLaunchDefault)
        XCTAssertEqual(defaults.codex, LightDebugPorts.codexLaunchDefault)
        XCTAssertNil(defaults.ag)
        let config = #"{"defaults":{"dsh":{"cdpPort":4409},"ag":{"cdpPort":[4410]},"codex":{"cdpPort":4411}}}"#
        let configured = LightDebugPorts.fromEnvironment([:], configJSON: config)
        XCTAssertEqual(configured.dsh, 4409)
        XCTAssertEqual(configured.ag, 4410)
        XCTAssertEqual(configured.codex, 4411)
        let overridden = LightDebugPorts.fromEnvironment(["PHAROS_DSH_CDP_PORT": "4401"], configJSON: config)
        XCTAssertEqual(overridden.dsh, 4401)
        XCTAssertEqual(overridden.codex, 4411)
        XCTAssertEqual(LightAppBins.fromEnvironment([:]).achat, "achat")
        XCTAssertNil(LightAppBins.fromEnvironment([:]).codex)

        let selfHost = LightSelfHost.fromEnvironment(["PHAROS_SELF_HOST": "desk", "PHAROS_NODE_NAME": "node-a"])
        XCTAssertTrue(selfHost.matches("local"))
        XCTAssertTrue(selfHost.matches("LOCAL"))
        XCTAssertTrue(selfHost.matches("desk"))
        XCTAssertTrue(selfHost.matches("node-a"))
        XCTAssertTrue(selfHost.matches(ProcessInfo.processInfo.hostName))
        if let short = ProcessInfo.processInfo.hostName.split(separator: ".").first, !short.isEmpty {
            XCTAssertTrue(selfHost.matches(String(short)))
        }
        XCTAssertFalse(selfHost.matches("mini"))
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
        XCTAssertTrue(prober.calls.isEmpty)
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
        ]
        for (probe, needle) in refuse {
            let runner = ScriptedSessionRunner([
                output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            ])
            let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([probe]))
            let result = service.execute(arguments: ["new", "--here", "--app", "dsh", "--workspace", "pharos", "--launch"])
            XCTAssertEqual(result.exitCode, 1, result.text)
            XCTAssertTrue(result.text.contains(needle), result.text)
            XCTAssertFalse(runner.invocations.contains { $0.argv.dropFirst(2).first == "new" })
        }

        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(0, ""),
            output(0, #"{"ok":true,"created":true,"route":"desktop","threadId":"thr-1"}"#),
        ])
        let prober = ScriptProber([.absent, .ready])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: prober)
        let result = service.execute(arguments: ["new", "--here", "--app", "ag", "--workspace", "pharos", "--launch"])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertTrue(result.text.contains("thr-1"))
        let launch = try XCTUnwrap(runner.invocations.first { $0.argv.contains { $0.hasPrefix("--remote-debugging-port=") } }?.argv)
        XCTAssertTrue(launch.contains("--remote-debugging-address=127.0.0.1"))
        XCTAssertTrue(launch.contains("--remote-debugging-port=4402"))
        XCTAssertFalse(launch.joined(separator: " ").contains("0.0.0.0"))
        XCTAssertEqual(runner.invocations.first?.argv.prefix(4).map { $0 }, ["/tmp/achat", "ag", "workspace", "list"])
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
        XCTAssertFalse(result.text.contains("queued"))
        XCTAssertFalse(result.text.lowercased().contains("unreachable"))
        XCTAssertEqual(runner.invocations.count, 1)
        let probe = try XCTUnwrap(runner.invocations.first?.argv)
        XCTAssertEqual(probe.first, "ssh")
        XCTAssertTrue(probe.contains("ConnectTimeout=5"))
        XCTAssertEqual(probe.last, "pharos --version")
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

        let missingRunner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[]}"#),
            output(0, #"{"ok":true,"status":"added","name":"pharos","path":"/src/pharos","addable":"ui"}"#),
        ])
        let missing = LightSessionService(relay: try makeRelay(), runner: missingRunner, prober: ScriptProber([.ready]),
                                          ports: LightDebugPorts(dsh: 4401, ag: nil, codex: 4403), apps: bins(), launchPolls: 1)
        let unconfigured = missing.executeProject(arguments: ["add", "--here", "--app", "ag", "--path", "/src/pharos", "--name", "pharos"])
        XCTAssertEqual(json(unconfigured.text)?["status"] as? String, "added")
        XCTAssertFalse(unconfigured.text.contains("debug port is not configured"))
        XCTAssertEqual(missingRunner.invocations.last?.argv.prefix(4).map { $0 }, ["/tmp/achat", "ag", "workspace", "add"])

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
        XCTAssertFalse(stopped.text.contains("queued"))
        XCTAssertEqual(quiet.invocations.count, 1)
        XCTAssertEqual(quiet.invocations.first?.argv.last, "pharos --version")
        XCTAssertTrue(quiet.invocations.first?.argv.contains("ConnectTimeout=5") == true)
    }

    func testSessionNewFailsWhenTheProjectIsNotRegistered() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"other","path":"/other"}]}"#),
            output(0, #"{"ok":true,"status":"added","name":"pharos","path":"pharos","addable":"api"}"#),
            output(0, #"{"ok":true,"created":true,"session":{"sessionId":"sess-should-not"}}"#),
        ])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([.ready]))
        let result = service.execute(arguments: [
            "new", "--here", "--app", "codex", "--workspace", "pharos", "--no-add-project",
        ])
        XCTAssertEqual(result.exitCode, 1, result.text)
        XCTAssertTrue(result.text.contains("project is not registered"), result.text)
        XCTAssertFalse(runner.invocations.contains { $0.argv.contains("new") })
        XCTAssertFalse(runner.invocations.contains { $0.argv.contains("add") })

        let strict = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(0, #"{"ok":true,"created":true,"session":{"sessionId":"sess-strict"}}"#),
        ])
        let kept = makeService(relay: try makeRelay(), runner: strict, prober: ScriptProber([]))
        let created = kept.execute(arguments: [
            "new", "--here", "--app", "codex", "--workspace", "pharos", "--no-add-project",
        ])
        XCTAssertEqual(created.exitCode, 0, created.text)
        XCTAssertTrue(strict.invocations.last?.argv.contains("--no-add-workspace") == true)
    }

    func testSessionNewAddsAMissingProjectThenCreates() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[]}"#),
            output(0, #"{"ok":true,"status":"added","name":"pharos","path":"/src/pharos","addable":"api"}"#),
            output(0, #"{"ok":true,"created":true,"route":"web","session":{"sessionId":"sess-9"}}"#),
        ])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([.ready]))
        let retired = service.execute(arguments: [
            "new", "--here", "--app", "codex", "--workspace", "pharos", "--add-project", "/src/pharos",
        ])
        XCTAssertEqual(retired.exitCode, 2, retired.text)
        XCTAssertTrue(retired.text.contains("--no-add-project"))
        XCTAssertTrue(runner.invocations.isEmpty)

        let result = service.execute(arguments: [
            "new", "--here", "--app", "codex", "--workspace", "pharos", "--path", "/src/pharos", "--title", "hello",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertEqual(json(result.text)?["sessionId"] as? String, "sess-9")
        XCTAssertEqual(runner.invocations.map(\.argv), [
            ["/tmp/achat", "codex", "workspace", "list", "--host", "local", "--json"],
            ["/tmp/achat", "codex", "workspace", "add", "/src/pharos", "--host", "local", "--json", "--name", "pharos"],
            ["/tmp/achat", "codex", "new", "--host", "local", "--json", "--project", "pharos", "hello"],
        ])
        XCTAssertFalse(runner.invocations.last?.argv.contains("--no-add-workspace") == true)

        let relay = try makeRelay()
        _ = try relay.heartbeat(node: "mini")
        let forward = ScriptedSessionRunner([
            output(0, #"{"ok":true,"status":"created","sessionId":"sess-forward","route":"web","dryRun":false,"projects":[]}"#),
        ])
        let caller = makeService(relay: relay, runner: forward, prober: ScriptProber([]))
        let sent = caller.execute(arguments: [
            "new", "--host", "mini", "--app", "codex", "--workspace", "/src/pharos",
        ])
        XCTAssertEqual(sent.exitCode, 0, sent.text)
        XCTAssertEqual(relay.member(named: "codex-mini-pharos")?.sessionID, "sess-forward")
        let remote = forward.invocations.first?.argv.dropFirst(7).joined(separator: " ") ?? ""
        XCTAssertTrue(remote.contains("'--workspace'"))
        XCTAssertTrue(remote.contains("'pharos'"))
        XCTAssertTrue(remote.contains("'--path'"))
        XCTAssertTrue(remote.contains("'/src/pharos'"))
        XCTAssertFalse(remote.contains("--add-project"))
        XCTAssertFalse(remote.contains("--host"))
        XCTAssertEqual(forward.invocations.first?.argv.first, "ssh")
    }

    func testNeedsUserActionStopsSessionNew() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[]}"#),
            output(0, #"{"ok":true,"created":true,"session":{"sessionId":"sess-no"}}"#),
        ])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([.runningWithoutDebug]))
        let result = service.execute(arguments: ["new", "--here", "--app", "dsh", "--workspace", "pharos"])
        XCTAssertEqual(result.exitCode, 1, result.text)
        XCTAssertEqual(json(result.text)?["status"] as? String, "needs_user_action")
        XCTAssertTrue(result.text.contains("Add workspace"))
        XCTAssertEqual(runner.invocations.map { $0.argv.prefix(4).map { $0 } }, [["/tmp/achat", "dsh", "workspace", "list"]])
    }

    func testLocalHostRunsInProcess() throws {
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(0, #"{"ok":true,"created":true,"route":"web","session":{"sessionId":"sess-local"}}"#),
        ])
        let relay = try makeRelay()
        let service = makeService(relay: relay, runner: runner, prober: ScriptProber([.absent]))
        let result = service.execute(arguments: [
            "new", "--host", "local", "--app", "codex", "--workspace", "pharos",
        ])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertTrue(result.text.contains("registered codex-local-pharos"), result.text)
        XCTAssertTrue(result.text.contains("session sess-local"))
        XCTAssertEqual(relay.member(named: "codex-local-pharos")?.sessionID, "sess-local")
        XCTAssertFalse(runner.invocations.contains { $0.argv.first == "ssh" })
        XCTAssertNil(relay.nodeStatus("local").lastSeen)

        let aliasRunner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(0, #"{"ok":true,"created":true,"route":"web","session":{"sessionId":"sess-self"}}"#),
        ])
        let aliasRelay = try makeRelay()
        let alias = LightSessionService(relay: aliasRelay, runner: aliasRunner, prober: ScriptProber([]),
                                        ports: LightDebugPorts(dsh: 4401, ag: 4402, codex: 4403), apps: bins(),
                                        selfHost: LightSelfHost(names: ["local", "this-mac"]), launchPolls: 1)
        let aliased = alias.execute(arguments: ["new", "--host", "this-mac", "--app", "dsh", "--workspace", "pharos"])
        XCTAssertEqual(aliased.exitCode, 0, aliased.text)
        XCTAssertEqual(aliasRelay.member(named: "dsh-this-mac-pharos")?.host, "this-mac")
        XCTAssertFalse(aliasRunner.invocations.contains { $0.argv.first == "ssh" })
    }

    func testVersionProbeTreatsAReachableNodeAsOnline() throws {
        let created = #"{"ok":true,"status":"created","sessionId":"sess-live","route":"web","dryRun":false,"projects":[]}"#
        let runner = ScriptedSessionRunner([
            output(0, "pharos 0.11.1\n"),
            output(0, created),
        ])
        let relay = try makeRelay()
        let service = makeService(relay: relay, runner: runner, prober: ScriptProber([]))
        let result = service.execute(arguments: ["new", "--host", "mini", "--app", "dsh", "--workspace", "pharos"])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertTrue(result.text.contains("registered dsh-mini-pharos"), result.text)
        XCTAssertTrue(result.text.contains("session sess-live"))
        XCTAssertFalse(result.text.contains("queued"))
        XCTAssertFalse(result.text.contains("last-seen never"))
        XCTAssertNil(relay.nodeStatus("mini").lastSeen)
        XCTAssertEqual(runner.invocations.count, 2)
        let probe = runner.invocations[0].argv
        XCTAssertEqual(Array(probe.prefix(6)), ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--"])
        XCTAssertEqual(probe.last, "pharos --version")
        let command = runner.invocations[1].argv
        XCTAssertTrue(command.contains("ConnectTimeout=6"))
        XCTAssertTrue(command.last?.contains("'--here'") == true)
        XCTAssertFalse(runner.invocations.contains { $0.argv.contains("achat") })

        let down = ScriptedSessionRunner([output(255, "", "ssh: connect to host mini port 22: Connection refused")])
        let queuedRelay = try makeRelay()
        let queuedService = makeService(relay: queuedRelay, runner: down, prober: ScriptProber([]))
        let queued = queuedService.execute(arguments: ["new", "--host", "mini", "--app", "dsh", "--workspace", "pharos"])
        XCTAssertEqual(queued.exitCode, 0, queued.text)
        XCTAssertTrue(queued.text.contains("queued "))
        XCTAssertTrue(queued.text.contains("last-seen never"))
        XCTAssertFalse(queued.text.lowercased().contains("unreachable"))
        XCTAssertFalse(queued.text.contains("Connection refused"))
        XCTAssertEqual(down.invocations.count, 1)
        XCTAssertEqual(down.invocations.first?.argv.last, "pharos --version")
    }

    func testSessionNewWithoutLaunchDoesNotNeedADebugPort() throws {
        let prober = ScriptProber([.absent])
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(0, #"{"ok":true,"created":true,"route":"app-server","session":{"sessionId":"sess-ipc"}}"#),
        ])
        let service = LightSessionService(relay: try makeRelay(), runner: runner, prober: prober,
                                          ports: LightDebugPorts(dsh: nil, ag: nil, codex: nil), apps: bins(), launchPolls: 1)
        let result = service.execute(arguments: ["new", "--here", "--app", "codex", "--workspace", "pharos"])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertEqual(json(result.text)?["sessionId"] as? String, "sess-ipc")
        XCTAssertFalse(result.text.contains("debug port is not configured"))
        XCTAssertFalse(result.text.contains("app not running"))
        XCTAssertTrue(prober.calls.isEmpty)

        let launchRunner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(0, ""),
            output(0, #"{"ok":true,"created":true,"route":"desktop","threadId":"thr-dsh"}"#),
        ])
        let launchProber = ScriptProber([.absent, .ready])
        let launching = LightSessionService(relay: try makeRelay(), runner: launchRunner, prober: launchProber,
                                            ports: LightDebugPorts.fromEnvironment([:]), apps: bins(), launchPolls: 2)
        let launched = launching.execute(arguments: ["new", "--here", "--app", "dsh", "--workspace", "pharos", "--launch"])
        XCTAssertEqual(launched.exitCode, 0, launched.text)
        let argv = try XCTUnwrap(launchRunner.invocations.first { $0.argv.contains { $0.hasPrefix("--remote-debugging-port=") } }?.argv)
        XCTAssertTrue(argv.contains("--remote-debugging-port=9301"))
        XCTAssertTrue(argv.contains("--remote-debugging-address=127.0.0.1"))

        let overridden = ScriptedSessionRunner([
            output(0, #"{"ok":true,"projects":[{"name":"pharos","path":"/src/pharos"}]}"#),
            output(0, ""),
            output(0, #"{"ok":true,"created":true,"route":"desktop","threadId":"thr-env"}"#),
        ])
        let envLaunch = LightSessionService(
            relay: try makeRelay(), runner: overridden, prober: ScriptProber([.absent, .ready]),
            ports: LightDebugPorts.fromEnvironment(["PHAROS_DSH_CDP_PORT": "4401"]), apps: bins(), launchPolls: 2)
        XCTAssertEqual(envLaunch.execute(arguments: ["new", "--here", "--app", "dsh", "--workspace", "pharos", "--launch"]).exitCode, 0)
        XCTAssertTrue(overridden.invocations.contains { $0.argv.contains("--remote-debugging-port=4401") })

        let quiet = ScriptedSessionRunner([])
        let ag = LightSessionService(relay: try makeRelay(), runner: quiet, prober: ScriptProber([.ready]),
                                     ports: LightDebugPorts.fromEnvironment([:]), apps: bins(), launchPolls: 1)
        let blocked = ag.execute(arguments: ["new", "--here", "--app", "ag", "--workspace", "pharos", "--launch"])
        XCTAssertEqual(blocked.exitCode, 1)
        XCTAssertTrue(blocked.text.contains("debug port is not configured"))
        XCTAssertTrue(quiet.invocations.isEmpty)
    }

    func testRealAchatWorkspaceListShapeAndTildePathsAreRecognised() throws {
        // achat 3a6acfc: `workspace list` emits `workspaces` and abbreviates $HOME to `~`.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let runner = ScriptedSessionRunner([
            output(0, #"{"ok":true,"app":"codex","workspaces":[{"name":"msg-test","path":"~/personal/msg-test","id":"p1","roots":1}]}"#),
            output(0, #"{"ok":true,"app":"codex","workspaces":[{"name":"msg-test","path":"~/personal/msg-test","id":"p1","roots":1}]}"#),
        ])
        let service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([]))
        let listed = service.executeProject(arguments: ["list", "--host", "local", "--app", "codex", "--json"])
        let rows = try XCTUnwrap(json(listed.text)?["projects"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["name"] as? String, "msg-test")
        let added = service.executeProject(arguments: ["add", "--host", "local", "--app", "codex",
                                                       "--path", home + "/personal/msg-test", "--json"])
        XCTAssertEqual(json(added.text)?["status"] as? String, "already", added.text)
        XCTAssertEqual(runner.invocations.count, 2, "an already-registered folder must not call achat workspace add")
        XCTAssertTrue(LightSessionService.samePath("~/personal/msg-test/", home + "/personal/msg-test"))
    }

    func testRemotePharosOverrideReachesProbeAndForwardedCommand() throws {
        XCTAssertEqual(LightAppBins.fromEnvironment([:]).remotePharosShell, "pharos")
        let bins = LightAppBins.fromEnvironment(["PHAROS_LIGHT_REMOTE_PHAROS": "~/.local/bin/pharos"])
        XCTAssertEqual(bins.remotePharosShell, #""$HOME"/'.local/bin/pharos'"#)
        XCTAssertEqual(LightAppBins.remoteExecutableShell("/opt/x y/pharos"), "'/opt/x y/pharos'")
        let runner = ScriptedSessionRunner([
            output(0, "pharos 0.11.1"),
            output(0, #"{"ok":true,"status":"listed","app":"codex","projects":[]}"#),
        ])
        var service = makeService(relay: try makeRelay(), runner: runner, prober: ScriptProber([]))
        service.apps = LightAppBins(achat: "/tmp/achat", remotePharos: "~/.local/bin/pharos")
        _ = service.executeProject(arguments: ["list", "--host", "mini", "--app", "codex", "--json"])
        XCTAssertEqual(runner.invocations.first?.argv.last, #""$HOME"/'.local/bin/pharos' --version"#)
        XCTAssertTrue(runner.invocations.last?.argv.last?.hasPrefix(#""$HOME"/'.local/bin/pharos' 'project' 'list'"#) == true)
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
