import XCTest
import AppKit
import Darwin
@testable import Pharos

// MARK: - SessionsService.encodeClaudePath

final class EncodeClaudePathTests: XCTestCase {

    func testForwardSlashesReplacedWithDash() {
        XCTAssertEqual(
            SessionsService.encodeClaudePath("/Users/alice/dev/my-app"),
            "-Users-alice-dev-my-app"
        )
    }

    func testDotsReplacedWithDash() {
        XCTAssertEqual(
            SessionsService.encodeClaudePath("/home/bob/proj.v2"),
            "-home-bob-proj-v2"
        )
    }

    func testMixedSlashesAndDots() {
        XCTAssertEqual(
            SessionsService.encodeClaudePath("/opt/app/1.2.3/main"),
            "-opt-app-1-2-3-main"
        )
    }

    func testEmptyStringUnchanged() {
        XCTAssertEqual(SessionsService.encodeClaudePath(""), "")
    }

    func testAlphanumericUnchanged() {
        XCTAssertEqual(SessionsService.encodeClaudePath("myproject"), "myproject")
    }
}

// MARK: - LaunchService.tmuxSessionName

final class TmuxSessionNameTests: XCTestCase {

    private func project(name: String) -> Project {
        Project(name: name)
    }

    func testLowercasesName() {
        let p = project(name: "MyApp")
        XCTAssertEqual(LaunchService.tmuxSessionName(p, .claude), "pharos-myapp-claude")
    }

    func testNonAlphanumericBecomeDash() {
        let p = project(name: "my-app_v2!")
        // 'm','y' ok, '-' -> '-', 'a','p','p' ok, '_' -> '-', 'v','2' ok, '!' -> '-'
        XCTAssertEqual(LaunchService.tmuxSessionName(p, .claude), "pharos-my-app-v2--claude")
    }

    func testCodexKind() {
        let p = project(name: "pharos")
        XCTAssertEqual(LaunchService.tmuxSessionName(p, .codex), "pharos-pharos-codex")
    }

    func testSpacesBecomeDashes() {
        let p = project(name: "Cool Project")
        XCTAssertEqual(LaunchService.tmuxSessionName(p, .claude), "pharos-cool-project-claude")
    }
}

// MARK: - GitService.parseWorktrees

final class ParseWorktreesTests: XCTestCase {

    // Minimal real-world porcelain output: main worktree + a branch worktree.
    private let samplePorcelain = """
    worktree /Users/alice/dev/my-app
    HEAD abc1234abc1234abc1234abc1234abc1234abc1234
    branch refs/heads/main

    worktree /Users/alice/dev/my-app-feature
    HEAD def5678def5678def5678def5678def5678def5678
    branch refs/heads/feature/cool-thing

    """

    func testCountOfWorktrees() {
        let wts = GitService.parseWorktrees(samplePorcelain)
        XCTAssertEqual(wts.count, 2)
    }

    func testFirstIsMain() {
        let wts = GitService.parseWorktrees(samplePorcelain)
        XCTAssertTrue(wts[0].isMain)
        XCTAssertFalse(wts[1].isMain)
    }

    func testPathsParsed() {
        let wts = GitService.parseWorktrees(samplePorcelain)
        XCTAssertEqual(wts[0].path, "/Users/alice/dev/my-app")
        XCTAssertEqual(wts[1].path, "/Users/alice/dev/my-app-feature")
    }

    func testBranchStripsRefsHeads() {
        let wts = GitService.parseWorktrees(samplePorcelain)
        XCTAssertEqual(wts[0].branch, "main")
        XCTAssertEqual(wts[1].branch, "feature/cool-thing")
    }

    func testBareWorktreeExcluded() {
        let porcelain = """
        worktree /Users/alice/dev/my-app
        HEAD abc1234abc1234abc1234abc1234abc1234abc1234
        branch refs/heads/main

        worktree /Users/alice/dev/my-app.git
        HEAD abc1234abc1234abc1234abc1234abc1234abc1234
        bare

        """
        let wts = GitService.parseWorktrees(porcelain)
        XCTAssertEqual(wts.count, 1)
        XCTAssertEqual(wts[0].branch, "main")
    }

    func testDetachedWorktree() {
        let porcelain = """
        worktree /Users/alice/dev/my-app
        HEAD abc1234abc1234abc1234abc1234abc1234abc1234
        detached

        """
        let wts = GitService.parseWorktrees(porcelain)
        XCTAssertEqual(wts.count, 1)
        XCTAssertEqual(wts[0].branch, "(detached)")
    }

    func testEmptyPorcelain() {
        XCTAssertTrue(GitService.parseWorktrees("").isEmpty)
    }
}

// MARK: - AgentKind.command

