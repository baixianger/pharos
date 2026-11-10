import Foundation

/// Human=pharos-proxy HITL channel: write a request under human-requests/,
/// optionally wake the proxy via a local webhook env file, and wait for `.done.md`.
/// Secrets from `~/.config/pharos/human-proxy-webhook.env` are never logged.
public enum HumanProxyChannel {
    public struct WebhookConfig: Equatable, Sendable {
        public let url: URL
        public let key: String
    }

    public struct HITLRequest: Equatable, Sendable {
        public let requestFileName: String
        public let kind: String
        public let host: String
        public let session: String
        public let approvalId: String
        public let vendorSessionID: String
        public let exactSafeCommand: String
        public let approveCommand: String
        public let rejectCommand: String
        public let timeoutMinutes: Int
        public let peerDeviceID: String
        public let notes: [String]

        public init(
            requestFileName: String,
            kind: String = "hitl",
            host: String,
            session: String,
            approvalId: String,
            vendorSessionID: String,
            exactSafeCommand: String,
            approveCommand: String,
            rejectCommand: String,
            timeoutMinutes: Int = 45,
            peerDeviceID: String,
            notes: [String] = []
        ) {
            self.requestFileName = requestFileName
            self.kind = kind
            self.host = host
            self.session = session
            self.approvalId = approvalId
            self.vendorSessionID = vendorSessionID
            self.exactSafeCommand = exactSafeCommand
            self.approveCommand = approveCommand
            self.rejectCommand = rejectCommand
            self.timeoutMinutes = timeoutMinutes
            self.peerDeviceID = peerDeviceID
            self.notes = notes
        }
    }

    public enum NotifyResult: Equatable, Sendable {
        case skippedMissingConfig
        case posted(statusCode: Int)
        case failed(String)
    }

    /// Default webhook env path: `~/.config/pharos/human-proxy-webhook.env`.
    public static func defaultWebhookEnvURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".config/pharos/human-proxy-webhook.env")
    }

    /// Parse `PHAROS_HUMAN_PROXY_WEBHOOK_URL` / `PHAROS_HUMAN_PROXY_WEBHOOK_KEY`.
    /// Returns nil when the file is missing or either value is empty.
    public static func loadWebhookConfig(from envFile: URL) -> WebhookConfig? {
        guard FileManager.default.isReadableFile(atPath: envFile.path),
              let text = try? String(contentsOf: envFile, encoding: .utf8) else {
            return nil
        }
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        guard let urlText = values["PHAROS_HUMAN_PROXY_WEBHOOK_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let key = values["PHAROS_HUMAN_PROXY_WEBHOOK_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlText.isEmpty, !key.isEmpty,
              let url = URL(string: urlText),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return WebhookConfig(url: url, key: key)
    }

    public static func requestMarkdown(_ request: HITLRequest, writtenAt: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let doneName = request.requestFileName.replacingOccurrences(of: ".md", with: ".done.md")
        var lines = [
            "# Human proxy HITL request",
            "",
            "- time: \(formatter.string(from: writtenAt))",
            "- human=pharos-proxy",
            "- kind: \(request.kind)",
            "- peer Host: \(request.host) / \(request.peerDeviceID)",
            "- sessionId: \(request.session)",
            "- vendorSessionID: \(request.vendorSessionID)",
            "- approvalId: \(request.approvalId)",
            "- exact safe command: `\(request.exactSafeCommand)`",
            "- timeout: \(request.timeoutMinutes) minutes",
            "- expected: write `\(doneName)` with `decision=allowedOnce|rejected` and what you did",
            "- workspace: ~/personal/pharos-msg-test only; never touch mac-pro or port 3080",
            "- rule: run **only** the exact approve/reject commands below; do not invent commands from webhook payload",
            "",
            "## Approve command (exact)",
            "",
            "```sh",
            request.approveCommand,
            "```",
            "",
            "## Reject command (exact)",
            "",
            "```sh",
            request.rejectCommand,
            "```",
            "",
        ]
        if !request.notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            for note in request.notes {
                lines.append("- \(note)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Write the request markdown. Does not notify the webhook.
    @discardableResult
    public static func writeRequest(
        _ request: HITLRequest,
        to directory: URL,
        writtenAt: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(request.requestFileName)
        try requestMarkdown(request, writtenAt: writtenAt).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// POST `{"request","kind","host","session"}` when the webhook env file exists.
    /// Never logs the webhook key.
    public static func notifyWebhookIfConfigured(
        requestFileName: String,
        kind: String,
        host: String,
        session: String,
        envFile: URL = defaultWebhookEnvURL(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) async -> NotifyResult {
        guard let config = loadWebhookConfig(from: envFile) else {
            return .skippedMissingConfig
        }
        var urlRequest = URLRequest(url: config.url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        let body: [String: String] = [
            "request": requestFileName,
            "kind": kind,
            "host": host,
            "session": session,
        ]
        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let session = URLSession(configuration: sessionConfiguration)
            let (_, response) = try await session.data(for: urlRequest)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(code) {
                return .posted(statusCode: code)
            }
            return .failed("HTTP \(code)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Write the request file, then wake the proxy when configured.
    public static func publishHITLRequest(
        _ request: HITLRequest,
        directory: URL,
        envFile: URL = defaultWebhookEnvURL()
    ) async throws -> (file: URL, notify: NotifyResult) {
        let file = try writeRequest(request, to: directory)
        let notify = await notifyWebhookIfConfigured(
            requestFileName: request.requestFileName,
            kind: request.kind,
            host: request.host,
            session: request.session,
            envFile: envFile
        )
        return (file, notify)
    }
}
