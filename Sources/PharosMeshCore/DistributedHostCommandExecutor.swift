import Foundation
import PharosMeshProtocol
import PharosMeshReplica

/// Host-private routing metadata. Controllers address only the opaque resource
/// ID and generation; they cannot choose a tmux socket or session in payloads.
public struct DistributedHostResourceBinding: Codable, Equatable, Sendable {
    public static let version = 1

    public var schemaVersion: Int
    public var resourceID: String
    public var tmuxSession: String
    public var tmuxSocket: String?

    public init(resourceID: MeshResourceID, tmuxSession: String, tmuxSocket: String?) throws {
        guard Self.validSession(tmuxSession), Self.validSocket(tmuxSocket) else {
            throw DistributedHostExecutorError.invalidBinding
        }
        schemaVersion = Self.version
        self.resourceID = resourceID.rawValue
        self.tmuxSession = tmuxSession
        self.tmuxSocket = tmuxSocket
    }

    public func validate(for resourceID: MeshResourceID) throws {
        guard schemaVersion == Self.version, self.resourceID == resourceID.rawValue,
              Self.validSession(tmuxSession), Self.validSocket(tmuxSocket) else {
            throw DistributedHostExecutorError.invalidBinding
        }
    }

    private static func validSession(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validSocket(_ value: String?) -> Bool {
        guard let value else { return true }
        guard value.hasPrefix("/"), value.utf8.count <= 1_024 else { return false }
        return !URL(fileURLWithPath: value).pathComponents.contains("..")
    }
}

public struct DistributedHostResourceBindings: Sendable {
    public let directory: URL

    public init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("host-resources-v1", isDirectory: true)
    }

    public func save(_ binding: DistributedHostResourceBinding, for resourceID: MeshResourceID) throws {
        try binding.validate(for: resourceID)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = fileURL(for: resourceID)
        try JSONEncoder().encode(binding).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path
        )
    }

    public func load(_ resourceID: MeshResourceID) throws -> DistributedHostResourceBinding {
        let binding = try JSONDecoder().decode(
            DistributedHostResourceBinding.self,
            from: Data(contentsOf: fileURL(for: resourceID))
        )
        try binding.validate(for: resourceID)
        return binding
    }

    public func remove(_ resourceID: MeshResourceID) throws {
        let file = fileURL(for: resourceID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(for resourceID: MeshResourceID) -> URL {
        let name = resourceID.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json", isDirectory: false)
    }
}

public struct DistributedHostPokePayload: Codable, Sendable {
    public var text: String

    public init(text: String) { self.text = text }

    public func validate() throws {
        guard !text.isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DistributedHostExecutorError.invalidPayload
        }
    }
}

public struct DistributedHostCommandExecutor: Sendable {
    public let bindings: DistributedHostResourceBindings

    public init(bindings: DistributedHostResourceBindings) {
        self.bindings = bindings
    }

    /// Wake a Host-local coding session with a fixed product-authored prompt.
    /// Remote callers must still use a signed host command; this entry point is
    /// for the owning Pharos process after it has verified local idle presence.
    public func pokeLocal(
        resourceID: MeshResourceID, text: String
    ) async -> MeshHostCommandExecutionOutcome {
        do {
            let payload = DistributedHostPokePayload(text: text)
            try payload.validate()
            let binding = try bindings.load(resourceID)
            try await poke(binding: binding, text: text)
            return .executed(Data("poke-ok".utf8))
        } catch let error as DistributedHostExecutorError {
            return .failed(code: error.failureCode)
        } catch {
            return .failed(code: "host-execution-failed")
        }
    }

    /// Runs an interactive tmux client for a resource owned by this Host. SSH
    /// callers provide only the opaque resource ID; the private socket/session
    /// binding never leaves the Host.
    public func attachLocal(resourceID: MeshResourceID) throws -> Int32 {
        let binding = try bindings.load(resourceID)
        let executable = try tmuxExecutable()
        if let socket = binding.tmuxSocket {
            let attributes = try FileManager.default.attributesOfItem(atPath: socket)
            guard attributes[.type] as? FileAttributeType == .typeSocket else {
                throw DistributedHostExecutorError.tmuxSocketUnavailable
            }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = (binding.tmuxSocket.map { ["-S", $0] } ?? []) + [
            "attach-session", "-d", "-t", "=\(binding.tmuxSession)",
        ]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func execute(_ command: MeshHostCommand) async -> MeshHostCommandExecutionOutcome {
        do {
            let binding = try bindings.load(command.resourceID)
            let executable = try tmuxExecutable()
            switch command.action {
            case .poke:
                let payload = try JSONDecoder().decode(
                    DistributedHostPokePayload.self, from: command.payload
                )
                try payload.validate()
                try await poke(executable: executable, binding: binding, text: payload.text)
                return .executed(Data("poke-ok".utf8))
            case .stop:
                guard command.payload.isEmpty else {
                    throw DistributedHostExecutorError.invalidPayload
                }
                try runTmux(
                    executable, binding: binding,
                    arguments: ["kill-session", "-t", "=\(binding.tmuxSession)"]
                )
                return .executed(Data("stop-ok".utf8))
            default:
                return .failed(code: "action-not-implemented")
            }
        } catch let error as DistributedHostExecutorError {
            return .failed(code: error.failureCode)
        } catch {
            return .failed(code: "host-execution-failed")
        }
    }

    private func poke(
        binding: DistributedHostResourceBinding, text: String
    ) async throws {
        try await poke(executable: tmuxExecutable(), binding: binding, text: text)
    }

    private func poke(
        executable: URL, binding: DistributedHostResourceBinding, text: String
    ) async throws {
        try runTmux(
            executable, binding: binding,
            // `send-keys` resolves a pane target. The trailing colon turns the
            // exact session match into its active pane.
            arguments: ["send-keys", "-t", "=\(binding.tmuxSession):", "-l", "--", text]
        )
        // Full-screen coding-agent TUIs need one render turn before Enter;
        // sending both back-to-back can leave the text sitting in the composer.
        try await Task.sleep(for: .milliseconds(350))
        try runTmux(
            executable, binding: binding,
            arguments: ["send-keys", "-t", "=\(binding.tmuxSession):", "Enter"]
        )
    }

    private func tmuxExecutable() throws -> URL {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw DistributedHostExecutorError.tmuxUnavailable
        }
        return URL(fileURLWithPath: path)
    }

    private func runTmux(
        _ executable: URL, binding: DistributedHostResourceBinding,
        arguments: [String]
    ) throws {
        if let socket = binding.tmuxSocket {
            let attributes = try FileManager.default.attributesOfItem(atPath: socket)
            guard attributes[.type] as? FileAttributeType == .typeSocket else {
                throw DistributedHostExecutorError.tmuxSocketUnavailable
            }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = (binding.tmuxSocket.map { ["-S", $0] } ?? []) + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DistributedHostExecutorError.tmuxCommandFailed
        }
    }
}

public enum DistributedHostExecutorError: Error {
    case invalidBinding
    case invalidPayload
    case tmuxUnavailable
    case tmuxSocketUnavailable
    case tmuxCommandFailed

    public var failureCode: String {
        switch self {
        case .invalidBinding: "invalid-host-binding"
        case .invalidPayload: "invalid-command-payload"
        case .tmuxUnavailable: "tmux-unavailable"
        case .tmuxSocketUnavailable: "tmux-socket-unavailable"
        case .tmuxCommandFailed: "tmux-command-failed"
        }
    }
}
