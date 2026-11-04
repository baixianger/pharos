import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

final class LightAttentionTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores { try? FileManager.default.removeItem(at: store) }
        stores.removeAll()
        super.tearDown()
    }

    func testNeedsHumanQueuesMessagesUntilTheAgentProceeds() throws {
        let clock = AttentionClock()
        let driver = CountingDriver()
        let relay = try makeRelay(driver: driver, now: clock.now)
        try registerPair(relay)
        let outcome = try relay.reportAttention(LightAttentionReport(
            state: .needsHuman, what: "Bash: rm -rf build", sessionID: "sess-codex", app: "codex", host: "mini"))
        XCTAssertEqual(outcome.recorded, ["codex-a"])
        clock.advance(90)

        let sent = try relay.send(from: "owner", to: ["codex-a"], text: "status?")
        XCTAssertEqual(sent.deliveries.map(\.state), [.queued])
        XCTAssertEqual(sent.deliveries.first?.attention?.what, "Bash: rm -rf build")
        XCTAssertTrue(sent.deliveries[0].detail.hasPrefix("needs_human: Bash: rm -rf build (host mini, session sess-codex, 1m ago)"))
        XCTAssertEqual(driver.delivered, [], "nothing is typed into a session waiting on a human")
        let log = try relay.read(thread: sent.threadID)
        XCTAssertTrue(log.contains { $0.kind == .notice && $0.text.hasPrefix("needs_human codex-a: Bash: rm -rf build") })

        XCTAssertEqual(relay.sweep().flushed, 0, "still waiting")
        let cleared = try relay.reportAttention(LightAttentionReport(state: .clear, sessionID: "sess-codex", app: "codex"))
        XCTAssertEqual(cleared.cleared, ["codex-a"])
        XCTAssertNil(relay.attention(for: "codex-a"))
        XCTAssertEqual(relay.sweep().flushed, 1)
        XCTAssertEqual(driver.delivered, ["codex-a"])
    }

    func testStateExpiresAfterItsTTLAndThenDelivers() throws {
        let clock = AttentionClock()
        let driver = CountingDriver()
        let relay = try makeRelay(driver: driver, now: clock.now)
        try registerPair(relay)
        try relay.reportAttention(LightAttentionReport(state: .needsHuman, what: "apply_patch", sessionID: "sess-codex",
                                                       ttl: 60))
        _ = try relay.send(from: "owner", to: ["codex-a"], text: "hi")
        XCTAssertEqual(driver.delivered, [])
        clock.advance(61)
        XCTAssertNil(relay.attention(for: "codex-a"))
        let swept = relay.sweep()
        XCTAssertEqual(swept.expiredAttention, 1)
        XCTAssertEqual(swept.flushed, 1)
        XCTAssertEqual(driver.delivered, ["codex-a"])
        try relay.reportAttention(LightAttentionReport(state: .needsHuman, sessionID: "sess-codex"))
        XCTAssertEqual(relay.attention(for: "codex-a")?.expiresAt, clock.current.addingTimeInterval(LightAttention.defaultTTL))
    }

    func testRefreshKeepsSinceAndAPollCannotClearAHook() throws {
        let clock = AttentionClock()
        let relay = try makeRelay(now: clock.now)
        try registerPair(relay)
        try relay.reportAttention(LightAttentionReport(state: .needsHuman, what: "first", sessionID: "sess-codex"))
        let since = try XCTUnwrap(relay.attention(for: "codex-a")?.since)
        clock.advance(30)
        try relay.reportAttention(LightAttentionReport(state: .needsHuman, what: "", sessionID: "sess-codex", source: "poll"))
        let refreshed = try XCTUnwrap(relay.attention(for: "codex-a"))
        XCTAssertEqual(refreshed.since, since)
        XCTAssertEqual(refreshed.what, "first")
        XCTAssertEqual(refreshed.source, "hook")
        let poll = try relay.reportAttention(LightAttentionReport(state: .clear, sessionID: "sess-codex", source: "poll"))
        XCTAssertEqual(poll.cleared, [])
        XCTAssertNotNil(relay.attention(for: "codex-a"))
        try relay.reportAttention(LightAttentionReport(state: .clear, sessionID: "sess-codex"))
        XCTAssertNil(relay.attention(for: "codex-a"))

        try relay.reportAttention(LightAttentionReport(state: .needsHuman, sessionID: "sess-codex", source: "poll"))
        XCTAssertEqual(relay.attention(for: "codex-a")?.expiresAt, clock.current.addingTimeInterval(LightAttention.pollTTL))
        XCTAssertEqual(try relay.reportAttention(LightAttentionReport(state: .clear, sessionID: "sess-codex", source: "poll")).cleared,
                       ["codex-a"])
    }

    func testMatchingIsBySessionAndAppAndUnknownSessionsChangeNothing() throws {
        let relay = try makeRelay()
        try registerPair(relay)
        XCTAssertTrue(try relay.reportAttention(LightAttentionReport(state: .needsHuman, sessionID: "nobody")).unmatched)
        XCTAssertTrue(try relay.reportAttention(LightAttentionReport(state: .needsHuman, sessionID: "sess-codex", app: "dsh")).unmatched)
        XCTAssertEqual(relay.activeAttention(), [])
        XCTAssertThrowsError(try relay.reportAttention(LightAttentionReport(state: .needsHuman, sessionID: "../etc")))
        let long = String(repeating: "x", count: 400) + "\nsecond line"
        try relay.reportAttention(LightAttentionReport(state: .needsHuman, what: long, sessionID: "sess-codex"))
        let what = try XCTUnwrap(relay.attention(for: "codex-a")?.what)
        XCTAssertEqual(what.count, LightAttention.whatLimit)
        XCTAssertFalse(what.contains("\n"))
    }

    func testWaitDoesNotHarvestWhileWaitingOnAHumanAndAReplyClears() throws {
        let driver = CountingDriver()
        driver.reply = "partial text"
        let relay = try makeRelay(driver: driver)
        try registerPair(relay)
        let sent = try relay.send(from: "owner", to: ["codex-a"], text: "q")
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        try relay.reportAttention(LightAttentionReport(state: .needsHuman, what: "Bash: make deploy", sessionID: "sess-codex"))
        let waited = try relay.wait(replyID: replyID, timeout: 0)
        XCTAssertEqual(waited.status, .pending)
        XCTAssertEqual(waited.attention?.member, "codex-a")
        XCTAssertEqual(driver.reads, 0)
        XCTAssertEqual(relay.pendingHarvest(maxAge: 3600, limit: 5), [])

        _ = try relay.reply(replyID, text: "done")
        XCTAssertNil(relay.attention(for: "codex-a"), "a member that runs pharos reply has proceeded")
    }

    func testHoldDoesNotDependOnNodeLiveness() throws {
        let clock = AttentionClock()
        let driver = CountingDriver()
        let relay = try makeRelay(driver: driver, now: clock.now)
        try registerPair(relay)
        _ = try relay.pull(node: "broker")
        clock.advance(LightRelay.nodeHeartbeatWindow + 5)
        try relay.reportAttention(LightAttentionReport(state: .needsHuman, what: "Bash: x", sessionID: "sess-codex"))
        let sent = try relay.send(from: "owner", to: ["codex-a"], text: "hi")
        XCTAssertEqual(sent.deliveries.first?.state, .queued)
        XCTAssertNotNil(sent.deliveries.first?.attention)
        XCTAssertNil(sent.deliveries.first?.via)
        XCTAssertEqual(relay.inboxNodes(), [], "held for the human, not parked as offline")
    }

    func testStatePersistsAcrossProcesses() throws {
        let store = freshStore()
        let first = try LightRelay(store: store)
        try registerPair(first)
        try first.reportAttention(LightAttentionReport(state: .needsHuman, what: "Bash: ls", sessionID: "sess-codex", host: "mini"))
        let second = try LightRelay(store: store)
        XCTAssertEqual(second.attention(for: "codex-a")?.what, "Bash: ls")
        XCTAssertEqual(second.attentionCandidates().map(\.name), ["codex-a"], "a recorded state is re-checked")
        _ = try second.send(from: "owner", to: ["codex-a"], text: "q")
        XCTAssertEqual(second.attentionCandidates().map(\.name), ["codex-a"])
    }

    func testCommandsReportListAndMarkMembersAndThreads() throws {
        let relay = try makeRelay(driver: CountingDriver())
        try registerPair(relay)
        func run(_ command: String, _ args: [String]) -> LightCLIResult {
            LightCommands.execute(command: command, arguments: args, relay: relay, routesForApp: { _ in [] })
        }
        XCTAssertEqual(run("attention", ["list"]).text, "no member needs a human")
        let reported = run("attention", ["report", "--state", "needs_human", "--session", "sess-codex", "--app", "codex",
                                         "--host", "mini", "--what=Bash: rm -rf build", "--at", "1700000000000"])
        XCTAssertEqual(reported.exitCode, 0)
        XCTAssertEqual(reported.text, "needs_human codex-a")
        XCTAssertEqual(run("attention", ["report", "--state", "needs_human", "--session", "nope"]).text, "no member has session nope")
        XCTAssertTrue(run("attention", ["list"]).text.hasPrefix("needs_human codex-a: Bash: rm -rf build (host mini, session sess-codex, "))
        let members = run("member", ["list"]).text.components(separatedBy: "\n")
        XCTAssertEqual(members[0], "NAME\tAPP\tHOST\tPROJECT\tSESSION\tROUTES\tSTATE")
        XCTAssertTrue(members.contains { $0.hasPrefix("codex-a\t") && $0.contains("\tneeds_human ") })
        XCTAssertTrue(members.contains { $0.hasPrefix("owner\t") && $0.hasSuffix("\t-") })

        let send = run("send", ["--from", "owner", "--to", "codex-a", "--", "status?"])
        XCTAssertTrue(send.text.contains("queued\tcodex-a\t"))
        XCTAssertTrue(send.text.contains("  needs_human: Bash: rm -rf build (host mini, session sess-codex, "))
        XCTAssertTrue(send.text.contains("queued until it proceeds"))
        let thread = try XCTUnwrap(relay.listThreads().first?.thread.id)
        XCTAssertTrue(run("thread", ["show", thread]).text.contains("\nneeds_human codex-a: Bash: rm -rf build"))
        let replyID = try XCTUnwrap(relay.read(thread: thread).first { $0.kind == .delivery }?.replyID)
        let waited = run("wait", [replyID])
        XCTAssertEqual(waited.exitCode, 2)
        XCTAssertTrue(waited.text.contains("\nneeds_human codex-a: "))

        XCTAssertEqual(run("attention", ["approve", "codex-a"]).exitCode, 2)
        XCTAssertEqual(run("attention", ["report", "--state", "clear", "--session", "sess-codex"]).text, "cleared codex-a")
        XCTAssertEqual(run("attention", ["report", "--state", "clear", "--session", "sess-codex"]).text, "nothing to clear")
        XCTAssertFalse(run("member", ["list"]).text.contains("needs_human"))
        XCTAssertTrue(LightCommands.chatHelp.contains("NEEDS HUMAN"))
    }

    func testAchatPendingPollReadsWithoutNavigatingAndCountsOnlyApprovals() {
        let ag = LightMember(name: "ag-a", host: "local", app: "ag", project: "p", sessionID: "conv-1", routes: [])
        let dsh = LightMember(name: "dsh-a", host: "local", app: "dsh", project: "p", sessionID: "session-1", routes: [])
        let cursor = LightMember(name: "cursor-a", host: "local", app: "cursor", project: "p", sessionID: "chat-1", routes: [])
        XCTAssertEqual(AchatPendingAttentionSource.pendingArgv(bin: "achat", member: ag), ["achat", "ag", "pending", "--json"])
        XCTAssertEqual(AchatPendingAttentionSource.pendingArgv(bin: "achat", member: dsh),
                       ["achat", "dsh", "pending", "--via", "files", "--session", "session-1", "--json"])

        let agOpen = #"{"ok":true,"conversation":"conv-1","pending":[{"id":"0","text":"Run command?\nls -la","choices":["Run","Reject"]}]}"#
        XCTAssertEqual(AchatPendingAttentionSource.interpret(member: ag, stdout: agOpen)?.state, .needsHuman)
        XCTAssertEqual(AchatPendingAttentionSource.interpret(member: ag, stdout: agOpen)?.what, "Run command? ls -la")
        let agOther = #"{"ok":true,"conversation":"conv-9","pending":[{"id":"0","text":"Run?","choices":["Run"]}]}"#
        XCTAssertNil(AchatPendingAttentionSource.interpret(member: ag, stdout: agOther), "another conversation says nothing")
        XCTAssertNil(AchatPendingAttentionSource.interpret(member: ag, stdout: #"{"ok":true,"pending":[]}"#))
        XCTAssertEqual(AchatPendingAttentionSource.interpret(member: ag, stdout: #"{"ok":true,"conversation":"conv-1","pending":[]}"#)?.state,
                       .clear)

        let dshApproval = #"{"ok":true,"sessionId":"session-1","pending":[{"id":"a1","kind":"approval","tool":"exec_command","reason":"needs network"}]}"#
        let report = AchatPendingAttentionSource.interpret(member: dsh, stdout: dshApproval)
        XCTAssertEqual(report?.state, .needsHuman)
        XCTAssertEqual(report?.what, "exec_command: needs network")
        XCTAssertEqual(report?.source, "poll")
        let dshQuestion = #"{"ok":true,"sessionId":"session-1","pending":[{"id":"q","kind":"question","questions":[]}]}"#
        XCTAssertEqual(AchatPendingAttentionSource.interpret(member: dsh, stdout: dshQuestion)?.state, .clear)
        XCTAssertNil(AchatPendingAttentionSource.interpret(member: dsh, stdout: #"{"ok":false,"error":{"code":"unavailable"}}"#))
        XCTAssertEqual(AchatPendingAttentionSource.interpret(member: cursor, stdout: #"{"ok":true,"chatId":"chat-1","pending":[]}"#)?.state,
                       .clear)
    }

    func testPollSkipsRemoteAndUnpolledAppsAndReadsTheWindowOnce() {
        let runner = PendingRunner(stdout: #"{"ok":true,"conversation":"conv-1","pending":[{"id":"0","text":"Allow?"}]}"#)
        let source = AchatPendingAttentionSource(runner: runner, achat: "achat", isLocal: { $0.host == "local" }, hostLabel: "mini")
        let members = [
            LightMember(name: "ag-a", host: "local", app: "ag", project: "p", sessionID: "conv-1", routes: []),
            LightMember(name: "ag-b", host: "local", app: "ag", project: "p", sessionID: "conv-2", routes: []),
            LightMember(name: "ag-air", host: "mac-air", app: "ag", project: "p", sessionID: "conv-3", routes: []),
            LightMember(name: "codex-a", host: "local", app: "codex", project: "p", sessionID: "s", routes: []),
        ]
        let reports = source.poll(members: members)
        XCTAssertEqual(reports.map(\.sessionID), ["conv-1"])
        XCTAssertEqual(reports.first?.host, "mini")
        XCTAssertEqual(runner.calls, 1)
    }

    func testARecordedStateIsPolledFirstAndSharedWindowReadsDoNotUseTheLimit() throws {
        let driver = CountingDriver()
        let relay = try makeRelay(driver: driver)
        try registerPair(relay)
        _ = try relay.register(LightMember(name: "aaa", host: "broker", app: "shell", project: "pharos", sessionID: "sess-aaa",
                                           routes: [LightRoute.named("app-server")]))
        _ = try relay.send(from: "owner", to: ["aaa"], text: "question?")
        _ = try relay.reportAttention(LightAttentionReport(state: .needsHuman, what: "Bash", sessionID: "sess-codex", app: "codex"))
        XCTAssertEqual(relay.attentionCandidates().first?.name, "codex-a", "a recorded state outranks an open ask")

        let runner = PendingRunner(stdout: #"{"ok":true,"sessionId":"session-1","pending":[]}"#)
        let source = AchatPendingAttentionSource(runner: runner, achat: "achat", isLocal: { _ in true }, hostLabel: "mini", limit: 2)
        let ags = (1...5).map { LightMember(name: "ag-\($0)", host: "local", app: "ag", project: "p", sessionID: "conv-\($0)", routes: []) }
        let dsh = LightMember(name: "dsh-a", host: "local", app: "dsh", project: "p", sessionID: "session-1", routes: [])
        let reports = source.poll(members: ags + [dsh])
        XCTAssertEqual(runner.calls, 2, "one shared Antigravity window read plus dsh")
        XCTAssertEqual(reports.map(\.sessionID), ["session-1"])
    }

    // MARK: helpers

    private func registerPair(_ relay: LightRelay) throws {
        for (name, app, session) in [("owner", "shell", "sess-owner"), ("codex-a", "codex", "sess-codex")]
        where relay.member(named: name) == nil {
            _ = try relay.register(LightMember(name: name, host: "broker", app: app, project: "pharos", sessionID: session,
                                               routes: [LightRoute.named("app-server")]))
        }
    }

    private func makeRelay(driver: any LightSessionDriver = IdleLightDriver(),
                           now: (@Sendable () -> Date)? = nil) throws -> LightRelay {
        if let now { return try LightRelay(store: freshStore(), now: now, driver: driver) }
        return try LightRelay(store: freshStore(), driver: driver)
    }

    private func freshStore() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-attention-\(UUID().uuidString)", isDirectory: true)
        stores.append(url)
        return url
    }
}

private final class AttentionClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { current }
    func advance(_ interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}

private final class CountingDriver: LightSessionDriver, @unchecked Sendable {
    var delivered: [String] = []
    var reads = 0
    var reply: String?

    func deliver(member: LightMember, body: String) -> LightDriveResult {
        delivered.append(member.name)
        return LightDriveResult(state: .delivered, route: "app-server", fallback: false, liveVerified: false, detail: "fake")
    }

    func readReply(member: LightMember, since: Date) -> String? {
        reads += 1
        return reply
    }
}

private final class PendingRunner: LightProcessRunning, @unchecked Sendable {
    let stdout: String
    var calls = 0
    init(stdout: String) { self.stdout = stdout }
    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        calls += 1
        return LightProcessOutput(status: 0, stdout: stdout, stderr: "")
    }
}
