import Foundation
import XCTest
@testable import PharosClientKit

/// Live smoke against a running S4 `pharos-web` (or meshd HTTP).
/// Skips unless `PHAROS_SMOKE_BASE_URL` is set (e.g. http://127.0.0.1:18787).
final class HttpPharosClientLiveSmokeTests: XCTestCase {
    func testListOpenReadThreadAndSession() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PHAROS_SMOKE_BASE_URL"],
              let base = URL(string: raw),
              !raw.isEmpty
        else {
            throw XCTSkip("Set PHAROS_SMOKE_BASE_URL to run live HTTP smoke")
        }

        let client = HttpPharosClientService(
            configuration: PharosAPIConfiguration(baseURL: base, backendKind: .rustAPI)
        )

        let health = try await client.fetchHealth()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.contractsVersion, "0.1.0")

        let threads = try await client.fetchThreads()
        XCTAssertFalse(threads.isEmpty, "expected at least one thread from fake/live service")
        let threadId = try XCTUnwrap(threads.first?.threadId)
        let messages = try await client.fetchThreadMessages(threadId: threadId)
        XCTAssertFalse(messages.isEmpty, "expected seed/read messages for \(threadId)")

        let sessions = try await client.fetchSessions()
        XCTAssertFalse(sessions.isEmpty, "expected at least one session")
        let sessionId = try XCTUnwrap(sessions.first?.sessionId)
        // Open + one read (history may be empty before send; send then re-read).
        _ = try await client.fetchSessionHistory(sessionId: sessionId)
        let turn = try await client.sendSessionMessage(
            sessionId: sessionId,
            text: "s6-swift-client smoke \(Int(Date().timeIntervalSince1970))"
        )
        XCTAssertEqual(turn.sessionId, sessionId)
        let history = try await client.fetchSessionHistory(sessionId: sessionId)
        XCTAssertTrue(history.contains(where: { $0.turnId == turn.turnId }))
    }
}
