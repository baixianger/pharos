import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

private final class FakeTmuxRunner: LightProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInvocations: [LightInvocation] = []
    var responses: [String: LightProcessOutput] = [:]
    var customHandlers: [([String]) -> LightProcessOutput?] = []

    init(responses: [String: LightProcessOutput] = [:]) {
        self.responses = responses
    }

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

    func setResponse(for key: String, output: LightProcessOutput) {
        lock.lock()
        defer { lock.unlock() }
        responses[key] = output
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

        let afterBinaryJoined = invocation.argv.dropFirst().joined(separator: " ")
        if let out = responses[afterBinaryJoined] {
            return out
        }

        if invocation.argv.count > 1, let out = responses[invocation.argv[1]] {
            return out
        }

        if let bin = invocation.argv.first, let out = responses[bin] {
            return out
        }

        return LightProcessOutput(status: 0, stdout: "", stderr: "")
    }
}

final class TmuxSessionsTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores {
            try? FileManager.default.removeItem(at: store)
        }
        stores.removeAll()
        super.tearDown()
    }

    private func freshStore() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-light-tmux-test-\(UUID().uuidString)")
        stores.append(url)
        return url
    }

    func testNewSessionArgvShape() {
        let runner = FakeTmuxRunner(responses: [
            "new-session": LightProcessOutput(status: 0, stdout: "", stderr: ""),
            "set-option": LightProcessOutput(status: 0, stdout: "", stderr: ""),
        ])
        let controller = TmuxController(tmux: "tmux", runner: runner)

        let err = controller.newSession(
            name: "alice",
            cwd: "/tmp/work",
            argv: ["codex", "exec", "--flag"]
        )
        XCTAssertNil(err)

        let argvs = runner.recordedArgvs
        XCTAssertEqual(argvs.count, 2)
        XCTAssertEqual(argvs[0], [
            "tmux", "new-session", "-d", "-s", "alice",
            "-x", "200", "-y", "50", "-c", "/tmp/work",
            "--", "codex", "exec", "--flag"
        ])
        XCTAssertEqual(argvs[1], [
            "tmux", "set-option", "-t", "=alice:", "remain-on-exit", "on"
        ])
    }

    func testNewSessionWithEnvironment() {
        let runner = FakeTmuxRunner(responses: [
            "new-session": LightProcessOutput(status: 0, stdout: "", stderr: ""),
            "set-option": LightProcessOutput(status: 0, stdout: "", stderr: ""),
        ])
        let controller = TmuxController(runner: runner)

        let err = controller.newSession(
            name: "bob",
            cwd: "/tmp/work",
            argv: ["agy"],
            env: ["PORT": "8080", "MODE": "test"]
        )
        XCTAssertNil(err)

        let argvs = runner.recordedArgvs
        XCTAssertEqual(argvs.count, 2)
        XCTAssertEqual(argvs[0], [
            "tmux", "new-session", "-d", "-s", "bob",
            "-e", "MODE=test", "-e", "PORT=8080",
            "-x", "200", "-y", "50", "-c", "/tmp/work",
            "--", "agy"
        ])
    }

    func testNewSessionFailureReturnsStderr() {
        let runner = FakeTmuxRunner(responses: [
            "new-session": LightProcessOutput(status: 1, stdout: "", stderr: "duplicate session: alice\n"),
        ])
        let controller = TmuxController(runner: runner)

        let err = controller.newSession(name: "alice", cwd: "/tmp/work", argv: ["codex"])
        XCTAssertEqual(err, "duplicate session: alice")
        XCTAssertEqual(runner.recordedArgvs.count, 1)
    }

    func testSendTextUsesLiteralAndSeparateEnter() {
        let runner = FakeTmuxRunner(responses: [
            "send-keys": LightProcessOutput(status: 0, stdout: "", stderr: ""),
        ])
        let controller = TmuxController(runner: runner)

        let ok = controller.sendText("pharos-alice", "ls -la")
        XCTAssertTrue(ok)

        let argvs = runner.recordedArgvs
        XCTAssertEqual(argvs.count, 2)
        XCTAssertEqual(argvs[0], ["tmux", "send-keys", "-t", "=pharos-alice:", "-l", "--", "ls -la"])
        XCTAssertEqual(argvs[1], ["tmux", "send-keys", "-t", "=pharos-alice:", "Enter"])
    }

    func testRespawnArgv() {
        let runner = FakeTmuxRunner(responses: [
            "respawn-pane": LightProcessOutput(status: 0, stdout: "", stderr: ""),
        ])
        let controller = TmuxController(runner: runner)

        let err = controller.respawn(name: "pharos-alice", cwd: "/tmp/work", argv: ["codex", "exec"])
        XCTAssertNil(err)

        let argvs = runner.recordedArgvs
        XCTAssertEqual(argvs.count, 1)
        XCTAssertEqual(argvs[0], [
            "tmux", "respawn-pane", "-k", "-t", "=pharos-alice:", "-c", "/tmp/work", "--", "codex", "exec"
        ])
    }

    func testPaneParsing() {
        let runner = FakeTmuxRunner()
        let controller = TmuxController(runner: runner)

        runner.setResponse(for: "list-panes", output: LightProcessOutput(status: 0, stdout: "1234\tcodex\t0\n", stderr: ""))
        let p1 = controller.pane("alice")
        XCTAssertEqual(p1?.pid, 1234)
        XCTAssertEqual(p1?.command, "codex")
        XCTAssertEqual(p1?.dead, false)

        runner.setResponse(for: "list-panes", output: LightProcessOutput(status: 0, stdout: "5678\tzsh\t1\n", stderr: ""))
        let p2 = controller.pane("alice")
        XCTAssertEqual(p2?.pid, 5678)
        XCTAssertEqual(p2?.command, "zsh")
        XCTAssertEqual(p2?.dead, true)

        runner.setResponse(for: "list-panes", output: LightProcessOutput(status: 1, stdout: "", stderr: "no session"))
        let p3 = controller.pane("alice")
        XCTAssertNil(p3)
    }

    func testCaptureAndKill() {
        let runner = FakeTmuxRunner()
        let controller = TmuxController(runner: runner)

        runner.setResponse(for: "capture-pane", output: LightProcessOutput(status: 0, stdout: "hello screen\n", stderr: ""))
        let c1 = controller.capture("alice")
        XCTAssertEqual(c1, "hello screen\n")
        XCTAssertEqual(runner.recordedArgvs.last, ["tmux", "capture-pane", "-p", "-t", "=alice:"])

        let c2 = controller.capture("alice", lines: 100)
        XCTAssertEqual(c2, "hello screen\n")
        XCTAssertEqual(runner.recordedArgvs.last, ["tmux", "capture-pane", "-p", "-t", "=alice:", "-S", "-100"])

        runner.setResponse(for: "kill-session", output: LightProcessOutput(status: 0, stdout: "", stderr: ""))
        let killed = controller.kill("alice")
        XCTAssertTrue(killed)
        XCTAssertEqual(runner.recordedArgvs.last, ["tmux", "kill-session", "-t", "=alice"])
    }

    func testLivenessAlive() {
        let runner = FakeTmuxRunner(responses: [
            "has-session": LightProcessOutput(status: 0, stdout: "", stderr: ""),
            "list-panes": LightProcessOutput(status: 0, stdout: "4242\tcodex\t0\n", stderr: ""),
            "ps": LightProcessOutput(status: 0, stdout: "Wed Nov  4 10:00:00 2026\n", stderr: ""),
        ])
        let controller = TmuxController(runner: runner)
        let binding = LightTmuxBinding(
            session: "pharos-alice",
            cwd: "/tmp",
            agentPID: 4242,
            agentStarted: "Wed Nov  4 10:00:00 2026"
        )

        let liveness = controller.liveness(binding)
        XCTAssertTrue(liveness.tmuxAlive)
        XCTAssertTrue(liveness.agentAlive)
        XCTAssertFalse(liveness.paneDead)
        XCTAssertEqual(liveness.panePID, 4242)
        XCTAssertEqual(liveness.paneCommand, "codex")
        XCTAssertEqual(liveness.label, "alive")
    }

    func testLivenessAgentExitedPaneDead() {
        let runner = FakeTmuxRunner(responses: [
            "has-session": LightProcessOutput(status: 0, stdout: "", stderr: ""),
            "list-panes": LightProcessOutput(status: 0, stdout: "4242\tcodex\t1\n", stderr: ""),
            "ps": LightProcessOutput(status: 0, stdout: "Wed Nov  4 10:00:00 2026\n", stderr: ""),
        ])
        let controller = TmuxController(runner: runner)
        let binding = LightTmuxBinding(
            session: "pharos-alice",
            cwd: "/tmp",
            agentPID: 4242,
            agentStarted: "Wed Nov  4 10:00:00 2026"
        )

        let liveness = controller.liveness(binding)
        XCTAssertTrue(liveness.tmuxAlive)
        XCTAssertFalse(liveness.agentAlive)
        XCTAssertTrue(liveness.paneDead)
        XCTAssertEqual(liveness.panePID, 4242)
        XCTAssertEqual(liveness.paneCommand, "codex")
        XCTAssertEqual(liveness.label, "agent-exited")
    }

    func testLivenessDeadTmuxSessionGone() {
        let runner = FakeTmuxRunner(responses: [
            "has-session": LightProcessOutput(status: 1, stdout: "", stderr: "no server running\n"),
        ])
        let controller = TmuxController(runner: runner)
        let binding = LightTmuxBinding(session: "pharos-alice", cwd: "/tmp")

        let liveness = controller.liveness(binding)
        XCTAssertFalse(liveness.tmuxAlive)
        XCTAssertFalse(liveness.agentAlive)
        XCTAssertFalse(liveness.paneDead)
        XCTAssertNil(liveness.panePID)
        XCTAssertEqual(liveness.label, "dead")
    }

    func testLivenessPidReuseLstartMismatch() {
        let runner = FakeTmuxRunner(responses: [
            "has-session": LightProcessOutput(status: 0, stdout: "", stderr: ""),
            "list-panes": LightProcessOutput(status: 0, stdout: "4242\tother-cmd\t0\n", stderr: ""),
            "ps": LightProcessOutput(status: 0, stdout: "Wed Nov  4 12:30:00 2026\n", stderr: ""),
        ])
        let controller = TmuxController(runner: runner)
        let binding = LightTmuxBinding(
            session: "pharos-alice",
            cwd: "/tmp",
            agentPID: 4242,
            agentStarted: "Wed Nov  4 10:00:00 2026"
        )

        let liveness = controller.liveness(binding)
        XCTAssertTrue(liveness.tmuxAlive)
        XCTAssertFalse(liveness.agentAlive)
        XCTAssertFalse(liveness.paneDead)
        XCTAssertEqual(liveness.panePID, 4242)
        XCTAssertEqual(liveness.label, "agent-exited")
    }

    func testTmuxNamesValidationAndSanitizing() {
        XCTAssertTrue(TmuxNames.isValid("pharos-alice"))
        XCTAssertTrue(TmuxNames.isValid("a"))
        XCTAssertTrue(TmuxNames.isValid("A_1-b"))
        XCTAssertFalse(TmuxNames.isValid(""))
        XCTAssertFalse(TmuxNames.isValid("-start-with-hyphen"))
        XCTAssertFalse(TmuxNames.isValid("_start-with-underscore"))
        XCTAssertFalse(TmuxNames.isValid("session:with:colon"))
        XCTAssertFalse(TmuxNames.isValid("session.with.dot"))
        XCTAssertFalse(TmuxNames.isValid(String(repeating: "a", count: 65)))
        XCTAssertTrue(TmuxNames.isValid(String(repeating: "a", count: 64)))

        XCTAssertEqual(TmuxNames.sessionName(forMember: "alice"), "pharos-alice")
        XCTAssertEqual(TmuxNames.sessionName(forMember: "alice.sub"), "pharos-alice-sub")
        XCTAssertEqual(TmuxNames.sessionName(forMember: "alice:part:2"), "pharos-alice-part-2")
        XCTAssertTrue(TmuxNames.isValid(TmuxNames.sessionName(forMember: "alice.sub")))
    }

    func testLightMemberDecodingOldJSONWithoutTmux() throws {
        let json = """
        {
            "name": "alice",
            "host": "mac",
            "app": "codex",
            "project": "pharos",
            "sessionID": "s-1",
            "routes": []
        }
        """.data(using: .utf8)!

        let member = try JSONDecoder().decode(LightMember.self, from: json)
        XCTAssertEqual(member.name, "alice")
        XCTAssertEqual(member.host, "mac")
        XCTAssertEqual(member.app, "codex")
        XCTAssertEqual(member.project, "pharos")
        XCTAssertEqual(member.sessionID, "s-1")
        XCTAssertEqual(member.routes, [])
        XCTAssertNil(member.tmux)
    }

    func testRegisterKeepsTmux() throws {
        let relay = try LightRelay(store: freshStore())
        let t1 = LightTmuxBinding(session: "pharos-alice", cwd: "/tmp/1", model: "flash")
        let m1 = LightMember(name: "alice", host: "local", app: "codex", project: "pharos", sessionID: "s-1", routes: [], tmux: t1)
        let r1 = try relay.register(m1)
        XCTAssertEqual(r1.tmux?.model, "flash")

        // Re-register with nil tmux: keeps the existing tmux binding
        let m2 = LightMember(name: "alice", host: "local", app: "codex", project: "pharos", sessionID: "s-1", routes: [], tmux: nil)
        let r2 = try relay.register(m2)
        XCTAssertEqual(r2.tmux?.model, "flash")

        // Re-register with updated tmux: replaces it
        let t3 = LightTmuxBinding(session: "pharos-alice", cwd: "/tmp/2", model: "pro")
        let m3 = LightMember(name: "alice", host: "local", app: "codex", project: "pharos", sessionID: "s-1", routes: [], tmux: t3)
        let r3 = try relay.register(m3)
        XCTAssertEqual(r3.tmux?.model, "pro")
        XCTAssertEqual(r3.tmux?.cwd, "/tmp/2")
    }

    func testUpdateTmuxPersists() throws {
        let store = freshStore()
        let relay1 = try LightRelay(store: store)
        let m = LightMember(name: "alice", host: "local", app: "codex", project: "pharos", sessionID: "s-1", routes: [])
        try relay1.register(m)
        XCTAssertNil(relay1.member(named: "alice")?.tmux)

        let binding = LightTmuxBinding(session: "pharos-alice", cwd: "/tmp/app", agentPID: 1234)
        try relay1.updateTmux(member: "alice", binding)
        XCTAssertEqual(relay1.member(named: "alice")?.tmux?.agentPID, 1234)

        // Re-open from disk to verify persistence
        let relay2 = try LightRelay(store: store)
        XCTAssertEqual(relay2.member(named: "alice")?.tmux?.agentPID, 1234)
        XCTAssertEqual(relay2.member(named: "alice")?.tmux?.session, "pharos-alice")
        XCTAssertEqual(relay2.member(named: "alice")?.tmux?.cwd, "/tmp/app")

        // Unknown member throws LightRelayError.unknownMember
        XCTAssertThrowsError(try relay1.updateTmux(member: "unknown-member", binding)) { error in
            XCTAssertEqual(error as? LightRelayError, .unknownMember("unknown-member"))
        }
    }
}
