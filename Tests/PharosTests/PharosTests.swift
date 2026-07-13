import XCTest
import AppKit
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
        XCTAssertEqual(MeshHooks.stateFor(event: "SessionEnd", notificationType: nil), .gone)
        XCTAssertEqual(MeshHooks.stateFor(event: "Notification", notificationType: "permission_prompt"), .blocked)
        XCTAssertEqual(MeshHooks.stateFor(event: "Notification", notificationType: "elicitation_dialog"), .blocked)
        XCTAssertEqual(MeshHooks.stateFor(event: "Notification", notificationType: "idle_prompt"), .idle)
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
}

final class MeshPokeRouteTests: XCTestCase {

    override func setUp() { setenv("PHAROS_HOST", "test-mac", 1) }
    override func tearDown() { unsetenv("PHAROS_HOST") }

    private func member(pane: String?, host: String?) -> MeshMemberInfo {
        MeshMemberInfo(nick: "bot", project: "/tmp/x", session: "s", host: host,
                       tmuxPane: pane, state: "stopped", stateTs: 0, rooms: ["r"], lastSeen: 0)
    }

    func testLocalPane() {
        if case .local(let pane) = MeshPoke.route(for: member(pane: "%7", host: "test-mac"), peerHost: "peer") {
            XCTAssertEqual(pane, "%7")
        } else { XCTFail("expected .local") }
    }

    func testRemotePaneViaPeer() {
        if case .remote(let pane, let host) = MeshPoke.route(for: member(pane: "%2", host: "other-mac"), peerHost: "home-ts") {
            XCTAssertEqual(pane, "%2")
            XCTAssertEqual(host, "home-ts")   // SSH alias, not the presence host name
        } else { XCTFail("expected .remote") }
    }

    func testNoPaneIsUnpokeable() {
        if case .unpokeable = MeshPoke.route(for: member(pane: nil, host: "test-mac"), peerHost: "peer") {
        } else { XCTFail("expected .unpokeable without a pane") }
    }

    func testUnknownHostIsUnpokeable() {
        // Guessing a host would send keystrokes to the wrong machine.
        if case .unpokeable = MeshPoke.route(for: member(pane: "%1", host: nil), peerHost: "peer") {
        } else { XCTFail("expected .unpokeable without a host") }
    }

    func testRemoteWithoutPeerIsUnpokeable() {
        if case .unpokeable = MeshPoke.route(for: member(pane: "%1", host: "other-mac"), peerHost: "") {
        } else { XCTFail("expected .unpokeable without a paired peer") }
    }

    /// The nudge is typed into a live pane; if it ever hit a shell instead, it
    /// must stay inert — so no quoting/expansion metacharacters, ever.
    func testNudgeTextHasNoShellMetacharacters() {
        let text = MeshPoke.nudgeText(for: "agent-a.1_x")
        let forbidden = CharacterSet(charactersIn: "`$\"';|&<>(){}[]*?~#!")
        XCTAssertNil(text.unicodeScalars.first(where: { forbidden.contains($0) }),
                     "nudge text must be shell-inert: \(text)")
    }
}

final class MeshWireCompatTests: XCTestCase {

    /// Pre-0.4 presence entries (no host/pane/state keys) must keep decoding —
    /// same tolerance rule as the registry itself.
    func testOldPresenceEntryDecodes() throws {
        let old = #"{"v":1,"nicks":{"bot":{"project":"/tmp/x","rooms":["r"],"lastSeen":1.0,"online":true}}}"#
        let p = try JSONDecoder().decode(MeshPresence.self, from: Data(old.utf8))
        XCTAssertEqual(p.nicks["bot"]?.rooms, ["r"])
        XCTAssertNil(p.nicks["bot"]?.tmuxPane)
        XCTAssertNil(p.nicks["bot"]?.state)
    }

    /// Text-mention parsing feeds both the GUI input and CLI say — the poke
    /// pipeline's very first step.
    func testParseTextMentions() {
        XCTAssertEqual(MeshHooks.parseTextMentions("@alice check the PR with @bob, @alice!"), ["alice", "bob"])
        XCTAssertEqual(MeshHooks.parseTextMentions("no mentions here"), [])
    }
}

final class MeshPokePaneCommandTests: XCTestCase {
    private func result(_ out: String) -> Shell.Result { Shell.Result(out: out, err: "", code: 0) }

