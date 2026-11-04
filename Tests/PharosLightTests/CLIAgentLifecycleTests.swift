import XCTest
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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1793821748)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current.addTimeInterval(seconds)
    }
}

final class CLIAgentLifecycleTests: XCTestCase {

    // MARK: - Descriptor Tests

    func testDescriptorArgvAndPaths() {
        let codex = CLIAgentDescriptor.codex
        XCTAssertEqual(codex.app, "codex")
        XCTAssertEqual(codex.launchArgv(bin: "/usr/bin/codex", model: nil), ["/usr/bin/codex", "--no-alt-screen"])
        XCTAssertEqual(codex.launchArgv(bin: "/usr/bin/codex", model: "o3-mini"), ["/usr/bin/codex", "--no-alt-screen", "-m", "o3-mini"])
        XCTAssertEqual(codex.resumeArgv(bin: "/usr/bin/codex", sessionID: "s-123", model: nil), ["/usr/bin/codex", "resume", "s-123", "--no-alt-screen"])
        XCTAssertEqual(codex.resumeArgv(bin: "/usr/bin/codex", sessionID: "s-123", model: "o3-mini"), ["/usr/bin/codex", "resume", "s-123", "--no-alt-screen", "-m", "o3-mini"])
        XCTAssertNil(codex.transcriptPath(sessionID: "s-123", home: "/Users/test"))
        XCTAssertEqual(codex.lockPath(sessionID: "s-123", home: "/Users/test"), "/Users/test/.codex/thread-writer-locks/s-123.lock")
        XCTAssertFalse(codex.openingMessageRequired)
        XCTAssertEqual(codex.routes.map(\.id), ["daemon", "tui"])
        XCTAssertTrue(codex.routes[0].summary.contains("shared app-server daemon"))
        XCTAssertTrue(codex.routes[1].fallback)

        let agy = CLIAgentDescriptor.agy(env: [:])
        XCTAssertEqual(agy.app, "agy")
        XCTAssertEqual(agy.launchArgv(bin: "/usr/bin/agy", model: nil), ["/usr/bin/agy"])
        XCTAssertEqual(agy.launchArgv(bin: "/usr/bin/agy", model: "gemini-2.5-pro"), ["/usr/bin/agy", "--model", "gemini-2.5-pro"])
        XCTAssertEqual(agy.resumeArgv(bin: "/usr/bin/agy", sessionID: "u-456", model: nil), ["/usr/bin/agy", "--conversation", "u-456"])
        XCTAssertEqual(agy.resumeArgv(bin: "/usr/bin/agy", sessionID: "u-456", model: "gemini-2.5-pro"), ["/usr/bin/agy", "--conversation", "u-456", "--model", "gemini-2.5-pro"])
        XCTAssertEqual(agy.transcriptPath(sessionID: "u-456", home: "/Users/test"), "/Users/test/.gemini/antigravity-cli/brain/u-456/.system_generated/logs/transcript.jsonl")
        XCTAssertEqual(agy.lockPath(sessionID: "u-456", home: "/Users/test"), "/Users/test/.gemini/antigravity-cli/presence/u-456.lock")
        XCTAssertTrue(agy.openingMessageRequired)
        XCTAssertEqual(agy.routes.map(\.id), ["tui"])

        XCTAssertEqual(CLIAgentDescriptor.named("codex", env: [:])?.app, "codex")
        XCTAssertEqual(CLIAgentDescriptor.named("agy", env: [:])?.app, "agy")
        XCTAssertNil(CLIAgentDescriptor.named("unknown", env: [:]))
    }

    func testResolveBinary() {
        let codex = CLIAgentDescriptor.codex

        // 1. Env override takes priority
        let envVal = codex.resolveBinary(env: ["PHAROS_CODEX_TUI_BIN": "/custom/bin/codex"], isExecutable: { _ in false })
        XCTAssertEqual(envVal, "/custom/bin/codex")

        // 2. First executable candidate (with ~ expansion)
        let resolvedCandidate = codex.resolveBinary(
            env: ["HOME": "/Users/test"],
            isExecutable: { path in path == "/Users/test/.local/bin/codex" }
        )
        XCTAssertEqual(resolvedCandidate, "/Users/test/.local/bin/codex")

        // 3. Fallback to app name when none executable
        let fallback = codex.resolveBinary(env: ["HOME": "/Users/test"], isExecutable: { _ in false })
        XCTAssertEqual(fallback, "codex")
    }

