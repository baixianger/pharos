import Foundation
import PharosMeshCore

/// Host-private routing metadata. Controllers address only the opaque resource
/// ID and generation; they cannot choose a tmux socket or session in payloads.
struct DistributedHostResourceBinding: Codable, Equatable, Sendable {
    static let version = 1

    var schemaVersion: Int
    var resourceID: String
    var tmuxSession: String
    var tmuxSocket: String?

    init(resourceID: MeshResourceID, tmuxSession: String, tmuxSocket: String?) throws {
        guard Self.validSession(tmuxSession), Self.validSocket(tmuxSocket) else {
            throw DistributedHostExecutorError.invalidBinding
        }
        schemaVersion = Self.version
        self.resourceID = resourceID.rawValue
        self.tmuxSession = tmuxSession
        self.tmuxSocket = tmuxSocket
    }

    func validate(for resourceID: MeshResourceID) throws {
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

struct DistributedHostResourceBindings: Sendable {
    let directory: URL

    init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("host-resources-v1", isDirectory: true)
    }

    func save(_ binding: DistributedHostResourceBinding, for resourceID: MeshResourceID) throws {
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

    func load(_ resourceID: MeshResourceID) throws -> DistributedHostResourceBinding {
        let binding = try JSONDecoder().decode(
            DistributedHostResourceBinding.self,
            from: Data(contentsOf: fileURL(for: resourceID))
        )
        try binding.validate(for: resourceID)
        return binding
    }

    func remove(_ resourceID: MeshResourceID) throws {
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

struct DistributedHostPokePayload: Codable, Sendable {
    var text: String

    func validate() throws {
        guard !text.isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DistributedHostExecutorError.invalidPayload
        }
    }
}

struct DistributedHostCommandExecutor: Sendable {
    let bindings: DistributedHostResourceBindings

    func execute(_ command: MeshHostCommand) async -> MeshHostCommandExecutionOutcome {
        do {
            let binding = try bindings.load(command.resourceID)
            let executable = try tmuxExecutable()
            switch command.action {
            case .poke:
                let payload = try JSONDecoder().decode(
                    DistributedHostPokePayload.self, from: command.payload
                )
                try payload.validate()
                try runTmux(
                    executable, binding: binding,
                    arguments: ["send-keys", "-t", "=\(binding.tmuxSession)", "-l", "--", payload.text]
                )
                try runTmux(
                    executable, binding: binding,
                    arguments: ["send-keys", "-t", "=\(binding.tmuxSession)", "Enter"]
                )
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

enum DistributedHostExecutorError: Error {
    case invalidBinding
    case invalidPayload
    case tmuxUnavailable
    case tmuxSocketUnavailable
    case tmuxCommandFailed

    var failureCode: String {
        switch self {
        case .invalidBinding: "invalid-host-binding"
        case .invalidPayload: "invalid-command-payload"
        case .tmuxUnavailable: "tmux-unavailable"
        case .tmuxSocketUnavailable: "tmux-socket-unavailable"
        case .tmuxCommandFailed: "tmux-command-failed"
        }
    }
}
