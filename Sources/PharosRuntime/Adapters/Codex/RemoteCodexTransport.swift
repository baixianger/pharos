import Foundation
import PharosClientKit

/// A private SSH forwarding process to a configured host's existing Codex daemon.
/// The process owns only its uniquely named local socket; it never starts a remote daemon.
public final class RemoteCodexTransport: CodexTransport, @unchecked Sendable {
    private let process: Process?
    private let sharedConnection: SharedSSHConnection?
    private let forwardSpecification: String?
    private let socketURL: URL
    private let transport: CodexDaemonUdsTransport
    private let prefix: String

    public init(destination: String, hostID: String, connection: SharedSSHConnection? = nil) throws {
        guard !destination.isEmpty, !destination.hasPrefix("-"), !destination.contains("\n") else {
            throw PharosClientError.operationFailed("Invalid SSH destination")
        }
        let query = Process()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let queryCommand = #"printf '%s' "${CODEX_HOME:-$HOME/.codex}""#
        query.arguments = try connection?.commandArguments(queryCommand)
            ?? ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", destination, queryCommand]
        let output = Pipe()
        query.standardOutput = output
        query.standardError = FileHandle.nullDevice
        try query.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        query.waitUntilExit()
        let home = String(decoding: data, as: UTF8.self)
        guard query.terminationStatus == 0, home.hasPrefix("/"), !home.contains(":"),
              !home.contains("\n"), home.utf8.count < 500 else {
            throw PharosClientError.backendUnreachable(backend: "codex", reason: "Could not locate remote Codex home")
        }
        let remote = home + "/app-server-control/app-server-control.sock"
        let directory = URL(fileURLWithPath: "/tmp/pharos-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let local = directory.appendingPathComponent("codex.sock")
        let specification = "\(local.path):\(remote)"
        let tunnel = Process()
        tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        if let connection {
            tunnel.arguments = try connection.forwardArguments(operation: "forward", specification: specification)
        } else {
            tunnel.arguments = ["-N", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                                "-o", "ExitOnForwardFailure=yes", "-L", specification, "--", destination]
        }
        tunnel.standardOutput = FileHandle.nullDevice
        tunnel.standardError = FileHandle.nullDevice
        do { try tunnel.run() }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        if connection != nil { tunnel.waitUntilExit() }
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: local.path), (connection?.isRunning ?? tunnel.isRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard (connection?.isRunning ?? tunnel.isRunning), (connection == nil || tunnel.terminationStatus == 0),
              FileManager.default.fileExists(atPath: local.path) else {
            if tunnel.isRunning { tunnel.terminate() }
            try? FileManager.default.removeItem(at: directory)
            throw PharosClientError.backendUnreachable(backend: "codex", reason: "Could not open the remote SSH tunnel")
        }
        self.process = connection == nil ? tunnel : nil
        self.sharedConnection = connection
        self.forwardSpecification = connection == nil ? nil : specification
        self.socketURL = local
        self.prefix = Self.prefix(hostID)
        self.transport = CodexDaemonUdsTransport(socketPath: local.path)
    }

    public static func prefix(_ hostID: String) -> String {
        "remote:" + Data(hostID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "") + ":codex:"
    }

    public var connectionGeneration: UInt64 { transport.connectionGeneration }

    public func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await callWithGeneration(method: method, params: params, expectedGeneration: nil).payload
    }

    public func callWithGeneration(method: String, params: [String: Any], expectedGeneration: UInt64?) async throws -> CodexCallResult {
        guard sharedConnection?.isRunning ?? (process?.isRunning == true) else { throw PharosClientError.backendUnreachable(backend: "codex", reason: "Remote SSH tunnel closed") }
        var raw = params
        if let id = raw["threadId"] as? String {
            guard id.hasPrefix(prefix) else { throw PharosClientError.operationFailed("Remote session belongs to another host") }
            raw["threadId"] = String(id.dropFirst(prefix.count))
        }
        let response = try await transport.callWithGeneration(method: method, params: raw, expectedGeneration: expectedGeneration)
        var result = response.payload
        if method == "thread/list" {
            for key in ["data", "threads"] {
                if let entries = result[key] as? [[String: Any]] {
                    result[key] = entries.map { entry in
                        var entry = entry
                        if let id = entry["id"] as? String { entry["id"] = prefix + id }
                        return entry
                    }
                }
            }
        }
        if method == "thread/read", var thread = result["thread"] as? [String: Any], let id = thread["id"] as? String {
            thread["id"] = prefix + id
            result["thread"] = thread
        }
        return CodexCallResult(payload: result, connectionGeneration: response.connectionGeneration)
    }

    public func observeEvents() -> AsyncStream<BackendWireEvent> {
        let source = transport.observeEvents()
        let prefix = prefix
        return AsyncStream { continuation in
            let task = Task {
                for await event in source {
                    var payload = event.payload
                    guard var params = payload["params"] as? [String: Any], let id = params["threadId"] as? String else { continue }
                    params["threadId"] = prefix + id
                    payload["params"] = params
                    continuation.yield(BackendWireEvent(payload, connectionGeneration: event.connectionGeneration))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func respond(requestID: CodexRequestID, result: [String: Any]) async throws {
        try await transport.respond(requestID: requestID, result: result)
    }

    public func respond(requestID: CodexRequestID, result: [String: Any], expectedGeneration: UInt64) async throws {
        try await transport.respond(requestID: requestID, result: result, expectedGeneration: expectedGeneration)
    }

    public func close() {
        transport.close()
        if process?.isRunning == true { process?.terminate() }
        if let sharedConnection, let forwardSpecification,
           let arguments = try? sharedConnection.forwardArguments(operation: "cancel", specification: forwardSpecification) {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            command.arguments = arguments
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            if (try? command.run()) != nil { command.waitUntilExit() }
        }
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
    deinit { close() }
}
