import Foundation
import PharosMeshCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Per-Host, least-privilege Mesh worker. It keeps an outbound event loop to
/// the Broker and may only type a fixed mailbox prompt into a locally-owned,
/// registered tmux pane that still contains the expected coding-agent process
/// and visibly shows an idle composer.
enum MeshNode {
    static func run(endpoint: String?) -> Int32 {
        if let endpoint { MeshClient.remoteEndpoint = endpoint }
        var cursor: UInt64?
        var backoff: UInt32 = 1
        FileHandle.standardError.write(Data("pharos node: starting as \(hostName)\(tailscaleIP.map { " (\($0))" } ?? "")\n".utf8))

        while true {
            heartbeat()
            let response = MeshClient.events(after: cursor, timeoutMs: 25_000)
            guard response.ok, let next = response.cursor else {
                FileHandle.standardError.write(Data("pharos node: broker unavailable; retrying\n".utf8))
                sleep(backoff)
                backoff = min(backoff * 2, 15)
                continue
            }
            backoff = 1
            let establishingBaseline = cursor == nil || next < (cursor ?? 0)
            cursor = next
            if establishingBaseline { sweepUnread() }
            for event in response.events ?? [] where event.kind == .poke {
                guard let member = event.member, owns(member) else { continue }
                let result = poke(member)
                log(result == nil ? "poked @\(member.nick) in \(member.tmuxPane ?? "?")"
                                  : "skipped @\(member.nick): \(result!)")
            }
            if (response.events ?? []).contains(where: { $0.kind == .roster }) {
                sweepUnread()
            }
        }
    }

    private static func heartbeat() {
        _ = MeshClient.send(MeshRequest(cmd: "node-heartbeat", memberID: nodeID,
                                        host: hostName, tailscaleIP: tailscaleIP))
    }

    /// Recover directed messages that arrived while this node was offline.
    private static func sweepUnread() {
        let response = MeshClient.send(MeshRequest(cmd: "who"))
        guard response.ok else { return }
        for member in response.members ?? [] where (member.unread ?? 0) > 0 && owns(member) {
            if let reason = poke(member) { log("unread sweep skipped @\(member.nick): \(reason)") }
            else { log("unread sweep poked @\(member.nick)") }
        }
    }

    static func owns(_ member: MeshMemberInfo) -> Bool {
        if let remoteIP = member.tailscaleIP, !remoteIP.isEmpty,
           let localIP = tailscaleIP, !localIP.isEmpty {
            return remoteIP == localIP
        }
        return normalized(member.host) == normalized(hostName)
    }

    static func poke(_ member: MeshMemberInfo) -> String? {
        guard let pane = member.tmuxPane, validPane(pane) else { return "missing or unsafe tmux pane" }
        guard let tmux = tmuxExecutable else { return "tmux not found" }
        if let socket = member.tmuxSocket, !validSocket(socket) { return "unsafe tmux socket" }
        let prefix = member.tmuxSocket.map { ["-S", $0] } ?? []

        let root = run(tmux, prefix + ["display-message", "-p", "-t", pane, "#{pane_pid}"])
        guard root.ok, let rootPID = Int(root.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "tmux pane is unavailable"
        }
        let processList = run("/bin/ps", ["-axo", "pid=,ppid=,comm="])
        guard processList.ok,
              MeshPaneSafety.processTreeContainsAgent(processList.output, rootPID: rootPID, kind: member.kind) else {
            return "pane no longer runs the registered agent"
        }
        let capture = run(tmux, prefix + ["capture-pane", "-p", "-t", pane])
        guard capture.ok, MeshPaneSafety.paneLooksIdle(capture.output) else { return "agent is not safely idle" }

        let message = "You have new mesh messages. Run: pharos mesh recv \(member.nick) --member \(member.id)"
        guard run(tmux, prefix + ["send-keys", "-t", pane, "-l", "--", message]).ok else {
            return "tmux send-keys failed"
        }
        usleep(350_000)
        guard run(tmux, prefix + ["send-keys", "-t", pane, "Enter"]).ok else {
            return "tmux Enter failed"
        }
        return nil
    }

    private static var hostName: String {
        let value = ProcessInfo.processInfo.hostName
        return value.isEmpty ? "this-host" : value
    }

    private static let nodeID: String = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pharos", isDirectory: true)
        let file = directory.appendingPathComponent("mesh-node-id")
        if let value = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data((value + "\n").utf8).write(to: file, options: .atomic)
        return value
    }()

    private static var tailscaleIP: String? {
        if let value = ProcessInfo.processInfo.environment["PHAROS_TAILSCALE_IP"], !value.isEmpty { return value }
        for executable in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                           "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"]
            where FileManager.default.isExecutableFile(atPath: executable) {
            let value = run(executable, ["ip", "-4"]).output
                .split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, value.split(separator: ".").count == 4 { return value }
        }
        return nil
    }

    private static var tmuxExecutable: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func validPane(_ value: String) -> Bool {
        let digits = value.first == "%" ? value.dropFirst() : Substring(value)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func validSocket(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\n") && !value.contains("\r")
    }

    private struct CommandResult { let ok: Bool; let output: String }

    private static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() }
        catch { return CommandResult(ok: false, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(ok: process.terminationStatus == 0,
                             output: String(decoding: data, as: UTF8.self))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("pharos node: \(message)\n".utf8))
    }
}
