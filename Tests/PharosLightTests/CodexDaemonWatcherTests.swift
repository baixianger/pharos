import XCTest
import Foundation
@testable import PharosRuntime
@testable import PharosMeshCore

private final class TestRunner: LightProcessRunning, @unchecked Sendable {
    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        if invocation.argv.contains("has-session") {
            return LightProcessOutput(status: 0, stdout: "", stderr: "")
        }
        if invocation.argv.contains("list-panes") {
            return LightProcessOutput(status: 0, stdout: "1234\tcodex\t0\n", stderr: "")
        }
        if invocation.argv.contains("ps") {
            return LightProcessOutput(status: 0, stdout: "Mon Nov 4 21:00:00 2026\n", stderr: "")
        }
        return LightProcessOutput(status: 0, stdout: "", stderr: "")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var val = 0

    func inc() {
        lock.lock()
        defer { lock.unlock() }
        val += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return val
    }
}

final class CodexDaemonWatcherTests: XCTestCase {
    private var socketsToClean: [String] = []
    private var filesToClean: [URL] = []

    override func tearDown() {
        for s in socketsToClean {
            unlink(s)
        }
        socketsToClean.removeAll()
        for f in filesToClean {
            try? FileManager.default.removeItem(at: f)
        }
        filesToClean.removeAll()
        super.tearDown()
    }

    func testCodexWatchFileReadStaleAndDisconnected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("watch-test-\(UUID().uuidString).json")
        filesToClean.append(tmp)

        let now = Date()

        // 1. Fresh connected state
        let freshState = CodexWatchState(
            updatedAt: now,
            connected: true,
            threads: ["t-1": CodexWatchThread(status: "idle", flags: [], at: now, pending: [])]
        )
        try CodexWatchFile.save(freshState, to: tmp)

        let readFresh = CodexWatchFile.read(tmp, now: now, maxAge: 45)
        XCTAssertNotNil(readFresh)
        XCTAssertEqual(readFresh?.connected, true)
        XCTAssertEqual(readFresh?.threads["t-1"]?.status, "idle")

        // 2. Disconnected state -> returns nil
        let disconnectedState = CodexWatchState(
            updatedAt: now,
            connected: false,
            threads: ["t-1": CodexWatchThread(status: "idle", flags: [], at: now, pending: [])]
        )
        try CodexWatchFile.save(disconnectedState, to: tmp)

        let readDisconnected = CodexWatchFile.read(tmp, now: now, maxAge: 45)
        XCTAssertNil(readDisconnected)

