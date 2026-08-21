import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class AgentRuntimeServer: @unchecked Sendable {
    public enum ServerError: LocalizedError {
        case socketPathTooLong
        case systemCall(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .socketPathTooLong: "Agent Runtime socket path is too long."
            case .systemCall(let operation, let code): "\(operation) failed with errno \(code)."
            }
        }
    }

    private let registry = AgentRuntimeRegistry()
    private let lifecycleLock = NSLock()
    private var listener: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "me.pai.pharos.agent-runtime", qos: .utility,
                                      attributes: .concurrent)

    public init() {}

    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !running else { return }

        let path = AgentRuntimePaths.socket.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ServerError.socketPathTooLong
        }
        try FileManager.default.createDirectory(at: AgentRuntimePaths.directory,
                                                withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: AgentRuntimePaths.directory.path)
        try? FileManager.default.removeItem(at: AgentRuntimePaths.socket)

        let descriptor = systemSocket()
        guard descriptor >= 0 else { throw ServerError.systemCall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemBind(descriptor, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            let code = errno
            systemClose(descriptor)
            throw ServerError.systemCall("bind", code)
        }
        guard systemListen(descriptor, 32) == 0 else {
            let code = errno
            systemClose(descriptor)
            throw ServerError.systemCall("listen", code)
        }
        _ = chmod(path, 0o600)
        listener = descriptor
        running = true
        queue.async { [weak self] in self?.acceptLoop(descriptor) }
    }

    public func stop() {
        lifecycleLock.lock()
        let descriptor = listener
        listener = -1
        running = false
        lifecycleLock.unlock()
        if descriptor >= 0 { systemClose(descriptor) }
        try? FileManager.default.removeItem(at: AgentRuntimePaths.socket)
    }

    deinit { stop() }

    private func acceptLoop(_ descriptor: Int32) {
        while isRunning(descriptor) {
            let client = systemAccept(descriptor)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            queue.async { [weak self] in
                self?.serve(client)
                systemClose(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                return systemRead(client, base, bytes.count)
            }
            if count <= 0 { return }
            pending.append(contentsOf: buffer.prefix(count))
            if pending.count > 1_048_576 { return }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard !line.isEmpty, let response = response(to: Data(line)) else { continue }
                guard writeAll(response + Data([0x0A]), to: client) else { return }
            }
        }
    }

    private func response(to data: Data) -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return encoded(["jsonrpc": "2.0", "id": NSNull(),
                            "error": ["code": -32600, "message": "Invalid Request"]])
        }
        let id = request["id"]
        do {
            let result = try registry.invoke(method: method,
                                             params: request["params"] as? [String: Any] ?? [:])
            guard let id else { return nil }
            return encoded(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as AgentRuntimeRegistry.RegistryError {
            guard let id else { return nil }
            let code = methodExistsError(error) ? -32601 : -32602
            return encoded(["jsonrpc": "2.0", "id": id,
                            "error": ["code": code, "message": error.localizedDescription]])
        } catch {
            guard let id else { return nil }
            return encoded(["jsonrpc": "2.0", "id": id,
                            "error": ["code": -32603, "message": error.localizedDescription]])
        }
    }

    private func methodExistsError(_ error: AgentRuntimeRegistry.RegistryError) -> Bool {
        if case .unsupportedMethod = error { return true }
        return false
    }

    private func encoded(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let count = systemWrite(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
    }

    private func isRunning(_ descriptor: Int32) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return running && listener == descriptor
    }
}

private func systemSocket() -> Int32 {
    #if canImport(Darwin)
    Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func systemBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.bind(fd, address, length)
    #else
    Glibc.bind(fd, address, length)
    #endif
}

private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.listen(fd, backlog)
    #else
    Glibc.listen(fd, backlog)
    #endif
}

private func systemAccept(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.accept(fd, nil, nil)
    #else
    Glibc.accept(fd, nil, nil)
    #endif
}

private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buffer, count)
    #else
    Glibc.read(fd, buffer, count)
    #endif
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, buffer, count)
    #else
    Glibc.write(fd, buffer, count)
    #endif
}

private func systemClose(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}
