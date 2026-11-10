import Foundation
import PharosClientKit

/// One privately owned SSH connection; independent commands and forwards share
/// its control socket without changing the user's SSH configuration.
public final class SharedSSHConnection: @unchecked Sendable {
    public let destination: String
    private let directory: URL
    private let process: Process
    private let input: Pipe
    private let lock = NSLock()
    private var closed = false

    public init(destination: String, timeout: TimeInterval = 8) throws {
        guard !destination.isEmpty, !destination.hasPrefix("-"), !destination.contains("\n"), !destination.contains("\r") else {
            throw PharosClientError.operationFailed("Invalid SSH destination")
        }
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pharos-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-M", "-S", directory.appendingPathComponent("control").path,
                             "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "BatchMode=yes",
                             "-o", "ConnectTimeout=5", "-T", "--", destination, "cat >/dev/null"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let deadline = Date().addingTimeInterval(timeout)
        let socket = directory.appendingPathComponent("control").path
        while process.isRunning && !FileManager.default.fileExists(atPath: socket) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard process.isRunning, FileManager.default.fileExists(atPath: socket) else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
            throw PharosClientError.backendUnreachable(backend: "ssh", reason: "Could not establish shared SSH connection")
        }
        self.destination = destination
        self.directory = directory
        self.process = process
        self.input = input
    }

    public var isRunning: Bool { lock.withLock { !closed && process.isRunning } }

    /// Arguments for a child ssh command. The caller retains this object for the
    /// entire child lifetime so the connection cannot be closed prematurely.
    public func commandArguments(_ remoteCommand: String) throws -> [String] {
        try lock.withLock {
            guard !closed, process.isRunning else {
                throw PharosClientError.backendUnreachable(backend: "ssh", reason: "Shared SSH connection closed")
            }
            return ["-S", directory.appendingPathComponent("control").path, "-o", "BatchMode=yes",
                    "-o", "ProxyCommand=/usr/bin/false", "-T", "--", destination, remoteCommand]
        }
    }

    /// Request an SSH forwarding operation on this connection. Forward specs are
    /// constructed by the caller; SSH reports refusal as a nonzero exit status.
    public func forwardArguments(operation: String, specification: String) throws -> [String] {
        guard operation == "forward" || operation == "cancel", !specification.contains("\n") else {
            throw PharosClientError.operationFailed("Invalid SSH forwarding request")
        }
        return try lock.withLock {
            guard !closed, process.isRunning else {
                throw PharosClientError.backendUnreachable(backend: "ssh", reason: "Shared SSH connection closed")
            }
            return ["-S", directory.appendingPathComponent("control").path, "-O", operation, "-L", specification, "--", destination]
        }
    }

    /// Wait only for this owned SSH child to exit before replacing it. Some
    /// hosts reject a new connection until the prior network session is gone.
    public func waitUntilStopped(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !process.isRunning
    }

    public func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        try? input.fileHandleForWriting.close()
        let process = process, directory = directory
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().async {
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    deinit { close() }
}