        // 3. Stale state (now is 50 seconds later) -> returns nil
        try CodexWatchFile.save(freshState, to: tmp)
        let readStale = CodexWatchFile.read(tmp, now: now.addingTimeInterval(50), maxAge: 45)
        XCTAssertNil(readStale)
    }

    func testWatcherPushesEventsAndUpdatesWatchFile() throws {
        let sockPath = "/tmp/pcx-watch-\(UUID().uuidString.prefix(8)).sock"
        socketsToClean.append(sockPath)
        let watchURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-\(UUID().uuidString).json")
        filesToClean.append(watchURL)

        let server = FakeCodexDaemonServer(path: sockPath)
        try server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let watcher = CodexDaemonWatcher(
            socketPath: sockPath,
            outputURL: watchURL,
            sleep: { Thread.sleep(forTimeInterval: min($0, 0.05)) }
        )
        watcher.start()
        defer { watcher.stop() }

        // Wait for initial seed
        var seeded = false
        for _ in 0..<50 {
            if let state = CodexWatchFile.read(watchURL, now: Date(), maxAge: 45), state.threads["01a1a81b-test"] != nil {
                seeded = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(seeded, "Watcher should seed initial thread from thread/loaded/list")

        // Push thread/status/changed notification
        server.pushFrame([
            "method": "thread/status/changed",
            "params": [
                "threadId": "01a1a81b-test",
                "status": [
                    "type": "active",
                    "activeFlags": ["waitingOnUserInput"]
                ]
            ]
        ])

        var statusUpdated = false
        for _ in 0..<50 {
            if let state = CodexWatchFile.read(watchURL, now: Date(), maxAge: 45),
               let t = state.threads["01a1a81b-test"],
               t.flags == ["waitingOnUserInput"] {
                statusUpdated = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(statusUpdated, "Watcher should update thread flags upon thread/status/changed")

        // Push server request approval
        server.pushFrame([
            "id": "srv-99",
            "method": "item/commandExecution/requestApproval",
            "params": [
                "threadId": "01a1a81b-test",
                "command": "rm -rf test-dir"
            ]
        ])

        var approvalRecorded = false
        for _ in 0..<50 {
            if let state = CodexWatchFile.read(watchURL, now: Date(), maxAge: 45),
               let t = state.threads["01a1a81b-test"],
               t.pending.contains(where: { $0.id == "srv-99" && $0.summary == "rm -rf test-dir" }) {
                approvalRecorded = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(approvalRecorded, "Watcher should record pending server request")

        // Assert watcher client NEVER sent any reply for srv-99 to server
        for payload in server.receivedPayloads {
            XCTAssertFalse(payload.contains("srv-99"), "Watcher must never respond to server requests!")
        }

        // Push serverRequest/resolved
        server.pushFrame([
            "method": "serverRequest/resolved",
            "params": [
                "requestId": "srv-99"
            ]
        ])

        var approvalCleared = false
        for _ in 0..<50 {
            if let state = CodexWatchFile.read(watchURL, now: Date(), maxAge: 45),
               let t = state.threads["01a1a81b-test"],
               !t.pending.contains(where: { $0.id == "srv-99" }) {
                approvalCleared = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(approvalCleared, "Watcher should clear resolved request")

        // Push thread/closed
        server.pushFrame([
            "method": "thread/closed",
            "params": [
                "threadId": "01a1a81b-test"
            ]
        ])

        var threadClosed = false
        for _ in 0..<50 {
            if let state = CodexWatchFile.read(watchURL, now: Date(), maxAge: 45),
               state.threads["01a1a81b-test"] == nil {
                threadClosed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(threadClosed, "Watcher should remove closed thread")
    }

    func testWatcherReconnectsAfterServerClose() throws {
        let sockPath = "/tmp/pcx-reconn-\(UUID().uuidString.prefix(8)).sock"
        socketsToClean.append(sockPath)
        let watchURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-\(UUID().uuidString).json")
        filesToClean.append(watchURL)

        let server = FakeCodexDaemonServer(path: sockPath)
        try server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let watcher = CodexDaemonWatcher(
            socketPath: sockPath,
            outputURL: watchURL,
            sleep: { Thread.sleep(forTimeInterval: min($0, 0.05)) }
        )
        watcher.start()
        defer { watcher.stop() }

        // Wait for first connection
        var connectedFirst = false
        for _ in 0..<50 {
            if let state = CodexWatchFile.read(watchURL, now: Date(), maxAge: 45), state.connected {
                connectedFirst = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(connectedFirst)

        // Drop the client from server side
        server.closeClient()

        // Wait for disconnected state or reconnection
        // Watcher catches error, writes connected: false, sleeps 5s (mocked to 0.05s), reconnects
        var reconnected = false
        for _ in 0..<100 {
            if let state = CodexWatchFile.read(watchURL, now: Date(), maxAge: 45), state.connected {
                reconnected = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(reconnected, "Watcher should reconnect after connection close")
    }

    func testLifecycleAndAttentionConsumerHitAndFallback() throws {
        let watchURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-\(UUID().uuidString).json")
        filesToClean.append(watchURL)

        let now = Date()
        let member = LightMember(
            name: "codex-tester",
            host: "local",
            app: "codex",
            project: "proj",
            sessionID: "thread-xyz",
            routes: [],
            tmux: LightTmuxBinding(
                session: "pharos-test-cx",
                cwd: "/tmp",
                model: nil,
                agentPID: 1234,
                agentStarted: "Mon Nov 4 21:00:00 2026",
                launchedAt: now,
                endedAt: nil
            )
        )

        let callCounter = Counter()
        let fakeReader: @Sendable (String) throws -> CodexThreadInfo = { _ in
            callCounter.inc()
            return CodexThreadInfo(
                id: "thread-xyz",
                cwd: "/tmp",
                path: "/tmp/thread.jsonl",
                originator: "test",
                status: .active(flags: ["fallbackFlag"])
            )
        }

        let runner = TestRunner()
        let tmux = TmuxController(runner: runner)

        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            env: [:],
            home: "/tmp",
            threadReader: fakeReader,
            watchFile: watchURL
        )

        // 1. Fresh watch state with pending approval
        let statePending = CodexWatchState(
            updatedAt: now,
            connected: true,
            threads: [
                "thread-xyz": CodexWatchThread(
                    status: "active",
                    flags: [],
                    at: now,
                    pending: [CodexWatchRequest(id: "r1", method: "approval", summary: "run bash test")]
                )
            ]
        )
        try CodexWatchFile.save(statePending, to: watchURL)

        let statusPending = lifecycle.status(member: member)
        XCTAssertEqual(statusPending.activity, .needsHuman)
        XCTAssertEqual(statusPending.detail, "run bash test")
        XCTAssertEqual(callCounter.value, 0, "Should use watch file cache without calling readThread")

        // 2. Fresh watch state with waitingOnUserInput flag
        let stateWaiting = CodexWatchState(
            updatedAt: now,
            connected: true,
            threads: [
                "thread-xyz": CodexWatchThread(
                    status: "active",
                    flags: ["waitingOnUserInput"],
                    at: now,
                    pending: []
                )
            ]
        )
        try CodexWatchFile.save(stateWaiting, to: watchURL)

        let statusWaiting = lifecycle.status(member: member)
        XCTAssertEqual(statusWaiting.activity, .needsHuman)
        XCTAssertEqual(statusWaiting.detail, "waiting on user input")
        XCTAssertEqual(callCounter.value, 0, "Should still use watch file cache")

        // 3. Stale watch state -> fallback to threadReader
        let stateStale = CodexWatchState(
            updatedAt: now.addingTimeInterval(-60),
            connected: true,
            threads: stateWaiting.threads
        )
        try CodexWatchFile.save(stateStale, to: watchURL)

        let statusStale = lifecycle.status(member: member)
        XCTAssertEqual(statusStale.activity, .thinking)
        XCTAssertEqual(statusStale.detail, "fallbackFlag")
        XCTAssertEqual(callCounter.value, 1, "Should fall back to reader when watch file is stale")
    }
}