    /// Claude Code's pane command is claude/node/bun — or a bare version number
    /// ("2.1.207") on current installs, where the launcher execs a versioned
    /// binary (observed live 2026-07-11).
    func testAcceptedPaneCommands() {
        for ok in ["claude", "node", "bun", "2.1.207", "10.0.1",
                   "codex", "codex-aarch64-apple-darwin"] {
            XCTAssertTrue(MeshPoke.paneRunsAgent(result(ok)), ok)
        }
        for bad in ["zsh", "bash", "vim", "2.1", "2.1.207-beta", "python3.11"] {
            XCTAssertFalse(MeshPoke.paneRunsAgent(result(bad)), bad)
        }
    }

    func testCodexStaleBusyRequiresProbeButClaudeBusyRefuses() {
        func member(kind: AgentKind, state: String?) -> MeshMemberInfo {
            MeshMemberInfo(nick: "bot", project: "/tmp", session: "s", host: "mac",
                           tmuxPane: "%1", state: state, stateTs: 1, kind: kind.rawValue,
                           rooms: ["r"], lastSeen: 1)
        }
        XCTAssertEqual(MeshPoke.probeRequirement(for: member(kind: .codex, state: "busy")), true)
        XCTAssertNil(MeshPoke.probeRequirement(for: member(kind: .claude, state: "busy")))
        XCTAssertEqual(MeshPoke.probeRequirement(for: member(kind: .codex, state: "stopped")), false)
        XCTAssertEqual(MeshPoke.probeRequirement(for: member(kind: .codex, state: nil)), true)
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

    private func writePresence(_ nicks: [String: MeshPresenceEntry]) throws {
        let d = try JSONEncoder().encode(MeshPresence(v: 1, nicks: nicks))
        try d.write(to: dir.appendingPathComponent("mesh-state/presence.json"))
    }

    private func entry(project: String?, session: String?) -> MeshPresenceEntry {
        MeshPresenceEntry(project: project, session: session, host: nil, tmuxPane: nil,
                          state: nil, stateTs: nil, rooms: ["r"], lastSeen: 1, online: true)
    }

    /// The identity rule (2026-07-11): an entry that declared a session id is
    /// NEVER claimed via the cwd fallback by a hook carrying a different
    /// session. Regression guard for the live hijack: a nick joined from $HOME
    /// was cwd-matched by every unregistered session on the host, which stole
    /// its unread notices and pinned its state busy.
    func testForeignSessionCannotClaimByCwdPrefix() throws {
        try writePresence(["kid": entry(project: "/Users/u", session: "kid-sid")])
        XCTAssertNil(MeshHooks.resolveNick(cwd: "/Users/u/some/other/project", session: "stranger-sid"))
        XCTAssertNil(MeshHooks.resolveNick(cwd: "/Users/u", session: nil))
        // The declared session itself still resolves exactly.
        XCTAssertEqual(MeshHooks.resolveNick(cwd: "/anywhere", session: "kid-sid"), "kid")
    }

    /// Session-less joins (legacy cwd-only) keep the old prefix behavior.
    func testSessionlessEntryStillResolvesByCwd() throws {
        try writePresence(["olde": entry(project: "/Users/u/proj", session: nil)])
        XCTAssertEqual(MeshHooks.resolveNick(cwd: "/Users/u/proj/sub", session: "any-sid"), "olde")
        XCTAssertNil(MeshHooks.resolveNick(cwd: "/Users/u/elsewhere", session: nil))
    }
}

final class MeshPaneProbeTests: XCTestCase {
    /// The unknown-state pane probe: only a visibly idle composer passes.
    func testPaneIdleDetection() {
        XCTAssertTrue(MeshPoke.paneLooksIdle("some output\n❯ \n  bypass permissions on"))
        XCTAssertTrue(MeshPoke.paneLooksIdle("ready\n› "), "Codex composer is pokeable")
        XCTAssertFalse(MeshPoke.paneLooksIdle("✻ Cooking… (esc to interrupt)"))
        XCTAssertFalse(MeshPoke.paneLooksIdle("Working\n› "), "busy Codex must never be poked")
        XCTAssertFalse(MeshPoke.paneLooksIdle("Do you want to proceed?\n❯ 1. Yes\n 2. No"))
        XCTAssertFalse(MeshPoke.paneLooksIdle("❯ 1. Yes, I trust this folder\nEnter to confirm · Esc to cancel"))
        XCTAssertFalse(MeshPoke.paneLooksIdle("plain shell output, no composer"))
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
