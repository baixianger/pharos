import Dispatch
import Foundation
import PharosAgentCore

/// Thin IPC client for the Rust Agent Runtime. Registry, queueing, Codex
/// process discovery, WebSocket framing and App Server JSON-RPC live behind
/// the packaged `pharos-meshd` helper.
final class CodexAppServerDriver: @unchecked Sendable {
    enum DriverError: LocalizedError {
        case unavailable(String)
        case timeout
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail): "Codex App Server unavailable: \(detail)"
            case .timeout: "Codex App Server request timed out."
            case .invalidResponse: "Codex App Server returned an invalid response."
            case .server(let detail): "Codex App Server error: \(detail)"
            }
        }
    }

    private struct Pending {
        let semaphore: DispatchSemaphore
        var result: Result<Any, Error>?
    }

    private let eventSink: any AgentEventSink
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let initializationLock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [String: Pending] = [:]
    private var initialized = false
    private var standardError = Data()

    init(eventSink: any AgentEventSink) {
        self.eventSink = eventSink
    }

    deinit {
        process?.terminate()
    }

    func request(method: String, params: [String: Any]) throws -> Any {
        try ensureStarted()
        let result = try rawRequest(method: method, params: params)
        lock.lock(); initialized = true; lock.unlock()
        return result
    }

    func prepare() throws -> [String: Any] {
        try ensureStarted()
        return status()
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "running": process?.isRunning == true,
            "initialized": initialized,
            "transport": "rust-runtime-jsonl",
            "managedBy": "codex-daemon",
        ]
    }

    private func ensureStarted() throws {
        initializationLock.lock()
        defer { initializationLock.unlock() }
        lock.lock()
        let ready = process?.isRunning == true
        lock.unlock()
        if ready { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = try helperExecutable()
        process.arguments = ["--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            self?.didTerminate(status: process.terminationStatus)
        }
        do { try process.run() }
        catch { throw DriverError.unavailable(error.localizedDescription) }

        lock.lock()
        self.process = process
        input = stdinPipe.fileHandleForWriting
        initialized = false
        buffer.removeAll(keepingCapacity: true)
        standardError.removeAll(keepingCapacity: true)
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStandardError(handle.availableData)
        }
        eventSink.publish(kind: "codex.started", payload: status())
    }

    private func helperExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let override = environment["PHAROS_AGENT_RUNTIME_EXECUTABLE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/pharos-meshd"))
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("pharos-meshd"))
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for configuration in ["debug", "release"] {
            candidates.append(root.appendingPathComponent(
                "rust/target/aarch64-apple-darwin/\(configuration)/pharos-meshd"
            ))
            candidates.append(root.appendingPathComponent(
                "rust/target/\(configuration)/pharos-meshd"
            ))
        }
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw DriverError.unavailable(
                "pharos-meshd helper not found; package the app or set "
                    + "PHAROS_AGENT_RUNTIME_EXECUTABLE"
            )
        }
        return executable
    }

    private func rawRequest(method: String, params: [String: Any]) throws -> Any {
        let id = UUID().uuidString
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        guard var payload = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            throw DriverError.invalidResponse
        }
        payload.append(0x0A)
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        pending[id] = Pending(semaphore: semaphore, result: nil)
        let writer = input
        lock.unlock()
        guard let writer else {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            throw DriverError.unavailable("Rust adapter input is unavailable")
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        do { try writer.write(contentsOf: payload) }
        catch {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            throw DriverError.unavailable(error.localizedDescription)
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            throw DriverError.timeout
        }
        lock.lock()
        let result = pending.removeValue(forKey: id)?.result
        lock.unlock()
        guard let result else { throw DriverError.invalidResponse }
        return try result.get()
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[..<newline]))
            buffer.removeSubrange(...newline)
        }
        lock.unlock()
        lines.forEach(handleLine)
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { return }
        let result: Result<Any, Error>
        if let error = object["error"] as? [String: Any] {
            result = .failure(DriverError.server(error["message"] as? String ?? "unknown error"))
        } else if let value = object["result"] {
            result = .success(value)
        } else {
            result = .failure(DriverError.invalidResponse)
        }
        lock.lock()
        if var request = pending[id] {
            request.result = result
            pending[id] = request
            request.semaphore.signal()
        }
        lock.unlock()
    }

    private func consumeStandardError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        standardError.append(data)
        if standardError.count > 16 * 1024 {
            standardError.removeFirst(standardError.count - 16 * 1024)
        }
        lock.unlock()
    }

    private func didTerminate(status: Int32) {
        lock.lock()
        let detail = String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = DriverError.unavailable(
            detail.isEmpty ? "Rust adapter exited with status \(status)" : detail
        )
        let failures = pending.mapValues { request -> Pending in
            var copy = request
            copy.result = .failure(error)
            return copy
        }
        pending = failures
        let semaphores = pending.values.map(\.semaphore)
        process = nil
        input = nil
        initialized = false
        lock.unlock()
        semaphores.forEach { $0.signal() }
        eventSink.publish(kind: "codex.stopped", payload: ["status": status])
    }
}
