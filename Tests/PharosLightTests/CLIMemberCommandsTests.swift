import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

final class FakeMemberAgents: LightMemberAgents, @unchecked Sendable {
    var onLaunch: ((_ name: String, _ app: String, _ cwd: String, _ host: String, _ model: String?, _ tmuxSession: String?,
                    _ openingMessage: String?, _ project: String) throws -> LightMember)?
    var onRevive: ((_ member: LightMember) throws -> LightTmuxBinding)?
    var onStop: ((_ member: LightMember, _ force: Bool) throws -> LightTmuxBinding)?
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

    func stop(_ member: LightMember, force: Bool) throws -> LightTmuxBinding {
        if let onStop {
            return try onStop(member, force)
        }
        guard var binding = member.tmux else {
            throw CLIAgentLifecycleError.invalid("no tmux binding")
        }
        binding.endedAt = Date()
        binding.endedReason = "stopped"
        notes = ["stop: graceful"]
        return binding
    }

    func status(_ member: LightMember) -> LightMemberRuntimeStatus? {
        if let onStatus {
            return onStatus(member)
        }
        guard let binding = member.tmux else { return nil }
        let live: String
        if binding.endedReason == "stopped" {
            live = "stopped"
        } else if binding.endedAt != nil {
            live = "ended"
        } else {
            live = "alive"
        }
        return LightMemberRuntimeStatus(
            tmux: binding.session,
            live: live,
            activity: (binding.endedAt != nil) ? "-" : "idle",
            detail: (binding.endedAt != nil) ? "-" : "idle"
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
        XCTAssertEqual(lines[0], "NAME\tAPP\tHOST\tPROJECT\tSESSION\tROUTES\tTMUX\tLIVE\tMODEL\tMODE\tSTATE")

        let plainLine = try XCTUnwrap(lines.first { $0.hasPrefix("plain-bot\t") })
        XCTAssertTrue(plainLine.contains("\t-\t-\t-\t-\t-"), "plain member has - for tmux, live, model, mode, and state")

        let liveLine = try XCTUnwrap(lines.first { $0.hasPrefix("live-bot\t") })
        XCTAssertTrue(liveLine.contains("\ttmux-live\talive\to3\tyolo\tthinking"), "live member shows tmux, live, model, mode, and activity")
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
        XCTAssertTrue(deadLine.contains("\ttmux-dead\tended\to3\tyolo\t-"), "dead status turns into ended and shows '-' for state")

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

    func testMemberStopClearsAttentionAndPrintsHow() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        let binding = LightTmuxBinding(session: "tmux-stop", cwd: "/tmp", launchedAt: Date())
        _ = try relay.register(LightMember(
            name: "stop-bot", host: "local", app: "codex", project: "p", sessionID: "s-stop", routes: [],
            tmux: binding
        ))

        // Record needs_human attention
        _ = try relay.reportAttention(LightAttentionReport(
            state: .needsHuman, what: "allow rm -rf", sessionID: "s-stop", app: "codex"
        ))
        XCTAssertNotNil(relay.attention(for: "stop-bot"))

        let res = run(relay, "member", ["stop", "stop-bot"], agents: fakeAgents)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.text.contains("stopped stop-bot (graceful); revive with: pharos member revive stop-bot"))

        // Binding updated
        let updated = try XCTUnwrap(relay.member(named: "stop-bot")?.tmux)
        XCTAssertEqual(updated.endedReason, "stopped")
        XCTAssertNotNil(updated.endedAt)

        // Attention cleared
        XCTAssertNil(relay.attention(for: "stop-bot"))
    }

    func testMemberStopForceAndJson() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()
        fakeAgents.onStop = { member, force in
            XCTAssertTrue(force)
            fakeAgents.notes = ["stop: killed"]
            var b = member.tmux!
            b.endedAt = Date()
            b.endedReason = "stopped"
            return b
        }

        let binding = LightTmuxBinding(session: "tmux-json-stop", cwd: "/tmp", launchedAt: Date())
        _ = try relay.register(LightMember(
            name: "json-stop-bot", host: "local", app: "codex", project: "p", sessionID: "s-jstop", routes: [],
            tmux: binding
        ))

