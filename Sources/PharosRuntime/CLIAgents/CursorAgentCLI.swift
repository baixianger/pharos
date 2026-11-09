import Foundation

/// Thin wrapper around the public Cursor `agent` CLI only.
/// Does not read `~/.cursor` private databases, GUI state, or tokens.
public enum CursorAgentCLI {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case executableMissing
        case nonZeroExit(Int32, String)
        case emptyChatID
        case listRequiresInteractiveTTY

        public var errorDescription: String? {
            switch self {
            case .executableMissing:
                "Cursor agent CLI is not available on PATH"
            case .nonZeroExit(let code, let detail):
                "Cursor agent exited \(code): \(detail)"
            case .emptyChatID:
                "Cursor agent create-chat returned an empty chat id"
            case .listRequiresInteractiveTTY:
                "Cursor agent ls requires an interactive TTY (Ink raw mode); non-interactive inventory is unsupported"
            }
        }
    }

    public static func resolveExecutable(
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> URL? {
        let path = pathEnvironment ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("agent")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin/agent")
        return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
    }

    /// `agent create-chat` returns a bare chat UUID on stdout.
    public static func createChat(
        executable: URL? = nil,
        workingDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        guard let binary = executable ?? resolveExecutable() else {
            throw Error.executableMissing
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["create-chat"]
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Error.nonZeroExit(process.terminationStatus, err.isEmpty ? out : err)
        }
        guard !out.isEmpty, out.utf8.count <= 128,
              out.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw Error.emptyChatID
        }
        return out
    }

    /// Documented `agent ls` is an Ink TUI and fails without raw-mode stdin.
    public static func listChats() throws -> [String] {
        throw Error.listRequiresInteractiveTTY
    }
}
