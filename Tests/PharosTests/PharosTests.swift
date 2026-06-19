import XCTest
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
