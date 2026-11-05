import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Same-user client used by the Host Node to bridge authenticated Broker
/// commands into the private Agent Runtime socket. Vendor protocols and local
/// registration methods are intentionally not exposed through this bridge.
public enum AgentRuntimeClient {
    public enum ClientError: LocalizedError {
        case invalidRequest
        case methodNotAllowed(String)
        case socketPathTooLong
        case unavailable
        case writeFailed
        case invalidResponse
        case responseTooLarge
        case runtime(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRequest: "Invalid Agent Runtime JSON-RPC request."
            case .methodNotAllowed(let method): "Agent Runtime method is not remotely allowed: \(method)"
            case .socketPathTooLong: "Agent Runtime socket path is too long."
            case .unavailable: "Agent Runtime is unavailable on this Host."
            case .writeFailed: "Could not write to Agent Runtime."
            case .invalidResponse: "Agent Runtime returned an invalid response."
            case .responseTooLarge: "Agent Runtime response exceeded 4 MiB."
            case .runtime(let message): message
            }
        }
    }

    private static let remotelyAllowedMethods: Set<String> = [
        "runtime.hello",
        "runtime.snapshot",
        "delivery.submit",
        "delivery.submit-member",
        "events.cursor",
        "events.resume",
        "adapter.list",
        "session.discover",
        "session.capabilities",
        "session.perform",
        "codex.status",
        "codex.thread.list",
        "codex.thread.read",
        "codex.thread.start",
        "codex.thread.resume",
        "codex.thread.fork",
        "codex.turn.start",
        "codex.turn.interrupt",
        "launch.submit",
        "launch.options.list",
    ]

    public static func send(_ rawRequest: String) throws -> String {
        guard let request = rawRequest.data(using: .utf8), request.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              object["jsonrpc"] as? String == "2.0",
              object["id"] != nil,
              let method = object["method"] as? String else {
            throw ClientError.invalidRequest
        }
        guard remotelyAllowedMethods.contains(method) else {
            throw ClientError.methodNotAllowed(method)
        }

        let path = AgentRuntimePaths.socket.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ClientError.socketPathTooLong
        }
        let descriptor = socket(AF_UNIX, socketStreamType, 0)
        guard descriptor >= 0 else { throw ClientError.unavailable }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0,
                       socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in path.utf8.enumerated() { bytes[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.unavailable }

        var framed = request
        framed.append(0x0A)
        let wroteAll = framed.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll else { throw ClientError.writeFailed }

        var response = Data()
        var byte: UInt8 = 0
        while response.count <= 4 * 1024 * 1024 {
            let count = read(descriptor, &byte, 1)
            guard count == 1 else { throw ClientError.invalidResponse }
            if byte == 0x0A {
                guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                      let value = String(data: response, encoding: .utf8) else {
                    throw ClientError.invalidResponse
                }
                if let error = object["error"] as? [String: Any] {
                    throw ClientError.runtime(error["message"] as? String ?? "Agent Runtime request failed.")
                }
                return value
            }
            response.append(byte)
        }
        throw ClientError.responseTooLarge
    }

    private static var socketStreamType: Int32 {
        #if canImport(Darwin)
        SOCK_STREAM
        #else
        Int32(SOCK_STREAM.rawValue)
        #endif
    }
}