final class AgentKindCommandTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testClaudeNoYoloNoArgs() {
        XCTAssertEqual(AgentKind.claude.command(yolo: false), "claude")
    }

    func testClaudeYoloNoArgs() {
        XCTAssertEqual(AgentKind.claude.command(yolo: true), "claude --dangerously-skip-permissions")
    }

    func testClaudeYoloWithExtraArgs() {
        XCTAssertEqual(
            AgentKind.claude.command(yolo: true, extraArgs: "--model sonnet"),
            "claude --dangerously-skip-permissions --model sonnet"
        )
    }

    func testCodexNoYoloNoArgs() {
        XCTAssertEqual(AgentKind.codex.command(yolo: false), "codex")
    }

    func testCodexYoloNoArgs() {
        XCTAssertEqual(AgentKind.codex.command(yolo: true), "codex --dangerously-bypass-approvals-and-sandbox")
    }

    func testExtraArgsWhitespaceStripped() {
        XCTAssertEqual(AgentKind.claude.command(yolo: false, extraArgs: "  "), "claude")
    }

    func testAbsoluteExecutableIsShellQuoted() {
        XCTAssertEqual(
            AgentKind.codex.command(yolo: true, executable: "/Applications/Tools Folder/Codex/codex"),
            "'/Applications/Tools Folder/Codex/codex' --dangerously-bypass-approvals-and-sandbox"
        )
    }

    func testChildProcessPathEnvironmentIsPropagated() {
        XCTAssertEqual(
            AgentKind.codex.command(
                yolo: false,
                executable: "/Users/tester/Node Versions/bin/codex",
                environment: ["PATH": "/Users/tester/Node Versions/bin:/usr/bin:/bin"]
            ),
            "/usr/bin/env 'PATH=/Users/tester/Node Versions/bin:/usr/bin:/bin' "
                + "'/Users/tester/Node Versions/bin/codex'"
        )
    }

    func testNormalLaunchCommandReceivesSuppliedResolution() {
        let resolution = LaunchService.AgentResolution(
            executable: "/resolved/bin/codex",
            environment: ["PATH": "/resolved/bin:/usr/bin:/bin"]
        )
        XCTAssertEqual(
            LaunchService.agentCommand(.codex, yolo: true, resolution: resolution),
            "/usr/bin/env 'PATH=/resolved/bin:/usr/bin:/bin' '/resolved/bin/codex' "
                + "--dangerously-bypass-approvals-and-sandbox"
        )
    }

    func testResumeCommandReceivesSuppliedResolution() {
        let resolution = LaunchService.AgentResolution(
            executable: "/resolved/bin/codex",
            environment: ["PATH": "/resolved/bin:/usr/bin:/bin"]
        )
        let session = AgentSession(id: "session-id", kind: .codex, title: "",
                                   modified: .distantPast, resumeCwd: "/tmp/project")
        let project = Project(name: "Test", yolo: false)
        XCTAssertEqual(
            LaunchService.resumeAgentCommand(session, project: project, resolution: resolution),
            "/usr/bin/env 'PATH=/resolved/bin:/usr/bin:/bin' "
                + "'/resolved/bin/codex' resume session-id"
        )
    }

    func testLocalMeshLaunchReceivesSuppliedEnvironment() {
        let resolution = LaunchService.AgentResolution(
            executable: "/resolved/bin/codex",
            environment: ["PATH": "/resolved/bin:/usr/bin:/bin"]
        )
        XCTAssertEqual(
            MeshSpawn.launchCommand(.codex, resolution: resolution),
            "/usr/bin/env 'PATH=/resolved/bin:/usr/bin:/bin' '/resolved/bin/codex' "
                + "--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        )
    }

    func testCodexResolverIncludesDesktopAppAndVersionManagerShims() {
        let paths = LaunchService.agentExecutableCandidates(.codex, home: "/Users/tester")
        XCTAssertTrue(paths.contains("/Applications/Codex.app/Contents/Resources/codex"))
        XCTAssertTrue(paths.contains("/Users/tester/Applications/Codex.app/Contents/Resources/codex"))
        XCTAssertTrue(paths.contains("/Users/tester/.asdf/shims/codex"))
        XCTAssertTrue(paths.contains("/Users/tester/.local/share/mise/shims/codex"))
        XCTAssertTrue(paths.contains("/Users/tester/.volta/bin/codex"))
    }

    func testRemoteCodexLaunchCanUseDesktopAppExecutable() {
        XCTAssertEqual(
            MeshSpawn.launchCommand(
                .codex,
                executable: "/Applications/Codex.app/Contents/Resources/codex"
            ),
            "'/Applications/Codex.app/Contents/Resources/codex' "
                + "--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        )
    }

    func testCodexAvailableDirectlyInPath() async {
        let resolution = await LaunchService.resolveAgent(
            .codex,
            environment: ["PATH": "/custom/bin:/usr/bin", "SHELL": "/bin/zsh"],
            candidates: [],
            isExecutable: { $0 == "/custom/bin/codex" },
            runShell: { _, _ in
                XCTFail("direct PATH resolution must not start a login shell")
                return Shell.Result(out: "", err: "", code: 1)
            }
        )
        XCTAssertEqual(resolution, .init(executable: "/custom/bin/codex",
                                         environment: ["PATH": "/custom/bin:/usr/bin"]))
    }

    @MainActor
    func testCodexAvailableOnlyThroughLoginShellRunsOffMainActor() async {
        let shellPath = "/Users/tester/.nvm/versions/node/v22/bin"
        let resolution = await LaunchService.resolveAgent(
            .codex,
            environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"],
            candidates: [],
            isExecutable: { ["/bin/zsh", "\(shellPath)/codex"].contains($0) },
            runShell: { executable, arguments in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(executable, "/bin/zsh")
                XCTAssertEqual(arguments.first, "-lic")
                return Shell.Result(
                    out: "Welcome back\n__PHAROS_EXECUTABLE__=\(shellPath)/codex\n"
                        + "__PHAROS_PATH__=\(shellPath):/usr/bin:/bin",
                    err: "",
                    code: 0
                )
            }
        )
        XCTAssertEqual(
            resolution,
            .init(executable: "\(shellPath)/codex",
                  environment: ["PATH": "\(shellPath):/usr/bin:/bin"])
        )
    }

    func testResolutionHappensOncePerLaunchAttempt() async {
        let count = Counter()
        _ = await LaunchService.resolveAgent(
            .codex,
            environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"],
            candidates: [],
            isExecutable: { ["/bin/zsh", "/resolved/bin/codex"].contains($0) },
            runShell: { _, _ in
                count.increment()
                return Shell.Result(
                    out: "__PHAROS_EXECUTABLE__=/resolved/bin/codex\n"
                        + "__PHAROS_PATH__=/resolved/bin:/usr/bin:/bin",
                    err: "", code: 0
                )
            }
        )
        XCTAssertEqual(count.read(), 1)
    }

    func testCodexUnavailable() async {
        let resolution = await LaunchService.resolveAgent(
            .codex,
            environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"],
            candidates: [],
            isExecutable: { $0 == "/bin/zsh" },
            runShell: { _, _ in
                Shell.Result(out: "__PHAROS_EXECUTABLE__=\n__PHAROS_PATH__=/usr/bin:/bin",
                             err: "", code: 0)
            }
        )
        XCTAssertNil(resolution)
    }

    func testBoundedShellStopsPathologicalStartup() {
        let started = Date()
        let result = Shell.run("/bin/zsh", ["-c", "while true; do :; done"], timeout: 0.05)
        XCTAssertEqual(result.code, 124)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }
}

final class ExecutionHostProfileTests: XCTestCase {
    func testExactMeshIdentitySelectsTheCorrectSSHHost() {
        let mini = ExecutionHostProfile(name: "Mini", sshHost: "mini-ts", meshHostID: "Xiang’s Mac mini")
        let air = ExecutionHostProfile(name: "Air", sshHost: "home-ts", meshHostID: "白富贵")
        XCTAssertEqual(ExecutionHostProfile.resolve(meshHostID: "白富贵", in: [mini, air]), air)
    }

    func testUnknownIdentityNeverGuessesWhenSeveralHostsExist() {
        let a = ExecutionHostProfile(name: "A", sshHost: "a")
        let b = ExecutionHostProfile(name: "B", sshHost: "b")
        XCTAssertNil(ExecutionHostProfile.resolve(meshHostID: "unknown", in: [a, b]))
        XCTAssertEqual(ExecutionHostProfile.resolve(meshHostID: "unknown", in: [a]), a)
    }

    func testTailscaleIPWinsOverConflictingDisplayName() {
        let mini = ExecutionHostProfile(name: "Office", sshHost: "100.64.0.8",
                                        meshHostID: "Xiang's Mac mini")
        let air = ExecutionHostProfile(name: "Xiang's Mac mini", sshHost: "100.64.0.9",
                                       meshHostID: "home")
        XCTAssertEqual(ExecutionHostProfile.resolve(meshHostID: "Xiang's Mac mini",
                                                    tailscaleIP: "100.64.0.8",
                                                    in: [air, mini]), mini)
    }

    func testAmbiguousTailscaleIPNeverRoutes() {
        let a = ExecutionHostProfile(name: "A", sshHost: "100.64.0.8")
        let b = ExecutionHostProfile(name: "B", sshHost: "100.64.0.8")
        XCTAssertNil(ExecutionHostProfile.resolve(meshHostID: "A", tailscaleIP: "100.64.0.8",
                                                  in: [a, b]))
    }
}

final class DashboardAgentMergeTests: XCTestCase {
    func testMeshBackedTmuxSessionIsNotDuplicated() {
        let registered = DashboardAgentSession(session: "pharos-pharos-codex", sshHost: nil)
        let result = DashboardAgentSession.unregistered(
            running: ["pharos-pharos-codex", "manual-shell"], remoteHosts: [:],
            registered: [registered]
        )
        XCTAssertEqual(result.map(\.session), ["manual-shell"])
    }

    func testSameSessionNameOnAnotherHostRemainsDistinct() {
        let registered = DashboardAgentSession(session: "agent", sshHost: "home-ts")
        let result = DashboardAgentSession.unregistered(
            running: ["agent"], remoteHosts: ["agent": "office-ts"], registered: [registered]
        )
        XCTAssertEqual(result, [DashboardAgentSession(session: "agent", sshHost: "office-ts")])
    }
}

final class HostLocalProjectPathTests: XCTestCase {
    func testLegacyHostPathMigratesOutOfPortableRegistry() {
        let id = UUID()
        var store = StoreData(projects: [
            Project(id: id, name: "Pharos", localPath: "/wrong",
                    localPaths: ["office": "/Users/pai/pharos", "home": "/srv/pharos"])
        ])
        var paths: [String: String] = [:]
        HostLocalProjectPaths.apply(to: &store, paths: &paths, host: "office")
        XCTAssertEqual(store.projects[0].localPath, "/Users/pai/pharos")
        XCTAssertEqual(paths[id.uuidString], "/Users/pai/pharos")
        XCTAssertTrue(store.projects[0].localPaths.isEmpty)
    }

    func testBrokerSnapshotStripsCheckoutPaths() {
        let id = UUID()
        var store = StoreData(projects: [Project(id: id, name: "Pharos", localPath: "/private/repo")])
        var paths: [String: String] = [:]
        HostLocalProjectPaths.captureAndStrip(&store, paths: &paths)
        XCTAssertNil(store.projects[0].localPath)
        XCTAssertTrue(store.projects[0].localPaths.isEmpty)
        XCTAssertEqual(paths[id.uuidString], "/private/repo")
        let encoded = try! JSONEncoder().encode(store)
        let root = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let project = (root["projects"] as! [[String: Any]])[0]
        XCTAssertNil(project["localPath"])
        XCTAssertNil(project["localPaths"])
    }
}

final class RemoteAttachCommandTests: XCTestCase {
    func testRemoteAttachUsesExactHostAndTerminalFallback() {
        let command = RemoteLaunch.interactiveAttachCommand(session: "work session", host: "home-ts")
        XCTAssertTrue(command.contains("ssh -t 'home-ts'"))
        XCTAssertTrue(command.contains("xterm-256color"))
        XCTAssertTrue(command.contains("work session"))
    }

    func testLocalAttachDoesNotUseSSH() {
        let command = RemoteLaunch.interactiveAttachCommand(session: "local", host: nil)
        XCTAssertFalse(command.contains("ssh -t"))
        XCTAssertTrue(command.contains("tmux attach"))
    }
}

// MARK: - StoreData soft-delete / Trash

final class StoreTrashTests: XCTestCase {

    private func sampleStore() -> StoreData {
        let p1 = Project(name: "Alpha", localPath: "/tmp/alpha", tags: ["work"],
                         playbooks: [Playbook(name: "dev", command: "make dev")], notes: "first")
        let p2 = Project(name: "Beta", localPath: "/tmp/beta", tags: ["work", "fun"])
        return StoreData(projects: [p1, p2], groups: ["fun", "work"])
    }

    // Regression guard: adding `trash` must NOT break decoding pre-existing
    // {projects, groups} registries (which would wipe the user's data on upgrade).
    func testTolerantDecodeOfLegacyRegistryWithoutTrashKey() throws {
        let json = #"{"projects":[{"name":"Alpha"}],"groups":["work"]}"#
        let store = try JSONDecoder().decode(StoreData.self, from: Data(json.utf8))
        XCTAssertEqual(store.projects.map(\.name), ["Alpha"])
        XCTAssertEqual(store.groups, ["work"])
        XCTAssertTrue(store.trash.isEmpty)
    }

    // A top-level JSON array (the legacy flat format) must still THROW here so
    // the caller's `[Project]` fallback path keeps handling migration.
    func testDecodingTopLevelArrayAsStoreThrows() {
        let json = #"[{"name":"Alpha"}]"#
        XCTAssertThrowsError(try JSONDecoder().decode(StoreData.self, from: Data(json.utf8)))
    }

    func testCodableRoundTripIncludingTrash() throws {
        var store = sampleStore()
        store.softDeleteProject(id: store.projects[0].id)
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(StoreData.self, from: data)
        XCTAssertEqual(decoded.projects, store.projects)
        XCTAssertEqual(decoded.groups, store.groups)
        XCTAssertEqual(decoded.trash, store.trash)
    }

    func testSoftDeleteAndRestoreProjectIsLossless() {
        var store = sampleStore()
        let original = store.projects[0]
        store.softDeleteProject(id: original.id)
        XCTAssertFalse(store.projects.contains { $0.id == original.id })
        XCTAssertEqual(store.trash.count, 1)

        let trashID = store.trash[0].id
        store.restoreTrash(trashID)
        XCTAssertTrue(store.trash.isEmpty)
        // Restored project is identical, including playbooks/notes/tags.
        XCTAssertEqual(store.projects.first { $0.id == original.id }, original)
    }

    func testSoftDeleteGroupRestoresMembershipExactly() {
        var store = sampleStore()
        let alphaID = store.projects[0].id   // in "work"
        let betaID  = store.projects[1].id   // in "work" + "fun"
        store.softDeleteGroup("work")
        XCTAssertFalse(store.groups.contains("work"))
        XCTAssertFalse(store.projects.contains { $0.tags.contains("work") })

        store.restoreTrash(store.trash[0].id)
        XCTAssertTrue(store.groups.contains("work"))
        XCTAssertTrue(store.project(withID: alphaID)?.tags.contains("work") ?? false)
        XCTAssertTrue(store.project(withID: betaID)?.tags.contains("work") ?? false)
        // "fun" membership on Beta was never touched.
        XCTAssertTrue(store.project(withID: betaID)?.tags.contains("fun") ?? false)
    }

    func testSoftDeleteAndRestorePlaybook() {
        var store = sampleStore()
        let projectID = store.projects[0].id
        let pb = store.projects[0].playbooks[0]
        store.softDeletePlaybook(projectID: projectID, playbookID: pb.id)
        XCTAssertTrue(store.project(withID: projectID)?.playbooks.isEmpty ?? false)

        store.restoreTrash(store.trash[0].id)
        XCTAssertEqual(store.project(withID: projectID)?.playbooks, [pb])
    }

    func testPurgeExpiredDropsOnlyItemsPastRetention() {
        var store = sampleStore()
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // Fresh delete (now) and a stale one (40 days ago).
        store.softDeleteProject(id: store.projects[0].id, now: now)
        store.softDeleteProject(id: store.projects[0].id, now: now.addingTimeInterval(-40 * 86_400))
        XCTAssertEqual(store.trash.count, 2)
        store.purgeExpiredTrash(now: now, retention: StoreData.trashRetention)
        XCTAssertEqual(store.trash.count, 1)   // the 40-day-old one is gone
    }

    func testRestoreUnknownIDIsNoOp() {
        var store = sampleStore()
        let before = store.projects
        store.restoreTrash(UUID())
        XCTAssertEqual(store.projects, before)
    }

    func testRestoreDoesNotDuplicate() {
        var store = sampleStore()
        let id = store.projects[0].id
        store.softDeleteProject(id: id)
        let trashID = store.trash[0].id
        store.restoreTrash(trashID)
        store.restoreTrash(trashID)   // second restore: id already consumed
        XCTAssertEqual(store.projects.filter { $0.id == id }.count, 1)
    }
}

private extension StoreData {
    func project(withID id: Project.ID) -> Project? { projects.first { $0.id == id } }
}

// MARK: - AuditLog formatting

final class AuditLogTests: XCTestCase {
    func testEntryIsNewlineTerminatedJSONWithFields() throws {
        let line = AuditLog.entry(actor: .cli, action: "remove_project", detail: "Alpha",
                                  at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(line.hasSuffix("\n"))
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["actor"] as? String, "cli")
        XCTAssertEqual(obj?["action"] as? String, "remove_project")
        XCTAssertEqual(obj?["detail"] as? String, "Alpha")
        XCTAssertNotNil(obj?["ts"] as? String)
    }
}

// MARK: - CLI argument parsing

final class CLIParseTests: XCTestCase {

    func testPositionalOptionsAndRepeatedTags() {
        let p = CLI.parse(["demo", "--path", "/tmp/demo", "--tag", "work", "--tag", "fun", "--notes", "hello world"])
        XCTAssertEqual(p.positional, ["demo"])
        XCTAssertEqual(p.opt("path"), "/tmp/demo")
        XCTAssertEqual(p.all("tag"), ["work", "fun"])
        XCTAssertEqual(p.opt("notes"), "hello world")
    }

    func testBooleanFlags() {
        let p = CLI.parse(["proj", "claude", "--tmux", "--no-yolo"])
        XCTAssertEqual(p.positional, ["proj", "claude"])
        XCTAssertTrue(p.has("tmux"))
        XCTAssertTrue(p.has("no-yolo"))
        XCTAssertFalse(p.has("yolo"))
    }

    func testEqualsFormAndShortJSON() {
        let p = CLI.parse(["--path=/x/y", "-j"])
        XCTAssertEqual(p.opt("path"), "/x/y")
        XCTAssertTrue(p.has("json"))
    }

    func testDoubleDashStopsOptionParsing() {
        let p = CLI.parse(["a", "--", "--notreallyaflag", "b"])
        XCTAssertEqual(p.positional, ["a", "--notreallyaflag", "b"])
    }

    func testIsCommandRoutesBareWordsToCLIButNotLaunchFlags() {
        XCTAssertTrue(CLI.isCommand("list"))
        XCTAssertTrue(CLI.isCommand("frobnicate"))    // typo → CLI usage error, not GUI
        XCTAssertTrue(CLI.isCommand("--help"))
        XCTAssertFalse(CLI.isCommand("-psn_0_12345")) // LaunchServices GUI arg
        XCTAssertFalse(CLI.isCommand("--mcp"))         // handled before isCommand
    }
}

// MARK: - PharosCore registry round-trip (shared by CLI + MCP)

final class CoreRegistryTests: XCTestCase {

    private var dir = ""

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pharos-core-test-" + UUID().uuidString
        setenv("PHAROS_REGISTRY", dir + "/projects.json", 1)
    }

    override func tearDown() {
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testAddRemoveRestoreRoundTrip() throws {
        _ = try PharosCore.addProject(name: "demo", localPath: "/tmp/demo",
                                      githubRemote: nil, tags: ["work"], notes: "n")
        XCTAssertEqual(PharosCore.loadProjects().map(\.name), ["demo"])

        _ = try PharosCore.removeProject(name: "demo")
        XCTAssertTrue(PharosCore.loadProjects().isEmpty)
        let trash = PharosCore.loadStore().trash
        XCTAssertEqual(trash.count, 1)
        XCTAssertEqual(trash[0].title, "demo")

        _ = try PharosCore.restoreTrash(id: trash[0].id.uuidString)
        XCTAssertEqual(PharosCore.loadProjects().map(\.name), ["demo"])
        XCTAssertTrue(PharosCore.loadStore().trash.isEmpty)
    }

    func testDuplicateAddThrows() throws {
        _ = try PharosCore.addProject(name: "demo", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        XCTAssertThrowsError(try PharosCore.addProject(name: "demo", localPath: nil,
                                                       githubRemote: nil, tags: [], notes: nil))
    }

    func testRemoveUnknownProjectThrows() {
        XCTAssertThrowsError(try PharosCore.removeProject(name: "nope"))
    }

    func testSetFlagPersists() throws {
        _ = try PharosCore.addProject(name: "demo", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.setFlag(name: "demo", flag: "yolo", value: false)
        XCTAssertEqual(PharosCore.loadProjects().first?.yolo, false)
    }
}

// MARK: - StoreData issues & project log

final class StoreIssueTests: XCTestCase {

    private func storeWithProject() -> (StoreData, Project.ID) {
        let p = Project(name: "App", localPath: "/tmp/app")
        return (StoreData(projects: [p]), p.id)
    }

    func testAddIssueAssignsIncrementalNumbers() {
        var (store, pid) = storeWithProject()
        let i1 = store.addIssue(projectID: pid, title: "first")
        let i2 = store.addIssue(projectID: pid, title: "second", priority: .high)
        XCTAssertEqual(i1?.number, 1)
        XCTAssertEqual(i2?.number, 2)
        XCTAssertEqual(i2?.priority, .high)
        XCTAssertEqual(store.projects[0].issues.count, 2)
    }

    func testIssueNumbersDoNotReuseAfterDelete() {
        var (store, pid) = storeWithProject()
        _ = store.addIssue(projectID: pid, title: "first")   // #1
        _ = store.addIssue(projectID: pid, title: "second")  // #2
        _ = store.softDeleteIssue(projectID: pid, number: 1)
        let i3 = store.addIssue(projectID: pid, title: "third")
        XCTAssertEqual(i3?.number, 3)   // max(2)+1, not a reused #1
    }

    func testSetStatusAndPriority() {
        var (store, pid) = storeWithProject()
        _ = store.addIssue(projectID: pid, title: "x")
        XCTAssertTrue(store.setIssueStatus(projectID: pid, number: 1, status: .done))
        XCTAssertTrue(store.setIssuePriority(projectID: pid, number: 1, priority: .urgent))
        XCTAssertEqual(store.projects[0].issues[0].status, .done)
        XCTAssertEqual(store.projects[0].issues[0].priority, .urgent)
        XCTAssertFalse(store.setIssueStatus(projectID: pid, number: 99, status: .done))
    }

    func testSoftDeleteIssueAndRestore() {
        var (store, pid) = storeWithProject()
        let issue = store.addIssue(projectID: pid, title: "deleteme")!
        let trashID = store.softDeleteIssue(projectID: pid, number: issue.number)
        XCTAssertNotNil(trashID)
        XCTAssertTrue(store.projects[0].issues.isEmpty)
        XCTAssertEqual(store.trash.count, 1)

        store.restoreTrash(trashID!)
        XCTAssertEqual(store.projects[0].issues.map(\.title), ["deleteme"])
        XCTAssertTrue(store.trash.isEmpty)
    }

    func testLinkAndPostAgentFinished() {
        var (store, pid) = storeWithProject()
        _ = store.addIssue(projectID: pid, title: "wire it up")
        XCTAssertTrue(store.linkIssueSession(projectID: pid, number: 1, session: "pharos-app-claude"))
        XCTAssertEqual(store.projects[0].issues[0].status, .inProgress)
        XCTAssertEqual(store.projects[0].issues[0].activeSession, "pharos-app-claude")

        let touched = store.postAgentFinished(session: "pharos-app-claude")
        XCTAssertEqual(touched, ["App"])
        XCTAssertNil(store.projects[0].issues[0].activeSession)        // link cleared
        XCTAssertEqual(store.projects[0].issues[0].status, .inProgress) // status left alone
        XCTAssertEqual(store.projects[0].updates.count, 1)             // auto-posted
        XCTAssertEqual(store.projects[0].updates[0].kind, .agent)
        XCTAssertEqual(store.projects[0].updates[0].issueNumber, 1)
    }

    func testPostAgentFinishedNoLinkIsNoOp() {
        var (store, pid) = storeWithProject()
        _ = store.addIssue(projectID: pid, title: "x")
        let touched = store.postAgentFinished(session: "pharos-other-codex")
        XCTAssertTrue(touched.isEmpty)
        XCTAssertTrue(store.projects[0].updates.isEmpty)
    }

    func testAddUpdateNewestFirst() {
        var (store, pid) = storeWithProject()
        _ = store.addUpdate(projectID: pid, body: "older", now: Date(timeIntervalSince1970: 1))
        _ = store.addUpdate(projectID: pid, body: "newer", now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.projects[0].updates.map(\.body), ["newer", "older"])
    }

    func testIssuesCarriedIntoTrashWithProjectAndBack() {
        var (store, pid) = storeWithProject()
        _ = store.addIssue(projectID: pid, title: "carry me")
        store.softDeleteProject(id: pid)
        XCTAssertTrue(store.projects.isEmpty)
        store.restoreTrash(store.trash[0].id)
        XCTAssertEqual(store.projects.first?.issues.map(\.title), ["carry me"])
    }
}

// MARK: - PharosCore issue ops (temp registry) + parsers

final class CoreIssueTests: XCTestCase {

    private var dir = ""

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pharos-issue-test-" + UUID().uuidString
        setenv("PHAROS_REGISTRY", dir + "/projects.json", 1)
    }
    override func tearDown() {
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testIssueAddListStatusRemoveRoundTrip() throws {
        _ = try PharosCore.addProject(name: "app", localPath: "/tmp/app",
                                      githubRemote: nil, tags: [], notes: nil)
        let added = try PharosCore.issueAdd(project: "app", title: "Fix bug", priority: "high", body: nil)
        XCTAssertTrue(added.contains("app#1"))

        _ = try PharosCore.issueSetStatus(project: "app", number: 1, status: "in_progress")
        let listed = try PharosCore.issueList(project: "app", all: false)
        let issues = (listed.json?["issues"] as? [[String: Any]]) ?? []
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?["status"] as? String, "in_progress")

        _ = try PharosCore.issueRemove(project: "app", number: 1)
        let after = try PharosCore.issueList(project: "app", all: true)
        XCTAssertEqual((after.json?["count"] as? Int), 0)
        XCTAssertEqual(PharosCore.loadStore().trash.count, 1)
    }

    func testParseStatusTolerantAndThrows() throws {
        XCTAssertEqual(try PharosCore.parseStatus("in-progress"), .inProgress)
        XCTAssertEqual(try PharosCore.parseStatus("DONE"), .done)
        XCTAssertThrowsError(try PharosCore.parseStatus("bogus"))
    }

    func testParsePriorityDefaultsAndThrows() throws {
        XCTAssertEqual(try PharosCore.parsePriority(nil), IssuePriority.none)
        XCTAssertEqual(try PharosCore.parsePriority("urgent"), .urgent)
        XCTAssertThrowsError(try PharosCore.parsePriority("p7"))
    }
}

// MARK: - Per-host local paths (multi-machine sync)

final class HostPathTests: XCTestCase {

    func testResolvePicksCurrentHostEntryElseNil() {
        var s = StoreData(projects: [Project(name: "x", localPaths: ["A": "/a", "B": "/b"])])
        s.resolveHostPaths(host: "A")
        XCTAssertEqual(s.projects[0].localPath, "/a")

        var s2 = StoreData(projects: [Project(name: "x", localPaths: ["A": "/a"])])
        s2.resolveHostPaths(host: "B")
        XCTAssertNil(s2.projects[0].localPath)   // known on A, not checked out on B
    }

    func testLegacyPathAdoptedUnderCurrentHost() {
        var s = StoreData(projects: [Project(name: "x", localPath: "/legacy")])
        s.resolveHostPaths(host: "A")
        XCTAssertEqual(s.projects[0].localPath, "/legacy")
        XCTAssertEqual(s.projects[0].localPaths["A"], "/legacy")
    }

    func testCaptureWritesCurrentHostAndLeavesOthers() {
        var s = StoreData(projects: [Project(name: "x", localPaths: ["A": "/a"])])
        s.resolveHostPaths(host: "B")          // B sees nil
        s.projects[0].localPath = "/bnew"
        s.captureHostPaths(host: "B")
        XCTAssertEqual(s.projects[0].localPaths["B"], "/bnew")
        XCTAssertEqual(s.projects[0].localPaths["A"], "/a")   // A's path untouched

        s.projects[0].localPath = nil
        s.captureHostPaths(host: "B")
        XCTAssertNil(s.projects[0].localPaths["B"])           // B's slot cleared
        XCTAssertEqual(s.projects[0].localPaths["A"], "/a")   // A still intact
    }

    func testTwoMachineRoundTrip() {
        // hostA adds at /a, saves (capture).
        var a = StoreData(projects: [Project(name: "x", localPath: "/a")])
        a.captureHostPaths(host: "mac-mini")
        let onDisk = a.projects[0].localPaths

        // hostB loads the same data, resolves → not checked out, sets /b, saves.
        var b = StoreData(projects: [Project(name: "x", localPaths: onDisk)])
        b.resolveHostPaths(host: "macbook-air")
        XCTAssertNil(b.projects[0].localPath)
        b.projects[0].localPath = "/b"
        b.captureHostPaths(host: "macbook-air")

        // hostA reloads → still its own /a.
        var a2 = StoreData(projects: [Project(name: "x", localPaths: b.projects[0].localPaths)])
        a2.resolveHostPaths(host: "mac-mini")
        XCTAssertEqual(a2.projects[0].localPath, "/a")
    }

    func testProjectDecodeTolerantOfMissingLocalPaths() throws {
        let p = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"x","localPath":"/x"}"#.utf8))
        XCTAssertEqual(p.localPath, "/x")
        XCTAssertTrue(p.localPaths.isEmpty)
    }
}

// MARK: - Attachments

final class AttachmentTests: XCTestCase {
    private var dir = ""

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pharos-att-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("PHAROS_REGISTRY", dir + "/projects.json", 1)   // attachments live beside it
    }
    override func tearDown() {
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testAddCopiesFileAndDetectsImage() throws {
        let src = URL(fileURLWithPath: dir).appendingPathComponent("pic.png")
        try Data("x".utf8).write(to: src)
        let id = UUID()
        let att = try AttachmentStore.add(fileAt: src, toIssue: id)
        XCTAssertEqual(att.originalName, "pic.png")
        XCTAssertTrue(att.isImage)
        XCTAssertEqual(att.byteSize, 1)
        XCTAssertNotEqual(att.storedName, "pic.png")   // unique stored name
        XCTAssertTrue(FileManager.default.fileExists(atPath: AttachmentStore.fileURL(att, issueID: id).path))
    }

    func testSweepDeletesOrphansKeepsListed() throws {
        let src = URL(fileURLWithPath: dir).appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: src)
        let keepID = UUID(), dropID = UUID()
        _ = try AttachmentStore.add(fileAt: src, toIssue: keepID)
        _ = try AttachmentStore.add(fileAt: src, toIssue: dropID)
        AttachmentStore.sweepOrphans(keepingIssueIDs: [keepID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: AttachmentStore.directory(forIssue: keepID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AttachmentStore.directory(forIssue: dropID).path))
    }

    func testIssueDecodeTolerantOfMissingAttachments() throws {
        let issue = try JSONDecoder().decode(Issue.self, from: Data(#"{"number":1,"title":"x"}"#.utf8))
        XCTAssertEqual(issue.title, "x")
        XCTAssertTrue(issue.attachments.isEmpty)
    }

    func testCoreIssueAddWithAttachment() throws {
        let src = URL(fileURLWithPath: dir).appendingPathComponent("log.txt")
        try Data("boom".utf8).write(to: src)
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "crash", priority: nil, body: nil, attach: [src.path])
        let issue = PharosCore.loadStore().projects.first?.issues.first
        XCTAssertEqual(issue?.attachments.count, 1)
        XCTAssertEqual(issue?.attachments.first?.originalName, "log.txt")
    }
}

// MARK: - pharos attach (existing issues)

final class CoreAttachTests: XCTestCase {
    private var dir = ""
    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pharos-coreattach-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("PHAROS_REGISTRY", dir + "/projects.json", 1)
    }
    override func tearDown() {
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testAttachAddListRemoveOnExistingIssue() throws {
        let src = URL(fileURLWithPath: dir).appendingPathComponent("img.png")
        try Data("x".utf8).write(to: src)
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "t", priority: nil, body: nil)
        _ = try PharosCore.attachAdd(project: "app", number: 1, paths: [src.path])

        let listed = try PharosCore.attachList(project: "app", number: 1)
        XCTAssertEqual(listed.json?["count"] as? Int, 1)
        let issueID = PharosCore.loadStore().projects[0].issues[0].id
        let att = PharosCore.loadStore().projects[0].issues[0].attachments[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: AttachmentStore.fileURL(att, issueID: issueID).path))

        _ = try PharosCore.attachRemove(project: "app", number: 1, ref: "1")
        XCTAssertEqual(PharosCore.loadStore().projects[0].issues[0].attachments.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AttachmentStore.fileURL(att, issueID: issueID).path))
    }

    func testAttachRemoveByName() throws {
        let src = URL(fileURLWithPath: dir).appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: src)
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "t", priority: nil, body: nil)
        _ = try PharosCore.attachAdd(project: "app", number: 1, paths: [src.path])
        _ = try PharosCore.attachRemove(project: "app", number: 1, ref: "notes.txt")
        XCTAssertEqual(PharosCore.loadStore().projects[0].issues[0].attachments.count, 0)
    }
}

