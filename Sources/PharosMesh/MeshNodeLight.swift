import Foundation
import PharosMeshCore
import PharosRuntime
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The lightweight tier on a node: run `light` node commands (another node asked
/// this machine to create a session, deliver a message, read an answer) with this
/// machine's own `pharos`, and a bounded background tick (`pharos light-tick`).
extension MeshNode {
    private static let lightState = LightNodeState()

    /// This machine's `pharos`: PHAROS_LIGHT_LOCAL_PHAROS, else ~/.local/bin/pharos.
    static var localPharos: String? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PHAROS_LIGHT_LOCAL_PHAROS"], !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/pharos").path
        return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
    }

    static func executeLightCommand(_ command: MeshNodeCommand) {
        guard let data = command.payload?.data(using: .utf8),
              let request = try? JSONDecoder().decode(MeshLightCommandPayload.self, from: data),
              let verb = request.argv.first else {
            update(command, state: .failed, result: "invalid light payload")
            return
        }
        guard LightNodeExec.allowed.contains(verb) else {
            update(command, state: .failed, result: "pharos \(verb) is not run for other nodes")
            return
        }
        guard let pharos = localPharos else {
            update(command, state: .failed, result: "no local pharos (set PHAROS_LIGHT_LOCAL_PHAROS)")
            return
        }
        guard lightState.begin(command.id) else { return }
        let timeout = min(max(request.timeoutSec ?? 120, 5), 900)
        update(command, state: .running, result: "running pharos \(verb)",
               retryAt: Date().timeIntervalSince1970 + timeout + 60)
        DispatchQueue.global(qos: .utility).async {
            defer { lightState.end(command.id) }
            let output = runBounded(pharos, request.argv, timeout: timeout, direct: true)
            let result = MeshLightCommandResult(exitCode: output.status, stdout: output.stdout, stderr: output.stderr)
            let text = (try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            update(command, state: .succeeded, result: text)
        }
    }

    /// At most one tick at a time, every 20s.
    static func scheduleLightTick() {
        guard let pharos = localPharos, lightState.tickDue(every: 20) else { return }
        DispatchQueue.global(qos: .background).async {
            defer { lightState.tickDone() }
            let output = runBounded(pharos, ["light-tick"], timeout: 120, direct: false)
            if output.status != 0 {
                log("light-tick exit \(output.status): \(output.stderr.prefix(300))")
            } else if output.stdout.contains("\"harvested\":[\""), let line = output.stdout.split(separator: "\n").last {
                log("light-tick \(line.prefix(300))")
            }
        }
    }

    struct BoundedOutput {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func runBounded(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                           direct: Bool) -> BoundedOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        if direct { env["PHAROS_LIGHT_DIRECT"] = "1" }
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let collected = LightCollected()
        out.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData, err: false) }
        err.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData, err: true) }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        do { try process.run() } catch {
            return BoundedOutput(status: 127, stdout: "", stderr: error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let (stdout, stderr) = collected.text()
            return BoundedOutput(status: 124, stdout: stdout, stderr: stderr + "\ntimed out after \(Int(timeout))s")
        }
        process.waitUntilExit()
        // Stop the handlers, then read what is left in the pipes.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.append(out.fileHandleForReading.readDataToEndOfFileSafely(), err: false)
        collected.append(err.fileHandleForReading.readDataToEndOfFileSafely(), err: true)
        let (stdout, stderr) = collected.text()
        return BoundedOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private extension FileHandle {
    func readDataToEndOfFileSafely() -> Data {
        (try? readToEnd()) ?? Data()
    }
}

final class LightCollected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private let cap = 512 * 1024

    func append(_ data: Data, err isErr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if isErr {
            if err.count < cap { err.append(data.prefix(cap - err.count)) }
        } else if out.count < cap {
            out.append(data.prefix(cap - out.count))
        }
    }

    func text() -> (String, String) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

final class LightNodeState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = Set<String>()
    private var ticking = false
    private var lastTick = Date.distantPast

    func begin(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.insert(id).inserted
    }

    func end(_ id: String) {
        lock.lock()
        running.remove(id)
        lock.unlock()
    }

    func tickDue(every seconds: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !ticking, Date().timeIntervalSince(lastTick) >= seconds else { return false }
        ticking = true
        lastTick = Date()
        return true
    }

    func tickDone() {
        lock.lock()
        ticking = false
        lock.unlock()
    }
}
