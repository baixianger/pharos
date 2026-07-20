import Foundation
import PharosMeshProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum LegacySocketMeshTransportError: LocalizedError, Equatable, Sendable {
    case cannotConnect
    case invalidResponse
    case oversizedResponse
    case truncatedBody

    public var errorDescription: String? {
        switch self {
        case .cannotConnect: "Cannot reach the Mesh broker."
        case .invalidResponse: "The Mesh broker returned an invalid response."
        case .oversizedResponse: "The Mesh broker response exceeded the protocol limit."
        case .truncatedBody: "The Mesh broker closed before the response body was complete."
        }
    }
}

/// Legacy newline-JSON over a local Unix socket or TCP. This is the migration
/// adapter: callers exchange transport-neutral header/body frames while the
/// on-wire bytes remain exactly compatible with the existing broker.
public struct LegacySocketMeshTransport: MeshTransport, Sendable {
    public enum Endpoint: Equatable, Sendable {
        case unixSocket(path: String)
        case tcp(endpoint: String, connectTimeoutSeconds: Double = 5)
    }

    public let endpoint: Endpoint

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    public var path: MeshTransportPath {
        get async {
            switch endpoint {
            case .unixSocket: .local
            case .tcp: .legacyTCP
            }
        }
    }

    public func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        try exchangeBlocking(request)
    }

    /// Synchronous bridge retained for the existing CLI and macOS call sites.
    /// Iroh transports remain async; only this legacy adapter exposes it.
    public func exchangeBlocking(_ request: MeshTransportRequest) throws -> MeshTransportResponse {
        try request.validate()
        guard let fd = connect() else { throw LegacySocketMeshTransportError.cannotConnect }
        defer { close(fd) }

        meshSetSocketTimeouts(fd, seconds: Double(request.timeoutMilliseconds) / 1_000)
        meshWriteAll(fd, request.header)
        if let body = request.body { meshWriteRaw(fd, body) }

        guard let header = readHeader(fd) else {
            throw LegacySocketMeshTransportError.invalidResponse
        }

        var body: Data?
        if expectsResponseBody(request.header),
           let response = try? JSONDecoder().decode(MeshResponse.self, from: header),
           response.ok, let attachment = response.attachment, attachment.byteSize > 0 {
            guard attachment.byteSize <= DistributedMeshProtocol.maximumBlobBytes else {
                throw LegacySocketMeshTransportError.oversizedResponse
            }
            guard let bytes = meshReadExactly(fd, count: attachment.byteSize) else {
                throw LegacySocketMeshTransportError.truncatedBody
            }
            body = bytes
        }

        let response = MeshTransportResponse(header: header, body: body)
        try response.validate()
        return response
    }

    private func connect() -> Int32? {
        switch endpoint {
        case .unixSocket(let path):
            let fd = socket(AF_UNIX, meshSocketStream(), 0)
            guard fd >= 0 else { return nil }
            var address = sockaddr_un()
            meshFillSockaddr(&address, path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    meshSystemConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { close(fd); return nil }
            return fd
        case .tcp(let endpoint, let timeout):
            return meshTCPConnect(endpoint, timeoutSec: timeout)
        }
    }

    private func readHeader(_ fd: Int32) -> Data? {
        var output = Data()
        output.reserveCapacity(1_024)
        var byte: UInt8 = 0
        while output.count <= DistributedMeshProtocol.maximumHeaderBytes {
            let count = read(fd, &byte, 1)
            guard count > 0 else { return nil }
            if byte == 0x0A { return output }
            output.append(byte)
        }
        return nil
    }

    private func expectsResponseBody(_ header: Data) -> Bool {
        (try? JSONDecoder().decode(MeshRequest.self, from: header).cmd) == "attachment-get"
    }
}