// MARK: - PasteboardImport

final class PasteboardImportTests: XCTestCase {
    func testPlainTextBecomesTxtTempFile() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("pharos-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("hello clipboard", forType: .string)
        let urls = PasteboardImport.fileURLs(from: pb)
        XCTAssertEqual(urls.count, 1)
        let url = try XCTUnwrap(urls.first)
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertTrue(PasteboardImport.isTemp(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello clipboard")
        try? FileManager.default.removeItem(at: url)
    }

    func testEmptyPasteboardReturnsNothing() {
        let pb = NSPasteboard(name: NSPasteboard.Name("pharos-test-empty-\(UUID().uuidString)"))
        pb.clearContents()
        XCTAssertTrue(PasteboardImport.fileURLs(from: pb).isEmpty)
    }
}

// MARK: - Labels & filtering

final class CoreLabelTests: XCTestCase {
    private var dir = ""
    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pharos-label-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("PHAROS_REGISTRY", dir + "/projects.json", 1)
    }
    override func tearDown() {
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testIssueAddDedupsLabels() throws {
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "x", priority: nil, body: nil,
                                    attach: [], labels: ["UI", "ui", "   ", "backend"])
        XCTAssertEqual(PharosCore.loadStore().projects[0].issues[0].labels, ["UI", "backend"])
    }

    func testLabelAddIsIdempotentAndRemoveCaseInsensitive() throws {
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "x", priority: nil, body: nil)
        _ = try PharosCore.issueLabel(project: "app", number: 1, add: true, label: "wip")
        _ = try PharosCore.issueLabel(project: "app", number: 1, add: true, label: "WIP")   // dup ignored
        XCTAssertEqual(PharosCore.loadStore().projects[0].issues[0].labels, ["wip"])
        _ = try PharosCore.issueLabel(project: "app", number: 1, add: false, label: "WIP")  // remove case-insensitive
        XCTAssertTrue(PharosCore.loadStore().projects[0].issues[0].labels.isEmpty)
    }

