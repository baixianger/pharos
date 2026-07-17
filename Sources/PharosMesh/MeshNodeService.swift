import Foundation
import PharosMeshCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum MeshNodeService {
    private static let label = "me.pai.pharos.mesh-node"

    static func install(endpoint: String?, buildID: String? = nil) throws -> String {
        if let endpoint, !safeEndpoint(endpoint) { throw ServiceError.invalidEndpoint }
        #if os(macOS)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let file = directory.appendingPathComponent("\(label).plist")
        let executable = executablePath
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pharos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let endpointArguments = endpoint.map {
            "<string>--endpoint</string><string>\(xml($0))</string>"
        } ?? ""
        let buildArguments = buildID.map {
            "<string>--build-id</string><string>\(xml($0))</string>"
        } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array>
            <string>\(xml(executable))</string><string>node</string><string>run</string>
            \(endpointArguments)\(buildArguments)
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
          <key>StandardOutPath</key><string>\(xml(logDirectory.appendingPathComponent("mesh-node.log").path))</string>
          <key>StandardErrorPath</key><string>\(xml(logDirectory.appendingPathComponent("mesh-node.log").path))</string>
        </dict></plist>
        """
        try Data(plist.utf8).write(to: file, options: .atomic)
        _ = command("/bin/launchctl", ["bootout", "gui/\(getuid())", file.path])
        let result = command("/bin/launchctl", ["bootstrap", "gui/\(getuid())", file.path])
        guard result.status == 0 else { throw ServiceError.command(result.output) }
        return file.path
        #elseif os(Linux)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/systemd/user", isDirectory: true)
        let file = directory.appendingPathComponent("pharos-mesh-node.service")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unit = """
        [Unit]
        Description=Pharos Mesh Host node
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        ExecStart=\(executablePath) node run\(endpoint.map { " --endpoint \($0)" } ?? "")
        Restart=always
        RestartSec=2
        NoNewPrivileges=true

        [Install]
        WantedBy=default.target
        """
        try Data(unit.utf8).write(to: file, options: .atomic)
        let reload = command("/usr/bin/systemctl", ["--user", "daemon-reload"])
        guard reload.status == 0 else { throw ServiceError.command(reload.output) }
        let enable = command("/usr/bin/systemctl", ["--user", "enable", "--now", "pharos-mesh-node.service"])
        guard enable.status == 0 else { throw ServiceError.command(enable.output) }
        return file.path
        #else
        throw ServiceError.unsupported
        #endif
    }

    static func uninstall() throws {
        #if os(macOS)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        _ = command("/bin/launchctl", ["bootout", "gui/\(getuid())", file.path])
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        #elseif os(Linux)
        _ = command("/usr/bin/systemctl", ["--user", "disable", "--now", "pharos-mesh-node.service"])
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/systemd/user/pharos-mesh-node.service")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        _ = command("/usr/bin/systemctl", ["--user", "daemon-reload"])
        #else
        throw ServiceError.unsupported
        #endif
    }

    private static var executablePath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func safeEndpoint(_ value: String) -> Bool {
        meshSplitHostPort(value) != nil
            && value.allSatisfy { $0.isLetter || $0.isNumber || ".-:".contains($0) }
    }

    private static func command(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { return (1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    enum ServiceError: LocalizedError {
        case unsupported
        case invalidEndpoint
        case command(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: "Automatic node service installation is unsupported on this platform."
            case .invalidEndpoint: "The node endpoint must be a Tailscale IP or DNS name followed by a port."
            case .command(let output): output.isEmpty ? "Service manager command failed." : output
            }
        }
    }
}
