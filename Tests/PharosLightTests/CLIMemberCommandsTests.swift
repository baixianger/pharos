import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

final class FakeMemberAgents: LightMemberAgents, @unchecked Sendable {
    var onLaunch: ((_ name: String, _ app: String, _ cwd: String, _ host: String, _ model: String?, _ tmuxSession: String?,
                    _ openingMessage: String?, _ project: String) throws -> LightMember)?
    var onRevive: ((_ member: LightMember) throws -> LightTmuxBinding)?
    var onStatus: ((_ member: LightMember) -> LightMemberRuntimeStatus?)?
    var notes: [String] = []

    func launch(name: String, app: String, cwd: String, host: String, model: String?, tmuxSession: String?,
                openingMessage: String?, project: String) throws -> LightMember {
        if let onLaunch {
            return try onLaunch(name, app, cwd, host, model, tmuxSession, openingMessage, project)
        }
        let binding = LightTmuxBinding(
            session: tmuxSession ?? "pharos-\(name)",
            cwd: cwd,
            model: model,
            agentPID: 1234,
            agentStarted: "now",
            launchedAt: Date(),
            endedAt: nil
        )
        return LightMember(
            name: name,
            host: host,
            app: app,
            project: project,
            sessionID: "sess-\(name)",
            routes: [LightRoute(id: "tmux", access: .write, fallback: false, summary: "tmux")],
            tmux: binding
        )
    }

    func revive(_ member: LightMember) throws -> LightTmuxBinding {
        if let onRevive {
            return try onRevive(member)
        }
        guard let binding = member.tmux else {
            throw CLIAgentLifecycleError.invalid("no tmux binding")
        }
        return LightTmuxBinding(
            session: binding.session,
            cwd: binding.cwd,
            model: binding.model,
            agentPID: 5678,
            agentStarted: "revived",
            launchedAt: Date(),
            endedAt: nil
        )
    }

    func status(_ member: LightMember) -> LightMemberRuntimeStatus? {
        if let onStatus {
            return onStatus(member)
        }
        guard let binding = member.tmux else { return nil }
        return LightMemberRuntimeStatus(
            tmux: binding.session,
            live: "alive",
            activity: "idle",
            detail: "idle"
        )
    }
}