    func testIssueListFilters() throws {
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "a", priority: "high", body: nil, attach: [], labels: ["x"])
        _ = try PharosCore.issueAdd(project: "app", title: "b", priority: "low", body: nil, attach: [], labels: ["y"])
        XCTAssertEqual(try PharosCore.issueList(project: "app", all: false, label: "x").json?["count"] as? Int, 1)
        XCTAssertEqual(try PharosCore.issueList(project: "app", all: false, priority: "low").json?["count"] as? Int, 1)
        XCTAssertEqual(try PharosCore.issueList(project: "app", all: false, status: "todo").json?["count"] as? Int, 2)
    }

    func testIssueDecodeTolerantOfMissingLabels() throws {
        let issue = try JSONDecoder().decode(Issue.self, from: Data(#"{"number":1,"title":"x"}"#.utf8))
        XCTAssertTrue(issue.labels.isEmpty)
    }
}

// MARK: - Manual ordering (moveIssue)

final class MoveIssueTests: XCTestCase {
    func testReorderWithinColumn() {
        var s = StoreData(projects: [Project(name: "app")])
        let pid = s.projects[0].id
        s.addIssue(projectID: pid, title: "a")   // #1
        s.addIssue(projectID: pid, title: "b")   // #2
        s.addIssue(projectID: pid, title: "c")   // #3
        XCTAssertTrue(s.moveIssue(projectID: pid, number: 3, toStatus: .todo, before: 1))
        let order = s.projects[0].issues
            .filter { $0.status == .todo }
            .sorted { ($0.sortOrder, $0.number) < ($1.sortOrder, $1.number) }
            .map(\.number)
        XCTAssertEqual(order, [3, 1, 2])
    }

    func testMoveAcrossColumnsChangesStatusAndAppends() {
        var s = StoreData(projects: [Project(name: "app")])
        let pid = s.projects[0].id
        s.addIssue(projectID: pid, title: "a")   // #1
        s.addIssue(projectID: pid, title: "b")   // #2
        XCTAssertTrue(s.moveIssue(projectID: pid, number: 1, toStatus: .inProgress, before: nil))
        XCTAssertEqual(s.projects[0].issues.first { $0.number == 1 }?.status, .inProgress)
        XCTAssertEqual(s.projects[0].issues.filter { $0.status == .todo }.map(\.number), [2])
    }

    func testMoveUnknownIssueReturnsFalse() {
        var s = StoreData(projects: [Project(name: "app")])
        XCTAssertFalse(s.moveIssue(projectID: s.projects[0].id, number: 99, toStatus: .done, before: nil))
    }
}

// MARK: - Milestones

final class CoreMilestoneTests: XCTestCase {
    private var dir = ""
    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pharos-ms-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("PHAROS_REGISTRY", dir + "/projects.json", 1)
    }
    override func tearDown() {
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testAddAssignFilterRemove() throws {
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "a", priority: nil, body: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "b", priority: nil, body: nil)
        _ = try PharosCore.milestoneAdd(project: "app", milestone: "Sprint 1", due: "2026-07-01")
        _ = try PharosCore.issueSetMilestone(project: "app", number: 1, milestone: "Sprint 1")
        XCTAssertEqual(try PharosCore.issueList(project: "app", all: false, milestone: "Sprint 1").json?["count"] as? Int, 1)

        _ = try PharosCore.milestoneRemove(project: "app", milestone: "Sprint 1")
        XCTAssertTrue(PharosCore.loadStore().projects[0].milestones.isEmpty)
        XCTAssertNil(PharosCore.loadStore().projects[0].issues.first { $0.number == 1 }?.milestoneID)
    }

    func testSetMilestoneAutocreatesAndClears() throws {
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "a", priority: nil, body: nil)
        _ = try PharosCore.issueSetMilestone(project: "app", number: 1, milestone: "Auto")   // autocreate
        XCTAssertEqual(PharosCore.loadStore().projects[0].milestones.map(\.name), ["Auto"])
        _ = try PharosCore.issueSetMilestone(project: "app", number: 1, milestone: "none")    // clear
        XCTAssertNil(PharosCore.loadStore().projects[0].issues[0].milestoneID)
    }

    func testBadDueThrows() throws {
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        XCTAssertThrowsError(try PharosCore.milestoneAdd(project: "app", milestone: "x", due: "not-a-date"))
    }
}

// MARK: - Relations & subtasks

final class RelationTests: XCTestCase {
    private func twoIssueStore() -> (StoreData, Project.ID) {
        var s = StoreData(projects: [Project(name: "app")])
        let pid = s.projects[0].id
        s.addIssue(projectID: pid, title: "a")   // #1
        s.addIssue(projectID: pid, title: "b")   // #2
        return (s, pid)
    }

    func testParentAndCycleGuard() {
        var (s, pid) = twoIssueStore()
        XCTAssertTrue(s.setIssueParent(projectID: pid, number: 2, parent: 1))
        XCTAssertEqual(s.projects[0].issues.first { $0.number == 2 }?.parent, 1)
        XCTAssertFalse(s.setIssueParent(projectID: pid, number: 1, parent: 1))   // self
        XCTAssertFalse(s.setIssueParent(projectID: pid, number: 1, parent: 2))   // cycle (2's parent is 1)
    }

    func testRelationDualWriteAndRemove() {
        var (s, pid) = twoIssueStore()
        XCTAssertTrue(s.addRelation(projectID: pid, from: 1, kind: .blocks, to: 2))
        XCTAssertEqual(s.projects[0].issues.first { $0.number == 1 }?.relations, [IssueRelation(kind: .blocks, target: 2)])
        XCTAssertEqual(s.projects[0].issues.first { $0.number == 2 }?.relations, [IssueRelation(kind: .blockedBy, target: 1)])
        XCTAssertTrue(s.removeRelation(projectID: pid, from: 1, kind: .blocks, to: 2))
        XCTAssertTrue(s.projects[0].issues.first { $0.number == 1 }?.relations.isEmpty ?? false)
        XCTAssertTrue(s.projects[0].issues.first { $0.number == 2 }?.relations.isEmpty ?? false)
    }

    func testRelatesIsSymmetric() {
        var (s, pid) = twoIssueStore()
        XCTAssertTrue(s.addRelation(projectID: pid, from: 1, kind: .relates, to: 2))
        XCTAssertEqual(s.projects[0].issues.first { $0.number == 2 }?.relations, [IssueRelation(kind: .relates, target: 1)])
    }

    func testIssueDecodeTolerantOfMissingRelations() throws {
        let i = try JSONDecoder().decode(Issue.self, from: Data(#"{"number":1,"title":"x"}"#.utf8))
        XCTAssertNil(i.parent)
        XCTAssertTrue(i.relations.isEmpty)
    }
}

// MARK: - Cross-project search

final class SearchTests: XCTestCase {
    private var dir = ""
    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pharos-search-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("PHAROS_REGISTRY", dir + "/projects.json", 1)
    }
    override func tearDown() {
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testSearchAcrossProjectsByBodyAndLabel() throws {
        _ = try PharosCore.addProject(name: "web", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.addProject(name: "api", localPath: nil, githubRemote: nil, tags: [], notes: nil)
        _ = try PharosCore.issueAdd(project: "web", title: "Login", priority: nil, body: "oauth callback", attach: [], labels: ["frontend"])
        _ = try PharosCore.issueAdd(project: "api", title: "Token", priority: nil, body: "refresh oauth token")
        _ = try PharosCore.issueAdd(project: "web", title: "Dark mode", priority: nil, body: nil)
        XCTAssertEqual(try PharosCore.search("oauth").json?["count"] as? Int, 2)     // body match, both projects
        XCTAssertEqual(try PharosCore.search("callback").json?["count"] as? Int, 1)  // body, web only
        XCTAssertEqual(try PharosCore.search("frontend").json?["count"] as? Int, 1)  // label match
        XCTAssertEqual(try PharosCore.search("zzzz").json?["count"] as? Int, 0)
        XCTAssertThrowsError(try PharosCore.search("   "))
    }
}

// MARK: - Overview / dashboard aggregates

final class OverviewTests: XCTestCase {
    func testStatusCountsAndOpenCount() {
        var s = StoreData(projects: [Project(name: "a"), Project(name: "b")])
        let aid = s.projects[0].id, bid = s.projects[1].id
        s.addIssue(projectID: aid, title: "1")
        s.addIssue(projectID: aid, title: "2")
        _ = s.setIssueStatus(projectID: aid, number: 2, status: .done)
        s.addIssue(projectID: bid, title: "1")
        let c = s.issueStatusCounts()
        XCTAssertEqual(c[.todo], 2)
        XCTAssertEqual(c[.done], 1)
        XCTAssertEqual(s.openIssueCount, 2)   // 2 todo open; the done one isn't
    }
}

final class CoreOverviewTests: XCTestCase {
    private var dir = ""
    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pharos-ov-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("PHAROS_REGISTRY", dir + "/projects.json", 1)
    }
    override func tearDown() {
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testOverviewJSON() throws {
        _ = try PharosCore.addProject(name: "app", localPath: nil, githubRemote: nil, tags: ["work"], notes: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "a", priority: "urgent", body: nil)
        _ = try PharosCore.issueAdd(project: "app", title: "b", priority: nil, body: nil)
        _ = try PharosCore.issueSetStatus(project: "app", number: 2, status: "done")
        let o = PharosCore.overview()
        XCTAssertEqual(o.json?["projects"] as? Int, 1)
        XCTAssertEqual(o.json?["openIssues"] as? Int, 1)
        XCTAssertEqual((o.json?["byStatus"] as? [String: Int])?["done"], 1)
        XCTAssertEqual((o.json?["byPriority"] as? [String: Int])?["urgent"], 1)
    }
}

// MARK: - Running-agent reconciliation + session naming

final class AgentTrackingTests: XCTestCase {
    func testPerIssueSessionNameAndPrefix() {
        let p = Project(name: "My App")
        XCTAssertEqual(LaunchService.tmuxSessionPrefix(p), "pharos-my-app-")
        XCTAssertEqual(LaunchService.tmuxSessionName(p, .claude), "pharos-my-app-claude")
        XCTAssertEqual(LaunchService.tmuxSessionName(p, .claude, issue: 3), "pharos-my-app-claude-i3")
    }

    func testReconcileClearsDeadLinksOnly() {
        var s = StoreData(projects: [Project(name: "app")])
        let pid = s.projects[0].id
        s.addIssue(projectID: pid, title: "x")   // #1
        _ = s.linkIssueSession(projectID: pid, number: 1, session: "pharos-app-claude-i1")

        // Session still live on this machine ("" bucket) → no change.
        _ = s.reconcileAgentLinks(live: ["": ["pharos-app-claude-i1"]])
        XCTAssertEqual(s.projects[0].issues[0].activeSession, "pharos-app-claude-i1")
        XCTAssertTrue(s.projects[0].updates.isEmpty)

        // Session gone (e.g. finished while app was closed) → clear + post finish.
        let touched = s.reconcileAgentLinks(live: ["": []])
        XCTAssertEqual(touched, ["app"])
        XCTAssertNil(s.projects[0].issues[0].activeSession)
        XCTAssertEqual(s.projects[0].updates.first?.kind, .agent)
        XCTAssertEqual(s.projects[0].updates.first?.issueNumber, 1)
        // Status is left as-is (agent finishing ≠ issue resolved).
        XCTAssertEqual(s.projects[0].issues[0].status, .inProgress)
    }
}

// MARK: - Mesh: session-state model + poke safety (probed ground truth)

final class MeshStateMappingTests: XCTestCase {

    /// The hook-event → state table, exactly as probed (cc-hook-probe FINDINGS,
    /// re-verified on CC v2.1.207, 2026-07-11).
    func testHookEventMapping() {
        XCTAssertEqual(MeshHooks.stateFor(event: "UserPromptSubmit", notificationType: nil), .busy)
        XCTAssertEqual(MeshHooks.stateFor(event: "PermissionRequest", notificationType: nil), .blocked)
        XCTAssertEqual(MeshHooks.stateFor(event: "ElicitationResult", notificationType: nil), .busy)
        XCTAssertEqual(MeshHooks.stateFor(event: "PostToolUseFailure", notificationType: nil), .busy)
        XCTAssertEqual(MeshHooks.stateFor(event: "StopFailure", notificationType: nil), .stopped)
        XCTAssertEqual(MeshHooks.stateFor(event: "SessionEnd", notificationType: nil), .gone)
        XCTAssertEqual(MeshHooks.stateFor(event: "Notification", notificationType: "permission_prompt"), .blocked)
        XCTAssertEqual(MeshHooks.stateFor(event: "Notification", notificationType: "elicitation_dialog"), .blocked)
        XCTAssertEqual(MeshHooks.stateFor(event: "Notification", notificationType: "idle_prompt"), .idle)
        XCTAssertEqual(MeshHooks.stateFor(event: "Notification", notificationType: "elicitation_complete"), .busy)
        XCTAssertEqual(MeshHooks.stateFor(event: "Notification", notificationType: "elicitation_response"), .busy)
    }

    /// Unknown events/notification types are deliberately ignored — a CC
    /// upgrade adding new notifications must never flip anyone's state.
    func testUnknownEventsIgnored() {
        XCTAssertNil(MeshHooks.stateFor(event: "Notification", notificationType: "auto_compact_started"))
        XCTAssertNil(MeshHooks.stateFor(event: "Notification", notificationType: nil))
        XCTAssertNil(MeshHooks.stateFor(event: "PreToolUse", notificationType: nil))
    }

    /// Poke may only reach a session whose composer is verifiably idle. busy is
    /// mid-turn; blocked means a PERMISSION DIALOG is up — keys would answer it.
    func testPokeableStates() {
        XCTAssertTrue(MeshSessionState.stopped.pokeable)
        XCTAssertTrue(MeshSessionState.idle.pokeable)
        XCTAssertFalse(MeshSessionState.busy.pokeable)
        XCTAssertFalse(MeshSessionState.blocked.pokeable)
        XCTAssertFalse(MeshSessionState.gone.pokeable)
    }

    func testStopContinuationUsesPlatformSpecificOutputSchema() {
        let claude = MeshHooks.continuationPayload(text: "hello", codex: false)
        XCTAssertNil(claude["decision"])
        let claudeOutput = claude["hookSpecificOutput"] as? [String: String]
        XCTAssertEqual(claudeOutput?["hookEventName"], "Stop")
        XCTAssertEqual(claudeOutput?["additionalContext"], "hello")

        let codex = MeshHooks.continuationPayload(text: "hello", codex: true)
        XCTAssertEqual(codex["decision"] as? String, "block")
        XCTAssertEqual(codex["reason"] as? String, "hello")
        XCTAssertEqual(codex["suppressOutput"] as? Bool, true)
        XCTAssertNil(codex["hookSpecificOutput"])
    }

    func testFormMessageRendersQuestionsAndOptions() {
        let toolInput: [String: Any] = [
            "questions": [[
                "question": "Which beam style should the icon use?",
                "header": "Beam style",
                "multiSelect": false,
                "options": [
                    ["label": "glow", "description": "Soft luminous halo."],
                    ["label": "neg", "description": "Negative-space beam."],
                ],
            ], [
                "question": "Ship it?",
                "multiSelect": true,
                "options": [["label": "yes"]],
            ]],
        ]
        let text = MeshHooks.formMessage(toolInput: toolInput)
        let rendered = try! XCTUnwrap(text)
        XCTAssertTrue(rendered.contains("1. Which beam style should the icon use?［Beam style］"))
        XCTAssertTrue(rendered.contains("◦ glow — Soft luminous halo."))
        XCTAssertTrue(rendered.contains("◦ neg — Negative-space beam."))
        XCTAssertTrue(rendered.contains("2. Ship it?（可多选）"))
        XCTAssertTrue(rendered.contains("◦ yes"))
        XCTAssertNil(MeshHooks.formMessage(toolInput: [:]))
    }

    func testClaudeHookInstallerWritesFullManifestAndRepairsMatcher() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(MeshHooks.installHooks(["--project", directory.path]), 0)
        let settings = directory.appendingPathComponent(".claude/settings.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: settings))
                                 as? [String: Any])
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in ["Stop", "SessionStart", "UserPromptSubmit", "PermissionRequest",
                      "Notification", "ElicitationResult", "PostToolUseFailure",
                      "StopFailure", "SessionEnd", "PostToolUse", "PreToolUse"] {
            XCTAssertNotNil(hooks[event], "missing \(event)")
        }
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre[0]["matcher"] as? String, "AskUserQuestion")

        var post = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        post[0]["matcher"] = "Edit"
        hooks["PostToolUse"] = post
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: settings, options: .atomic)

        XCTAssertEqual(MeshHooks.installHooks(["--project", directory.path]), 0)
        root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: settings))
                             as? [String: Any])
        hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        post = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(post[0]["matcher"] as? String, "*")
    }
}

