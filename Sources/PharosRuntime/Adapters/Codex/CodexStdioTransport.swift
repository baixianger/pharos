import Foundation
import PharosClientKit

/// An app-owned Codex app-server connection. The process, not a passive daemon
/// observer, owns server requests issued for turns started on this connection.
public final class CodexStdioTransport: CodexTransport, @unchecked Sendable {
    private actor Handshake {
        private var task: Task<Void, Error>?
        func ensure(_ child: AgyAcpProcessTransport) async throws {
            if let task { return try await task.value }
            let next = Task {
                _ = try await child.sendRequest(method: "initialize", params: [
                    "clientInfo": ["name": "pharos", "version": "1"],
                    "capabilities": ["experimentalApi": true]
                ])
                try child.notify(method: "initialized")
            }
            task = next
            do { try await next.value }
            catch { task = nil; throw error }
        }
    }

    private let child: AgyAcpProcessTransport
    private let handshake = Handshake()

    public init(executableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/codex"), arguments: [String] = ["app-server"]) {
        child = AgyAcpProcessTransport(executableURL: executableURL, arguments: arguments, backendName: "codex")
    }

    public func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await handshake.ensure(child)
        return try await child.sendRequest(method: method, params: params).payload
    }

    public func observeEvents() -> AsyncStream<BackendWireEvent> { child.observeEvents() }

    public func respond(requestID: CodexRequestID, result: [String: Any]) async throws {
        try child.respondJSONRPC(requestID: requestID.wireValue, result: result)
    }

    public func close() { child.close() }
    deinit { close() }
}
