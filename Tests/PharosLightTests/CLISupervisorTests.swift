import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

final class CLISupervisorTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-supervisor-test-\(UUID().uuidString)")
        tempDirs.append(dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private final class FakeSupervisorRunner: LightProcessRunning, @unchecked Sendable {
        typealias Handler = ([String]) -> LightProcessOutput?
        var handlers: [Handler] = []
        var recordedArgvs: [[String]] = []

        func addHandler(_ h: @escaping Handler) {
            handlers.append(h)
        }

        func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
            recordedArgvs.append(invocation.argv)
            for h in handlers {
                if let out = h(invocation.argv) { return out }
            }
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }
    }

    private final class TestClock: @unchecked Sendable {
        private var current: Date
        init(_ initial: Date = Date(timeIntervalSince1970: 10_000)) { self.current = initial }
        func now() -> Date { current }
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    func testAliveIdle() throws {
        let runner = FakeSupervisorRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                return LightProcessOutput(status: 0, stdout: "1000\tcodex\t0\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› prompt\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(tmux: "tmux", runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux, runner: runner, now: clock.now,
            threadReader: { id in
                CodexThreadInfo(id: id, cwd: "/tmp", path: nil, originator: "codex", status: .idle)
            }
        )
        let stateURL = makeTempURL("supervisor.json")
        let supervisor = CLISupervisor(lifecycle: lifecycle, node: "node-local", stateStore: stateURL, now: clock.now)

        let member = LightMember(
            name: "m-alive", host: "local", app: "codex", project: "p", sessionID: "s-1", routes: [],
            tmux: LightTmuxBinding(session: "pharos-m-alive", cwd: "/tmp", launchedAt: clock.now())
        )

        let reports = supervisor.pass(members: [member])
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.member, "m-alive")
        XCTAssertEqual(r.node, "node-local")
        XCTAssertEqual(r.live, "alive")
        XCTAssertEqual(r.activity, "idle")
        XCTAssertNil(r.binding, "alive member without changes does not stamp binding")
    }

    func testDeadEndedMarkerOnce() throws {
        let runner = FakeSupervisorRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "") // session gone
            }
            return nil
        }

        let tmux = TmuxController(tmux: "tmux", runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux, runner: runner, now: clock.now,
            threadReader: { id in
                CodexThreadInfo(id: id, cwd: "/tmp", path: nil, originator: "codex", status: .idle)
            }
        )
        let stateURL = makeTempURL("supervisor.json")
        let supervisor = CLISupervisor(lifecycle: lifecycle, node: "node-local", stateStore: stateURL, now: clock.now)

        var member = LightMember(
            name: "m-dead", host: "local", app: "codex", project: "p", sessionID: "s-2", routes: [],
            tmux: LightTmuxBinding(session: "pharos-m-dead", cwd: "/tmp", launchedAt: clock.now(), endedAt: nil)
        )

        // Pass 1: stamps endedAt and endedReason "exited"
        let reports1 = supervisor.pass(members: [member])
        XCTAssertEqual(reports1.count, 1)
        let r1 = reports1[0]
        XCTAssertEqual(r1.live, "ended")
        XCTAssertNotNil(r1.binding)
        XCTAssertEqual(r1.binding?.endedReason, "exited")
        XCTAssertEqual(r1.binding?.endedAt, clock.now())

        // Pass 2: with the ended binding, does not re-stamp
        member.tmux = r1.binding
        clock.advance(10)
        let reports2 = supervisor.pass(members: [member])
        XCTAssertEqual(reports2.count, 1)
        let r2 = reports2[0]
        XCTAssertEqual(r2.live, "ended")
        XCTAssertNil(r2.binding, "second pass with ended binding does not re-stamp")
    }

    func testAutoReviveSuccess() throws {
        let runner = FakeSupervisorRunner()
        var respawned = false
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("respawn-pane") {
                respawned = true
                return LightProcessOutput(status: 0, stdout: "", stderr: "")
            }
            if argv.contains("list-panes") {
                let deadStr = respawned ? "0" : "1"
                return LightProcessOutput(status: 0, stdout: "2000\tcodex\t\(deadStr)\n", stderr: "")
            }
            if argv.contains("ps") {
                return LightProcessOutput(status: respawned ? 0 : 1, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
            }
            if argv.contains("capture-pane") {
                return LightProcessOutput(status: 0, stdout: "› ready\n", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(tmux: "tmux", runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux, runner: runner, now: clock.now,
            threadReader: { id in
                CodexThreadInfo(id: id, cwd: "/tmp", path: nil, originator: "codex", status: .idle)
            }
        )
        let stateURL = makeTempURL("supervisor.json")
        let supervisor = CLISupervisor(lifecycle: lifecycle, node: "node-local", stateStore: stateURL, now: clock.now)

        let member = LightMember(
            name: "m-revive", host: "local", app: "codex", project: "p", sessionID: "s-3", routes: [],
            tmux: LightTmuxBinding(
                session: "pharos-m-revive", cwd: "/tmp",
                launchedAt: clock.now(), endedAt: clock.now(), autoRevive: true, endedReason: "exited"
            )
        )

        let reports = supervisor.pass(members: [member])
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.live, "alive")
        XCTAssertEqual(r.detail, "auto-revived")
        XCTAssertNotNil(r.binding)
        XCTAssertNil(r.binding?.endedAt)
        XCTAssertNil(r.binding?.endedReason)
        XCTAssertEqual(r.binding?.agentPID, 2000)
    }

    func testAutoReviveBackoffAndGiveUpAfterThree() throws {
        let runner = FakeSupervisorRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "") // session gone
            }
            if argv.contains("new-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "failed to spawn\n")
            }
            return nil
        }

        let tmux = TmuxController(tmux: "tmux", runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux, runner: runner, now: clock.now,
            threadReader: { id in
                CodexThreadInfo(id: id, cwd: "/tmp", path: nil, originator: "codex", status: .idle)
            }
        )
        let stateURL = makeTempURL("supervisor.json")
        let supervisor = CLISupervisor(
            lifecycle: lifecycle, node: "node-local", stateStore: stateURL,
            reviveBackoff: 60, maxReviveFailures: 3, now: clock.now
        )

        var member = LightMember(
            name: "m-fail", host: "local", app: "codex", project: "p", sessionID: "s-4", routes: [],
            tmux: LightTmuxBinding(
                session: "pharos-m-fail", cwd: "/tmp",
                launchedAt: clock.now(), endedAt: clock.now(), autoRevive: true, endedReason: "exited"
            )
        )

        // Attempt 1: fails
        let r1 = supervisor.pass(members: [member])[0]
        XCTAssertEqual(r1.live, "ended")
        XCTAssertTrue(r1.detail.contains("auto-revive failed (1/3)"))

        // Pass 1.1: 10s later, within backoff (60s) -> no attempt made
        clock.advance(10)
        let r1_1 = supervisor.pass(members: [member])[0]
        XCTAssertEqual(r1_1.live, "ended")

        // Attempt 2: 60s after attempt 1
        clock.advance(55) // total 65s since attempt 1
        let r2 = supervisor.pass(members: [member])[0]
        XCTAssertTrue(r2.detail.contains("auto-revive failed (2/3)"))

        // Attempt 3: 60s later -> reaches max failures
        clock.advance(65)
        let r3 = supervisor.pass(members: [member])[0]
        XCTAssertTrue(r3.detail.contains("auto-revive gave up after 3 failures; run pharos member revive m-fail"))

        // Pass 4: after further backoff, gave up remains and no attempt is made
        clock.advance(100)
        let r4 = supervisor.pass(members: [member])[0]
        XCTAssertTrue(r4.detail.contains("auto-revive gave up after 3 failures; run pharos member revive m-fail"))

        // Manual revive / launch resets failures
        clock.advance(10)
        member.tmux?.launchedAt = clock.now()
        let r5 = supervisor.pass(members: [member])[0]
        XCTAssertTrue(r5.detail.contains("auto-revive failed (1/3)"), "failures reset so attempt 1 runs again")
    }

    func testStoppedMemberNeverAutoRevived() throws {
        let runner = FakeSupervisorRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(tmux: "tmux", runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux, runner: runner, now: clock.now,
            threadReader: { id in
                CodexThreadInfo(id: id, cwd: "/tmp", path: nil, originator: "codex", status: .idle)
            }
        )
        let stateURL = makeTempURL("supervisor.json")
        let supervisor = CLISupervisor(lifecycle: lifecycle, node: "node-local", stateStore: stateURL, now: clock.now)

        let member = LightMember(
            name: "m-stopped", host: "local", app: "codex", project: "p", sessionID: "s-5", routes: [],
            tmux: LightTmuxBinding(
                session: "pharos-m-stopped", cwd: "/tmp",
                launchedAt: clock.now(), endedAt: clock.now(), autoRevive: true, endedReason: "stopped"
            )
        )

        let reports = supervisor.pass(members: [member])
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.live, "stopped")
        XCTAssertFalse(r.detail.contains("auto-revive"))
    }

    func testAutoReviveOffNeverRevives() throws {
        let runner = FakeSupervisorRunner()
        runner.addHandler { argv in
            if argv.contains("has-session") {
                return LightProcessOutput(status: 1, stdout: "", stderr: "")
            }
            return nil
        }

        let tmux = TmuxController(tmux: "tmux", runner: runner)
        let clock = TestClock()
        let lifecycle = CLIAgentLifecycle(
            tmux: tmux, runner: runner, now: clock.now,
            threadReader: { id in
                CodexThreadInfo(id: id, cwd: "/tmp", path: nil, originator: "codex", status: .idle)
            }
        )
        let stateURL = makeTempURL("supervisor.json")
        let supervisor = CLISupervisor(lifecycle: lifecycle, node: "node-local", stateStore: stateURL, now: clock.now)

        let member = LightMember(
            name: "m-no-revive", host: "local", app: "codex", project: "p", sessionID: "s-6", routes: [],
            tmux: LightTmuxBinding(
                session: "pharos-m-no-revive", cwd: "/tmp",
                launchedAt: clock.now(), endedAt: clock.now(), autoRevive: false, endedReason: "exited"
            )
        )

        let reports = supervisor.pass(members: [member])
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.live, "ended")
        XCTAssertFalse(r.detail.contains("auto-revive"))
    }
}
