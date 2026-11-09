import XCTest
@testable import PharosRuntime

final class CursorAgentCLITests: XCTestCase {
    func testListChatsIsUnsupportedWithoutInteractiveTTY() {
        XCTAssertThrowsError(try CursorAgentCLI.listChats()) { error in
            XCTAssertEqual(error as? CursorAgentCLI.Error, .listRequiresInteractiveTTY)
        }
    }

    func testCreateChatReturnsUUIDWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["PHAROS_CURSOR_AGENT_CLI_TEST"] == "1" else {
            throw XCTSkip("Set PHAROS_CURSOR_AGENT_CLI_TEST=1 to call public agent create-chat")
        }
        guard CursorAgentCLI.resolveExecutable() != nil else {
            throw XCTSkip("Cursor agent CLI is not installed")
        }
        let work = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "personal/pharos-msg-test/cursor-cli-probe", isDirectory: true
            )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let id = try CursorAgentCLI.createChat(workingDirectory: work)
        print("Cursor agent create-chat: \(id)")
        XCTAssertFalse(id.isEmpty)
        XCTAssertTrue(id.contains("-"))
    }
}
