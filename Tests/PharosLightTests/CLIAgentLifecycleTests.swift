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

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var val: Bool

    init(_ val: Bool) { self.val = val }

    func set(_ newVal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        val = newVal
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return val
    }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var val = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        val += 1
        return val
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return val
    }
}

private final class TestCollector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class CLIAgentLifecycleTests: XCTestCase {

    // MARK: - Descriptor Tests

    func testDescriptorArgvAndPaths() {
        let codex = CLIAgentDescriptor.codex
        XCTAssertEqual(codex.app, "codex")
        XCTAssertEqual(codex.launchArgv(bin: "/usr/bin/codex", model: nil), ["/usr/bin/codex", "--no-alt-screen", "-c", "check_for_update_on_startup=false", "--dangerously-bypass-approvals-and-sandbox"])
        XCTAssertEqual(codex.launchArgv(bin: "/usr/bin/codex", model: "o3-mini"), ["/usr/bin/codex", "--no-alt-screen", "-c", "check_for_update_on_startup=false", "--dangerously-bypass-approvals-and-sandbox", "-m", "o3-mini"])
        XCTAssertEqual(codex.launchArgv(bin: "/usr/bin/codex", model: "o3-mini", mode: "safe"), ["/usr/bin/codex", "--no-alt-screen", "-c", "check_for_update_on_startup=false", "-m", "o3-mini"])
        XCTAssertEqual(codex.resumeArgv(bin: "/usr/bin/codex", sessionID: "s-123", model: nil), ["/usr/bin/codex", "resume", "s-123", "--no-alt-screen", "-c", "check_for_update_on_startup=false", "--dangerously-bypass-approvals-and-sandbox"])
        XCTAssertEqual(codex.resumeArgv(bin: "/usr/bin/codex", sessionID: "s-123", model: "o3-mini"), ["/usr/bin/codex", "resume", "s-123", "--no-alt-screen", "-c", "check_for_update_on_startup=false", "--dangerously-bypass-approvals-and-sandbox", "-m", "o3-mini"])
        XCTAssertEqual(codex.resumeArgv(bin: "/usr/bin/codex", sessionID: "s-123", model: "o3-mini", mode: "safe"), ["/usr/bin/codex", "resume", "s-123", "--no-alt-screen", "-c", "check_for_update_on_startup=false", "-m", "o3-mini"])
        XCTAssertNil(codex.transcriptPath(sessionID: "s-123", home: "/Users/test"))
        XCTAssertEqual(codex.lockPath(sessionID: "s-123", home: "/Users/test"), "/Users/test/.codex/thread-writer-locks/s-123.lock")
        XCTAssertFalse(codex.openingMessageRequired)
        XCTAssertEqual(codex.routes.map(\.id), ["daemon", "tui"])
        XCTAssertTrue(codex.routes[0].summary.contains("shared app-server daemon"))
        XCTAssertTrue(codex.routes[1].fallback)
        XCTAssertEqual(codex.exitCommand, "/quit")

        let agy = CLIAgentDescriptor.agy(env: [:])
        XCTAssertEqual(agy.app, "agy")
        XCTAssertEqual(agy.launchArgv(bin: "/usr/bin/agy", model: nil), ["/usr/bin/agy", "--dangerously-skip-permissions"])
        XCTAssertEqual(agy.launchArgv(bin: "/usr/bin/agy", model: "gemini-2.5-pro"), ["/usr/bin/agy", "--dangerously-skip-permissions", "--model", "gemini-2.5-pro"])
        XCTAssertEqual(agy.launchArgv(bin: "/usr/bin/agy", model: "gemini-2.5-pro", mode: "safe"), ["/usr/bin/agy", "--model", "gemini-2.5-pro"])
        XCTAssertEqual(agy.resumeArgv(bin: "/usr/bin/agy", sessionID: "u-456", model: nil), ["/usr/bin/agy", "--conversation", "u-456", "--dangerously-skip-permissions"])
        XCTAssertEqual(agy.resumeArgv(bin: "/usr/bin/agy", sessionID: "u-456", model: "gemini-2.5-pro"), ["/usr/bin/agy", "--conversation", "u-456", "--dangerously-skip-permissions", "--model", "gemini-2.5-pro"])
        XCTAssertEqual(agy.resumeArgv(bin: "/usr/bin/agy", sessionID: "u-456", model: "gemini-2.5-pro", mode: "safe"), ["/usr/bin/agy", "--conversation", "u-456", "--model", "gemini-2.5-pro"])
        XCTAssertEqual(agy.transcriptPath(sessionID: "u-456", home: "/Users/test"), "/Users/test/.gemini/antigravity-cli/brain/u-456/.system_generated/logs/transcript.jsonl")
        XCTAssertEqual(agy.lockPath(sessionID: "u-456", home: "/Users/test"), "/Users/test/.gemini/antigravity-cli/presence/u-456.lock")
        XCTAssertTrue(agy.openingMessageRequired)
        XCTAssertEqual(agy.routes.map(\.id), ["tui"])
        XCTAssertEqual(agy.exitCommand, "/exit")

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

    // MARK: - Stop and Revive Tests

    func testStopAlreadyEnded() throws {
        let runner = FakeLifecycleRunner()
        // has-session returns exit 1 (session missing)
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "can't find session")
            }
            return nil
        }
        let tmux = TmuxController(runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner, now: clock.now)

        let member = LightMember(
            name: "m-stop", host: "local", app: "codex", project: "p", sessionID: "s-1", routes: [],
            tmux: LightTmuxBinding(session: "pharos-m-stop", cwd: "/tmp", launchedAt: Date())
        )

        let res = try lifecycle.stop(member: member, force: false)
        XCTAssertEqual(res.how, "already-ended")
        XCTAssertEqual(res.binding.endedReason, "stopped")
        XCTAssertNotNil(res.binding.endedAt)
    }

    func testStopGraceful() throws {
        let runner = FakeLifecycleRunner()
        var sessionAlive = true
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› prompt\n", stderr: "") // idle
            }
            if argv.contains("send-keys") && argv.contains("/quit") {
                sessionAlive = false // session exits after /quit
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            return nil
        }
        let tmux = TmuxController(runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner, now: clock.now)

        let member = LightMember(
            name: "m-graceful", host: "local", app: "codex", project: "p", sessionID: "s-2", routes: [],
            tmux: LightTmuxBinding(session: "pharos-m-graceful", cwd: "/tmp", launchedAt: Date())
        )

        let res = try lifecycle.stop(member: member, force: false)
        XCTAssertEqual(res.how, "graceful")
        XCTAssertEqual(res.binding.endedReason, "stopped")
        XCTAssertNotNil(res.binding.endedAt)
    }

    func testStopTimeoutKilled() throws {
        let runner = FakeLifecycleRunner()
        var killed = false
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: killed ? 1 : 0, stdout: "", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› prompt\n", stderr: "") // idle
            }
            if argv.contains("kill-session") {
                killed = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1234\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            return nil
        }
        let tmux = TmuxController(runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux, runner: runner,
            timeout: 5, pollInterval: 1,
            sleep: { _ in clock.advance(2) },
            now: clock.now
        )

        let member = LightMember(
            name: "m-kill", host: "local", app: "codex", project: "p", sessionID: "s-3", routes: [],
            tmux: LightTmuxBinding(session: "pharos-m-kill", cwd: "/tmp", launchedAt: Date())
        )

        let res = try lifecycle.stop(member: member, force: false, timeout: 5)
        XCTAssertEqual(res.how, "killed")
        XCTAssertTrue(killed, "tmux kill-session was called")
        XCTAssertEqual(res.binding.endedReason, "stopped")
    }

    func testStopBusyWithoutForceThrowsAndWithForceSendsEscape() throws {
        let runner = FakeLifecycleRunner()
        var sessionAlive = true
        var escapeSent = false
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "esc to cancel\n", stderr: "") // agy busy
            }
            if argv.contains("send-keys") && argv.contains("Escape") {
                escapeSent = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("send-keys") && argv.contains("/exit") {
                sessionAlive = false
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            return nil
        }
        let tmux = TmuxController(runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner, sleep: { _ in }, now: clock.now)

        let member = LightMember(
            name: "m-busy", host: "local", app: "agy", project: "p", sessionID: "s-4", routes: [],
            tmux: LightTmuxBinding(session: "pharos-m-busy", cwd: "/tmp", launchedAt: Date())
        )

        // Without force -> throws invalid("member is busy; use --force to interrupt and stop")
        XCTAssertThrowsError(try lifecycle.stop(member: member, force: false)) { error in
            XCTAssertEqual((error as? CLIAgentLifecycleError)?.errorDescription, "invalid: member is busy; use --force to interrupt and stop")
        }
        XCTAssertFalse(escapeSent)

        // With force -> sends Escape then /exit
        let res = try lifecycle.stop(member: member, force: true)
        XCTAssertTrue(escapeSent)
        XCTAssertEqual(res.how, "graceful")
    }

    func testStopNeedsHumanWithoutForceThrows() throws {
        let runner = FakeLifecycleRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Requesting permission for:\nrm -rf\n", stderr: "") // needsHuman
            }
            return nil
        }
        let tmux = TmuxController(runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner, now: clock.now)

        let member = LightMember(
            name: "m-prompt", host: "local", app: "agy", project: "p", sessionID: "s-5", routes: [],
            tmux: LightTmuxBinding(session: "pharos-m-prompt", cwd: "/tmp", launchedAt: Date())
        )

        XCTAssertThrowsError(try lifecycle.stop(member: member, force: false)) { error in
            XCTAssertEqual((error as? CLIAgentLifecycleError)?.errorDescription, "invalid: member is waiting on a prompt; answer it or use --force")
        }
    }

    func testReviveClearsEndedReasonAndPreservesAutoRevive() throws {
        let runner = FakeLifecycleRunner()
        var respawned = false
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("respawn-pane") {
                respawned = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
            }
            if argv.contains("list-panes") {
                let deadStr = respawned ? "0" : "1"
                return LightProcessOutput(status: 0, stdout: "5555\tcodex\t\(deadStr)\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: respawned ? 0 : 1, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            return nil
        }
        let tmux = TmuxController(runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner, now: clock.now)

        let oldBinding = LightTmuxBinding(
            session: "pharos-cx-rev", cwd: "/tmp", model: "o3-mini",
            agentPID: 1111, agentStarted: "start", launchedAt: Date(),
            endedAt: Date(), autoRevive: true, endedReason: "stopped"
        )
        let member = LightMember(
            name: "cx-rev", host: "local", app: "codex", project: "p", sessionID: "s-rev", routes: [],
            tmux: oldBinding
        )

        let newBinding = try lifecycle.revive(member: member)
        XCTAssertEqual(newBinding.autoRevive, true, "autoRevive is preserved")
        XCTAssertNil(newBinding.endedReason, "endedReason is cleared")
        XCTAssertNil(newBinding.endedAt, "endedAt is cleared")
        XCTAssertEqual(newBinding.agentPID, 5555)
    }

    // MARK: - Update Prompt Tests

    func testCodexPaneClassifyUpdatePrompt() {
        let p1 = """
        Update available · 0.162.1 → 0.166.0
        › 1. Update now (runs `brew upgrade --cask codex`)
          2. Skip
        """
        XCTAssertEqual(CodexPane.classify(p1), .needsHuman(what: "codex update prompt: choose Skip in tmux session"))

        let p2 = """
        Update available · 0.162.1 → 0.166.0
        › 1. Skip until next version
        """
        XCTAssertEqual(CodexPane.classify(p2), .needsHuman(what: "codex update prompt: choose Skip in tmux session"))
    }

    func testCodexUpdatePromptThrowsNeedsHumanWithoutKeypress() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "6003\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Update available · 0.162.1 → 0.166.0\n› 1. Update now\n", stderr: "")
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

        let req = CLIAgentLaunchRequest(name: "cx-upd", app: "codex", cwd: tmpDir)
        XCTAssertThrowsError(try lifecycle.launch(req)) { error in
            guard case CLIAgentLifecycleError.needsHuman(let msg) = error else {
                return XCTFail("Expected needsHuman error but got \(error)")
            }
            XCTAssertTrue(msg.contains("codex update prompt"))
            XCTAssertTrue(msg.contains("choose Skip"))
        }

        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.isEmpty, "Never press keys to answer update prompts")
    }

    func testAgyUpdatePromptThrowsNeedsHumanWithoutKeypress() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "6004\tagy\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Update available · 1.0 → 2.0\n› 1. Update now\n  2. Skip\n", stderr: "")
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

        let req = CLIAgentLaunchRequest(name: "agy-upd", app: "agy", cwd: tmpDir)
        XCTAssertThrowsError(try lifecycle.launch(req)) { error in
            guard case CLIAgentLifecycleError.needsHuman(let msg) = error else {
                return XCTFail("Expected needsHuman error but got \(error)")
            }
            XCTAssertTrue(msg.contains("agy update prompt"))
            XCTAssertTrue(msg.contains("choose Skip"))
        }

        let sendKeys = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertTrue(sendKeys.isEmpty, "Never press keys to answer update prompts")
    }

    // MARK: - Visible Screen Only (Scrollback Ignored)

    func testVisibleScreenOnlyUsedForReadinessAndScrollbackTrustPromptIgnored() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "7001\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                // If -S is passed (scrollback), return trust prompt; otherwise return idle/ready
                if argv.contains("-S") {
                    return LightProcessOutput(status: 0, stdout: "Trust this folder? [y/n]\n", stderr: "")
                } else {
                    return LightProcessOutput(status: 0, stdout: "Ask Codex: \n› Ready\n", stderr: "")
                }
            }
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            daemon: { nil },
            timeout: 5,
            pollInterval: 0.01,
            sleep: { _ in },
            now: { clock.now() },
            isExecutable: { _ in true },
            threadFinder: { _, _ in "cx-discovered-123" }
        )

        // Launch an adopted session where scrollback contains "Trust this folder?", but visible screen is ready.
        let req = CLIAgentLaunchRequest(name: "cx-adopt-visible", app: "codex", cwd: tmpDir)
        let res = try lifecycle.launch(req)
        XCTAssertEqual(res.sessionID, "cx-discovered-123")
        XCTAssertTrue(res.notes.contains("adopted existing tmux session pharos-cx-adopt-visible"))

        // Assert all capture-pane invocations in readiness did NOT include "-S"
        let captureArgvs = runner.recordedArgvs.filter { $0.contains("capture-pane") }
        for argv in captureArgvs {
            XCTAssertFalse(argv.contains("-S"), "Readiness must capture visible screen only without -S")
        }
    }

    // MARK: - Rollout Session Discovery

    func testCodexSessionIDDiscoveryFallbackFromRollout() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionsDir = tempDir.appendingPathComponent("sessions/2026/11/04", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetCwd = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let rolloutFile = sessionsDir.appendingPathComponent("rollout-2026-11-04-1000-01a1a81b-5678.jsonl")
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"01a1a81b-rollout-found\",\"cwd\":\"\(targetCwd)\"}}\n"
        try meta.write(to: rolloutFile, atomically: true, encoding: .utf8)

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "8001\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Ask Codex: \n› \n", stderr: "")
            }
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            daemon: { nil }, // No daemon available
            timeout: 5,
            pollInterval: 0.01,
            sleep: { _ in },
            now: { clock.now() },
            isExecutable: { _ in true },
            threadFinder: nil,
            rolloutsRoot: tempDir
        )

        let req = CLIAgentLaunchRequest(name: "cx-rollout", app: "codex", cwd: targetCwd)
        let res = try lifecycle.launch(req)
        XCTAssertEqual(res.sessionID, "01a1a81b-rollout-found")
        XCTAssertTrue(res.notes.contains("session id from rollout (this codex TUI is not on the shared daemon)"))
    }

    func testCodexSessionIDRolloutIgnoresArchivedAndOlderFiles() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionsDir = tempDir.appendingPathComponent("sessions/2026/11/04", isDirectory: true)
        let archivedDir = tempDir.appendingPathComponent("sessions/archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetCwd = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        // 1. Archived file (matching cwd) -> should be ignored
        let archFile = archivedDir.appendingPathComponent("rollout-archived.jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"id-archived\",\"cwd\":\"\(targetCwd)\"}}\n"
            .write(to: archFile, atomically: true, encoding: .utf8)

        // 2. Older file (mtime < launchStart - 2s) -> should be ignored
        let oldFile = sessionsDir.appendingPathComponent("rollout-old.jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"id-old\",\"cwd\":\"\(targetCwd)\"}}\n"
            .write(to: oldFile, atomically: true, encoding: .utf8)
        let oldDate = clock.now().addingTimeInterval(-10)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile.path)

        // 3. Different cwd -> should be ignored
        let wrongCwdFile = sessionsDir.appendingPathComponent("rollout-wrong-cwd.jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"id-wrong\",\"cwd\":\"/some/other/path\"}}\n"
            .write(to: wrongCwdFile, atomically: true, encoding: .utf8)

        // 4. Valid newest matching file -> must be picked
        let validFile = sessionsDir.appendingPathComponent("rollout-valid.jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"id-valid-newest\",\"cwd\":\"\(targetCwd)\"}}\n"
            .write(to: validFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: clock.now()], ofItemAtPath: validFile.path)

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "8002\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "Ask Codex: \n› \n", stderr: "")
            }
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            daemon: { nil },
            timeout: 5,
            pollInterval: 0.01,
            sleep: { _ in },
            now: { clock.now() },
            isExecutable: { _ in true },
            threadFinder: nil,
            rolloutsRoot: tempDir
        )

        let req = CLIAgentLaunchRequest(name: "cx-rollout-filter", app: "codex", cwd: targetCwd)
        let res = try lifecycle.launch(req)
        XCTAssertEqual(res.sessionID, "id-valid-newest")
    }

    // MARK: - Stop Exit Command & Enter Retry

    func testStopExitCommandSendsLiteralThenPauseThenEnter() throws {
        let runner = FakeLifecycleRunner()
        let sessionAlive = TestFlag(true)
        let sleeps = TestCollector<TimeInterval>()

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive.value ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
            }
            if argv.contains("send-keys") && argv.contains("Enter") {
                sessionAlive.set(false)
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            daemon: { nil },
            sleep: { sleeps.append($0) },
            now: clock.now
        )

        let member = LightMember(
            name: "cx-stop-cmd", host: "local", app: "codex", project: "p", sessionID: "s-1", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-stop-cmd", cwd: "/tmp", launchedAt: Date())
        )

        let res = try lifecycle.stop(member: member, force: false)
        XCTAssertEqual(res.how, "graceful")

        // Invocations: first sendLiteral ("/quit"), then sendKey ("Enter")
        let sendKeysArgvs = runner.recordedArgvs.filter { $0.contains("send-keys") }
        XCTAssertGreaterThanOrEqual(sendKeysArgvs.count, 2)
        XCTAssertTrue(sendKeysArgvs[0].contains("-l") && sendKeysArgvs[0].contains("/quit"))
        XCTAssertTrue(sendKeysArgvs[1].contains("Enter"))
        // Check sleep(0.7) occurred before Enter
        XCTAssertTrue(sleeps.values.contains(0.7), "Must sleep 0.7s between /quit and Enter")
    }

    func testStopRetriesEnterAfterFourSeconds() throws {
        let runner = FakeLifecycleRunner()
        let clock = TestClock()
        let sessionAlive = TestFlag(true)
        let enterCount = TestCounter()

        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: sessionAlive.value ? 0 : 1, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "9001\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
            }
            if argv.contains("send-keys") && argv.contains("Enter") {
                let cnt = enterCount.increment()
                if cnt >= 2 {
                    // Die on second Enter (the 4s retry)
                    sessionAlive.set(false)
                }
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(runner: runner)
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            daemon: { nil },
            pollInterval: 0.1,
            sleep: { secs in
                clock.advance(secs)
            },
            now: clock.now
        )

        let member = LightMember(
            name: "cx-stop-retry", host: "local", app: "codex", project: "p", sessionID: "s-2", routes: [],
            tmux: LightTmuxBinding(session: "pharos-cx-stop-retry", cwd: "/tmp", agentPID: 9001, agentStarted: "Mon Nov 4 21:00:00 2026", launchedAt: Date())
        )

        let res = try lifecycle.stop(member: member, force: false, timeout: 10)
        XCTAssertEqual(res.how, "graceful")
        XCTAssertEqual(enterCount.count, 2, "Must retry Enter once when still alive after 4s")
    }
}