final class MeshTransportResilienceTests: XCTestCase {
    func testSocketReadTimeoutPreventsHalfOpenNodeLoop() {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        guard descriptors[0] >= 0, descriptors[1] >= 0 else { return }
        defer { close(descriptors[0]); close(descriptors[1]) }

        meshSetSocketTimeouts(descriptors[0], seconds: 0.25)
        let start = Date()
        var byte: UInt8 = 0
        XCTAssertEqual(read(descriptors[0], &byte, 1), -1)
        XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testTmuxTargetValidationAcceptsDefaultAndAbsoluteSocketsOnly() {
        XCTAssertTrue(MeshPaneSafety.validTmuxPane("%28"))
        XCTAssertTrue(MeshPaneSafety.validTmuxPane("28"))
        XCTAssertFalse(MeshPaneSafety.validTmuxPane("%2;kill-server"))
        XCTAssertTrue(MeshPaneSafety.validTmuxSocket("/private/tmp/tmux-501/default"))
        XCTAssertFalse(MeshPaneSafety.validTmuxSocket("relative.sock"))
        XCTAssertFalse(MeshPaneSafety.validTmuxSocket("/tmp/ok\nkill-server"))
    }
}

final class MeshWireTests: XCTestCase {

    func testSessionKeyedPresenceDecodes() throws {
        let raw = #"{"v":2,"members":{"sid":{"project":"/tmp/x","session":"sid","state":"blocked","stateReason":"permission:Bash","aliases":{"r":"bot"},"rooms":["r"],"lastSeen":1.0,"online":true}}}"#
        let p = try JSONDecoder().decode(MeshPresence.self, from: Data(raw.utf8))
        XCTAssertEqual(p.members["sid"]?.aliases["r"], "bot")
        XCTAssertEqual(p.members["sid"]?.session, "sid")
        XCTAssertEqual(p.members["sid"]?.stateReason, "permission:Bash")
    }

    /// Text-mention parsing feeds both the GUI input and CLI say — the poke
    /// pipeline's very first step.
    func testParseTextMentions() {
        XCTAssertEqual(MeshHooks.parseTextMentions("@alice check the PR with @bob, @alice!"), ["alice", "bob"])
        XCTAssertEqual(MeshHooks.parseTextMentions("no mentions here"), [])
    }

    func testParseTextMentionsHandlesCJKAdjacency() {
        // A CJK char immediately after the nick must NOT be swallowed into it.
        XCTAssertEqual(MeshHooks.parseTextMentions("@ios-home-claude你看看这个"), ["ios-home-claude"])
        XCTAssertEqual(MeshHooks.parseTextMentions("@a2a-codex你好 @codex，麻烦了"), ["a2a-codex", "codex"])
        // A space still works, as before.
        XCTAssertEqual(MeshHooks.parseTextMentions("@ios-home-claude 其实是通的"), ["ios-home-claude"])
        // Bare "@" + CJK / CJK punctuation is not a mention.
        XCTAssertEqual(MeshHooks.parseTextMentions("交给@我，然后@，就会立刻"), [])
        // Trailing sentence period is trimmed; email-ish text isn't a leading mention.
        XCTAssertEqual(MeshHooks.parseTextMentions("ping @bob."), ["bob"])
    }
}

final class MeshSessionContextTests: XCTestCase {
    func testSessionStartIdentityIsResolvedByExactTmuxServerAndPane() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-session-context-\(UUID().uuidString)")
        setenv("PHAROS_MESH_DIR", directory.path, 1)
        defer {
            unsetenv("PHAROS_MESH_DIR")
            try? FileManager.default.removeItem(at: directory)
        }
        let environment = [
            "TMUX": "/private/tmp/tmux-501/default,123,0",
            "TMUX_PANE": "%22",
        ]
        XCTAssertTrue(MeshHooks.recordSessionContext(sessionID: "session-abc", cwd: "/tmp/project",
                                                     environment: environment))
        XCTAssertEqual(MeshHooks.currentSessionID(environment: environment), "session-abc")
        XCTAssertNil(MeshHooks.currentSessionID(environment: [
            "TMUX": "/private/tmp/tmux-501/default,123,0",
            "TMUX_PANE": "%23",
        ]))
        XCTAssertNil(MeshHooks.currentSessionID(environment: [
            "TMUX": "/private/tmp/tmux-501/other,123,0",
            "TMUX_PANE": "%22",
        ]))
    }
}

final class MeshPaneSafetyTests: XCTestCase {
    func testOnlyExplicitTurnBoundaryStatesAllowNodePoke() {
        XCTAssertTrue(MeshPaneSafety.allowsPoke(state: "stopped"))
        XCTAssertTrue(MeshPaneSafety.allowsPoke(state: "idle"))
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: "busy"))
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: "blocked"))
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: "gone"))
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: nil))
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: "future-state"))
    }

    func testStaleBusyAndBlockedLeasesPermitAProbeButGoneNeverDoes() {
        let now = 10_000.0
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: "busy", stateTs: now - 10, now: now))
        XCTAssertTrue(MeshPaneSafety.allowsPoke(
            state: "busy", stateTs: now - MeshPaneSafety.busyLeaseSeconds - 1, now: now
        ))
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: "blocked", stateTs: now - 10, now: now))
        XCTAssertTrue(MeshPaneSafety.allowsPoke(
            state: "blocked", stateTs: now - MeshPaneSafety.blockedLeaseSeconds - 1, now: now
        ))
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: "gone", stateTs: 1, now: now))
        XCTAssertTrue(MeshPaneSafety.allowsPoke(state: "busy", stateTs: nil, now: now))
        XCTAssertTrue(MeshPaneSafety.allowsPoke(state: nil, stateTs: nil, now: now))
        XCTAssertTrue(MeshPaneSafety.allowsPoke(state: "future-state", stateTs: nil, now: now))
        XCTAssertFalse(MeshPaneSafety.allowsPoke(state: "busy", stateTs: now + 1, now: now))
    }

    func testAgentDetectedBehindTmuxWrapperShell() {
        let codex = """
          100     1 /bin/zsh
          101   100 /opt/homebrew/bin/codex
          102   101 /usr/bin/helper
        """
        XCTAssertTrue(MeshPaneSafety.processTreeContainsAgent(codex, rootPID: 100, kind: nil))
        XCTAssertTrue(MeshPaneSafety.processTreeContainsAgent(codex, rootPID: 100, kind: "codex"))
        XCTAssertFalse(MeshPaneSafety.processTreeContainsAgent(codex, rootPID: 100, kind: "claude"))

        let nestedClaude = """
          200     1 /bin/zsh
          201   200 /usr/bin/env
          202   201 /Users/u/.local/bin/claude
        """
        XCTAssertTrue(MeshPaneSafety.processTreeContainsAgent(nestedClaude, rootPID: 200, kind: nil))
        XCTAssertFalse(MeshPaneSafety.processTreeContainsAgent(nestedClaude, rootPID: 200, kind: "codex"),
                       "a stale Codex registration must not claim a Claude pane")

        let shellOnly = """
          300     1 /bin/zsh
          301   300 /usr/bin/vim
        """
        XCTAssertFalse(MeshPaneSafety.processTreeContainsAgent(shellOnly, rootPID: 300, kind: nil))
    }
}

final class MeshNickResolutionTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("mesh-state"), withIntermediateDirectories: true)
        setenv("PHAROS_MESH_DIR", dir.path, 1)
    }
    override func tearDown() {
        unsetenv("PHAROS_MESH_DIR")
        try? FileManager.default.removeItem(at: dir)
    }

    private func writePresence(_ members: [String: MeshPresenceEntry]) throws {
        let d = try JSONEncoder().encode(MeshPresence(v: 2, members: members))
        try d.write(to: dir.appendingPathComponent("mesh-state/presence.json"))
    }

    private func entry(project: String?, session: String?) -> MeshPresenceEntry {
        MeshPresenceEntry(project: project, session: session, host: nil, tmuxPane: nil,
                          state: nil, stateTs: nil, aliases: ["r": "kid"], rooms: ["r"],
                          lastSeen: 1, online: true)
    }

    /// The identity rule (2026-07-11): an entry that declared a session id is
    /// NEVER claimed via the cwd fallback by a hook carrying a different
    /// session. Regression guard for the live hijack: a nick joined from $HOME
    /// was cwd-matched by every unregistered session on the host, which stole
    /// its unread notices and pinned its state busy.
    func testForeignSessionCannotClaimByCwdPrefix() throws {
        try writePresence(["kid-sid": entry(project: "/Users/u", session: "kid-sid")])
        XCTAssertNil(MeshHooks.resolveNick(cwd: "/Users/u/some/other/project", session: "stranger-sid"))
        XCTAssertEqual(MeshHooks.resolveNick(cwd: "/Users/u", session: nil), "kid")
        // The declared session itself still resolves exactly.
        XCTAssertEqual(MeshHooks.resolveNick(cwd: "/anywhere", session: "kid-sid"), "kid")
    }

    /// An interactive recv command has no hook payload; cwd still resolves its
    /// own registered session, while a foreign hook session never can.
    func testCwdResolutionWithoutHookSession() throws {
        var e = entry(project: "/Users/u/proj", session: "sid")
        e.aliases = ["r": "olde"]
        try writePresence(["sid": e])
        XCTAssertEqual(MeshHooks.resolveNick(cwd: "/Users/u/proj/sub", session: nil), "olde")
        XCTAssertNil(MeshHooks.resolveNick(cwd: "/Users/u/elsewhere", session: nil))
    }
}

