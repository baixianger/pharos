import Foundation

/// Shared source of truth for the user-installed `pharos` and `chat` commands.
/// Hooks use this entry point instead of guessing where Pharos.app is installed.
enum CLIInstaller {
    private static let names = ["pharos", "chat"]
    private static var home: String { NSHomeDirectory() }
    private static var candidateDirectories: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
    }

    static var installDirectory: String {
        let fm = FileManager.default
        for directory in candidateDirectories {
            if fm.fileExists(atPath: directory) {
                if fm.isWritableFile(atPath: directory) { return directory }
            } else if directory.hasPrefix(home) {
                return directory
            }
        }
        return "\(home)/.local/bin"
    }

    static func executablePath() -> String {
        (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    static func commandSnippet(_ name: String) -> String {
        guard names.contains(name) else { return "" }
        return "ln -sf \"\(executablePath())\" \"\(installDirectory)/\(name)\""
    }

    /// Returns the installed command path, preserving the symlink path itself.
    /// This lets hooks follow the same command that Settings installed.
    static func installedExecutablePath(name: String = "pharos") -> String? {
        guard names.contains(name) else { return nil }
        let fm = FileManager.default
        return candidateDirectories
            .map { "\($0)/\(name)" }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    static func install(_ name: String) -> String {
        guard names.contains(name) else { return "Unknown CLI command: \(name)" }
        let fm = FileManager.default
        let source = executablePath()

        for directory in candidateDirectories {
            if !fm.fileExists(atPath: directory) {
                guard directory.hasPrefix(home) else { continue }
                try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            guard fm.isWritableFile(atPath: directory) else { continue }
            let destination = "\(directory)/\(name)"
            if (try? fm.destinationOfSymbolicLink(atPath: destination)) != nil {
                try? fm.removeItem(atPath: destination)
            } else if fm.fileExists(atPath: destination) {
                continue // Do not clobber a real user-owned command.
            }
            do {
                try fm.createSymbolicLink(atPath: destination, withDestinationPath: source)
                let short = destination.replacingOccurrences(of: home, with: "~")
                return "Installed → \(short)"
            } catch {
                continue
            }
        }
        return "Couldn't auto-install — copy the command below (no sudo needed)."
    }
}
