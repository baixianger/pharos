import XCTest
import Foundation
@testable import PharosMeshCore
@testable import PharosRuntime

private final class FakeLifecycleRunner: LightProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInvocations: [LightInvocation] = []
    var customHandlers: [([String]) -> LightProcessOutput?] = []

    var invocations: [LightInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    var recordedArgvs: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations.map(\.argv)
    }

    func addHandler(_ handler: @escaping ([String]) -> LightProcessOutput?) {
        lock.lock()
        defer { lock.unlock() }
        customHandlers.append(handler)
    }

    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        lock.lock()
        defer { lock.unlock() }
        recordedInvocations.append(invocation)

        for handler in customHandlers {
            if let out = handler(invocation.argv) {
                return out
            }
        }

        return LightProcessOutput(status: 0, stdout: "", stderr: "")
    }
}

private final class FakeRouter: LightNodeRouting, @unchecked Sendable {
    var cannedRun: LightNodeRun?
    var cannedStatus: LightNodeStatus = LightNodeStatus(host: "remote-host", online: true, lastSeen: Date())
    var lastArgv: [String]?

    func run(_ node: String, argv: [String], timeout: TimeInterval) -> LightNodeRun? {
        lastArgv = argv
        return cannedRun
    }

    func status(_ node: String) -> LightNodeStatus {
        cannedStatus
    }

    func directory() -> LightHostDirectory? {
        nil
    }
}