final class MeshStateCorrectionTests: XCTestCase {
    private func entry(state: String, ts: Double) -> MeshPresenceEntry {
        MeshPresenceEntry(project: "/p", session: "s", host: "h", tmuxPane: "%1",
                          state: state, stateTs: ts, kind: "codex", aliases: ["r": "codex"], rooms: ["r"],
                          lastSeen: 1, online: true)
    }

    func testCorrectionOnlyAppliesToTheObservedBusyVersion() {
        let correction = MeshRequest(cmd: "mark", nick: "codex", state: "stopped",
                                     expectedState: "busy", expectedStateTs: 10)
        XCTAssertTrue(MeshBroker.markMatchesSnapshot(entry(state: "busy", ts: 10),
                                                      request: correction))
        XCTAssertFalse(MeshBroker.markMatchesSnapshot(entry(state: "busy", ts: 11),
                                                       request: correction),
                       "a newer busy hook must win over an old idle probe")
        XCTAssertFalse(MeshBroker.markMatchesSnapshot(entry(state: "stopped", ts: 10),
                                                       request: correction))
        XCTAssertTrue(MeshBroker.markMatchesSnapshot(entry(state: "busy", ts: 11),
                                                      request: MeshRequest(cmd: "mark", state: "stopped")),
                      "ordinary hook marks remain unconditional")
    }
}

final class MeshRoomScopedIdentityTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-room-id-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("mesh-state/unread"),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("mesh/attachments"),
                                                 withIntermediateDirectories: true)
        setenv("PHAROS_MESH_DIR", dir.path, 1)
        setenv("PHAROS_REGISTRY", dir.appendingPathComponent("projects.json").path, 1)
    }

    override func tearDown() {
        unsetenv("PHAROS_MESH_DIR")
        unsetenv("PHAROS_REGISTRY")
        try? FileManager.default.removeItem(at: dir)
    }

    func testSameAliasInTwoRoomsRoutesToEachSession() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "orbidash-dev", nick: "codex",
                                                 project: "/orbidash", session: "session-orbidash",
                                                 host: "mac", tmuxPane: "%19",
                                                 tmuxSocket: "/private/tmp/tmux-501/orbidash",
                                                 kind: "codex")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "lelantos-dev", nick: "codex",
                                                 project: "/lelantos", session: "session-lelantos",
                                                 host: "mac", tmuxPane: "%22", kind: "codex")).ok)

        let orbi = broker.process(MeshRequest(cmd: "say", room: "orbidash-dev", nick: "human",
                                              text: "@codex plan", to: ["codex"]))
        XCTAssertEqual(orbi.members?.first?.id, "session-orbidash")
        XCTAssertEqual(orbi.members?.first?.tmuxPane, "%19")
        XCTAssertEqual(orbi.members?.first?.tmuxSocket, "/private/tmp/tmux-501/orbidash")

        let lel = broker.process(MeshRequest(cmd: "say", room: "lelantos-dev", nick: "human",
                                             text: "@codex deploy", to: ["codex"]))
        XCTAssertEqual(lel.members?.first?.id, "session-lelantos")
        XCTAssertEqual(lel.members?.first?.tmuxPane, "%22")

        let orbiInbox = broker.process(MeshRequest(cmd: "recv", nick: "codex",
                                                   memberID: "session-orbidash"))
        XCTAssertEqual(orbiInbox.messages?.map(\.text), ["@codex plan"])
        let lelInbox = broker.process(MeshRequest(cmd: "recv", nick: "codex",
                                                  memberID: "session-lelantos"))
        XCTAssertEqual(lelInbox.messages?.map(\.text), ["@codex deploy"])

        let roster = broker.process(MeshRequest(cmd: "who")).members ?? []
        XCTAssertEqual(Set(roster.filter { $0.nick == "codex" }.map(\.id)),
                       ["session-orbidash", "session-lelantos"])
    }

    func testSayDerivesSenderAliasFromMemberSession() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "dev", nick: "real-agent",
                                                 session: "session-real", host: "mac")).ok)

        let sent = broker.process(MeshRequest(cmd: "say", room: "dev", nick: "spoofed-agent",
                                              memberID: "session-real", text: "hello"))
        XCTAssertTrue(sent.ok)
        let history = broker.process(MeshRequest(cmd: "history", room: "dev")).messages ?? []
        XCTAssertEqual(history.last?.from, "real-agent")
    }

    func testHistoryPagesBackwardFromAnchor() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "paging", nick: "agent",
                                                 session: "session-page", host: "mac")).ok)
        for index in 0..<12 {
            XCTAssertTrue(broker.process(MeshRequest(cmd: "say", room: "paging",
                                                     memberID: "session-page",
                                                     text: "m\(index)")).ok)
        }
        let tail = broker.process(MeshRequest(cmd: "history", room: "paging", limit: 4)).messages ?? []
        XCTAssertEqual(tail.map(\.text), ["m8", "m9", "m10", "m11"])

        var pageRequest = MeshRequest(cmd: "history", room: "paging", limit: 4)
        pageRequest.beforeID = tail.first?.id
        let middle = broker.process(pageRequest).messages ?? []
        XCTAssertEqual(middle.map(\.text), ["m4", "m5", "m6", "m7"])

        var headRequest = MeshRequest(cmd: "history", room: "paging", limit: 10)
        headRequest.beforeID = middle.first?.id
        let head = broker.process(headRequest).messages ?? []
        XCTAssertEqual(head.map(\.text), ["m0", "m1", "m2", "m3"])

        var unknownAnchor = MeshRequest(cmd: "history", room: "paging", limit: 4)
        unknownAnchor.beforeID = "missing-id"
        XCTAssertTrue((broker.process(unknownAnchor).messages ?? []).isEmpty)
    }

    func testSayInfersOnlyJoinedRoomFromMemberSession() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "only-room", nick: "agent",
                                                 session: "session-only", host: "mac")).ok)

        let sent = broker.process(MeshRequest(cmd: "say", memberID: "session-only", text: "hello"))
        XCTAssertTrue(sent.ok)
        XCTAssertEqual(broker.process(MeshRequest(cmd: "history", room: "only-room"))
            .messages?.last?.from, "agent")
    }

    func testSayRequiresExplicitRoomWhenSessionJoinedMultipleRooms() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "alpha", nick: "alpha-agent",
                                                 session: "session-many", host: "mac")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "beta", nick: "beta-agent",
                                                 session: "session-many", host: "mac")).ok)

        let ambiguous = broker.process(MeshRequest(cmd: "say", memberID: "session-many", text: "wrong room"))
        XCTAssertFalse(ambiguous.ok)
        XCTAssertTrue(ambiguous.error?.contains("multiple rooms") == true)
        XCTAssertTrue((broker.process(MeshRequest(cmd: "history", room: "alpha")).messages ?? []).isEmpty)
        XCTAssertTrue((broker.process(MeshRequest(cmd: "history", room: "beta")).messages ?? []).isEmpty)

        let explicit = broker.process(MeshRequest(cmd: "say", room: "beta",
                                                  memberID: "session-many", text: "right room"))
        XCTAssertTrue(explicit.ok)
        XCTAssertEqual(broker.process(MeshRequest(cmd: "history", room: "beta"))
            .messages?.last?.from, "beta-agent")
    }

    func testSayRejectsUnregisteredAgentButAllowsExplicitHuman() {
        let broker = MeshBroker()
        let agent = broker.process(MeshRequest(cmd: "say", room: "dev", nick: "agent", text: "hello"))
        XCTAssertFalse(agent.ok)
        XCTAssertTrue(agent.error?.contains("member identity required") == true)

        let human = broker.process(MeshRequest(cmd: "say", room: "dev", nick: "human", text: "hello"))
        XCTAssertTrue(human.ok)
        XCTAssertEqual(broker.process(MeshRequest(cmd: "history", room: "dev"))
            .messages?.last?.from, "human")
    }

    func testJoinReportsTailscaleIPInRosterAndSay() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "ts-room", nick: "ip-agent",
                                                 session: "session-ip", host: "白富贵",
                                                 tmuxPane: "%12", kind: "claude",
                                                 tailscaleIP: "100.91.91.43")).ok)
        // `who` surfaces the reported IP so the mobile app can auto-fill SSH.
        let roster = broker.process(MeshRequest(cmd: "who")).members ?? []
        let m = roster.first { $0.nick == "ip-agent" }
        XCTAssertEqual(m?.tailscaleIP, "100.91.91.43")
        XCTAssertEqual(m?.host, "白富贵")
        // `say` echoes the @-target's IP as well.
        let echoed = broker.process(MeshRequest(cmd: "say", room: "ts-room", nick: "human",
                                                text: "@ip-agent hi", to: ["ip-agent"]))
        XCTAssertEqual(echoed.members?.first?.tailscaleIP, "100.91.91.43")
    }

    func testJoinWithoutTailscaleIPLeavesItNil() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "ts-room2", nick: "no-ip",
                                                 session: "session-noip", host: "mac",
                                                 kind: "codex")).ok)
        let roster = broker.process(MeshRequest(cmd: "who")).members ?? []
        XCTAssertNil(roster.first { $0.nick == "no-ip" }?.tailscaleIP)
    }

    func testBrokerServesRegistryProjectsAndIssues() {
        let broker = MeshBroker()
        let projects = broker.process(MeshRequest(cmd: "projects"))
        XCTAssertTrue(projects.ok)
        XCTAssertTrue(projects.payload?.contains("\"projects\"") == true)
        let issues = broker.process(MeshRequest(cmd: "issues"))
        XCTAssertTrue(issues.ok)
        XCTAssertTrue(issues.payload?.contains("\"issues\"") == true)
    }

    func testRegistryWritesAreCompareAndSwapAndBackedUp() throws {
        let initial = #"{"projects":[{"name":"before"}],"groups":[],"trash":[]}"#
        try Data(initial.utf8).write(to: dir.appendingPathComponent("projects.json"))
        let broker = MeshBroker()
        let first = broker.process(MeshRequest(cmd: "registry-get"))
        XCTAssertTrue(first.ok)
        XCTAssertEqual(first.payload, initial)
        XCTAssertEqual(first.revision?.count, 64)

        let updated = #"{"projects":[{"name":"after"}],"groups":[],"trash":[]}"#
        let accepted = broker.process(MeshRequest(cmd: "registry-put", payload: updated,
                                                  expectedRevision: first.revision))
        XCTAssertTrue(accepted.ok)
        XCTAssertNotEqual(accepted.revision, first.revision)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("projects.json"), encoding: .utf8), updated)

        let stale = broker.process(MeshRequest(cmd: "registry-put", payload: initial,
                                               expectedRevision: first.revision))
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.error, "registry conflict")
        XCTAssertEqual(stale.revision, accepted.revision)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("projects.json"), encoding: .utf8), updated)

        let backups = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("registry-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), initial)
    }

    func testRegistryRejectsMalformedOrUnversionedWrites() {
        let broker = MeshBroker()
        let snapshot = broker.process(MeshRequest(cmd: "registry-get"))
        XCTAssertFalse(broker.process(MeshRequest(cmd: "registry-put", payload: "[]",
                                                  expectedRevision: snapshot.revision)).ok)
        XCTAssertFalse(broker.process(MeshRequest(cmd: "registry-put",
                                                  payload: #"{"projects":[]}"#)).ok)
    }

    func testCapabilitiesAdvertiseHeadlessRepliesAndAttachments() {
        let capabilities = MeshBroker().process(MeshRequest(cmd: "capabilities")).capabilities ?? []
        XCTAssertTrue(capabilities.contains("headless-v1"))
        XCTAssertTrue(capabilities.contains("reply-v1"))
        XCTAssertTrue(capabilities.contains("attachment-v1"))
        XCTAssertTrue(capabilities.contains("registry-cas-v1"))
        XCTAssertTrue(capabilities.contains("pairing-v2"))
        XCTAssertTrue(capabilities.contains("events-v1"))
        XCTAssertTrue(capabilities.contains("node-v2"))
        XCTAssertTrue(capabilities.contains("session-sender-v1"))
    }

    func testEventCursorPublishesMessageAndDurableNodeCommand() throws {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "node-heartbeat", memberID: "node-1",
                                                 host: "mac")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "dev", nick: "agent",
                                                 session: "session-1", host: "mac",
                                                 tmuxPane: "%7", kind: "codex")).ok)
        let baseline = try XCTUnwrap(broker.process(MeshRequest(cmd: "events")).cursor)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "say", room: "dev", nick: "human",
                                                 text: "@agent hello", to: ["agent"])).ok)
        let response = broker.process(MeshRequest(cmd: "events", timeoutMs: 250, cursor: baseline))
        XCTAssertEqual(response.events?.map(\.kind), [.message, .nodeCommand])
        let commands = broker.process(MeshRequest(cmd: "node-command-list", nodeID: "node-1")).commands
        XCTAssertEqual(commands?.first?.action, .poke)
        XCTAssertEqual(commands?.first?.state, .queued)
        XCTAssertEqual(response.cursor, response.events?.last?.sequence)
    }

    func testNodeHeartbeatMarksOnlyItsHostMembersManaged() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "node-heartbeat", memberID: "node-1",
                                                 host: "display-name", tailscaleIP: "100.64.0.8")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "dev", nick: "local",
                                                 session: "local-1", host: "different-name",
                                                 tmuxPane: "%1", kind: "codex",
                                                 tailscaleIP: "100.64.0.8")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "dev", nick: "remote",
                                                 session: "remote-1", host: "remote",
                                                 tmuxPane: "%2", kind: "codex",
                                                 tailscaleIP: "100.64.0.9")).ok)
        let roster = broker.process(MeshRequest(cmd: "who")).members ?? []
        XCTAssertEqual(roster.first { $0.nick == "local" }?.nodeOnline, true)
        XCTAssertEqual(roster.first { $0.nick == "remote" }?.nodeOnline, false)
        XCTAssertEqual(broker.process(MeshRequest(cmd: "node-list")).nodes?.map(\.id), ["node-1"])
    }

    func testManualPokeRequiresHostNodeAndPublishesDurableCommand() throws {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "dev", nick: "agent",
                                                 session: "session-1", host: "mac",
                                                 tmuxPane: "%7", kind: "codex")).ok)
        XCTAssertFalse(broker.process(MeshRequest(cmd: "poke", room: "dev", nick: "agent")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "node-heartbeat", memberID: "node-1",
                                                 host: "mac")).ok)
        let baseline = try XCTUnwrap(broker.process(MeshRequest(cmd: "events")).cursor)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "poke", room: "dev", nick: "agent")).ok)
        let response = broker.process(MeshRequest(cmd: "events", timeoutMs: 250, cursor: baseline))
        XCTAssertEqual(response.events?.map(\.kind), [.nodeCommand])
        let command = try XCTUnwrap(broker.process(
            MeshRequest(cmd: "node-command-list", nodeID: "node-1")
        ).commands?.first)
        XCTAssertEqual(command.action, .poke)
        XCTAssertEqual(command.state, .queued)
    }

    func testHeartbeatRecoveryDeduplicatesTheOriginalMessagePoke() throws {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "node-heartbeat", memberID: "node-1",
                                                 host: "mac")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "dev", nick: "agent",
                                                 session: "session-1", host: "mac",
                                                 tmuxPane: "%7", kind: "codex")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "say", room: "dev", nick: "human",
                                                 text: "directed", to: ["agent"])).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "node-heartbeat", memberID: "node-1",
                                                 host: "mac")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "node-heartbeat", memberID: "node-1",
                                                 host: "mac")).ok)
        let commands = broker.process(MeshRequest(cmd: "node-command-list", nodeID: "node-1"))
            .commands?.filter { $0.action == .poke }
        XCTAssertEqual(commands?.count, 1)
    }

    func testDurableNodeCommandIsIdempotentAndExhaustsRetries() throws {
        let broker = MeshBroker()
        let deadline = Date().timeIntervalSince1970 + 300
        let request = MeshRequest(cmd: "node-command-enqueue", payload: "{}", nodeID: "node-1",
                                  action: MeshNodeCommandAction.reconcile.rawValue,
                                  idempotencyKey: "same-request", deadline: deadline,
                                  maxAttempts: 2)
        let first = try XCTUnwrap(broker.process(request).command)
        let duplicate = try XCTUnwrap(broker.process(request).command)
        XCTAssertEqual(first.id, duplicate.id)

        let accepted = try XCTUnwrap(broker.process(
            MeshRequest(cmd: "node-command-next", nodeID: "node-1")
        ).command)
        XCTAssertEqual(accepted.state, .accepted)
        for _ in 0..<2 {
            var deferred = MeshRequest(cmd: "node-command-update",
                                       state: MeshNodeCommandState.accepted.rawValue,
                                       payload: "still busy", nodeID: "node-1",
                                       commandID: first.id)
            deferred.retryAt = Date().timeIntervalSince1970
            _ = broker.process(deferred)
        }
        let final = try XCTUnwrap(broker.process(
            MeshRequest(cmd: "node-command-list", nodeID: "node-1")
        ).commands?.first)
        XCTAssertEqual(final.state, .failed)
        XCTAssertEqual(final.attempts, 2)
    }

    func testDirectTerminalNodeCommandAckCountsOneAttempt() throws {
        let broker = MeshBroker()
        let command = try XCTUnwrap(broker.process(MeshRequest(
            cmd: "node-command-enqueue", payload: "{}", nodeID: "node-1",
            action: MeshNodeCommandAction.poke.rawValue,
            idempotencyKey: "permanent-rejection",
            deadline: Date().timeIntervalSince1970 + 300
        )).command)
        _ = broker.process(MeshRequest(cmd: "node-command-next", nodeID: "node-1"))
        let failed = try XCTUnwrap(broker.process(MeshRequest(
            cmd: "node-command-update", state: MeshNodeCommandState.failed.rawValue,
            payload: "agent session is gone", nodeID: "node-1", commandID: command.id
        )).command)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.attempts, 1)
    }

    func testRemoteControlCommandsRequireCredential() {
        let broker = MeshBroker()
        XCTAssertFalse(broker.process(MeshRequest(cmd: "node-heartbeat", memberID: "node-1",
                                                  host: "mac"), trustedLocal: false).ok)
        XCTAssertFalse(broker.process(MeshRequest(cmd: "node-command-list"),
                                      trustedLocal: false).ok)
    }

    func testBrokerRestartRestoresUnreadMailboxAndNodeCommandThenPersistsAck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-mesh-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PHAROS_MESH_DIR", directory.path, 1)
        setenv("PHAROS_MESH_DATA_DIR", directory.path, 1)
        defer {
            unsetenv("PHAROS_MESH_DIR")
            unsetenv("PHAROS_MESH_DATA_DIR")
            try? FileManager.default.removeItem(at: directory)
        }

        let first = MeshBroker()
        XCTAssertTrue(first.process(MeshRequest(cmd: "node-heartbeat", memberID: "node-1",
                                                host: "mac")).ok)
        XCTAssertTrue(first.process(MeshRequest(cmd: "join", room: "dev", nick: "agent",
                                                session: "session-1", host: "mac",
                                                tmuxPane: "%7", kind: "codex")).ok)
        XCTAssertTrue(first.process(MeshRequest(cmd: "say", room: "dev", nick: "human",
                                                text: "@agent durable", to: ["agent"])).ok)
        let commandID = try XCTUnwrap(first.process(
            MeshRequest(cmd: "node-command-list", nodeID: "node-1")
        ).commands?.first?.id)

        let restarted = MeshBroker(loadPersistentState: true)
        XCTAssertEqual(restarted.process(
            MeshRequest(cmd: "node-command-list", nodeID: "node-1")
        ).commands?.first?.id, commandID)
        let delivered = restarted.process(MeshRequest(cmd: "recv", memberID: "session-1"))
        XCTAssertEqual(delivered.messages?.map(\.text), ["@agent durable"])

        let restartedAfterAck = MeshBroker(loadPersistentState: true)
        XCTAssertEqual(restartedAfterAck.process(
            MeshRequest(cmd: "recv", memberID: "session-1")
        ).messages, [])
    }

    func testPairingLinkRejectsDuplicateQueryKeys() throws {
        let raw = "pharos://pair?v=1&v=1&host=100.64.0.1&port=47800&broker=broker-id&token=12345678901234567890&expires=9999999999"
        XCTAssertNil(MeshPairingLink(url: try XCTUnwrap(URL(string: raw))))
    }

    func testPairingLinkRoundTripAndOneTimeRedemption() throws {
        let broker = MeshBroker()
        let created = broker.process(MeshRequest(cmd: "pairing-create",
                                                  timeoutMs: 300_000,
                                                  host: "personal-dev:47800"))
        XCTAssertTrue(created.ok)
        let raw = try XCTUnwrap(created.payload)
        let url = try XCTUnwrap(URL(string: raw))
        let link = try XCTUnwrap(MeshPairingLink(url: url))
        XCTAssertEqual(link.host, "personal-dev")
        XCTAssertEqual(link.port, 47_800)
        XCTAssertFalse(link.isExpired)

        let wrongIdentity = broker.process(MeshRequest(cmd: "pairing-redeem",
                                                        memberID: "another-broker",
                                                        payload: link.token))
        XCTAssertFalse(wrongIdentity.ok)
        XCTAssertEqual(wrongIdentity.error, "Broker identity mismatch")

        let accepted = broker.process(MeshRequest(cmd: "pairing-redeem",
                                                   memberID: link.brokerID,
                                                   payload: link.token))
        XCTAssertTrue(accepted.ok)
        let credentialData = try XCTUnwrap(accepted.payload?.data(using: .utf8))
        let credential = try JSONDecoder().decode(MeshPairingCredential.self, from: credentialData)
        XCTAssertEqual(credential.brokerID, link.brokerID)
        XCTAssertGreaterThanOrEqual(credential.controlToken.count, 32)

        let replay = broker.process(MeshRequest(cmd: "pairing-redeem",
                                                 memberID: link.brokerID,
                                                 payload: link.token))
        XCTAssertFalse(replay.ok)
        XCTAssertEqual(replay.error, "pairing code expired or already used")
    }

    func testReplyResolvesStableMessageAndPersistsSnapshot() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "dev", nick: "codex",
                                                 session: "session-codex", host: "mac")).ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "say", room: "dev", nick: "human",
                                                 text: "original context")).ok)
        let original = broker.process(MeshRequest(cmd: "history", room: "dev")).messages!.first!
        XCTAssertFalse(original.stableID.isEmpty)

        XCTAssertTrue(broker.process(MeshRequest(cmd: "say", room: "dev", memberID: "session-codex",
                                                 text: "answer", replyToID: original.stableID)).ok)
        let reply = broker.process(MeshRequest(cmd: "history", room: "dev")).messages!.last!
        XCTAssertEqual(reply.replyTo?.messageID, original.stableID)
        XCTAssertEqual(reply.replyTo?.from, "human")
        XCTAssertEqual(reply.replyTo?.preview, "original context")
    }

    func testSayCarriesOnlyPreviouslyStoredAttachmentMetadata() throws {
        let broker = MeshBroker()
        let attachment = MeshAttachment(id: UUID().uuidString, name: "design.pdf",
                                        mimeType: "application/pdf", byteSize: 3,
                                        sha256: String(repeating: "a", count: 64))
        let attachmentDirectory = MeshPaths.attachmentDirectory(attachment.id)
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: MeshPaths.attachmentData(attachment.id))
        try JSONEncoder().encode(attachment).write(to: MeshPaths.attachmentMetadata(attachment.id))

        let accepted = broker.process(MeshRequest(cmd: "say", room: "dev", nick: "human",
                                                  text: "review", attachments: [attachment]))
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(broker.process(MeshRequest(cmd: "history", room: "dev"))
            .messages?.last?.attachments, [attachment])

        var forged = attachment
        forged.byteSize = 4
        XCTAssertFalse(broker.process(MeshRequest(cmd: "say", room: "dev", nick: "human",
                                                  text: "bad", attachments: [forged])).ok)
    }

    func testRejoinReplacesAliasOnlyInsideThatRoom() {
        let broker = MeshBroker()
        _ = broker.process(MeshRequest(cmd: "join", room: "room-a", nick: "codex",
                                       session: "old-a", host: "mac", tmuxPane: "%1"))
        _ = broker.process(MeshRequest(cmd: "join", room: "room-b", nick: "codex",
                                       session: "stable-b", host: "mac", tmuxPane: "%2"))
        _ = broker.process(MeshRequest(cmd: "join", room: "room-a", nick: "codex",
                                       session: "new-a", host: "mac", tmuxPane: "%3"))

        let roster = broker.process(MeshRequest(cmd: "who")).members ?? []
        XCTAssertEqual(roster.first { $0.rooms == ["room-a"] }?.id, "new-a")
        XCTAssertEqual(roster.first { $0.rooms == ["room-b"] }?.id, "stable-b")
    }

    func testRenameMemberKeepsIdentityAndMailboxThenExactRemoveLeavesRoom() {
        let broker = MeshBroker()
        XCTAssertTrue(broker.process(MeshRequest(cmd: "join", room: "dev", nick: "office",
                                                 session: "stable-session", host: "air",
                                                 tmuxPane: "%7", kind: "claude")).ok)
        _ = broker.process(MeshRequest(cmd: "say", room: "dev", nick: "human",
                                       text: "before rename", to: ["office"]))

        let renamed = broker.process(MeshRequest(cmd: "rename-member", room: "dev", nick: "office",
                                                 memberID: "stable-session", text: "air"))
        XCTAssertTrue(renamed.ok)
        let roster = broker.process(MeshRequest(cmd: "who")).members ?? []
        XCTAssertNil(roster.first { $0.nick == "office" })
        XCTAssertEqual(roster.first { $0.nick == "air" }?.id, "stable-session")

        _ = broker.process(MeshRequest(cmd: "say", room: "dev", nick: "human",
                                       text: "after rename", to: ["air"]))
        let inbox = broker.process(MeshRequest(cmd: "recv", nick: "air", memberID: "stable-session"))
        XCTAssertEqual(inbox.messages?.map(\.text), ["before rename", "after rename"])

        let staleRemove = broker.process(MeshRequest(cmd: "leave", room: "dev", nick: "air",
                                                     memberID: "another-session"))
        XCTAssertFalse(staleRemove.ok)
        XCTAssertTrue(broker.process(MeshRequest(cmd: "leave", room: "dev", nick: "air",
                                                 memberID: "stable-session")).ok)
        XCTAssertTrue((broker.process(MeshRequest(cmd: "who")).members ?? []).isEmpty)
    }

    func testRenameMemberRejectsAnOccupiedNick() {
        let broker = MeshBroker()
        _ = broker.process(MeshRequest(cmd: "join", room: "dev", nick: "one", session: "session-1"))
        _ = broker.process(MeshRequest(cmd: "join", room: "dev", nick: "two", session: "session-2"))
        let response = broker.process(MeshRequest(cmd: "rename-member", room: "dev", nick: "one",
                                                  memberID: "session-1", text: "two"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(Set((broker.process(MeshRequest(cmd: "who")).members ?? []).map(\.nick)),
                       ["one", "two"])
    }

    func testSpawnedTmuxNameIsRoomScoped() {
        XCTAssertNotEqual(MeshSpawn.sessionName(room: "room-a", nick: "codex"),
                          MeshSpawn.sessionName(room: "room-b", nick: "codex"))
    }

    func testFormReasonStaysStickyWhileBlocked() {
        let broker = MeshBroker()
        _ = broker.process(MeshRequest(cmd: "join", room: "dev", nick: "bot", session: "sid"))

        func reason() -> String? {
            (broker.process(MeshRequest(cmd: "who")).members ?? [])
                .first(where: { $0.nick == "bot" })?.stateReason
        }
        // PreToolUse{AskUserQuestion} sets blocked(form:…).
        var form = MeshRequest(cmd: "mark", session: "sid", state: "blocked")
        form.stateReason = "form:AskUserQuestion"
        _ = broker.process(form)
        XCTAssertEqual(reason(), "form:AskUserQuestion")

        // The dialog's Notification{permission_prompt} must NOT clobber it.
        var perm = MeshRequest(cmd: "mark", session: "sid", state: "blocked")
        perm.stateReason = "permission"
        _ = broker.process(perm)
        XCTAssertEqual(reason(), "form:AskUserQuestion")

        // A non-blocked state clears the sticky form reason normally.
        _ = broker.process(MeshRequest(cmd: "mark", session: "sid", state: "busy"))
        XCTAssertNil(reason())
    }
}

final class MeshPaneProbeTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).txt")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The unknown-state pane probe: only a visibly idle composer passes.
    func testPaneIdleDetection() {
        XCTAssertTrue(MeshPaneSafety.paneLooksIdle("some output\n❯ \n  bypass permissions on"))
        XCTAssertTrue(MeshPaneSafety.paneLooksIdle("ready\n› "), "Codex composer is pokeable")
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle("✻ Cooking… (esc to interrupt)"))
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle("Working\n› "), "busy Codex must never be poked")
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle("Do you want to proceed?\n❯ 1. Yes\n 2. No"))
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle("❯ 1. Yes, I trust this folder\nEnter to confirm · Esc to cancel"))
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle("plain shell output, no composer"))
    }

    func testHistoricalBusyWordsDoNotPoisonCurrentComposer() {
        XCTAssertTrue(MeshPaneSafety.paneLooksIdle("""
        Both delivered. I checked messages while I was working, then returned to idle.
        ✻ Cogitated for 10m 41s
        ❯
        """))
        XCTAssertTrue(MeshPaneSafety.paneLooksIdle("""
        › previous request
        • Working (8s • esc to interrupt)
        ─ Worked for 12s ─
        ›
        """))
    }

    func testRealClaudeLongSessionWithQuotedBusyMarkerAndRandomCompletionVerbIsIdle() {
        XCTAssertTrue(MeshPaneSafety.paneLooksIdle("""
        Root cause: ordinary words like \"working\"/\"esc to interrupt\" saturate transcripts.
        Both v3 messages delivered. Returning to the idle composer.
        ✻ Baked for 12m 24s
        ❯ 保留横向台阶，scale 降到 1.0
        """))
    }

    func testCurrentBusyStatusStillBlocksPokeAfterQueuedComposerText() {
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle("""
        › previous request
        • Working (8s • esc to interrupt)
        › queued while busy
        tab to queue message
        """))
    }

    func testClaudeBootstrapSpinnerBlocksPokeEvenWithVisibleComposer() {
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle("""
        ❯ Join the room
        ✳ Bootstrapping… (1m 34s · ↓ 2.2k tokens)
        ❯
        """))
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle("""
        ❯ Do the work
        Running 6 shell commands…
        ❯
        """))
    }

    func testResolvedHistoricalConfirmationDoesNotBlockIdleComposer() {
        XCTAssertTrue(MeshPaneSafety.paneLooksIdle("""
        ❯ 1. Yes, I trust this folder
        Enter to confirm · Esc to cancel
        accepted
        ✻ Cogitated for 1s
        ❯
        """))
    }

    func testRealClaude212IdlePaneFixtureIsPokeable() throws {
        XCTAssertTrue(MeshPaneSafety.paneLooksIdle(try fixture("claude-2.1.212-idle")))
    }

    func testRealCodexBusyPaneFixtureIsNotPokeable() throws {
        XCTAssertFalse(MeshPaneSafety.paneLooksIdle(try fixture("codex-busy-with-queued-input")))
    }

    func testOnlyNativeWorkspaceTrustPromptsAreAutoConfirmable() {
        XCTAssertTrue(MeshPaneSafety.isKnownWorkspaceTrustPrompt("""
        ❯ 1. Yes, I trust this folder
        Enter to confirm · Esc to cancel
        """))
        XCTAssertTrue(MeshPaneSafety.isKnownWorkspaceTrustPrompt("""
        Do you trust the contents of this directory?
        › 1. Yes, continue
        Press enter to continue
        """))
        XCTAssertFalse(MeshPaneSafety.isKnownWorkspaceTrustPrompt("""
        Do you want to proceed?
        ❯ 1. Yes
        Enter to confirm · Esc to cancel
        """))
        XCTAssertFalse(MeshPaneSafety.isKnownWorkspaceTrustPrompt("Press enter to continue"))
    }
}

