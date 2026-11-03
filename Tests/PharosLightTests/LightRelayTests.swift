import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

final class LightRelayTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores {
            try? FileManager.default.removeItem(at: store)
        }
        stores.removeAll()
        super.tearDown()
    }

    func testRegistryResolvesStableNamesAndRejectsConflicts() throws {
        let relay = try makeRelay()
        let codex = try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex"))
        XCTAssertEqual(try relay.register(codex).sessionID, "sess-codex")
        XCTAssertEqual(relay.member(named: "codex-mini-pharos")?.routes.map(\.id), ["app-server"])
        XCTAssertThrowsError(try relay.register(member("codex-mini-pharos", app: "codex", session: "other-session"))) { error in
            XCTAssertEqual(error as? LightRelayError, .duplicateMember("codex-mini-pharos"))
        }
        XCTAssertThrowsError(try relay.register(member("Owner@Example.com", app: "codex", session: "sess-1")))
        XCTAssertThrowsError(try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex", host: "10.1.2.3")))
        XCTAssertEqual(relay.listMembers().map(\.name), ["codex-mini-pharos"])
    }

    func testReplyIDIssueLookupExpiryAndOnce() throws {
        let clock = ManualClock()
        let driver = FakeDriver(delivered("app-server"))
        let relay = try makeRelay(driver: driver, now: clock.now)
        let thread = try openPair(relay)
        let sent = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos ping")
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        XCTAssertTrue(LightTokens.isValid(replyID, prefix: "r"))
        XCTAssertGreaterThanOrEqual(replyID.count, 10)
        XCTAssertTrue(sent.deliveries[0].header.contains("pharos reply \(replyID)"))
        XCTAssertTrue(sent.deliveries[0].header.contains("[pharos from=owner thread=\(thread.id) reply-id=\(replyID) hop=1/8]"))

        let answered = try relay.reply(replyID, text: "ack")
        XCTAssertEqual(answered.deliveries.map(\.to), ["owner"])
        XCTAssertEqual(try relay.read(thread: thread.id).filter { $0.kind == .message }.map(\.text), ["@codex-mini-pharos ping", "ack"])

        clock.advance(25 * 60 * 60)
        XCTAssertThrowsError(try relay.reply(replyID, text: "late")) { error in
            XCTAssertEqual(error as? LightRelayError, .expiredReply(replyID))
        }
        XCTAssertEqual(relay.rejections().last?.reason, "expired")
        XCTAssertThrowsError(try relay.reply(replyID, text: "again")) { error in
            XCTAssertEqual(error as? LightRelayError, .unknownReply(replyID))
        }

        let onceRelay = try makeRelay(driver: FakeDriver(delivered("app-server")))
        let onceThread = try openPair(onceRelay)
        let onceSent = try onceRelay.send(from: "owner", thread: onceThread.id, text: "@codex-mini-pharos once", once: true)
        let onceID = try XCTUnwrap(onceSent.deliveries.first?.replyID)
        _ = try onceRelay.reply(onceID, text: "first")
        XCTAssertThrowsError(try onceRelay.reply(onceID, text: "second")) { error in
            XCTAssertEqual(error as? LightRelayError, .consumedReply(onceID))
        }
        XCTAssertEqual(onceRelay.rejections().map(\.reason), ["consumed"])

        XCTAssertThrowsError(try relay.reply("nope", text: "x")) { error in
            XCTAssertEqual(error as? LightRelayError, .malformedReply("nope"))
        }
        XCTAssertThrowsError(try relay.reply("r_notissued", text: "x")) { error in
            XCTAssertEqual(error as? LightRelayError, .unknownReply("r_notissued"))
        }
        XCTAssertEqual(relay.rejections().map(\.reason).suffix(2), ["malformed", "unknown"])
    }

    func testMentionSelectionDeliversOnlyToNamedMembers() throws {
        let driver = FakeDriver(delivered("app-server"))
        let relay = try makeRelay(driver: driver)
        _ = try relay.register(member("owner", app: "shell", session: "owner-1", routes: []))
        _ = try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: []))
        _ = try relay.register(member("claude-mini", app: "claude", session: "sess-claude", routes: []))
        let thread = try relay.openThread(members: ["owner", "codex-mini-pharos", "claude-mini"])

        let silent = try relay.send(from: "owner", thread: thread.id, text: "owner@example.com just talking")
        XCTAssertTrue(silent.deliveries.isEmpty)
        XCTAssertEqual(LightMentions.tokens(in: silent.deliveries.isEmpty ? "owner@example.com @codex-mini-pharos" : ""), ["codex-mini-pharos"])

        let one = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos @codex-mini-pharos only you")
        XCTAssertEqual(one.deliveries.map(\.to), ["codex-mini-pharos"])
        XCTAssertEqual(driver.calls.map(\.name), ["codex-mini-pharos"])

        let all = try relay.send(from: "owner", thread: thread.id, text: "@ALL @codex-mini-pharos everyone")
        XCTAssertEqual(Set(all.deliveries.map(\.to)), ["codex-mini-pharos", "claude-mini"])
        XCTAssertEqual(all.deliveries.count, 2)
        XCTAssertFalse(all.deliveries.map(\.to).contains("owner"))

        let missing = try relay.send(from: "owner", thread: thread.id, text: "@nobody and @claude-mini go")
        XCTAssertEqual(missing.unresolved, ["nobody"])
        XCTAssertEqual(missing.deliveries.map(\.to), ["claude-mini"])

        let shared = try relay.read(thread: thread.id)
        XCTAssertTrue(shared.contains { $0.kind == .message && $0.text.contains("just talking") })

        let handoff = try XCTUnwrap(one.deliveries.first?.replyID)
        let passed = try relay.reply(handoff, text: "@claude-mini your turn")
        XCTAssertEqual(passed.deliveries.map(\.to), ["claude-mini"])
    }

    func testHopLimitStopsTheThreadAndNotifiesTheOpener() throws {
        let driver = FakeDriver(delivered("app-server"))
        let relay = try makeRelay(driver: driver)
        let thread = try openPair(relay, hopLimit: 1)
        let sent = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos start")
        XCTAssertEqual(sent.hop, 1)
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        let stopped = try relay.reply(replyID, text: "cannot continue")
        XCTAssertTrue(stopped.stopped)
        XCTAssertEqual(stopped.notice?.contains("Hop limit 1 reached"), true)
        XCTAssertEqual(stopped.notice?.contains("cannot continue"), true)
        XCTAssertEqual(stopped.deliveries.map(\.to), ["owner"])
        let log = try relay.read(thread: thread.id)
        XCTAssertTrue(log.contains { $0.kind == .notice && ($0.text.contains("Hop limit")) })
        XCTAssertThrowsError(try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos again")) { error in
            XCTAssertEqual(error as? LightRelayError, .threadStopped(thread.id))
        }
        let terminal = try XCTUnwrap(stopped.deliveries.first?.replyID)
        let ack = try relay.reply(terminal, text: "seen")
        XCTAssertTrue(ack.deliveries.isEmpty)
        XCTAssertTrue(try relay.read(thread: thread.id).contains { $0.text == "seen" })
    }

    func testReusableReplyAdvancesHopInsteadOfResettingIt() throws {
        let relay = try makeRelay(driver: FakeDriver(delivered("app-server")))
        let thread = try openPair(relay, hopLimit: 3)
        let sent = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos start")
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        let first = try relay.reply(replyID, text: "one")
        XCTAssertEqual(first.hop, 2)
        let second = try relay.reply(replyID, text: "two")
        XCTAssertEqual(second.hop, 3)
        let third = try relay.reply(replyID, text: "three")
        XCTAssertTrue(third.stopped)
    }

    func testSingleWriterQueuePreservesOrder() throws {
        let driver = FakeDriver(LightDriveResult(state: .busy, route: "app-server", fallback: false, liveVerified: false, detail: "writer lock"))
        let relay = try makeRelay(driver: driver)
        let thread = try openPair(relay)
        let first = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos one")
        let second = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos two")
        XCTAssertEqual(first.deliveries.map(\.state), [.queued])
        XCTAssertEqual(second.deliveries.map(\.state), [.queued])
        XCTAssertEqual(driver.calls.filter { $0.state == .delivered }.map(\.name), [])

        driver.result = delivered("app-server")
        XCTAssertEqual(relay.pump(), 2)
        let deliveredTo = driver.calls.filter { $0.state == .delivered }.map(\.body)
        XCTAssertEqual(deliveredTo.count, 2)
        XCTAssertTrue(deliveredTo[0].contains("one"))
        XCTAssertTrue(deliveredTo[1].contains("two"))
        XCTAssertTrue(deliveredTo[0].contains("pharos reply"))
        let states = try relay.read(thread: thread.id).filter { $0.kind == .delivery }.compactMap(\.state)
        XCTAssertEqual(Array(states.suffix(2)), [.delivered, .delivered])
    }

    func testQueuedReplyExpiresAndNotifiesTheOpener() throws {
        let clock = ManualClock()
        let driver = FakeDriver(LightDriveResult(state: .busy, route: nil, fallback: false, liveVerified: false, detail: "busy"))
        let relay = try makeRelay(driver: driver, now: clock.now)
        let thread = try openPair(relay)
        _ = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos hold")
        clock.advance(25 * 60 * 60)
        let report = relay.sweep()
        XCTAssertEqual(report.expiredQueued, 1)
        XCTAssertGreaterThanOrEqual(report.notices, 1)
        let log = try relay.read(thread: thread.id)
        XCTAssertTrue(log.contains { $0.kind == .notice && $0.text.contains("expired before delivery") })
        XCTAssertTrue(log.contains { $0.state == .expired })
    }

    func testWaitIngestsAProvenSessionReplyOnce() throws {
        let driver = FakeDriver(delivered("app-server"))
        let relay = try makeRelay(driver: driver)
        let thread = try openPair(relay)
        let sent = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos question")
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        let pending = try relay.wait(replyID: replyID, timeout: 0)
        XCTAssertEqual(pending.status, .pending)
        driver.reads["codex-mini-pharos"] = "answer from the session"
        let waited = try relay.wait(replyID: replyID, timeout: 0)
        XCTAssertEqual(waited.status, .replied)
        XCTAssertEqual(waited.text, "answer from the session")
        let callsAfter = driver.calls.count
        let again = try relay.wait(replyID: replyID, timeout: 0)
        XCTAssertEqual(again.status, .replied)
        XCTAssertEqual(driver.calls.count, callsAfter)
    }

    func testForwarderDoesNotTouchTheLocalLedger() throws {
        let driver = FakeDriver(delivered("app-server"))
        let forwarder = RecordingForwarder(result: LightForwardResult(ok: true, message: "forwarded"))
        let relay = try makeRelay(driver: driver, forwarder: forwarder)
        let thread = try openPair(relay)
        let sent = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos hi")
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        let forwarded = try relay.reply(replyID, text: "via ssh")
        XCTAssertTrue(forwarded.forwarded)
        XCTAssertEqual(forwarder.seen.map(\.0), [replyID])
        XCTAssertEqual(try relay.read(thread: thread.id).filter { $0.kind == .message }.map(\.text), ["@codex-mini-pharos hi"])
    }

    func testWebhookIsLoopbackOnlyAndIntakeReplies() throws {
        XCTAssertThrowsError(try LightRelay(store: freshStore(), webhook: "http://example.com/hook")) { error in
            XCTAssertEqual(error as? LightRelayError, .webhookNotLoopback)
        }
        let relay = try makeRelay(driver: FakeDriver(delivered("app-server")), webhook: "http://127.0.0.1:9/pharos/reply")
        let thread = try openPair(relay)
        let sent = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos hi")
        XCTAssertTrue(sent.deliveries[0].header.contains("http://127.0.0.1:9/pharos/reply"))
        let replyID = sent.deliveries[0].replyID
        let body = #"{"replyId":"\#(replyID)","text":"posted"}"#.data(using: .utf8)!
        let accepted = try LightWebhookIntake.accept(body, relay: relay)
        XCTAssertEqual(accepted.deliveries.map(\.to), ["owner"])
    }

    func testStoreReloadsTheDirectoryAndAppendOnlyLog() throws {
        let store = freshStore()
        let first = try LightRelay(store: store, driver: FakeDriver(delivered("app-server")))
        _ = try openPair(first, storeAlreadyOpen: true)
        let thread = try XCTUnwrap(first.listThreads().first)
        _ = try first.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos persist")
        let second = try LightRelay(store: store, driver: IdleLightDriver())
        XCTAssertEqual(second.member(named: "codex-mini-pharos")?.sessionID, "sess-codex")
        XCTAssertEqual(try second.read(thread: thread.id).first { $0.kind == .message }?.text, "@codex-mini-pharos persist")
    }

    func testExternalDriverDefersTheHeadlessRouteWithoutClaimingALiveTurn() throws {
        let driver = ExternalLightDriver()
        let relay = try makeRelay(driver: driver)
        _ = try relay.register(member("owner", app: "shell", session: "owner-1", routes: [LightRoute.named("native")]))
        _ = try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: []))
        let thread = try relay.openThread(members: ["owner", "codex-mini-pharos"])
        let sent = try relay.send(from: "owner", thread: thread.id, text: "@codex-mini-pharos hello")
        XCTAssertEqual(sent.deliveries.first?.state, .deferred)
        XCTAssertEqual(sent.deliveries.first?.route, "app-server")
        XCTAssertEqual(sent.deliveries.first?.fallback, false)
        XCTAssertEqual(sent.deliveries.first?.liveVerified, false)
        XCTAssertNil(driver.readReply(member: member("codex-mini-pharos", app: "codex", session: "sess-codex"), since: Date()))
    }

    func testCommandsRoundTrip() throws {
        let relay = try makeRelay(driver: FakeDriver(delivered("native")))
        let routes: (String) -> [LightRoute] = { _ in [LightRoute.named("native")] }
        func run(_ command: String, _ arguments: [String]) -> LightCLIResult {
            LightCommands.execute(command: command, arguments: arguments, relay: relay, routesForApp: routes)
        }
        XCTAssertEqual(run("member", ["register"]).exitCode, 2)
        XCTAssertEqual(run("member", ["register", "--name", "owner", "--host", "broker", "--app", "shell", "--project", "pharos", "--session", "owner-1"]).exitCode, 0)
        XCTAssertEqual(run("member", ["register", "--name", "codex-mini-pharos", "--host", "broker", "--app", "codex", "--project", "pharos", "--session", "sess-codex"]).exitCode, 0)
        let created = run("thread", ["new", "--member", "owner", "--member", "codex-mini-pharos"])
        XCTAssertEqual(created.exitCode, 0)
        let threadID = created.text.replacingOccurrences(of: "thread ", with: "")
        let sent = run("send", ["--from", "owner", "--thread", threadID, "@codex-mini-pharos", "hello"])
        XCTAssertEqual(sent.exitCode, 0)
        XCTAssertTrue(sent.text.contains("delivered"))
        let listed = run("member", ["list"])
        XCTAssertTrue(listed.text.contains("codex-mini-pharos"))
        let read = run("read", ["--thread", threadID])
        XCTAssertTrue(read.text.contains("hello"))
    }

    private func openPair(_ relay: LightRelay, hopLimit: Int? = nil, storeAlreadyOpen: Bool = false) throws -> LightThread {
        if relay.member(named: "owner") == nil {
            _ = try relay.register(member("owner", app: "shell", session: "owner-1"))
        }
        if relay.member(named: "codex-mini-pharos") == nil {
            _ = try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex"))
        }
        _ = storeAlreadyOpen
        return try relay.openThread(members: ["owner", "codex-mini-pharos"], hopLimit: hopLimit)
    }

    private func makeRelay(driver: any LightSessionDriver = IdleLightDriver(),
                           now: (@Sendable () -> Date)? = nil,
                           forwarder: (any LightReplyForwarding)? = nil,
                           webhook: String? = nil) throws -> LightRelay {
        if let now {
            return try LightRelay(store: freshStore(), now: now, driver: driver, forwarder: forwarder, webhook: webhook)
        }
        return try LightRelay(store: freshStore(), driver: driver, forwarder: forwarder, webhook: webhook)
    }

    private func freshStore() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-light-\(UUID().uuidString)", isDirectory: true)
        stores.append(url)
        return url
    }

    private func member(_ name: String, app: String, session: String, host: String = "broker",
                        routes: [LightRoute]? = nil) -> LightMember {
        LightMember(name: name, host: host, app: app, project: "pharos", sessionID: session,
                    routes: routes ?? [LightRoute.named("app-server")])
    }

    private func delivered(_ route: String) -> LightDriveResult {
        LightDriveResult(state: .delivered, route: route, fallback: false, liveVerified: true, detail: "fake")
    }
}

