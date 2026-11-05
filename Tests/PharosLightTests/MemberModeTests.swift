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

final class MemberModeTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores {
            try? FileManager.default.removeItem(at: store)
        }
        stores.removeAll()
        super.tearDown()
    }

    private func makeRelay() throws -> LightRelay {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-mode-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
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

    func testLaunchDefaultModeIsYolo() throws {
        let relay = try makeRelay()
        let runner = FakeLifecycleRunner()
        var sessionAlive = false

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("new-session") {
                sessionAlive = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› Ask Codex\n", stderr: "")
            }
            if argv.contains("display-message") {
                return LightProcessOutput(status: 0, stdout: "12345", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            home: relay.storeURL.path,
            pollInterval: 0.01,
            sleep: { _ in },
            isExecutable: { _ in true },
            threadFinder: { _, _ in "session-123" }
        )
        let agents = CLIMemberAgents(
            lifecycle: lifecycle,
            selfHost: LightSelfHost(names: ["local"])
        )

        let res = run(relay, "member", [
            "launch", "--app", "codex", "--name", "cx-yolo",
            "--dir", relay.storeURL.path, "--project", "testproj"
        ], agents: agents)

        XCTAssertEqual(res.exitCode, 0, "res.text: \(res.text)")
        let member = try XCTUnwrap(relay.member(named: "cx-yolo"))
        XCTAssertEqual(member.tmux?.permissionMode, "yolo")
        XCTAssertEqual(member.tmux?.effectiveMode, "yolo")

        // Verify tmux new-session argv included bypass flag
        let newSessionArgv = runner.recordedArgvs.first { $0.contains("new-session") }
        let argvStr = try XCTUnwrap(newSessionArgv).joined(separator: " ")
        XCTAssertTrue(argvStr.contains("--dangerously-bypass-approvals-and-sandbox"), "default launch includes codex bypass flag")
    }

    func testLaunchSafeMode() throws {
        let relay = try makeRelay()
        let runner = FakeLifecycleRunner()
        var sessionAlive = false

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("new-session") {
                sessionAlive = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "? for shortcuts\n", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "100\tagy\t0\n", stderr: "")
            }
            if argv.contains("lsof") {
                return LightProcessOutput(status: 0, stdout: "n\(relay.storeURL.path)/.gemini/antigravity-cli/presence/uuid-123.lock\n", stderr: "")
            }
            if argv.contains("display-message") {
                return LightProcessOutput(status: 0, stdout: "12345", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            home: relay.storeURL.path,
            pollInterval: 0.01,
            sleep: { _ in },
            isExecutable: { _ in true },
            threadFinder: { _, _ in "session-456" }
        )
        let agents = CLIMemberAgents(
            lifecycle: lifecycle,
            selfHost: LightSelfHost(names: ["local"])
        )

        let res = run(relay, "member", [
            "launch", "--app", "agy", "--name", "ag-safe",
            "--dir", relay.storeURL.path, "--project", "testproj", "--safe"
        ], agents: agents)

        XCTAssertEqual(res.exitCode, 0, "res.text: \(res.text)")
        let member = try XCTUnwrap(relay.member(named: "ag-safe"))
        XCTAssertEqual(member.tmux?.permissionMode, "safe")
        XCTAssertEqual(member.tmux?.effectiveMode, "safe")

        // Verify tmux new-session argv omitted skip-permissions flag
        let newSessionArgv = runner.recordedArgvs.first { $0.contains("new-session") }
        let argvStr = try XCTUnwrap(newSessionArgv).joined(separator: " ")
        XCTAssertFalse(argvStr.contains("--dangerously-skip-permissions"), "safe launch omits agy skip-permissions flag")
    }

    func testMemberModeShow() throws {
        let relay = try makeRelay()
        let binding = LightTmuxBinding(session: "tmux-safe", cwd: relay.storeURL.path, permissionMode: "safe")
        _ = try relay.register(LightMember(name: "safe-bot", host: "local", app: "codex", project: "p", sessionID: "s-1", routes: [], tmux: binding))

        let showText = run(relay, "member", ["mode", "safe-bot"])
        XCTAssertEqual(showText.exitCode, 0)
        XCTAssertTrue(showText.text.contains("member: safe-bot"))
        XCTAssertTrue(showText.text.contains("mode: safe"))

        let showJSON = run(relay, "member", ["mode", "safe-bot", "--json"])
        XCTAssertEqual(showJSON.exitCode, 0)
        XCTAssertTrue(showJSON.text.contains("\"mode\" : \"safe\""))
    }

    func testMemberModeSwitchLocal() throws {
        let relay = try makeRelay()
        let runner = FakeLifecycleRunner()
        var sessionAlive = true

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "100\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "start\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
            }
            if argv.contains("send-keys") && argv.contains("/quit") {
                sessionAlive = false
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("respawn-pane") || argv.contains("new-session") {
                sessionAlive = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("display-message") {
                return LightProcessOutput(status: 0, stdout: "12345", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            home: relay.storeURL.path,
            pollInterval: 0.01,
            sleep: { _ in },
            isExecutable: { _ in true }
        )
        let agents = CLIMemberAgents(
            lifecycle: lifecycle,
            selfHost: LightSelfHost(names: ["local"])
        )

        let binding = LightTmuxBinding(
            session: "tmux-cx", cwd: relay.storeURL.path, agentPID: 100, agentStarted: "start",
            launchedAt: Date(), permissionMode: "yolo"
        )
        _ = try relay.register(LightMember(name: "cx-bot", host: "local", app: "codex", project: "p", sessionID: "s-99", routes: [], tmux: binding))

        let switchRes = run(relay, "member", ["mode", "cx-bot", "safe"], agents: agents)
        XCTAssertEqual(switchRes.exitCode, 0, switchRes.text)
        XCTAssertTrue(switchRes.text.contains("switched cx-bot to mode safe"), switchRes.text)

        let updated = try XCTUnwrap(relay.member(named: "cx-bot"))
        XCTAssertEqual(updated.tmux?.permissionMode, "safe")

        // Verify respawn was called with resume and without bypass flag
        let resumeArgv = runner.recordedArgvs.first { $0.contains("resume") }
        let resumeStr = try XCTUnwrap(resumeArgv).joined(separator: " ")
        XCTAssertFalse(resumeStr.contains("--dangerously-bypass-approvals-and-sandbox"), "safe switch restarts without bypass flag")
    }

    func testMemberModeRemoteForward() throws {
        let relay = try makeRelay()
        let router = FakeRouter()

        let returnedBinding = LightTmuxBinding(session: "tmux-air", cwd: "/tmp", permissionMode: "safe")
        let response = LightNodeAgentResponse(ok: true, binding: returnedBinding)
        let respData = try JSONEncoder().encode(response)
        router.cannedRun = LightNodeRun(
            path: .mesh,
            status: 0,
            stdout: String(data: respData, encoding: .utf8)!,
            stderr: "",
            node: "mac-air"
        )

        let runner = FakeLifecycleRunner()
        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner, home: relay.storeURL.path)
        let agents = CLIMemberAgents(
            lifecycle: lifecycle,
            selfHost: LightSelfHost(names: ["mini"]),
            nodes: router
        )

        let binding = LightTmuxBinding(session: "tmux-air", cwd: "/tmp", permissionMode: "yolo")
        _ = try relay.register(LightMember(name: "air-bot", host: "mac-air", app: "codex", project: "p", sessionID: "s-air", routes: [], tmux: binding))

        let res = run(relay, "member", ["mode", "air-bot", "safe"], agents: agents)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.text.contains("switched air-bot to mode safe"))

        // Check remote payload
        let argv = try XCTUnwrap(router.lastArgv)
        let payloadIdx = try XCTUnwrap(argv.firstIndex(of: "--payload"))
        let b64 = argv[payloadIdx + 1]
        let reqData = try XCTUnwrap(Data(base64Encoded: b64))
        let req = try JSONDecoder().decode(LightNodeAgentRequest.self, from: reqData)
        XCTAssertEqual(req.action, "mode")
        XCTAssertEqual(req.mode, "safe")
        XCTAssertEqual(req.member?.name, "air-bot")
    }

    func testMemberListModeColumn() throws {
        let relay = try makeRelay()
        let b1 = LightTmuxBinding(session: "s1", cwd: "/tmp", model: "o3", permissionMode: "yolo")
        let b2 = LightTmuxBinding(session: "s2", cwd: "/tmp", model: "gpt-4o", permissionMode: "safe")
        _ = try relay.register(LightMember(name: "m1", host: "local", app: "codex", project: "p", sessionID: "s1", routes: [], tmux: b1))
        _ = try relay.register(LightMember(name: "m2", host: "local", app: "codex", project: "p", sessionID: "s2", routes: [], tmux: b2))
        _ = try relay.register(LightMember(name: "m3", host: "webhook", app: "webhook", project: "p", sessionID: "s3", routes: []))

        let res = run(relay, "member", ["list"])
        XCTAssertEqual(res.exitCode, 0)
        let lines = res.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "NAME\tAPP\tHOST\tPROJECT\tSESSION\tROUTES\tTMUX\tLIVE\tMODEL\tMODE\tSTATE")

        let m1Line = try XCTUnwrap(lines.first { $0.hasPrefix("m1\t") })
        XCTAssertTrue(m1Line.contains("\tyolo\t"))

        let m2Line = try XCTUnwrap(lines.first { $0.hasPrefix("m2\t") })
        XCTAssertTrue(m2Line.contains("\tsafe\t"))

        let m3Line = try XCTUnwrap(lines.first { $0.hasPrefix("m3\t") })
        XCTAssertTrue(m3Line.contains("\t-\t-\t-\t-\t-"))
    }
}