// MARK: - Native tab titles

final class WindowTabTitleTests: XCTestCase {
    func testContentAndTabTitlesAreDeliberatelyIndependent() {
        XCTAssertEqual(PharosViewTitle.dashboard, "Pharos")
        XCTAssertEqual(PharosViewTitle.rooms, "Chat Rooms")
        XCTAssertEqual(PharosViewTitle.project, "Project")
        XCTAssertEqual(PharosTabTitle.dashboard, "Dashboard")
        XCTAssertEqual(PharosTabTitle.room(""), "Chat Rooms")
        XCTAssertEqual(PharosTabTitle.room("team"), "team")
        XCTAssertEqual(PharosTabTitle.project("Lelantos"), "Lelantos")
    }

    @MainActor
    func testCoordinatorChangesTabLabelWithoutOverwritingWindowTitle() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = PharosViewTitle.rooms
        let view = NSView(frame: .zero)
        window.contentView = view
        let coordinator = WindowTabBar.Coordinator()

        coordinator.update(title: PharosTabTitle.room(""), from: view)
        coordinator.update(title: PharosTabTitle.room("team"), from: view)

        XCTAssertEqual(window.title, "Chat Rooms")
        XCTAssertEqual(window.tab.title, "team")
        XCTAssertEqual(window.titleVisibility, .hidden)
    }
}

final class LegacyPeerMigrationTests: XCTestCase {
    func testTailnetDiscoveryIncludesAllNodesAndMarksOfflineOnes() throws {
        let json = #"""
        {
          "Self": {"HostName":"Mac mini","DNSName":"mac-mini.example.ts.net.","TailscaleIPs":["100.0.0.1"],"Online":true,"OS":"macOS"},
          "Peer": {
            "linux": {"HostName":"ubuntu","DNSName":"personal-dev.example.ts.net.","TailscaleIPs":["100.0.0.2"],"Online":true,"OS":"linux"},
            "phone": {"HostName":"localhost","DNSName":"iphone.example.ts.net.","TailscaleIPs":["100.0.0.3"],"Online":true,"OS":"iOS"},
            "old": {"HostName":"old","DNSName":"old.example.ts.net.","TailscaleIPs":["100.0.0.4"],"Online":false,"OS":"linux"}
          }
        }
        """#
        let devices = PairingService.parseTailnetDevices(try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(devices.map(\.name), ["mac-mini", "iphone", "personal-dev", "old"])
        XCTAssertEqual(devices.map(\.os), ["macOS", "iOS", "linux", "linux"])
        XCTAssertTrue(devices[0].isThisMac)
        XCTAssertFalse(devices[1].isThisMac)
        XCTAssertTrue(devices[2].isOnline)
        XCTAssertFalse(devices[3].isOnline)
    }

    func testPeerDiscoveryKeepsOnlyOnlineMacs() {
        let status = """
        100.0.0.1  mac-mini      user@  macOS  -
        100.0.0.2  macbook-air   user@  macOS  active; direct
        100.0.0.3  old-mac       user@  macOS  offline, last seen 2d ago
        100.0.0.4  linux-box     user@  linux  -
        100.0.0.5  iphone        user@  iOS    -
        """
        XCTAssertEqual(PairingService.parsePeers(status, excluding: "100.0.0.1").map(\.ip),
                       ["100.0.0.2"])
    }

    func testMatchesExactReachableComputerNameWithoutGuessing() {
        let peers = [
            PairingService.Peer(name: "mac-mini", ip: "100.0.0.1"),
            PairingService.Peer(name: "macbook-air", ip: "100.0.0.2")
        ]
        let names = ["100.0.0.1": "Xiang's Mac mini", "100.0.0.2": "白富贵"]
        let match = PairingService.peer(matchingLegacyComputerName: "白富贵", among: peers) {
            names[$0.ip]
        }
        XCTAssertEqual(match?.ip, "100.0.0.2")
    }

    func testNoReachableExactMatchLeavesPairingUnset() {
        let peers = [PairingService.Peer(name: "macbook-air", ip: "100.0.0.2")]
        XCTAssertNil(PairingService.peer(matchingLegacyComputerName: "other", among: peers) { _ in "白富贵" })
        XCTAssertNil(PairingService.peer(matchingLegacyComputerName: "白富贵", among: peers) { _ in nil })
    }
}

final class MeshBroadcastTests: XCTestCase {
    /// Delivery model B: a directed message carries a non-empty `to`; a
    /// broadcast carries an empty `to`. The poke paths key on exactly this to
    /// tell "@you, wake up" from ambient room chatter.
    func testToDiscriminatesDirectedFromBroadcast() {
        let directed = MeshMsg(from: "alice", room: "r", text: "hi", ts: 1, to: ["bob"])
        let broadcast = MeshMsg(from: "alice", room: "r", text: "standup!", ts: 1, to: [])
        // "directed at bob" ⇔ bob ∈ to; broadcast is directed at nobody.
        XCTAssertTrue(directed.to.contains("bob"))
        XCTAssertFalse(broadcast.to.contains("bob"))
        // The mid-turn/poke filter (`to.contains(me)`) keeps only the directed one.
        let mailbox = [broadcast, directed]
        XCTAssertEqual(mailbox.filter { $0.to.contains("bob") }.map(\.text), ["hi"])
        // recv drains everything — bob still RECEIVES the broadcast.
        XCTAssertEqual(mailbox.count, 2)
    }
}

final class RemoteLaunchTmuxIdentityTests: XCTestCase {
    func testRemoteInteractiveShellFallsBackWhenForwardedTerminfoIsMissing() {
        let command = RemoteLaunch.terminalSafeRemoteShell("exec tmux attach -t '=agent'")

        XCTAssertTrue(command.contains(#"TERM="${TERM:-xterm-256color}""#))
        XCTAssertTrue(command.contains(#"infocmp "$TERM""#))
        XCTAssertTrue(command.contains("export TERM=xterm-256color"))
        XCTAssertTrue(command.hasSuffix("exec tmux attach -t '=agent'"))
    }

    func testParsesSocketFromTmuxEnvironment() {
        XCTAssertEqual(
            RemoteLaunch.tmuxSocket(fromEnvironmentValue: "/private/tmp/tmux-501/agent,1234,0"),
            "/private/tmp/tmux-501/agent"
        )
        XCTAssertNil(RemoteLaunch.tmuxSocket(fromEnvironmentValue: "relative/socket,1234,0"))
        XCTAssertNil(RemoteLaunch.tmuxSocket(fromEnvironmentValue: nil))
    }

    func testRemoteErrorSurfacesItsMessage() {
        let error = RemoteLaunch.RemoteError(message: "exact failure")
        XCTAssertEqual(error.localizedDescription, "exact failure")
    }

    func testLegacyRemoteSocketDiscoveryDeduplicatesAndRejectsRelativePaths() {
        let output = """
        /private/tmp/tmux-501/default
        relative/socket
        /private/tmp/tmux-501/agent
        /private/tmp/tmux-501/default
        """
        XCTAssertEqual(RemoteLaunch.legacySocketMatches(output), [
            "/private/tmp/tmux-501/agent",
            "/private/tmp/tmux-501/default"
        ])
    }
}
