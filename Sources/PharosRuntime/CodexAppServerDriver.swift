import Dispatch
import Foundation

/// A Pharos-owned Codex App Server connection. It deliberately uses stdio so
/// no vendor socket is exposed and a Codex upgrade can be isolated here.
final class CodexAppServerDriver: @unchecked Sendable {
    static let shared = CodexAppServerDriver()

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

    private let lock = NSLock()
    private let initializationLock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: [String: Pending] = [:]
    private var initialized = false

    func request(method: String, params: [String: Any]) throws -> Any {
        try ensureInitialized()
        return try rawRequest(method: method, params: params)
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["running": process?.isRunning == true,
                "initialized": initialized,
                "transport": "stdio",
                "managedBy": "pharos"]
    }

    private func ensureInitialized() throws {
        initializationLock.lock()
        defer { initializationLock.unlock() }
        lock.lock()
        let ready = initialized && process?.isRunning == true
        lock.unlock()
        if ready { return }
        try startProcess()
        _ = try rawRequest(method: "initialize", params: [
            "clientInfo": ["name": "pharos", "title": "Pharos", "version": "0.1.0"],
            "capabilities": ["experimentalApi": false],
        ])
        lock.lock(); initialized = true; lock.unlock()
    }

    private func startProcess() throws {
        lock.lock()
        if process?.isRunning == true { lock.unlock(); return }
        lock.unlock()

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            self?.didTerminate(status: process.terminationStatus)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        do { try process.run() }
        catch { throw DriverError.unavailable(error.localizedDescription) }

        lock.lock()
        self.process = process
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        initialized = false
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        AgentRuntimeEventJournal.shared.publish(kind: "codex.started", payload: status())
    }

    private func rawRequest(method: String, params: [String: Any]) throws -> Any {
        let id = UUID().uuidString
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            throw DriverError.invalidResponse
        }
        data.append(0x0A)
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        pending[id] = Pending(semaphore: semaphore, result: nil)
        let writer = input
        lock.unlock()
        do { try writer?.write(contentsOf: data) }
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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = object["id"].map({ String(describing: $0) }) {
            lock.lock()
            if var waiter = pending[id] {
                if let error = object["error"] as? [String: Any] {
                    waiter.result = .failure(DriverError.server(error["message"] as? String ?? "unknown"))
                } else if let result = object["result"] {
                    waiter.result = .success(result)
                } else {
                    waiter.result = .failure(DriverError.invalidResponse)
                }
                pending[id] = waiter
                lock.unlock()
                waiter.semaphore.signal()
                return
            }
            lock.unlock()
            AgentRuntimeEventJournal.shared.publish(kind: "codex.serverRequest", payload: object)
            return
        }
        AgentRuntimeEventJournal.shared.publish(kind: "codex.notification", payload: object)
    }

    private func didTerminate(status: Int32) {
        lock.lock()
        var waiters: [DispatchSemaphore] = []
        for id in pending.keys {
            guard var waiter = pending[id] else { continue }
            waiter.result = .failure(DriverError.unavailable("process exited with status \(status)"))
            pending[id] = waiter
            waiters.append(waiter.semaphore)
        }
        process = nil
        input = nil
        output = nil
        initialized = false
        lock.unlock()
        waiters.forEach { $0.signal() }
        AgentRuntimeEventJournal.shared.publish(kind: "codex.stopped", payload: ["status": status])
    }
}