final class MemberModelTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores {
            try? FileManager.default.removeItem(at: store)
        }
        stores.removeAll()
        super.tearDown()
    }

    private func makeRelay() throws -> LightRelay {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-model-test-\(UUID().uuidString)")
        stores.append(storeURL)
        return try LightRelay(store: storeURL)
    }

    private func run(
        _ relay: LightRelay,
        _ command: String,
        _ arguments: [String],
        agents: (any LightMemberAgents)? = nil
    ) -> LightCLIResult {
        LightCommands.execute(command: command, arguments: arguments, relay: relay, routesForApp: { _ in [] }, agents: agents)
    }

    func testShowModelsAgyWithQuotaNote() throws {
        let relay = try makeRelay()
        let now = Date()

        let quota = CLIQuotaBook(store: relay.storeURL.appendingPathComponent("cli-quota.json"), now: { now })
        let until = now.addingTimeInterval(3600)
        quota.mark(app: "agy", model: "Gemini 3.8 Flash (High)", until: until)

        let binding = LightTmuxBinding(
            session: "tmux-agy",
            cwd: "/tmp",
            model: "Gemini 3.8 Flash (Medium)",
            agentPID: 101,
            agentStarted: "start",
            launchedAt: now
        )
        _ = try relay.register(LightMember(
            name: "agy-bot",
            host: "local",
            app: "agy",
            project: "proj",
            sessionID: "sess-agy-1",
            routes: [],
            tmux: binding
        ))

        let runner = FakeLifecycleRunner()
        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner, quota: quota, now: { now })
        let agents = CLIMemberAgents(lifecycle: lifecycle, selfHost: LightSelfHost(names: ["local"]))

        // 1. Text output
        let res = run(relay, "member", ["model", "agy-bot"], agents: agents)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.text.contains("current model: Gemini 3.8 Flash (Medium)"))
        XCTAssertTrue(res.text.contains("available models:"))
        XCTAssertTrue(res.text.contains("Gemini 3.8 Flash (High) (over quota until"))
        XCTAssertTrue(res.text.contains("Gemini 3.8 Flash (Low)"))

        // 2. JSON output
        let jsonRes = run(relay, "member", ["model", "agy-bot", "--json"], agents: agents)
        XCTAssertEqual(jsonRes.exitCode, 0)
        let decoder = JSONDecoder()
        let info = try decoder.decode(LightMemberModelInfo.self, from: Data(jsonRes.text.utf8))
        XCTAssertEqual(info.member, "agy-bot")
        XCTAssertEqual(info.app, "agy")
        XCTAssertEqual(info.current, "Gemini 3.8 Flash (Medium)")
        XCTAssertTrue(info.available.contains("Gemini 3.8 Flash (High)"))
        XCTAssertNotNil(info.quota["Gemini 3.8 Flash (High)"])
    }

    func testShowModelsCodexEnvList() throws {
        let relay = try makeRelay()
        let now = Date()

        let binding = LightTmuxBinding(
            session: "tmux-codex",
            cwd: "/tmp",
            model: nil,
            agentPID: 102,
            agentStarted: "start",
            launchedAt: now
        )
        _ = try relay.register(LightMember(
            name: "codex-bot",
            host: "local",
            app: "codex",
            project: "proj",
            sessionID: "sess-cx-1",
            routes: [],
            tmux: binding
        ))

        let prevEnv = getenv("PHAROS_CODEX_MODELS").flatMap { String(cString: $0) }
        setenv("PHAROS_CODEX_MODELS", "o3-mini,o1,gpt-4o", 1)
        defer {
            if let prev = prevEnv {
                setenv("PHAROS_CODEX_MODELS", prev, 1)
            } else {
                unsetenv("PHAROS_CODEX_MODELS")
            }
        }

        let runner = FakeLifecycleRunner()
        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner, now: { now })
        let agents = CLIMemberAgents(lifecycle: lifecycle, selfHost: LightSelfHost(names: ["local"]))

        let res = run(relay, "member", ["model", "codex-bot"], agents: agents)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.text.contains("current model: default"))
        XCTAssertTrue(res.text.contains("o3-mini"))
        XCTAssertTrue(res.text.contains("o1"))
        XCTAssertTrue(res.text.contains("gpt-4o"))
    }

    func testSwitchModelLocal() throws {
        let relay = try makeRelay()
        let now = Date()

        let runner = FakeLifecycleRunner()
        var sessionAlive = true
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1024\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
            }
            if argv.contains("send-keys") && argv.contains("/quit") {
                sessionAlive = false
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("new-session") || argv.contains("respawn-pane") {
                sessionAlive = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            timeout: 5,
            pollInterval: 0.01,
            sleep: { _ in },
            now: Date.init,
            isExecutable: { _ in true }
        )
        let agents = CLIMemberAgents(lifecycle: lifecycle, selfHost: LightSelfHost(names: ["local"]))

        let binding = LightTmuxBinding(
            session: "pharos-cx-switch",
            cwd: "/tmp",
            model: nil,
            agentPID: 1024,
            agentStarted: "Mon Nov 4 21:00:00 2026",
            launchedAt: now
        )
        _ = try relay.register(LightMember(
            name: "cx-switch",
            host: "local",
            app: "codex",
            project: "proj",
            sessionID: "01a1a81b-switch",
            routes: [],
            tmux: binding
        ))

        let res = run(relay, "member", ["model", "cx-switch", "o3-mini"], agents: agents)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.text.contains("switched cx-switch to model o3-mini (restarted in tmux pharos-cx-switch, resumed 01a1a81b-switch)"))

        // Relay updated
        let updated = try XCTUnwrap(relay.member(named: "cx-switch"))
        XCTAssertEqual(updated.tmux?.model, "o3-mini")

        // Argv has -m o3-mini
        let respawnOrNew = runner.recordedArgvs.filter { $0.contains("respawn-pane") || $0.contains("new-session") }
        XCTAssertFalse(respawnOrNew.isEmpty)
        let lastLaunchArgv = respawnOrNew.last ?? []
        XCTAssertTrue(lastLaunchArgv.contains("-m") && lastLaunchArgv.contains("o3-mini"), "Argv should pass -m o3-mini to codex")
    }

    func testSwitchModelRemoteViaFakeRouter() throws {
        let relay = try makeRelay()
        let now = Date()

        let runner = FakeLifecycleRunner()
        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner)
        let router = FakeRouter()
        let agents = CLIMemberAgents(lifecycle: lifecycle, selfHost: LightSelfHost(names: ["local"]), nodes: router)

        let binding = LightTmuxBinding(
            session: "pharos-remote-agy",
            cwd: "/tmp",
            model: "Gemini 3.8 Flash (High)",
            agentPID: 9001,
            agentStarted: "remote-start",
            launchedAt: now
        )
        _ = try relay.register(LightMember(
            name: "remote-agy",
            host: "remote-box",
            app: "agy",
            project: "proj",
            sessionID: "agy-rem-1",
            routes: [],
            tmux: binding
        ))

        let newBinding = LightTmuxBinding(
            session: "pharos-remote-agy",
            cwd: "/tmp",
            model: "Gemini 3.8 Flash (Low)",
            agentPID: 9002,
            agentStarted: "remote-switched",
            launchedAt: now
        )
        let remoteResp = LightNodeAgentResponse(ok: true, binding: newBinding, notes: ["remote switched"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let respJson = String(data: try encoder.encode(remoteResp), encoding: .utf8)!

        router.cannedRun = LightNodeRun(path: .mesh, status: 0, stdout: respJson, stderr: "", node: "remote-box")

        let res = run(relay, "member", ["model", "remote-agy", "Gemini 3.8 Flash (Low)"], agents: agents)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.text.contains("switched remote-agy to model Gemini 3.8 Flash (Low)"))

        let updated = try XCTUnwrap(relay.member(named: "remote-agy"))
        XCTAssertEqual(updated.tmux?.model, "Gemini 3.8 Flash (Low)")

        // Verify request payload sent to remote
        guard let payloadIdx = router.lastArgv?.firstIndex(of: "--payload"),
              let b64 = router.lastArgv?[payloadIdx + 1],
              let req = LightNodeExec.decode(LightNodeAgentRequest.self, b64) else {
            XCTFail("Failed to decode remote node-agent request")
            return
        }
        XCTAssertEqual(req.action, "model")
        XCTAssertEqual(req.model, "Gemini 3.8 Flash (Low)")
        XCTAssertEqual(req.member?.name, "remote-agy")
    }

    func testSwitchModelBusyWithoutForceRefused() throws {
        let relay = try makeRelay()
        let now = Date()

        let runner = FakeLifecycleRunner()
        var sessionAlive = true
        var busyState = true
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1024\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                if busyState {
                    return LightProcessOutput(status: 0, stdout: "Thinking (3s • esc to interrupt)\n", stderr: "")
                } else {
                    return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
                }
            }
            if argv.contains("send-keys") && argv.contains("/quit") {
                sessionAlive = false
                busyState = false
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("new-session") || argv.contains("respawn-pane") {
                sessionAlive = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            timeout: 5,
            pollInterval: 0.01,
            sleep: { _ in },
            now: Date.init,
            isExecutable: { _ in true }
        )
        let agents = CLIMemberAgents(lifecycle: lifecycle, selfHost: LightSelfHost(names: ["local"]))

        let binding = LightTmuxBinding(
            session: "pharos-busy-cx",
            cwd: "/tmp",
            model: nil,
            agentPID: 1024,
            agentStarted: "Mon Nov 4 21:00:00 2026",
            launchedAt: now
        )
        _ = try relay.register(LightMember(
            name: "busy-bot",
            host: "local",
            app: "codex",
            project: "proj",
            sessionID: "sess-busy",
            routes: [],
            tmux: binding
        ))

        // Without --force: refused
        let fail = run(relay, "member", ["model", "busy-bot", "o1"], agents: agents)
        XCTAssertEqual(fail.exitCode, 1)
        XCTAssertTrue(fail.text.contains("busy"))
        XCTAssertTrue(fail.text.contains("--force"))

        // With --force: proceeds
        let okRes = run(relay, "member", ["model", "busy-bot", "o1", "--force"], agents: agents)
        XCTAssertEqual(okRes.exitCode, 0)
        XCTAssertTrue(okRes.text.contains("switched busy-bot to model o1"))
    }

    func testNonTmuxMemberError() throws {
        let relay = try makeRelay()

        _ = try relay.register(LightMember(
            name: "webhook-bot",
            host: "webhook",
            app: "webhook",
            project: "proj",
            sessionID: "wh-1",
            routes: []
        ))

        let runner = FakeLifecycleRunner()
        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner)
        let agents = CLIMemberAgents(lifecycle: lifecycle, selfHost: LightSelfHost(names: ["local"]))

        let showRes = run(relay, "member", ["model", "webhook-bot"], agents: agents)
        XCTAssertEqual(showRes.exitCode, 1)
        XCTAssertTrue(showRes.text.contains("error: member webhook-bot has no tmux binding"))

        let switchRes = run(relay, "member", ["model", "webhook-bot", "some-model"], agents: agents)
        XCTAssertEqual(switchRes.exitCode, 1)
        XCTAssertTrue(switchRes.text.contains("error: member webhook-bot has no tmux binding"))
    }

    func testMemberListModelColumn() throws {
        let relay = try makeRelay()
        let now = Date()

        let b1 = LightTmuxBinding(session: "s1", cwd: "/tmp", model: "gpt-4o", agentPID: 1, agentStarted: "t1", launchedAt: now)
        _ = try relay.register(LightMember(name: "m1", host: "local", app: "codex", project: "p", sessionID: "id1", routes: [], tmux: b1))

        let b2 = LightTmuxBinding(session: "s2", cwd: "/tmp", model: nil, agentPID: 2, agentStarted: "t2", launchedAt: now)
        _ = try relay.register(LightMember(name: "m2", host: "local", app: "codex", project: "p", sessionID: "id2", routes: [], tmux: b2))

        _ = try relay.register(LightMember(name: "m3", host: "webhook", app: "webhook", project: "p", sessionID: "id3", routes: []))

        let res = run(relay, "member", ["list"])
        XCTAssertEqual(res.exitCode, 0)
        let lines = res.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "NAME\tAPP\tHOST\tPROJECT\tSESSION\tROUTES\tTMUX\tLIVE\tMODEL\tSTATE")

        let m1Line = try XCTUnwrap(lines.first { $0.hasPrefix("m1\t") })
        XCTAssertTrue(m1Line.contains("\tgpt-4o\t"), "m1 shows gpt-4o in MODEL column")

        let m2Line = try XCTUnwrap(lines.first { $0.hasPrefix("m2\t") })
        XCTAssertTrue(m2Line.contains("\t-\t"), "m2 shows - in MODEL column")

        let m3Line = try XCTUnwrap(lines.first { $0.hasPrefix("m3\t") })
        XCTAssertTrue(m3Line.contains("\t-\t-\t-\t-"), "m3 shows - across tmux, live, model, state")
    }
}
