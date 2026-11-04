import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import PharosMeshCore
@testable import PharosRuntime

private final class FakeDriverRunner: LightProcessRunning, @unchecked Sendable {
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

final class CLIAgentDriverTests: XCTestCase {

    // MARK: - Codex Tests

    func testCodexQueueAddDeliveredAndStoresCursor() throws {
        let sockPath = "/tmp/pcx-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeCodexDaemonServer(path: sockPath)
        server.threadStatus = ["type": "idle"]
        try server.start()
        defer { server.stop() }

        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1001\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let cursors = CLIReplyCursorBook()
        let client = CodexDaemonClient(socketPath: sockPath, timeout: 4)
        let driver = CLIAgentDriver(
            tmux: tmux,
            daemon: { client },
            cursors: cursors,
            sleep: { _ in }
        )

        let member = LightMember(
            name: "cx-1", host: "local", app: "codex", project: "p", sessionID: "01a1a81b-test", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-1", cwd: "/tmp", model: nil, agentPID: 1001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "echo 1", replyID: "req-1")
        XCTAssertEqual(res.state, .delivered)
        XCTAssertEqual(res.route, "daemon")
        XCTAssertFalse(res.fallback)
        XCTAssertEqual(res.detail, "queued sub-123")

        let cur = cursors.get(member: "cx-1")
        XCTAssertNotNil(cur)
        XCTAssertEqual(cur?.kind, "codex-client")
        XCTAssertEqual(cur?.value, "req-1")
    }

    func testCodexWaitingOnApprovalQueuesAndSaysWaitingOnHuman() throws {
        let sockPath = "/tmp/pcx-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeCodexDaemonServer(path: sockPath)
        server.threadStatus = [
            "type": "active",
            "activeFlags": ["waitingOnApproval"]
        ]
        try server.start()
        defer { server.stop() }

        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1002\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let client = CodexDaemonClient(socketPath: sockPath, timeout: 4)
        let driver = CLIAgentDriver(tmux: tmux, daemon: { client }, sleep: { _ in })

        let member = LightMember(
            name: "cx-2", host: "local", app: "codex", project: "p", sessionID: "01a1a81b-test", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-2", cwd: "/tmp", model: nil, agentPID: 1002, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "echo 2", replyID: nil)
        XCTAssertEqual(res.state, .delivered)
        XCTAssertEqual(res.route, "daemon")
        XCTAssertTrue(res.detail.contains("(thread waiting on a human)"))
    }

    func testCodexDaemonNilTUIFallbackSendsLiteralText() {
        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1003\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let cursors = CLIReplyCursorBook()
        let driver = CLIAgentDriver(tmux: tmux, daemon: { nil }, cursors: cursors, sleep: { _ in })

        let member = LightMember(
            name: "cx-3", host: "local", app: "codex", project: "p", sessionID: "01a1a81b-test", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-3", cwd: "/tmp", model: nil, agentPID: 1003, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "echo 3", replyID: nil)
        XCTAssertEqual(res.state, .delivered)
        XCTAssertEqual(res.route, "tui")
        XCTAssertTrue(res.fallback)

        // Verify tmux sendText sent literal text
        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.contains(where: { $0.contains("-l") && $0.contains("echo 3") }))

        let cur = cursors.get(member: "cx-3")
        XCTAssertEqual(cur?.kind, "codex-client")
        XCTAssertEqual(cur?.value, "")
    }

    func testCodexBusyPaneReturnsBusyAndNoSendKeys() {
        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1004\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "thinking... esc to interrupt\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let driver = CLIAgentDriver(tmux: tmux, daemon: { nil }, sleep: { _ in })

        let member = LightMember(
            name: "cx-4", host: "local", app: "codex", project: "p", sessionID: "01a1a81b-test", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-4", cwd: "/tmp", model: nil, agentPID: 1004, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "echo 4", replyID: nil)
        XCTAssertEqual(res.state, .busy)
        XCTAssertEqual(res.route, "tui")

        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.isEmpty, "Busy agent must never receive keypresses")
    }

    func testCodexUpdatePromptReturnsBusyAndNoSendKeys() {
        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1004\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                let pane = """
                Update available · 0.162.1 → 0.166.0
                › 1. Update now (runs `brew upgrade --cask codex`)
                  2. Skip
                  3. Skip until next version
                """
                return LightProcessOutput(status: 0, stdout: pane, stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let driver = CLIAgentDriver(tmux: tmux, daemon: { nil }, sleep: { _ in })

        let member = LightMember(
            name: "cx-upd", host: "local", app: "codex", project: "p", sessionID: "01a1a81b-test", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-upd", cwd: "/tmp", model: nil, agentPID: 1004, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "echo 4", replyID: nil)
        XCTAssertEqual(res.state, .busy)
        XCTAssertEqual(res.route, "tui")
        XCTAssertEqual(res.detail, "needs_human: codex update prompt: choose Skip in tmux session")

        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.isEmpty, "Update prompt must never receive keypresses")
    }

    func testCodexReadReplyViaTurnsByClientID() throws {
        let sockPath = "/tmp/pcx-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeCodexDaemonServer(path: sockPath)
        try server.start()
        defer { server.stop() }

        let runner = FakeDriverRunner()
        let tmux = TmuxController(runner: runner)
        let cursors = CLIReplyCursorBook()
        let client = CodexDaemonClient(socketPath: sockPath, timeout: 4)
        let driver = CLIAgentDriver(tmux: tmux, daemon: { client }, cursors: cursors, sleep: { _ in })

        let member = LightMember(
            name: "cx-reply", host: "local", app: "codex", project: "p", sessionID: "01a1a81b-test", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-reply", cwd: "/tmp", model: nil, agentPID: 1005, agentStarted: "start", launchedAt: Date(), endedAt: nil)
        )

        cursors.set(member: "cx-reply", CLIReplyCursor(kind: "codex-client", value: "r-test-1", at: Date()))
        let reply = driver.readReply(member: member, since: Date(timeIntervalSince1970: 1793821740))
        XCTAssertEqual(reply, "PONG-1")
    }

    // MARK: - Agy Tests

    func testAgyIdleCursorSavedAndSendKeys() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let transcriptDir = tmpDir.appendingPathComponent(".gemini/antigravity-cli/brain/agy-sess-1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcriptFile = transcriptDir.appendingPathComponent("transcript.jsonl")
        let jsonl = """
        {"step_index": 1, "type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE", "content": "hi"}
        """
        try jsonl.write(to: transcriptFile, atomically: true, encoding: .utf8)

        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "2001\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "? for shortcuts\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let cursors = CLIReplyCursorBook()
        let driver = CLIAgentDriver(
            tmux: tmux,
            cursors: cursors,
            home: tmpDir.path,
            quotaWindow: 0.05,
            pollInterval: 0.01,
            sleep: { _ in }
        )

        let member = LightMember(
            name: "agy-1", host: "local", app: "agy", project: "p", sessionID: "agy-sess-1", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-1", cwd: tmpDir.path, model: "gemini-2.5-pro", agentPID: 2001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "run tests", replyID: nil)
        XCTAssertEqual(res.state, .delivered)
        XCTAssertEqual(res.route, "tui")

        let cur = cursors.get(member: "agy-1")
        XCTAssertEqual(cur?.kind, "agy-line")
        XCTAssertEqual(cur?.value, "1")

        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.contains(where: { $0.contains("-l") && $0.contains("run tests") }))
    }

    func testAgyBusyOrPermissionReturnsBusyAndNoSendKeys() {
        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "2002\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Requesting permission for:\nrm -rf build\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let driver = CLIAgentDriver(tmux: tmux, sleep: { _ in })

        let member = LightMember(
            name: "agy-2", host: "local", app: "agy", project: "p", sessionID: "agy-sess-2", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-2", cwd: "/tmp", model: "gemini-2.5-pro", agentPID: 2002, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "do next", replyID: nil)
        XCTAssertEqual(res.state, .busy)
        XCTAssertEqual(res.route, "tui")
        XCTAssertTrue(res.detail.contains("needs_human: rm -rf build"))

        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.isEmpty, "Never send keys on permission prompt")
    }

    func testAgyUpdatePromptReturnsBusyAndNoSendKeys() {
        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "2002\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                let pane = """
                Update available · 0.162.1 → 0.166.0
                › 1. Update now
                  2. Skip
                """
                return LightProcessOutput(status: 0, stdout: pane, stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let driver = CLIAgentDriver(tmux: tmux, sleep: { _ in })

        let member = LightMember(
            name: "agy-upd", host: "local", app: "agy", project: "p", sessionID: "agy-sess-upd", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-upd", cwd: "/tmp", model: "gemini-2.5-pro", agentPID: 2002, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "do next", replyID: nil)
        XCTAssertEqual(res.state, .busy)
        XCTAssertEqual(res.route, "tui")
        XCTAssertTrue(res.detail.contains("needs_human: agy update prompt: choose Skip in tmux session"))

        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.isEmpty, "Never send keys on update prompt")
    }

    func testAgyQuotaAppearsAfterSendReturnsDeferredAndMarksQuota() {
        let runner = FakeDriverRunner()
        var captureCallCount = 0
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "2003\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                captureCallCount += 1
                if captureCallCount == 1 {
                    // pre-send idle
                    return LightProcessOutput(status: 0, stdout: "? for shortcuts\n", stderr: "")
                } else {
                    // post-send quota
                    return LightProcessOutput(status: 0, stdout: "> do something\nQuota exceeded (resets in 30m)\n", stderr: "")
                }
            }
            return nil
        }

        let quota = CLIQuotaBook()
        let tmux = TmuxController(runner: runner)
        let driver = CLIAgentDriver(
            tmux: tmux,
            quota: quota,
            quotaWindow: 1.0,
            pollInterval: 0.01,
            sleep: { _ in }
        )

        let member = LightMember(
            name: "agy-quota", host: "local", app: "agy", project: "p", sessionID: "agy-sess-3", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-3", cwd: "/tmp", model: "gemini-2.5-pro", agentPID: 2003, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "do something", replyID: nil)
        XCTAssertEqual(res.state, .deferred)
        XCTAssertEqual(res.route, "tui")
        XCTAssertTrue(res.detail.contains("agy quota reached on gemini-2.5-pro until"))

        XCTAssertNotNil(quota.exhausted(app: "agy", model: "gemini-2.5-pro"))
    }

    func testAgyReadReplyFromFixtureTranscriptAfterCursor() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let transcriptDir = tmpDir.appendingPathComponent(".gemini/antigravity-cli/brain/agy-read-1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcriptFile = transcriptDir.appendingPathComponent("transcript.jsonl")
        let jsonl = """
        {"step_index": 1, "type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE", "content": "turn 1"}
        {"step_index": 2, "type": "PLANNER_RESPONSE", "source": "MODEL", "status": "DONE", "content": "done 1"}
        {"step_index": 3, "type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE", "content": "turn 2"}
        {"step_index": 4, "type": "PLANNER_RESPONSE", "source": "MODEL", "status": "DONE", "content": "Ready to proceed"}
        """
        try jsonl.write(to: transcriptFile, atomically: true, encoding: .utf8)

        let runner = FakeDriverRunner()
        let tmux = TmuxController(runner: runner)
        let cursors = CLIReplyCursorBook()
        let driver = CLIAgentDriver(
            tmux: tmux,
            cursors: cursors,
            home: tmpDir.path,
            sleep: { _ in }
        )

        let member = LightMember(
            name: "agy-read", host: "local", app: "agy", project: "p", sessionID: "agy-read-1", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-read", cwd: tmpDir.path, model: "gemini-2.5-pro", agentPID: 2004, agentStarted: "start", launchedAt: Date(), endedAt: nil)
        )

        // Cursor at step 2, reply should be step 4
        cursors.set(member: "agy-read", CLIReplyCursor(kind: "agy-step", value: "2", at: Date()))
        let reply = driver.readReply(member: member, since: Date())
        XCTAssertEqual(reply, "Ready to proceed")
    }

    /// A resumed agy TUI restarts step_index at 0 in the same transcript: the record-count cursor still finds the reply.
    func testAgyReplyAfterStepIndexResetUsesRecordCount() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-agy-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let logs = tmpDir.appendingPathComponent(".gemini/antigravity-cli/brain/agy-reset-1/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let lines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-04T21:20:00Z","content":"<USER_REQUEST>first</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-04T21:20:02Z","content":"OLD-ANSWER"}"#,
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-04T21:23:05Z","content":"<USER_REQUEST>after revive</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-04T21:23:07Z","content":"NEW-ANSWER"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: logs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        let cursors = CLIReplyCursorBook()
        let driver = CLIAgentDriver(tmux: TmuxController(runner: FakeDriverRunner()), cursors: cursors,
                                    home: tmpDir.path, sleep: { _ in })
        let member = LightMember(
            name: "agy-reset", host: "local", app: "agy", project: "p", sessionID: "agy-reset-1", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-reset", cwd: tmpDir.path)
        )
        let sent = Date()
        cursors.set(member: "agy-reset", CLIReplyCursor(kind: "agy-line", value: "2", at: sent))
        XCTAssertEqual(driver.readReply(member: member, since: sent), "NEW-ANSWER")
    }

    func testCursorBookMatchesTheSendForEachTicket() {
        let book = CLIReplyCursorBook()
        let t0 = Date(timeIntervalSince1970: 1_000)
        book.set(member: "m", CLIReplyCursor(kind: "codex-client", value: "r1", at: t0))
        book.set(member: "m", CLIReplyCursor(kind: "codex-client", value: "r2", at: t0.addingTimeInterval(60)))
        XCTAssertEqual(book.match(member: "m", since: t0)?.value, "r1")
        XCTAssertEqual(book.match(member: "m", since: t0.addingTimeInterval(59))?.value, "r2")
        XCTAssertNil(book.match(member: "m", since: t0.addingTimeInterval(120)))
        XCTAssertEqual(book.get(member: "m")?.value, "r2")
    }

    func testDeadTmuxReturnsFailedWithReviveHint() {
        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "") // session gone
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let driver = CLIAgentDriver(tmux: tmux, sleep: { _ in })

        let member = LightMember(
            name: "agy-dead", host: "local", app: "agy", project: "p", sessionID: "agy-dead-1", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-dead", cwd: "/tmp", model: "gemini-2.5-pro", agentPID: 2005, agentStarted: "start", launchedAt: Date(), endedAt: nil)
        )

        let res = driver.deliver(member: member, text: "hello", replyID: nil)
        XCTAssertEqual(res.state, .failed)
        XCTAssertNil(res.route)
        XCTAssertTrue(res.detail.contains("run: pharos member revive agy-dead"))
    }

    // MARK: - Attention Source Tests

    func testAttentionSourceReports() throws {
        let sockPath = "/tmp/pcx-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeCodexDaemonServer(path: sockPath)
        server.threadStatus = [
            "type": "active",
            "activeFlags": ["waitingOnApproval"]
        ]
        try server.start()
        defer { server.stop() }

        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                // Return alive for cx-attn and agy-perm, dead for dead-member
                if argv.contains("=pharos-dead:") || argv.contains("=pharos-dead") {
                    return LightProcessOutput(status: 1, stdout: "", stderr: "")
                }
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "3001\tagent\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                if argv.contains("=pharos-agy-perm:") {
                    return LightProcessOutput(status: 0, stdout: "Requesting permission for:\nRun curl https://example.com\n", stderr: "")
                }
                if argv.contains("=pharos-agy-idle:") {
                    return LightProcessOutput(status: 0, stdout: "? for shortcuts\n", stderr: "")
                }
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let client = CodexDaemonClient(socketPath: sockPath, timeout: 4)
        let driver = CLIAgentDriver(tmux: tmux, daemon: { client }, sleep: { _ in })
        let source = CLIAgentAttentionSource(driver: driver, isLocal: { _ in true }, hostLabel: "local-mac")

        let cxMember = LightMember(
            name: "cx-attn", host: "local", app: "codex", project: "p", sessionID: "01a1a81b-test", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-attn", cwd: "/tmp", model: nil, agentPID: 3001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )
        let agyPermMember = LightMember(
            name: "agy-perm", host: "local", app: "agy", project: "p", sessionID: "agy-perm-sess", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-perm", cwd: "/tmp", model: "gemini-2.5-pro", agentPID: 3001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )
        let agyIdleMember = LightMember(
            name: "agy-idle", host: "local", app: "agy", project: "p", sessionID: "agy-idle-sess", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy-idle", cwd: "/tmp", model: "gemini-2.5-pro", agentPID: 3001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )
        let deadMember = LightMember(
            name: "dead-mem", host: "local", app: "agy", project: "p", sessionID: "dead-sess", routes: [],
            tmux: LightTmuxBinding(session: "pharos-dead", cwd: "/tmp", model: "gemini-2.5-pro", agentPID: 3001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let reports = source.poll(members: [cxMember, agyPermMember, agyIdleMember, deadMember])

        // 1. Codex waiting on approval
        let cxReport = reports.first(where: { $0.sessionID == "01a1a81b-test" })
        XCTAssertNotNil(cxReport)
        XCTAssertEqual(cxReport?.state, .needsHuman)
        XCTAssertEqual(cxReport?.source, "daemon")
        XCTAssertEqual(cxReport?.host, "local-mac")

        // 2. Agy permission prompt
        let agyPermReport = reports.first(where: { $0.sessionID == "agy-perm-sess" })
        XCTAssertNotNil(agyPermReport)
        XCTAssertEqual(agyPermReport?.state, .needsHuman)
        XCTAssertEqual(agyPermReport?.source, "tui")
        XCTAssertEqual(agyPermReport?.what, "Run curl https://example.com")

        // 3. Agy idle -> clear
        let agyIdleReport = reports.first(where: { $0.sessionID == "agy-idle-sess" })
        XCTAssertNotNil(agyIdleReport)
        XCTAssertEqual(agyIdleReport?.state, .clear)

        // 4. Dead member -> nothing reported
        XCTAssertNil(reports.first(where: { $0.sessionID == "dead-sess" }))
    }

    // MARK: - ExternalLightDriver Wiring (Bypasses achat)

    func testExternalLightDriverNeverInvokesAchatForTmuxMember() {
        let runner = FakeDriverRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "4001\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "? for shortcuts\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let cliDriver = CLIAgentDriver(
            tmux: tmux,
            quotaWindow: 0.05,
            pollInterval: 0.01,
            sleep: { _ in }
        )

        let externalDriver = ExternalLightDriver(
            allowLive: true,
            runner: runner,
            cliAgents: cliDriver
        )

        let member = LightMember(
            name: "agy-wire", host: "local", app: "agy", project: "p", sessionID: "wire-sess", routes: [],
            tmux: LightTmuxBinding(session: "pharos-wire", cwd: "/tmp", model: "gemini-2.5-pro", agentPID: 4001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        let envelope = LightEnvelope(
            replyId: "env-1", threadId: "t-1", from: "test", to: "agy-wire", cc: [], intent: "ask",
            text: "do work", hop: 0, hopLimit: 5, expectsReply: true, replyCommand: nil, prompt: "do work"
        )

        let res = externalDriver.deliver(member: member, envelope: envelope)
        XCTAssertEqual(res.state, .delivered)
        XCTAssertEqual(res.route, "tui")

        // Assert runner never saw any argv containing "achat"
        let achatCalls = runner.recordedArgvs.filter { argv in
            argv.contains(where: { $0.contains("achat") })
        }
        XCTAssertTrue(achatCalls.isEmpty, "tmux-backed member must never invoke achat: \(achatCalls)")
    }
}
