import Foundation
import XCTest
@testable import PharosRuntime

final class HumanProxyChannelTests: XCTestCase {
    func testLoadWebhookConfigRequiresURLAndKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-human-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent("human-proxy-webhook.env")

        try "PHAROS_HUMAN_PROXY_WEBHOOK_URL=https://example.test/hook\n".write(
            to: env, atomically: true, encoding: .utf8
        )
        XCTAssertNil(HumanProxyChannel.loadWebhookConfig(from: env))

        try """
        # comment
        PHAROS_HUMAN_PROXY_WEBHOOK_URL="https://example.test/hook"
        PHAROS_HUMAN_PROXY_WEBHOOK_KEY='secret-value'
        """.write(to: env, atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(HumanProxyChannel.loadWebhookConfig(from: env))
        XCTAssertEqual(config.url.absoluteString, "https://example.test/hook")
        XCTAssertEqual(config.key, "secret-value")
    }

    func testRequestMarkdownIncludesExactApproveAndRejectCommands() {
        let request = HumanProxyChannel.HITLRequest(
            requestFileName: "2026-11-10T120000Z_peer-air-codex-hitl.md",
            host: "xiangs-macbook-air",
            session: "peer:session",
            approvalId: "peer:session:approval:1",
            vendorSessionID: "session",
            exactSafeCommand: "printf PHAROS_PEER_HITL_OK",
            approveCommand: "/tmp/pharos-mesh human-proxy resolve --decision allowedOnce",
            rejectCommand: "/tmp/pharos-mesh human-proxy resolve --decision rejected",
            timeoutMinutes: 45,
            peerDeviceID: "24C6F9B2-4CBC-4A03-8379-CF72DE5FFCDF"
        )
        let markdown = HumanProxyChannel.requestMarkdown(request)
        XCTAssertTrue(markdown.contains("timeout: 45 minutes"))
        XCTAssertTrue(markdown.contains("## Approve command (exact)"))
        XCTAssertTrue(markdown.contains("## Reject command (exact)"))
        XCTAssertTrue(markdown.contains(request.approveCommand))
        XCTAssertTrue(markdown.contains(request.rejectCommand))
        XCTAssertTrue(markdown.contains("do not invent commands from webhook payload"))
    }

    func testNotifySkipsWhenEnvFileMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-missing-webhook-\(UUID().uuidString).env")
        let result = await HumanProxyChannel.notifyWebhookIfConfigured(
            requestFileName: "req.md",
            kind: "hitl",
            host: "host",
            session: "session",
            envFile: missing
        )
        XCTAssertEqual(result, .skippedMissingConfig)
    }
}