        let res = run(relay, "member", ["stop", "json-stop-bot", "--force", "--json"], agents: fakeAgents)
        XCTAssertEqual(res.exitCode, 0)
        guard let data = res.text.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tmuxDict = dict["tmux"] as? [String: Any] else {
            return XCTFail("expected JSON output with tmux object")
        }
        XCTAssertEqual(tmuxDict["endedReason"] as? String, "stopped")
    }

    func testMemberSetAutoRevive() throws {
        let relay = try makeRelay()
        let binding = LightTmuxBinding(session: "tmux-set", cwd: "/tmp", launchedAt: Date())
        _ = try relay.register(LightMember(
            name: "set-bot", host: "local", app: "codex", project: "p", sessionID: "s-set", routes: [],
            tmux: binding
        ))

        // Set on
        let onRes = run(relay, "member", ["set", "set-bot", "--auto-revive", "on"])
        XCTAssertEqual(onRes.exitCode, 0)
        XCTAssertEqual(relay.member(named: "set-bot")?.tmux?.autoRevive, true)

        // Set off
        let offRes = run(relay, "member", ["set", "set-bot", "--auto-revive", "off"])
        XCTAssertEqual(offRes.exitCode, 0)
        XCTAssertEqual(relay.member(named: "set-bot")?.tmux?.autoRevive, false)

        // No binding error
        _ = try relay.register(LightMember(
            name: "no-b", host: "local", app: "codex", project: "p", sessionID: "s-nob", routes: []
        ))
        let failRes = run(relay, "member", ["set", "no-b", "--auto-revive", "on"])
        XCTAssertEqual(failRes.exitCode, 1)
        XCTAssertTrue(failRes.text.contains("has no tmux binding"))
    }

    func testMemberLaunchWithAutoRevive() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        let res = run(relay, "member", [
            "launch", "--app", "codex", "--name", "auto-bot", "--dir", "/tmp/autorevive",
            "--auto-revive"
        ], agents: fakeAgents)

        XCTAssertEqual(res.exitCode, 0)
        let member = try XCTUnwrap(relay.member(named: "auto-bot"))
        XCTAssertEqual(member.tmux?.autoRevive, true)
    }

    func testMemberListShowsStopped() throws {
        let relay = try makeRelay()
        let fakeAgents = FakeMemberAgents()

        let binding = LightTmuxBinding(
            session: "tmux-stopped", cwd: "/tmp", launchedAt: Date(),
            endedAt: Date(), autoRevive: false, endedReason: "stopped"
        )
        _ = try relay.register(LightMember(
            name: "stopped-bot", host: "local", app: "codex", project: "p", sessionID: "s-stop-list", routes: [],
            tmux: binding
        ))

        let res = run(relay, "member", ["list"], agents: fakeAgents)
        XCTAssertEqual(res.exitCode, 0)
        let lines = res.text.components(separatedBy: "\n")
        let line = try XCTUnwrap(lines.first { $0.hasPrefix("stopped-bot\t") })
        XCTAssertTrue(line.contains("\ttmux-stopped\tstopped\t-"), "shows 'stopped' instead of 'ended'")
    }

    func testLightNodeExecNodeAgentPayloadRoundTripAndErrors() throws {
        let fakeAgents = FakeMemberAgents()

        // 1. Launch request
        let spec = LightNodeLaunchSpec(
            name: "node-launched", app: "codex", cwd: "/tmp/node", project: "node", host: "remote-node"
        )
        let req = LightNodeAgentRequest(action: "launch", launch: spec)
        let b64 = LightNodeExec.encode(req)

        let res = LightNodeExec.executeAgent(arguments: ["node-agent", "--payload", b64], agents: fakeAgents)
        XCTAssertEqual(res.exitCode, 0)
        let resp = try XCTUnwrap(CLIMemberAgents.parseResponse(res.text))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.member?.name, "node-launched")
        XCTAssertEqual(resp.member?.host, "remote-node")

        // 2. Unreadable payload -> exit code 2
        let badRes = LightNodeExec.executeAgent(arguments: ["node-agent", "--payload", "not-valid-base64-json!!!"], agents: fakeAgents)
        XCTAssertEqual(badRes.exitCode, 2)
        XCTAssertTrue(badRes.text.contains("unreadable agent payload"))

        // 3. No live agents -> ok = false response
        let noAgentsRes = LightNodeExec.executeAgent(arguments: ["node-agent", "--payload", b64], agents: nil)
        XCTAssertEqual(noAgentsRes.exitCode, 0)
        let noAgentsResp = try XCTUnwrap(CLIMemberAgents.parseResponse(noAgentsRes.text))
        XCTAssertFalse(noAgentsResp.ok)
        XCTAssertTrue(noAgentsResp.error?.contains("PHAROS_LIGHT_LIVE=1") ?? false)
    }

    func testCLIMemberAgentsRemoteLaunchReviveStop() throws {
        let runner = FakeTestRunner()
        let tmux = TmuxController(tmux: "tmux", runner: runner)
        let lifecycle = CLIAgentLifecycle(tmux: tmux, runner: runner)
        let selfHost = LightSelfHost(names: ["local"])

        final class FakeRouter: LightNodeRouting, @unchecked Sendable {
            var cannedRun: LightNodeRun?
            var cannedStatus: LightNodeStatus = LightNodeStatus(host: "remote-host", online: false, lastSeen: nil)

            func run(_ node: String, argv: [String], timeout: TimeInterval) -> LightNodeRun? {
                cannedRun
            }

            func status(_ node: String) -> LightNodeStatus {
                cannedStatus
            }

            func directory() -> LightHostDirectory? {
                nil
            }
        }

        let router = FakeRouter()
        let agents = CLIMemberAgents(lifecycle: lifecycle, selfHost: selfHost, nodes: router)

        // 1. Remote launch success
        let returnedMember = LightMember(
            name: "remote-bot", host: "remote-host", app: "codex", project: "proj", sessionID: "s-remote", routes: [],
            tmux: LightTmuxBinding(session: "pharos-remote", cwd: "/tmp", launchedAt: Date())
        )
        let launchResp = LightNodeAgentResponse(ok: true, member: returnedMember, notes: ["remote launch note"])
        let encoder = JSONEncoder()
        let jsonStr = String(data: try encoder.encode(launchResp), encoding: .utf8)!

        router.cannedRun = LightNodeRun(path: .mesh, status: 0, stdout: jsonStr, stderr: "", node: "remote-host")

        let launched = try agents.launch(
            name: "remote-bot", app: "codex", cwd: "/tmp", host: "remote-host",
            model: nil, tmuxSession: nil, openingMessage: nil, project: "proj"
        )
        XCTAssertEqual(launched.name, "remote-bot")
        XCTAssertEqual(launched.host, "remote-host")
        XCTAssertTrue(agents.notes.contains("remote launch note"))
        XCTAssertTrue(agents.notes.contains("via mesh on remote-host"))

        // 2. Remote revive success
        let reviveBinding = LightTmuxBinding(session: "pharos-remote", cwd: "/tmp", agentPID: 4321, launchedAt: Date())
        let reviveResp = LightNodeAgentResponse(ok: true, binding: reviveBinding)
        router.cannedRun = LightNodeRun(path: .ssh, status: 0, stdout: String(data: try encoder.encode(reviveResp), encoding: .utf8)!, stderr: "", node: "remote-host")

        let revivedBinding = try agents.revive(returnedMember)
        XCTAssertEqual(revivedBinding.agentPID, 4321)
        XCTAssertTrue(agents.notes.contains("via ssh on remote-host"))

        // 3. Remote stop success
        let stopBinding = LightTmuxBinding(session: "pharos-remote", cwd: "/tmp", endedAt: Date(), endedReason: "stopped")
        let stopResp = LightNodeAgentResponse(ok: true, binding: stopBinding, notes: ["stop: graceful"])
        router.cannedRun = LightNodeRun(path: .mesh, status: 0, stdout: String(data: try encoder.encode(stopResp), encoding: .utf8)!, stderr: "", node: "remote-host")

        let stoppedBinding = try agents.stop(returnedMember, force: false)
        XCTAssertEqual(stoppedBinding.endedReason, "stopped")
        XCTAssertTrue(agents.notes.contains("stop: graceful"))

        // 4. Offline node -> error
        router.cannedRun = nil
        router.cannedStatus = LightNodeStatus(host: "remote-host", online: false, lastSeen: nil)

        XCTAssertThrowsError(try agents.launch(
            name: "off-bot", app: "codex", cwd: "/tmp", host: "remote-host",
            model: nil, tmuxSession: nil, openingMessage: nil, project: "proj"
        )) { error in
            XCTAssertTrue((error as? CLIMemberAgentsError)?.message.contains("Pharos node remote-host is offline") ?? false)
        }
    }

    func testLightRelayRecordRuntimeAndPersistence() throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-record-runtime-\(UUID().uuidString)")
        stores.append(store)
        let relay = try LightRelay(store: store)

        let initialBinding = LightTmuxBinding(session: "tmux-run", cwd: "/tmp", launchedAt: Date())
        _ = try relay.register(LightMember(
            name: "m-run", host: "node-a", app: "codex", project: "p", sessionID: "s-run", routes: [],
            tmux: initialBinding
        ))
        _ = try relay.register(LightMember(
            name: "m-foreign", host: "node-b", app: "codex", project: "p", sessionID: "s-foreign", routes: [],
            tmux: initialBinding
        ))

        var updatedBinding = initialBinding
        updatedBinding.endedAt = Date()
        updatedBinding.endedReason = "exited"

        let reportRun = LightMemberRuntimeReport(
            member: "m-run", node: "node-a", tmux: "tmux-run", live: "ended",
            activity: "needs_human", detail: "prompt question", at: Date(), binding: updatedBinding
        )
        let reportForeign = LightMemberRuntimeReport(
            member: "m-foreign", node: "node-b", tmux: "tmux-run", live: "alive",
            activity: "idle", detail: "idle", at: Date()
        )

        // 1. Record runtime: nodeMatches only accepts node-a
        let accepted = try relay.recordRuntime([reportRun, reportForeign]) { $0.host == "node-a" }
        XCTAssertEqual(accepted, ["m-run"])
        XCTAssertEqual(relay.member(named: "m-run")?.tmux?.endedReason, "exited")
        XCTAssertNotNil(relay.attention(for: "m-run"))
        XCTAssertEqual(relay.attention(for: "m-run")?.what, "prompt question")

        // 2. Clear via poll when activity is idle
        let reportRunIdle = LightMemberRuntimeReport(
            member: "m-run", node: "node-a", tmux: "tmux-run", live: "alive",
            activity: "idle", detail: "running", at: Date()
        )
        let accepted2 = try relay.recordRuntime([reportRunIdle]) { _ in true }
        XCTAssertEqual(accepted2, ["m-run"])
        XCTAssertNil(relay.attention(for: "m-run"), "idle runtime clears poll attention")

        // 3. Persistence round trip
        let relay2 = try LightRelay(store: store)
        let savedReport = relay2.runtime(for: "m-run")
        XCTAssertEqual(savedReport?.member, "m-run")
        XCTAssertEqual(savedReport?.activity, "idle")

        // 4. Old state file without 'runtime' loads
        let oldStateJSON = """
        {
          "version": 3,
          "members": [],
          "threads": [],
          "ledger": [],
          "outbox": [],
          "inbox": [],
          "nodes": [],
          "applied": [],
          "attention": []
        }
        """
        let oldStore = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-old-store-\(UUID().uuidString)")
        stores.append(oldStore)
        try FileManager.default.createDirectory(at: oldStore, withIntermediateDirectories: true)
        try oldStateJSON.data(using: .utf8)!.write(to: oldStore.appendingPathComponent("state.json"))
        XCTAssertNoThrow(try LightRelay(store: oldStore))
    }

    func testMemberNodeMembersAndNodeReport() throws {
        let relay = try makeRelay()
        let binding = LightTmuxBinding(session: "tmux-node", cwd: "/tmp", launchedAt: Date())
        _ = try relay.register(LightMember(
            name: "bot-a", host: "node-a", app: "codex", project: "p", sessionID: "s-a", routes: [],
            tmux: binding
        ))
        _ = try relay.register(LightMember(
            name: "bot-b", host: "node-b", app: "codex", project: "p", sessionID: "s-b", routes: [],
            tmux: binding
        ))

        // 1. node-members
        let resMembers = run(relay, "member", ["node-members", "--node", "node-a", "--json"])
        XCTAssertEqual(resMembers.exitCode, 0)
        let members: [LightMember] = try JSONDecoder().decode([LightMember].self, from: resMembers.text.data(using: .utf8)!)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].name, "bot-a")

        // 2. node-report
        let report = LightMemberRuntimeReport(
            member: "bot-a", node: "node-a", tmux: "tmux-node", live: "alive",
            activity: "idle", detail: "ok", at: Date()
        )
        let b64 = LightCodec.encode([report])!
        let resReport = run(relay, "member", ["node-report", "--node", "node-a", "--payload", b64])
        XCTAssertEqual(resReport.exitCode, 0)
        let dict = try JSONDecoder().decode([String: [String]].self, from: resReport.text.data(using: .utf8)!)
        XCTAssertEqual(dict["accepted"], ["bot-a"])
        XCTAssertEqual(relay.runtime(for: "bot-a")?.detail, "ok")
    }

    func testMemberListRemoteFreshAndStaleRows() throws {
        let relay = try makeRelay()
        let binding = LightTmuxBinding(session: "tmux-remote", cwd: "/tmp", launchedAt: Date())
        _ = try relay.register(LightMember(
            name: "remote-fresh", host: "remote-host", app: "codex", project: "p", sessionID: "s-f", routes: [],
            tmux: binding
        ))
        _ = try relay.register(LightMember(
            name: "remote-stale", host: "remote-host", app: "codex", project: "p", sessionID: "s-s", routes: [],
            tmux: binding
        ))
        _ = try relay.register(LightMember(
            name: "remote-none", host: "remote-host", app: "codex", project: "p", sessionID: "s-n", routes: [],
            tmux: binding
        ))

        let now = Date()
        let freshReport = LightMemberRuntimeReport(
            member: "remote-fresh", node: "remote-host", tmux: "tmux-remote", live: "alive",
            activity: "thinking", detail: "computing", at: now.addingTimeInterval(-10)
        )
        let staleReport = LightMemberRuntimeReport(
            member: "remote-stale", node: "remote-host", tmux: "tmux-remote", live: "alive",
            activity: "thinking", detail: "old task", at: now.addingTimeInterval(-180) // 3m ago > 90s
        )

        _ = try relay.recordRuntime([freshReport, staleReport]) { _ in true }

        // Plain text list (agents == nil -> treats remote as having no local agent)
        let res = run(relay, "member", ["list"])
        XCTAssertEqual(res.exitCode, 0)
        let lines = res.text.components(separatedBy: "\n")

        let freshLine = try XCTUnwrap(lines.first { $0.hasPrefix("remote-fresh\t") })
        XCTAssertTrue(freshLine.contains("\ttmux-remote\talive\t-\tyolo\tthinking"))

        let staleLine = try XCTUnwrap(lines.first { $0.hasPrefix("remote-stale\t") })
        XCTAssertTrue(staleLine.contains("\ttmux-remote\tstale\t-\tyolo\t-"))

        let noneLine = try XCTUnwrap(lines.first { $0.hasPrefix("remote-none\t") })
        XCTAssertTrue(noneLine.contains("\ttmux-remote\t?\t-\tyolo\t-"))

        // JSON list includes reportedAt, reportedBy, and stale detail annotation
        let jsonRes = run(relay, "member", ["list", "--json"])
        XCTAssertEqual(jsonRes.exitCode, 0)
        let entries: [LightMemberListEntry] = try JSONDecoder().decode([LightMemberListEntry].self, from: jsonRes.text.data(using: .utf8)!)
        let staleEntry = try XCTUnwrap(entries.first { $0.name == "remote-stale" })
        XCTAssertEqual(staleEntry.runtime?.live, "stale")
        XCTAssertTrue(staleEntry.runtime?.detail.contains("3m ago") ?? false)
        XCTAssertEqual(staleEntry.reportedBy, "remote-host")
        XCTAssertNotNil(staleEntry.reportedAt)
    }

    func testAttentionListAndMemberListDeDuplication() throws {
        let relay = try makeRelay()
        _ = try relay.register(LightMember(
            name: "bot-1", host: "local", app: "codex", project: "p", sessionID: "shared-sess", routes: []
        ))
        _ = try relay.register(LightMember(
            name: "bot-2", host: "local", app: "codex", project: "p", sessionID: "shared-sess", routes: []
        ))

        // 1. Report needs_human on shared session
        _ = try relay.reportAttention(LightAttentionReport(
            state: .needsHuman, what: "allow rm -rf", sessionID: "shared-sess", app: "codex",
            host: "local", source: "hook"
        ))

        // attention list: grouped into single line with sorted members
        let resAtt = run(relay, "attention", ["list"])
        XCTAssertEqual(resAtt.exitCode, 0)
        let attLines = resAtt.text.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(attLines.count, 1)
        XCTAssertTrue(attLines[0].hasPrefix("needs_human bot-1,bot-2:"))
        XCTAssertTrue(attLines[0].contains("allow rm -rf"))

        // member list: trailing attention is grouped into single line
        let resMember = run(relay, "member", ["list"])
        XCTAssertEqual(resMember.exitCode, 0)
        let memTrailing = resMember.text.components(separatedBy: "\n").filter { $0.hasPrefix("needs_human ") }
        XCTAssertEqual(memTrailing.count, 1)
        XCTAssertTrue(memTrailing[0].hasPrefix("needs_human bot-1,bot-2:"))

        // 2. Hook and poll for same member: poll refresh keeps hook ownership
        _ = try relay.reportAttention(LightAttentionReport(
            state: .needsHuman, what: "poll refreshed", sessionID: "shared-sess", app: "codex",
            host: "local", source: "poll"
        ))
        let resAtt2 = run(relay, "attention", ["list"])
        let attLines2 = resAtt2.text.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(attLines2.count, 1)
        XCTAssertTrue(attLines2[0].hasPrefix("needs_human bot-1,bot-2:"))
    }
}

private final class FakeTestRunner: LightProcessRunning, @unchecked Sendable {
    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        LightProcessOutput(status: 0, stdout: "", stderr: "")
    }
}