    // MARK: - Agy Launch Happy Path

    func testAgyLaunchHappyPath() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "session not found")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "5555\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                // Agy idle
                return LightProcessOutput(status: 0, stdout: "Welcome to Antigravity\n? for shortcuts\n", stderr: "")
            }
            if argv.contains("lsof") {
                // lsof reporting presence lock
                return LightProcessOutput(status: 0, stdout: "p5555\nf3\nn/Users/pai/.gemini/antigravity-cli/presence/01a1a81b-1111-2222-3333-444455556666.lock\n", stderr: "")
            }
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            env: ["HOME": "/Users/pai"],
            timeout: 5,
            pollInterval: 0.01,
            sleep: { _ in },
            now: { clock.now() },
            isExecutable: { _ in true }
        )

        let req = CLIAgentLaunchRequest(name: "worker-1", app: "agy", cwd: tmpDir)
        let result = try lifecycle.launch(req)

        XCTAssertEqual(result.sessionID, "01a1a81b-1111-2222-3333-444455556666")
        XCTAssertEqual(result.binding.session, "pharos-worker-1")
        XCTAssertEqual(result.binding.cwd, tmpDir)
        XCTAssertEqual(result.binding.agentPID, 5555)
        XCTAssertEqual(result.binding.agentStarted, "Mon Nov 4 21:00:00 2026")

        // Verify opening message was sent with -l
        let sendKeysArgvs = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeysArgvs.contains(where: { $0.contains("-l") && $0.contains("Pharos registered this session as member worker-1. Reply with exactly: ready") }))
    }

    // MARK: - Trust Prompt Stops Launch Without Keypresses

    func testCodexTrustPromptThrowsNeedsHumanWithoutKeypress() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "6001\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Trust this folder? [y/n]\n", stderr: "")
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
            now: { clock.now() },
            isExecutable: { _ in true }
        )

        let req = CLIAgentLaunchRequest(name: "cx-trust", app: "codex", cwd: tmpDir)
        XCTAssertThrowsError(try lifecycle.launch(req)) { error in
            guard case CLIAgentLifecycleError.needsHuman(let msg) = error else {
                return XCTFail("Expected needsHuman error but got \(error)")
            }
            XCTAssertTrue(msg.contains("codex asks to trust"))
            XCTAssertTrue(msg.contains("tmux attach -t pharos-cx-trust"))
        }

        // Verify NO send-keys were executed
        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.isEmpty, "Never press keys to answer trust prompts")
    }

    func testAgyTrustPromptThrowsNeedsHumanWithoutKeypress() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "6002\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Do you trust the contents of this project?\nYes, I trust this folder\n", stderr: "")
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
            now: { clock.now() },
            isExecutable: { _ in true }
        )

        let req = CLIAgentLaunchRequest(name: "agy-trust", app: "agy", cwd: tmpDir)
        XCTAssertThrowsError(try lifecycle.launch(req)) { error in
            guard case CLIAgentLifecycleError.needsHuman(let msg) = error else {
                return XCTFail("Expected needsHuman error but got \(error)")
            }
            XCTAssertTrue(msg.contains("agy asks to trust"))
        }

        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.isEmpty, "Never press keys to answer trust prompts")
    }

    // MARK: - Adopt Existing Alive Session

    func testAdoptExistingAliveSession() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "") // session exists
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "7001\tcodex\t0\n", stderr: "") // agent alive
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
            }
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }

        let tmux = TmuxController(runner: runner)
        var lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            timeout: 5,
            pollInterval: 0.01,
            sleep: { _ in },
            now: { clock.now() },
            isExecutable: { _ in true }
        )
        lifecycle.threadFinder = { _, _ in "thread-adopted-123" }

        let req = CLIAgentLaunchRequest(name: "cx-adopt", app: "codex", cwd: tmpDir)
        let result = try lifecycle.launch(req)

        XCTAssertEqual(result.sessionID, "thread-adopted-123")
        XCTAssertEqual(result.notes, ["adopted existing tmux session pharos-cx-adopt"])

        // Did not run new-session
        let newSessions = runner.recordedArgvs.filter { $0.contains("new-session") }
        XCTAssertTrue(newSessions.isEmpty)
    }

    // MARK: - Revive Respawn vs New-Session

    func testReviveRespawnWhenSessionExistsAndPaneDead() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "") // tmux session exists
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "8001\tcodex\t1\n", stderr: "") // pane dead (1)
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "") // pid dead
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Ask Codex: hi\n", stderr: "")
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
            now: { clock.now() },
            isExecutable: { _ in true }
        )

        let member = LightMember(
            name: "cx-dead",
            host: "local",
            app: "codex",
            project: "p1",
            sessionID: "sess-8001",
            routes: [],
            tmux: LightTmuxBinding(
                session: "pharos-cx-dead",
                cwd: tmpDir,
                model: "o3-mini",
                agentPID: 8001,
                agentStarted: "old-start",
                launchedAt: Date(timeIntervalSince1970: 1000),
                endedAt: nil
            )
        )

        let newBinding = try lifecycle.revive(member: member)
        XCTAssertEqual(newBinding.session, "pharos-cx-dead")
        XCTAssertEqual(newBinding.model, "o3-mini")

        // Must have called respawn-pane, not new-session
        let respawnCalls = runner.recordedArgvs.filter { $0.contains("respawn-pane") }
        XCTAssertFalse(respawnCalls.isEmpty)
        let newSessionCalls = runner.recordedArgvs.filter { $0.contains("new-session") }
        XCTAssertTrue(newSessionCalls.isEmpty)
    }

    func testReviveNewSessionWhenTmuxSessionGone() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "") // tmux gone
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "8002\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
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
            now: { clock.now() },
            isExecutable: { _ in true }
        )

        let member = LightMember(
            name: "cx-gone",
            host: "local",
            app: "codex",
            project: "p1",
            sessionID: "sess-8002",
            routes: [],
            tmux: LightTmuxBinding(
                session: "pharos-cx-gone",
                cwd: tmpDir,
                model: nil,
                agentPID: nil,
                agentStarted: nil,
                launchedAt: Date(timeIntervalSince1970: 1000),
                endedAt: nil
            )
        )

        let newBinding = try lifecycle.revive(member: member)
        XCTAssertEqual(newBinding.session, "pharos-cx-gone")

        // Must have called new-session
        let newSessionCalls = runner.recordedArgvs.filter { $0.contains("new-session") }
        XCTAssertFalse(newSessionCalls.isEmpty)
    }

    func testReviveWhenAgentAliveThrowsAlreadyAlive() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "8003\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
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
            now: { clock.now() },
            isExecutable: { _ in true }
        )

        let member = LightMember(
            name: "cx-alive",
            host: "local",
            app: "codex",
            project: "p1",
            sessionID: "sess-8003",
            routes: [],
            tmux: LightTmuxBinding(
                session: "pharos-cx-alive",
                cwd: tmpDir,
                model: nil,
                agentPID: 8003,
                agentStarted: "Mon Nov 4 21:00:00 2026",
                launchedAt: Date(timeIntervalSince1970: 1000),
                endedAt: nil
            )
        )

        XCTAssertThrowsError(try lifecycle.revive(member: member)) { error in
            guard case CLIAgentLifecycleError.alreadyAlive = error else {
                return XCTFail("Expected alreadyAlive error, got \(error)")
            }
        }
    }

    // MARK: - Quota-Exhausted Chain

    func testQuotaExhaustedChainThrowsNeedsHuman() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            return nil
        }

        let quota = CLIQuotaBook(now: { clock.now() })
        // Mark both models in chain over quota until future
        let resetDate = clock.now().addingTimeInterval(3600)
        quota.mark(app: "agy", model: "gemini-2.5-pro", until: resetDate)
        quota.mark(app: "agy", model: "gemini-2.5-flash", until: resetDate)

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            env: ["PHAROS_AGY_MODELS": "gemini-2.5-pro,gemini-2.5-flash"],
            quota: quota,
            timeout: 5,
            pollInterval: 0.01,
            sleep: { _ in },
            now: { clock.now() },
            isExecutable: { _ in true }
        )

        let req = CLIAgentLaunchRequest(name: "quota-test", app: "agy", cwd: tmpDir)
        XCTAssertThrowsError(try lifecycle.launch(req)) { error in
            guard case CLIAgentLifecycleError.needsHuman(let msg) = error else {
                return XCTFail("Expected needsHuman error, got \(error)")
            }
            XCTAssertTrue(msg.contains("all agy models are over quota until"))
        }
    }

    // MARK: - Status Labels

    func testStatusLabels() {
        let runner = FakeLifecycleRunner()
        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            daemon: { nil }
        )

        // 1. No binding -> "-"
        let memberNoBinding = LightMember(
            name: "m1", host: "local", app: "agy", project: "p", sessionID: "s1", routes: [], tmux: nil
        )
        let st1 = lifecycle.status(member: memberNoBinding)
        XCTAssertEqual(st1.tmux, "-")
        XCTAssertEqual(st1.live, "-")
        XCTAssertEqual(st1.activity, .unknown)

        // 2. Tmux session gone, endedAt not set -> "dead"
        let bindingDead = LightTmuxBinding(
            session: "pharos-m2", cwd: "/tmp", model: nil, agentPID: nil, agentStarted: nil, launchedAt: Date(), endedAt: nil
        )
        let memberDead = LightMember(
            name: "m2", host: "local", app: "agy", project: "p", sessionID: "s2", routes: [], tmux: bindingDead
        )
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            return nil
        }
        let st2 = lifecycle.status(member: memberDead)
        XCTAssertEqual(st2.tmux, "pharos-m2")
        XCTAssertEqual(st2.live, "dead")
        XCTAssertEqual(st2.activity, .unknown)

        // 3. Tmux session gone, endedAt set -> "ended"
        var bindingEnded = bindingDead
        bindingEnded.endedAt = Date()
        let memberEnded = LightMember(
            name: "m3", host: "local", app: "agy", project: "p", sessionID: "s3", routes: [], tmux: bindingEnded
        )
        let st3 = lifecycle.status(member: memberEnded)
        XCTAssertEqual(st3.live, "ended")

        // 4. Agy alive states
        let runnerAlive = FakeLifecycleRunner()
        var currentPaneText = "? for shortcuts\n"
        runnerAlive.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "9001\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: currentPaneText, stderr: "")
            }
            return nil
        }
        let tmuxAlive = TmuxController(runner: runnerAlive)
        var lifecycleAlive = CLIAgentLifecycle(tmux: tmuxAlive, runner: runnerAlive)

        let agyMember = LightMember(
            name: "m-agy", host: "local", app: "agy", project: "p", sessionID: "s-agy", routes: [],
            tmux: LightTmuxBinding(session: "pharos-agy", cwd: "/tmp", model: nil, agentPID: 9001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        // 4a. idle
        currentPaneText = "? for shortcuts\n"
        XCTAssertEqual(lifecycleAlive.status(member: agyMember).activity, .idle)

        // 4b. busy -> thinking
        currentPaneText = "esc to cancel\n"
        XCTAssertEqual(lifecycleAlive.status(member: agyMember).activity, .thinking)

        // 4c. quota -> idle with detail "quota"
        currentPaneText = "> prompt\nQuota exceeded (resets in 10m)\n"
        let quotaSt = lifecycleAlive.status(member: agyMember)
        XCTAssertEqual(quotaSt.activity, .idle)
        XCTAssertEqual(quotaSt.detail, "quota")

        // 4d. needsHuman
        currentPaneText = "Requesting permission for:\nDelete all files\n"
        XCTAssertEqual(lifecycleAlive.status(member: agyMember).activity, .needsHuman)

        // 5. Codex alive states via threadReader
        let codexMember = LightMember(
            name: "m-cx", host: "local", app: "codex", project: "p", sessionID: "s-cx", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx", cwd: "/tmp", model: nil, agentPID: 9001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date(), endedAt: nil)
        )

        lifecycleAlive.threadReader = { _ in
            CodexThreadInfo(id: "s-cx", cwd: "/tmp", path: nil, originator: "codex-tui", status: .idle)
        }
        XCTAssertEqual(lifecycleAlive.status(member: codexMember).activity, .idle)

        lifecycleAlive.threadReader = { _ in
            CodexThreadInfo(id: "s-cx", cwd: "/tmp", path: nil, originator: "codex-tui", status: .active(flags: []))
        }
        XCTAssertEqual(lifecycleAlive.status(member: codexMember).activity, .thinking)

        lifecycleAlive.threadReader = { _ in
            CodexThreadInfo(id: "s-cx", cwd: "/tmp", path: nil, originator: "codex-tui", status: .active(flags: ["waitingOnApproval"]))
        }
        XCTAssertEqual(lifecycleAlive.status(member: codexMember).activity, .needsHuman)
    }
}