final class LightDriverTests: XCTestCase {
    func testRouteOrderPrefersHeadlessAndLabelsTmuxLast() {
        XCTAssertEqual(LightRouteCatalog.defaults(for: "codex").map(\.id), ["app-server", "ipc", "desktop", "tmux"])
        XCTAssertEqual(LightRouteCatalog.defaults(for: "dsh").map(\.id), ["web", "desktop", "files", "tmux"])
        XCTAssertEqual(LightRouteCatalog.defaults(for: "claude").map(\.id), ["headless", "tmux"])
        XCTAssertEqual(LightRouteCatalog.defaults(for: "ag").map(\.id), ["desktop"])
        XCTAssertTrue(LightRouteCatalog.codex.last?.fallback == true)
        XCTAssertEqual(LightRouteCatalog.dsh.first { $0.id == "files" }?.access, .read)
        let codex = member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: [])
        XCTAssertEqual(LightRoutePlanner.select(member: codex, operation: .send)?.id, "app-server")
        let filesThenTmux = member("codex-mini-pharos", app: "dsh", session: "sess-dsh", routes: [
            LightRoute(id: "files", access: .read, fallback: false, summary: "read-only session files."),
            LightRoute(id: "tmux", access: .write, fallback: true, summary: "last resort: tmux send-keys and capture-pane."),
        ])
        let selected = LightRoutePlanner.select(member: filesThenTmux, operation: .send)
        XCTAssertEqual(selected?.id, "tmux")
        XCTAssertEqual(selected?.fallback, true)
    }

    func testHeadlessArgvDoesNotAnswerApprovalsOrLeaveLoopback() {
        let codex = member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: [])
        let route = try! XCTUnwrap(LightRoutePlanner.select(member: codex, operation: .send))
        let invocation = LightRoutePlanner.invocation(member: codex, route: route, body: "hello", binaries: .names)
        XCTAssertEqual(invocation.argv, ["codex", "exec", "resume", "sess-codex", "-", "--json", "--skip-git-repo-check"])
        XCTAssertEqual(invocation.stdin, "hello")
        XCTAssertTrue(invocation.executable)
        assertNoApprovalBypass(invocation.argv + [invocation.summary])

        let claude = member("claude-mini", app: "claude", session: "sess-claude", routes: [])
        let claudeRoute = try! XCTUnwrap(LightRoutePlanner.select(member: claude, operation: .send))
        let claudeCall = LightRoutePlanner.invocation(member: claude, route: claudeRoute, body: "hello", binaries: .names)
        XCTAssertEqual(claudeCall.argv, ["claude", "-p", "--resume", "sess-claude"])
        XCTAssertEqual(claudeCall.stdin, "hello")
        assertNoApprovalBypass(claudeCall.argv)

        let dsh = member("dsh-mini", app: "dsh", session: "sess-dsh", routes: [])
        let dshRoute = try! XCTUnwrap(LightRoutePlanner.select(member: dsh, operation: .send))
        let dshCall = LightRoutePlanner.invocation(member: dsh, route: dshRoute, body: "hello", binaries: .names)
        XCTAssertEqual(dshCall.argv, ["dsh", "--profile", "web", "--no-open", "--port", "0", "--host", "127.0.0.1"])
        XCTAssertFalse(dshCall.executable)
        XCTAssertTrue(dshCall.loopback)
        XCTAssertTrue(dshCall.summary.contains("stop after the turn"))

        let tmux = LightRoutePlanner.invocation(
            member: filesThenTmuxMember(),
            route: LightRoute.named("tmux"),
            body: "hello",
            binaries: .names
        )
        XCTAssertEqual(tmux.argv.prefix(4), ["tmux", "send-keys", "-t", "sess-dsh"].prefix(4))
        XCTAssertTrue(tmux.fallback)
        XCTAssertTrue(tmux.summary.contains("last resort"))
        let capture = LightRoutePlanner.readInvocation(member: filesThenTmuxMember(), route: LightRoute.named("tmux"), binaries: .names)
        XCTAssertEqual(capture.argv, ["tmux", "capture-pane", "-t", "sess-dsh", "-p"])
    }

    func testLiveFailureFallsThroughWithoutMarkingTheTurnVerified() {
        let runner = ScriptedRunner([
            LightProcessOutput(status: 1, stdout: "", stderr: "writer lock"),
        ])
        let driver = ExternalLightDriver(allowLive: true, runner: runner)
        let codex = member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: [])
        let result = driver.deliver(member: codex, body: "hello")
        XCTAssertEqual(result.state, .deferred)
        XCTAssertEqual(result.route, "ipc")
        XCTAssertFalse(result.liveVerified)
        XCTAssertEqual(runner.invocations.map { $0.argv.first }, ["codex"])
        XCTAssertTrue(result.detail.contains("not certified") || result.detail.contains("unverified"))
        XCTAssertNil(driver.readReply(member: codex, since: Date()))
    }

    func testSSHForwarderUsesTheExistingRouteWithoutATunnel() {
        let runner = ScriptedRunner([LightProcessOutput(status: 0, stdout: "", stderr: "")])
        let forwarder = SSHLightReplyForwarder(destination: "broker-ssh", runner: runner)
        let result = forwarder.forward(replyID: "r_token1xxx", text: "hello 'there'")
        XCTAssertEqual(result?.ok, true)
        let argv = try! XCTUnwrap(runner.invocations.first?.argv)
        XCTAssertEqual(argv.prefix(6).map { $0 }, ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "--"])
        XCTAssertEqual(argv.dropFirst(6).first, "broker-ssh")
        XCTAssertFalse(argv.contains("-L"))
        XCTAssertFalse(argv.contains("-R"))
        XCTAssertTrue(argv.joined(separator: " ").contains("pharos reply 'r_token1xxx'"))
        XCTAssertTrue(argv.joined(separator: " ").contains(SSHLightReplyForwarder.shellQuote("hello 'there'")))
    }

    private func assertNoApprovalBypass(_ parts: [String]) {
        let joined = parts.joined(separator: " ").lowercased()
        for banned in ["dangerously", "approve-for-me", "bypass", "requestapproval"] {
            XCTAssertFalse(joined.contains(banned), banned)
        }
    }

    private func filesThenTmuxMember() -> LightMember {
        member("dsh-mini", app: "dsh", session: "sess-dsh", routes: [LightRoute.named("tmux")])
    }

    private func member(_ name: String, app: String, session: String, routes: [LightRoute]) -> LightMember {
        LightMember(name: name, host: "broker", app: app, project: "pharos", sessionID: session, routes: routes)
    }
}

private final class ManualClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { current }
    func advance(_ interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}

private final class FakeDriver: LightSessionDriver, @unchecked Sendable {
    struct Call {
        var name: String
        var body: String
        var state: LightDriveResult.State
    }

    var result: LightDriveResult
    var calls: [Call] = []
    var reads: [String: String] = [:]

    init(_ result: LightDriveResult) { self.result = result }

    func deliver(member: LightMember, body: String) -> LightDriveResult {
        calls.append(Call(name: member.name, body: body, state: result.state))
        return result
    }

    func readReply(member: LightMember, since: Date) -> String? {
        _ = since
        return reads[member.name]
    }
}

private final class RecordingForwarder: LightReplyForwarding, @unchecked Sendable {
    var result: LightForwardResult?
    var seen: [(String, String)] = []
    init(result: LightForwardResult?) { self.result = result }
    func forward(replyID: String, text: String) -> LightForwardResult? {
        seen.append((replyID, text))
        return result
    }
}

private final class ScriptedRunner: LightProcessRunning, @unchecked Sendable {
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