final class CLIMemberCommandsTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores { try? FileManager.default.removeItem(at: store) }
        stores.removeAll()
        super.tearDown()
    }

    private func makeRelay() throws -> LightRelay {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-member-test-\(UUID().uuidString)")
        stores.append(dir)
        return try LightRelay(store: dir)
    }

    private func run(_ relay: LightRelay, _ command: String, _ args: [String],
                     agents: (any LightMemberAgents)? = nil) -> LightCLIResult {
        LightCommands.execute(
            command: command,
            arguments: args,
            relay: relay,
            routesForApp: { _ in [LightRoute(id: "tmux", access: .write, fallback: false, summary: "")] },
            agents: agents
        )
    }

    func testMemberListHeaderAndColumnsWithFakeAgents() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        // 1. Member with no tmux
        _ = try relay.register(LightMember(
            name: "plain-bot", host: "local", app: "codex", project: "proj", sessionID: "s-1", routes: []
        ))

        // 2. Member with tmux and alive status
        let liveBinding = LightTmuxBinding(
            session: "tmux-live", cwd: "/tmp", model: "o3", agentPID: 100, agentStarted: "start",
            launchedAt: Date(), endedAt: nil
        )
        _ = try relay.register(LightMember(
            name: "live-bot", host: "local", app: "codex", project: "proj", sessionID: "s-2", routes: [],
            tmux: liveBinding
        ))

        fakeAgents.onStatus = { member in
            if member.name == "live-bot" {
                return LightMemberRuntimeStatus(tmux: "tmux-live", live: "alive", activity: "thinking", detail: "running")
            }
            return nil
        }

        let res = run(relay, "member", ["list"], agents: fakeAgents)
        XCTAssertEqual(res.exitCode, 0)
        let lines = res.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "NAME\tAPP\tHOST\tPROJECT\tSESSION\tROUTES\tTMUX\tLIVE\tSTATE")

        let plainLine = try XCTUnwrap(lines.first { $0.hasPrefix("plain-bot\t") })
        XCTAssertTrue(plainLine.contains("\t-\t-\t-"), "plain member has - for tmux, live, and state")

        let liveLine = try XCTUnwrap(lines.first { $0.hasPrefix("live-bot\t") })
        XCTAssertTrue(liveLine.contains("\ttmux-live\talive\tthinking"), "live member shows tmux, live, and activity")
    }

    func testMemberListEndedMarkerPersistence() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        let deadBinding = LightTmuxBinding(
            session: "tmux-dead", cwd: "/tmp", model: "o3", agentPID: 101, agentStarted: "start",
            launchedAt: Date(), endedAt: nil
        )
        _ = try relay.register(LightMember(
            name: "dead-bot", host: "local", app: "codex", project: "proj", sessionID: "s-3", routes: [],
            tmux: deadBinding
        ))

        fakeAgents.onStatus = { member in
            if member.name == "dead-bot" {
                return LightMemberRuntimeStatus(tmux: "tmux-dead", live: "dead", activity: "unknown", detail: "exited")
            }
            return nil
        }

        XCTAssertNil(relay.member(named: "dead-bot")?.tmux?.endedAt)

        let res = run(relay, "member", ["list"], agents: fakeAgents)
        XCTAssertEqual(res.exitCode, 0)
        let lines = res.text.components(separatedBy: "\n")
        let deadLine = try XCTUnwrap(lines.first { $0.hasPrefix("dead-bot\t") })
        XCTAssertTrue(deadLine.contains("\ttmux-dead\tended\t-"), "dead status turns into ended and shows '-' for state")

        // Relay must have persisted endedAt
        let persisted = try XCTUnwrap(relay.member(named: "dead-bot")?.tmux)
        XCTAssertNotNil(persisted.endedAt, "endedAt was saved in relay")
    }

    func testMemberListJSONIncludesRuntime() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        let binding = LightTmuxBinding(
            session: "tmux-json", cwd: "/tmp", model: "o3", agentPID: 102, agentStarted: "start",
            launchedAt: Date(), endedAt: nil
        )
        _ = try relay.register(LightMember(
            name: "json-bot", host: "local", app: "codex", project: "proj", sessionID: "s-4", routes: [],
            tmux: binding
        ))

        fakeAgents.onStatus = { member in
            LightMemberRuntimeStatus(tmux: "tmux-json", live: "alive", activity: "idle", detail: "ready")
        }

        let res = run(relay, "member", ["list", "--json"], agents: fakeAgents)
        XCTAssertEqual(res.exitCode, 0)
        guard let data = res.text.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else {
            return XCTFail("expected JSON array")
        }

        XCTAssertEqual(first["name"] as? String, "json-bot")
        guard let runtime = first["runtime"] as? [String: Any] else {
            return XCTFail("expected runtime dictionary in JSON")
        }
        XCTAssertEqual(runtime["tmux"] as? String, "tmux-json")
        XCTAssertEqual(runtime["live"] as? String, "alive")
        XCTAssertEqual(runtime["activity"] as? String, "idle")
        XCTAssertEqual(runtime["detail"] as? String, "ready")
    }

    func testMemberLaunchRegistersMember() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()
        fakeAgents.notes = ["note: adopted"]

        let res = run(relay, "member", [
            "launch", "--app", "codex", "--name", "launched-bot", "--dir", "/path/to/myproject",
            "--tmux", "custom-tmux", "--model", "o3"
        ], agents: fakeAgents)

        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.text.contains("launched launched-bot (app codex) in tmux custom-tmux, session sess-launched-bot"))
        XCTAssertEqual(res.notes, ["note: adopted"])

        let registered = try XCTUnwrap(relay.member(named: "launched-bot"))
        XCTAssertEqual(registered.app, "codex")
        XCTAssertEqual(registered.project, "myproject", "project defaults to last path component of dir")
        XCTAssertEqual(registered.tmux?.session, "custom-tmux")

        // Launching same name again fails before launching
        let fail = run(relay, "member", [
            "launch", "--app", "codex", "--name", "launched-bot", "--dir", "/path/to/myproject"
        ], agents: fakeAgents)
        XCTAssertEqual(fail.exitCode, 1)
        XCTAssertTrue(fail.text.contains("already registered to a different session"))
    }

    func testMemberLaunchWithoutAgentsReturnsError() throws {
        let relay = try makeRelay()
        let res = run(relay, "member", [
            "launch", "--app", "agy", "--name", "agy-bot", "--dir", "/tmp"
        ], agents: nil)

        XCTAssertEqual(res.exitCode, 1)
        XCTAssertEqual(res.text, "error: member launch needs live CLI access (PHAROS_LIGHT_LIVE=1)")
    }

    func testMemberLaunchInvalidNameOrProject() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        let invalidName = run(relay, "member", [
            "launch", "--app", "codex", "--name", "BAD_NAME", "--dir", "/tmp"
        ], agents: fakeAgents)
        XCTAssertEqual(invalidName.exitCode, 1)
        XCTAssertTrue(invalidName.text.contains("invalid member name"))
    }

    func testMemberReviveUpdatesBinding() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        let oldBinding = LightTmuxBinding(
            session: "tmux-revive", cwd: "/tmp", model: "o3", agentPID: 100, agentStarted: "old",
            launchedAt: Date().addingTimeInterval(-1000), endedAt: Date().addingTimeInterval(-100)
        )
        _ = try relay.register(LightMember(
            name: "rev-bot", host: "local", app: "codex", project: "proj", sessionID: "sess-rev-1", routes: [],
            tmux: oldBinding
        ))

        let res = run(relay, "member", ["revive", "rev-bot"], agents: fakeAgents)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertEqual(res.text, "revived rev-bot in tmux tmux-revive (resumed sess-rev-1)")

        let updated = try XCTUnwrap(relay.member(named: "rev-bot")?.tmux)
        XCTAssertEqual(updated.agentPID, 5678)
        XCTAssertNil(updated.endedAt)
    }

    func testMemberReviveErrors() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        // 1. Unknown member
        let unknown = run(relay, "member", ["revive", "ghost"], agents: fakeAgents)
        XCTAssertEqual(unknown.exitCode, 1)
        XCTAssertTrue(unknown.text.contains("unknown member ghost"))

        // 2. Member without tmux
        _ = try relay.register(LightMember(
            name: "notmux", host: "local", app: "codex", project: "p", sessionID: "s", routes: []
        ))
        let noTmux = run(relay, "member", ["revive", "notmux"], agents: fakeAgents)
        XCTAssertEqual(noTmux.exitCode, 1)
        XCTAssertEqual(noTmux.text, "error: member notmux has no tmux binding")

        // 3. Without live agents
        let noAgents = run(relay, "member", ["revive", "notmux"], agents: nil)
        XCTAssertEqual(noAgents.exitCode, 1)
        XCTAssertEqual(noAgents.text, "error: member revive needs live CLI access (PHAROS_LIGHT_LIVE=1)")
    }

    func testCLIMemberAgentsHostChecks() throws {
        let runner = FakeTestRunner()
        let tmux = TmuxController(tmux: "tmux", runner: runner)
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner)
        let selfHost = LightSelfHost(names: ["mini"])
        let agents = CLIMemberAgents(lifecycle: lifecycle, selfHost: selfHost)

        // Remote launch
        XCTAssertThrowsError(try agents.launch(
            name: "remote-bot", app: "codex", cwd: "/tmp", host: "other-machine", model: nil,
            tmuxSession: nil, openingMessage: nil, project: "p"
        )) { error in
            XCTAssertEqual((error as? CLIMemberAgentsError)?.message, "launch on another host is not supported yet: run it on that machine")
        }

        // Remote revive
        let remoteMember = LightMember(
            name: "remote-bot", host: "other-machine", app: "codex", project: "p", sessionID: "s",
            routes: [], tmux: LightTmuxBinding(session: "t", cwd: "/tmp", launchedAt: Date())
        )
        XCTAssertThrowsError(try agents.revive(remoteMember)) { error in
            XCTAssertEqual((error as? CLIMemberAgentsError)?.message, "revive on another host is not supported yet: run it on that machine")
        }

        // Remote status
        XCTAssertNil(agents.status(remoteMember))
    }

    func testCombinedAttentionSource() {
        struct MockSource: HumanAttentionSource {
            var reports: [LightAttentionReport]
            func poll(members: [LightMember]) -> [LightAttentionReport] { reports }
        }

        let r1 = LightAttentionReport(state: .needsHuman, what: "first", sessionID: "s1")
        let r2 = LightAttentionReport(state: .needsHuman, what: "second", sessionID: "s2")
        let combined = CombinedAttentionSource(sources: [
            MockSource(reports: [r1]),
            MockSource(reports: [r2])
        ])

        let results = combined.poll(members: [])
        XCTAssertEqual(results.map(\.what), ["first", "second"])
    }

    func testCLIAgentEnvironmentResolution() {
        let custom = CLIAgentEnvironment.resolveTmuxBin(env: ["PHAROS_TMUX_BIN": "/custom/tmux"])
        XCTAssertEqual(custom, "/custom/tmux")

        let fallback = CLIAgentEnvironment.resolveTmuxBin(env: [:])
        XCTAssertFalse(fallback.isEmpty)
    }
}

private final class FakeTestRunner: LightProcessRunning, @unchecked Sendable {
    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        LightProcessOutput(status: 0, stdout: "", stderr: "")
    }
}
