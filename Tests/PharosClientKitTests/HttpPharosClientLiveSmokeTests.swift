import Foundation
import XCTest
@testable import PharosClientKit

/// Live smoke against a running S4 `pharos-web` (or meshd HTTP).
/// Skips unless `PHAROS_SMOKE_BASE_URL` is set (e.g. http://127.0.0.1:18791,
/// fake mode). Never part of the ungated test run.
final class HttpPharosClientLiveSmokeTests: XCTestCase {
    private func liveClient() throws -> HttpPharosClientService {
        guard let raw = ProcessInfo.processInfo.environment["PHAROS_SMOKE_BASE_URL"],
              let base = URL(string: raw),
              !raw.isEmpty
        else {
            throw XCTSkip("Set PHAROS_SMOKE_BASE_URL to run live HTTP smoke")
        }
        return HttpPharosClientService(
            configuration: PharosAPIConfiguration(baseURL: base, backendKind: .rustAPI)
        )
    }

    func testListOpenReadThreadAndSession() async throws {
        let client = try liveClient()

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

    /// Wave-2 web endpoints round-trip: config, member settings/avatar,
    /// attachments, thread bindings, approvals and backend health.
    func testWave2WebEndpointsRoundTrip() async throws {
        let client = try liveClient()
        let stamp = Int(Date().timeIntervalSince1970)

        let probe = await client.probeBackend()
        guard case let .reachable(health) = probe else {
            return XCTFail("live backend probe must be reachable: \(probe)")
        }
        XCTAssertTrue(health.ok)
        let baseURL = await client.configuration.baseURL
        XCTAssertNil(
            PharosBackendDiagnostics.guidance(baseURL: baseURL, probe: probe)
        )

        let sessions = try await client.fetchSessions()
        let sessionId = try XCTUnwrap(sessions.first?.sessionId)

        // --- session configuration ---
        let configurationView = try await client.fetchSessionConfiguration(sessionId: sessionId)
        let configuration = try XCTUnwrap(configurationView)
        XCTAssertEqual(configuration.sessionId, sessionId)
        let supportsAttachments = await client.supportsSessionTextAttachments(sessionId: sessionId)
        XCTAssertEqual(supportsAttachments, configuration.capabilities.attachments)
        if configuration.supported, configuration.supportedFields.contains("mode"),
           let originalMode = configuration.mode {
            let target = originalMode == "safe" ? "yolo" : "safe"
            let updated = try await client.setSessionConfiguration(
                sessionId: sessionId,
                configId: "mode",
                value: target
            )
            XCTAssertEqual(updated.mode, target, "fake adapter applies session config writes")
            _ = try await client.setSessionConfiguration(
                sessionId: sessionId,
                configId: "mode",
                value: originalMode
            )
        }

        // --- stop / revive (reversible; capability-gated) ---
        if configuration.capabilities.stop, configuration.capabilities.revive {
            try await client.stopSession(sessionId: sessionId)
            try await client.reviveSession(sessionId: sessionId)
        }

        // --- member settings / avatar identity ---
        let member = try await client.fetchMemberDetail(name: "human")
        XCTAssertEqual(member.name, "human")
        try await client.setMemberMode(name: "human", mode: "safe")
        try await client.setMemberAvatar(
            name: "human",
            avatar: ClientAvatarInfo(seed: "human", shape: "cloud", color: "blue")
        )
        let updatedMember = try await client.fetchMemberDetail(name: "human")
        XCTAssertEqual(updatedMember.mode, "safe")
        XCTAssertEqual(updatedMember.avatarShape, "cloud")
        XCTAssertEqual(updatedMember.avatarColor, "blue")

        // --- attachments: upload then send with attachmentIds ---
        if configuration.capabilities.attachments {
            let payload = Data("swift client smoke \(stamp)".utf8)
            let turn = try await client.sendSessionMessage(
                sessionId: sessionId,
                text: "wave2 smoke attachment \(stamp)",
                files: [SessionFileUpload(name: "swift-smoke-\(stamp).txt", data: payload)],
                requestId: "swift-smoke-\(stamp)"
            )
            XCTAssertEqual(turn.sessionId, sessionId)
            let attachments = try await client.fetchSessionAttachments(sessionId: sessionId)
            let uploaded = try XCTUnwrap(
                attachments.first { $0.filename == "swift-smoke-\(stamp).txt" },
                "uploaded attachment must be listed"
            )
            XCTAssertEqual(uploaded.contentType, "text/plain")
            XCTAssertEqual(uploaded.sizeBytes, payload.count)
            let metadata = try await client.fetchAttachment(attachmentId: uploaded.attachmentId)
            XCTAssertEqual(metadata.attachmentId, uploaded.attachmentId)
            let content = try await client.fetchAttachmentContent(attachmentId: uploaded.attachmentId)
            XCTAssertEqual(content, payload)
        }

        // --- thread bindings ---
        let threads = try await client.fetchThreads()
        if let threadId = threads.first?.threadId {
            let supportsBinding = await client.supportsThreadSessionBinding()
            XCTAssertTrue(supportsBinding)
            let candidates = await client.threadSessionBindingCandidates()
            let liveSessions = try await client.fetchSessions()
            XCTAssertEqual(candidates.map(\.sessionId), liveSessions.map(\.sessionId))
            let nickname = "swift-smoke-\(stamp)"
            try await client.bindThreadSession(
                threadId: threadId,
                sessionId: sessionId,
                nickname: nickname
            )
            let boundMembers = try await client.fetchThreadMembers(threadId: threadId)
            XCTAssertEqual(
                boundMembers.first { $0.name == nickname }?.sessionId,
                sessionId,
                "thread member view must reflect the binding"
            )
            try await client.unbindThreadSession(threadId: threadId, member: nickname)
            let afterUnbind = try await client.fetchThreadMembers(threadId: threadId)
            XCTAssertNil(afterUnbind.first { $0.name == nickname })
        }

        // --- approvals snapshot (empty is a valid honest answer) ---
        if let approval = try await client.fetchSessionApproval(sessionId: sessionId) {
            XCTAssertEqual(approval.sessionId, sessionId)
            XCTAssertFalse(approval.approvalId.isEmpty)
        }
    }
}
