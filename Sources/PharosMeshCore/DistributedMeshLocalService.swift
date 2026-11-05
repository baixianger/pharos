import Foundation
import PharosMeshControl
import PharosMeshProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DistributedMeshLocalServiceOperation: String, Codable, Sendable {
    case health
    case status
    case syncNow = "sync-now"
    case locateAgent = "locate-agent"
    case stopAgent = "stop-agent"
    case issueInvitation = "issue-invitation"
    case revokeDevice = "revoke-device"
    case fetchAttachment = "fetch-attachment"
}

public struct DistributedMeshInvitationRequest:
    Codable, Equatable, Sendable
{
    public var requestedRoles: Set<MeshDeviceRole>

    public init(requestedRoles: Set<MeshDeviceRole>) {
        self.requestedRoles = requestedRoles
    }
}

public struct DistributedMeshRevokeDeviceRequest:
    Codable, Equatable, Sendable
{
    public var deviceID: MeshDeviceID
    public var localDisplayName: String

    public init(deviceID: MeshDeviceID, localDisplayName: String) {
        self.deviceID = deviceID
        self.localDisplayName = localDisplayName
    }
}

public struct DistributedMeshLocalServiceRequest:
    Codable, Equatable, Sendable
{
    public static let protocolVersion = 1

    public var protocolVersion: Int
    public var requestID: UUID
    public var operation: DistributedMeshLocalServiceOperation
    public var deadlineMilliseconds: Int64
    public var payload: Data?

    public init(
        operation: DistributedMeshLocalServiceOperation,
        requestID: UUID = UUID(),
        deadlineMilliseconds: Int64 =
            Int64(Date().timeIntervalSince1970 * 1_000) + 5_000,
        payload: Data? = nil
    ) {
        protocolVersion = Self.protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.deadlineMilliseconds = deadlineMilliseconds
        self.payload = payload
    }
}

public struct DistributedMeshLocalServiceStatus:
    Codable, Equatable, Sendable
{
    public enum NetworkState: String, Codable, Sendable {
        case starting
        case online
        case reconnecting
        case failed
        case stopped
    }

    /// Optional for compatibility with the first service build, whose status
    /// payload predated this explicit diagnostic field.
    public var protocolVersion: Int?
    public var buildID: String
    public var processID: Int32
    public var startedAtMilliseconds: Int64
    public var deviceID: MeshDeviceID
    public var endpointID: MeshEndpointID
    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var networkState: NetworkState
    public var lastSuccessfulSyncMilliseconds: Int64?
    public var hostCommandRecoveryCount: Int?
    public var pendingLocalEventCount: Int?
    public var connections: [MeshConnectionSnapshot]
    public var presence: [MeshAgentPresenceSnapshot]
    public var lastError: String?

    public init(
        protocolVersion: Int? =
            DistributedMeshLocalServiceRequest.protocolVersion,
        buildID: String, processID: Int32 = getpid(),
        startedAtMilliseconds: Int64 =
            Int64(Date().timeIntervalSince1970 * 1_000),
        deviceID: MeshDeviceID, endpointID: MeshEndpointID,
        trustGroupID: MeshTrustGroupID, membershipEpoch: UInt64,
        networkState: NetworkState,
        lastSuccessfulSyncMilliseconds: Int64? = nil,
        hostCommandRecoveryCount: Int? = nil,
        pendingLocalEventCount: Int? = nil,
        connections: [MeshConnectionSnapshot] = [],
        presence: [MeshAgentPresenceSnapshot] = [],
        lastError: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.buildID = buildID
        self.processID = processID
        self.startedAtMilliseconds = startedAtMilliseconds
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.networkState = networkState
        self.lastSuccessfulSyncMilliseconds = lastSuccessfulSyncMilliseconds
        self.hostCommandRecoveryCount = hostCommandRecoveryCount
        self.pendingLocalEventCount = pendingLocalEventCount
        self.connections = connections
        self.presence = presence
        self.lastError = lastError
    }
}

public struct DistributedMeshLocalServiceResponse:
    Codable, Equatable, Sendable
{
    public var protocolVersion: Int
    public var requestID: UUID
    public var status: DistributedMeshLocalServiceStatus?
    public var payload: Data?
    public var accepted: Bool
    public var error: String?

    public init(
        requestID: UUID, status: DistributedMeshLocalServiceStatus? = nil,
        payload: Data? = nil, accepted: Bool = true, error: String? = nil
    ) {
        protocolVersion = DistributedMeshLocalServiceRequest.protocolVersion
        self.requestID = requestID
        self.status = status
        self.payload = payload
        self.accepted = accepted
        self.error = error
    }
}

public enum DistributedMeshLocalServiceError:
    LocalizedError, Equatable, Sendable
{
    case socketPathTooLong
    case cannotListen(Int32)
    case cannotConnect
    case peerNotAuthorized
    case requestTooLarge
    case invalidFrame
    case invalidProtocolVersion
    case expiredRequest
    case mismatchedResponse
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong:
            "The local Mesh service socket path exceeds the macOS limit."
        case .cannotListen(let code):
            "Could not start the local Mesh service socket (errno \(code))."
        case .cannotConnect:
            "The local Mesh service is unavailable."
        case .peerNotAuthorized:
            "The local Mesh service rejected a client from another user."
        case .requestTooLarge:
            "The local Mesh service request exceeded its size limit."
        case .invalidFrame:
            "The local Mesh service returned an invalid frame."
        case .invalidProtocolVersion:
            "The local Mesh service protocol version is incompatible."
        case .expiredRequest:
            "The local Mesh service request expired before execution."
        case .mismatchedResponse:
            "The local Mesh service returned a response for another request."
        case .remote(let message):
            message
        }
    }
}

public enum DistributedMeshLocalServicePaths {
    public static let socketFileName = "runtime.sock"
    public static let maximumControlFrameBytes = 64 * 1_024

    public static func socketURL(dataDirectory: URL) throws -> URL {
        let value = dataDirectory.standardizedFileURL
            .appendingPathComponent(socketFileName)
        // Darwin sockaddr_un.sun_path contains 104 bytes including the NUL.
        guard value.path.utf8.count < 104 else {
            throw DistributedMeshLocalServiceError.socketPathTooLong
        }
        return value
    }
}

/// One-request-per-connection local control server. Durable product data does
/// not pass through this socket; it carries only bounded runtime diagnostics
/// and scheduling requests.
public final class DistributedMeshLocalServiceServer: @unchecked Sendable {
    public typealias Handler = @Sendable (
        DistributedMeshLocalServiceRequest
    ) async -> DistributedMeshLocalServiceResponse

    public let socketURL: URL
    private let allowedUserID: uid_t
    private let handler: Handler
    private let stateLock = NSLock()
    private let connectionSlots = DispatchSemaphore(value: 8)
    private var listener: Int32?

    public init(
        dataDirectory: URL, allowedUserID: uid_t = getuid(),
        handler: @escaping Handler
    ) throws {
        socketURL = try DistributedMeshLocalServicePaths.socketURL(
            dataDirectory: dataDirectory
        )
        self.allowedUserID = allowedUserID
        self.handler = handler
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listener == nil else { return }

        unlink(socketURL.path)
        let descriptor = socket(AF_UNIX, meshSocketStream(), 0)
        guard descriptor >= 0 else {
            throw DistributedMeshLocalServiceError.cannotListen(errno)
        }
        var address = sockaddr_un()
        meshFillSockaddr(&address, socketURL.path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                distributedMeshBind(
                    descriptor, $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0, listen(descriptor, 16) == 0,
              chmod(socketURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0
        else {
            let code = errno
            close(descriptor)
            unlink(socketURL.path)
            throw DistributedMeshLocalServiceError.cannotListen(code)
        }
        listener = descriptor

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(descriptor: descriptor)
        }
    }

    public func stop() {
        stateLock.lock()
        let descriptor = listener
        listener = nil
        stateLock.unlock()
        if let descriptor {
            shutdown(descriptor, Int32(SHUT_RDWR))
            close(descriptor)
        }
        unlink(socketURL.path)
    }

    deinit {
        stop()
    }

    private func acceptLoop(descriptor: Int32) {
        while true {
            let connection = accept(descriptor, nil, nil)
            if connection < 0 {
                stateLock.lock()
                let active = listener == descriptor
                stateLock.unlock()
                if !active { return }
                if errno == EINTR { continue }
                return
            }
            guard connectionSlots.wait(timeout: .now()) == .success else {
                close(connection)
                continue
            }
            Thread.detachNewThread { [self] in
                handle(connection)
                close(connection)
                connectionSlots.signal()
            }
        }
    }

    private func handle(_ descriptor: Int32) {
        meshSetSocketTimeouts(descriptor, seconds: 2)
        guard peerUserID(descriptor) == allowedUserID else { return }
        guard let data = readUntilEOF(
            descriptor,
            maximumBytes:
                DistributedMeshLocalServicePaths.maximumControlFrameBytes
        ), let frame = try? MeshStreamFrameCodec.decode(data),
              frame.kind == .request, frame.body == nil,
              let request = try? JSONDecoder().decode(
                DistributedMeshLocalServiceRequest.self,
                from: frame.header
              )
        else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let response: DistributedMeshLocalServiceResponse
        if request.protocolVersion !=
            DistributedMeshLocalServiceRequest.protocolVersion {
            response = .init(
                requestID: request.requestID, accepted: false,
                error: DistributedMeshLocalServiceError
                    .invalidProtocolVersion.localizedDescription
            )
        } else if request.deadlineMilliseconds < now {
            response = .init(
                requestID: request.requestID, accepted: false,
                error: DistributedMeshLocalServiceError
                    .expiredRequest.localizedDescription
            )
        } else {
            let box = DistributedMeshLocalResponseBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                box.set(await handler(request))
                semaphore.signal()
            }
            let remaining = max(
                0,
                request.deadlineMilliseconds -
                    Int64(Date().timeIntervalSince1970 * 1_000)
            )
            if semaphore.wait(
                timeout: .now() + .milliseconds(Int(remaining))
            ) == .success, let value = box.get() {
                response = value
            } else {
                response = .init(
                    requestID: request.requestID, accepted: false,
                    error: DistributedMeshLocalServiceError
                        .expiredRequest.localizedDescription
                )
            }
        }
        guard let header = try? JSONEncoder().encode(response),
              let encoded = try? MeshStreamFrameCodec.encode(
                .init(kind: .response, header: header)
              ),
              encoded.count <=
                DistributedMeshLocalServicePaths.maximumControlFrameBytes
        else { return }
        meshWriteRaw(descriptor, encoded)
    }
}

public struct DistributedMeshLocalServiceClient: Sendable {
    public let socketURL: URL

    public init(dataDirectory: URL) throws {
        socketURL = try DistributedMeshLocalServicePaths.socketURL(
            dataDirectory: dataDirectory
        )
    }

    public func request(
        _ operation: DistributedMeshLocalServiceOperation,
        payload: Data? = nil, timeoutMilliseconds: Int = 2_000
    ) throws -> DistributedMeshLocalServiceResponse {
        let request = DistributedMeshLocalServiceRequest(
            operation: operation,
            deadlineMilliseconds:
                Int64(Date().timeIntervalSince1970 * 1_000)
                + Int64(timeoutMilliseconds),
            payload: payload
        )
        let header = try JSONEncoder().encode(request)
        let encoded = try MeshStreamFrameCodec.encode(
            .init(kind: .request, header: header)
        )
        guard encoded.count <=
            DistributedMeshLocalServicePaths.maximumControlFrameBytes
        else {
            throw DistributedMeshLocalServiceError.requestTooLarge
        }

        let descriptor = socket(AF_UNIX, meshSocketStream(), 0)
        guard descriptor >= 0 else {
            throw DistributedMeshLocalServiceError.cannotConnect
        }
        defer { close(descriptor) }
        var address = sockaddr_un()
        meshFillSockaddr(&address, socketURL.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                meshSystemConnect(
                    descriptor, $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            throw DistributedMeshLocalServiceError.cannotConnect
        }
        meshSetSocketTimeouts(
            descriptor, seconds: Double(timeoutMilliseconds) / 1_000
        )
        meshWriteRaw(descriptor, encoded)
        shutdown(descriptor, Int32(SHUT_WR))
        guard let data = readUntilEOF(
            descriptor,
            maximumBytes:
                DistributedMeshLocalServicePaths.maximumControlFrameBytes
        ), let frame = try? MeshStreamFrameCodec.decode(data),
              frame.kind == .response, frame.body == nil,
              let response = try? JSONDecoder().decode(
                DistributedMeshLocalServiceResponse.self,
                from: frame.header
              )
        else {
            throw DistributedMeshLocalServiceError.invalidFrame
        }
        guard response.protocolVersion ==
            DistributedMeshLocalServiceRequest.protocolVersion
        else {
            throw DistributedMeshLocalServiceError.invalidProtocolVersion
        }
        guard response.requestID == request.requestID else {
            throw DistributedMeshLocalServiceError.mismatchedResponse
        }
        guard response.accepted else {
            throw DistributedMeshLocalServiceError.remote(
                response.error ?? "The local Mesh service rejected the request."
            )
        }
        return response
    }

    public func locateAgent(
        memberID: String
    ) throws -> DistributedAgentHostLocation {
        let payload = try JSONEncoder().encode(memberID)
        let response = try request(
            .locateAgent, payload: payload, timeoutMilliseconds: 35_000
        )
        guard let data = response.payload else {
            throw DistributedMeshLocalServiceError.invalidFrame
        }
        return try JSONDecoder().decode(
            DistributedAgentHostLocation.self, from: data
        )
    }

    public func stopAgent(memberID: String) throws {
        let payload = try JSONEncoder().encode(memberID)
        _ = try request(
            .stopAgent, payload: payload, timeoutMilliseconds: 35_000
        )
    }

    public func issueInvitation(
        requestedRoles: Set<MeshDeviceRole>
    ) throws -> URL {
        let payload = try JSONEncoder().encode(
            DistributedMeshInvitationRequest(
                requestedRoles: requestedRoles
            )
        )
        let response = try request(
            .issueInvitation, payload: payload,
            timeoutMilliseconds: 10_000
        )
        guard let data = response.payload,
              let value = try? JSONDecoder().decode(String.self, from: data),
              let url = URL(string: value)
        else {
            throw DistributedMeshLocalServiceError.invalidFrame
        }
        return url
    }

    @discardableResult
    public func revokeDevice(
        _ deviceID: MeshDeviceID, localDisplayName: String
    ) throws -> UInt64 {
        let payload = try JSONEncoder().encode(
            DistributedMeshRevokeDeviceRequest(
                deviceID: deviceID,
                localDisplayName: localDisplayName
            )
        )
        let response = try request(
            .revokeDevice, payload: payload,
            timeoutMilliseconds: 35_000
        )
        guard let data = response.payload else {
            throw DistributedMeshLocalServiceError.invalidFrame
        }
        return try JSONDecoder().decode(UInt64.self, from: data)
    }

    public func fetchAttachment(_ attachment: MeshAttachment) throws {
        let payload = try JSONEncoder().encode(attachment)
        _ = try request(
            .fetchAttachment, payload: payload,
            timeoutMilliseconds: 35_000
        )
    }
}

/// Bridges the synchronous local socket handler and the async service loop
/// without making ephemeral runtime state durable replicated truth.
public final class DistributedMeshLocalServiceControl: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DistributedMeshLocalServiceStatus
    private var immediateSyncRequested = false

    public init(status: DistributedMeshLocalServiceStatus) {
        value = status
    }

    public func snapshot() -> DistributedMeshLocalServiceStatus {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func update(
        _ body: (inout DistributedMeshLocalServiceStatus) -> Void
    ) {
        lock.lock()
        body(&value)
        lock.unlock()
    }

    public func requestImmediateSync() {
        lock.lock()
        immediateSyncRequested = true
        lock.unlock()
    }

    public func consumeImmediateSyncRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let requested = immediateSyncRequested
        immediateSyncRequested = false
        return requested
    }

    public func response(
        to request: DistributedMeshLocalServiceRequest
    ) -> DistributedMeshLocalServiceResponse {
        switch request.operation {
        case .health, .status:
            return .init(requestID: request.requestID, status: snapshot())
        case .syncNow:
            requestImmediateSync()
            return .init(
                requestID: request.requestID, status: snapshot()
            )
        case .locateAgent, .stopAgent, .issueInvitation, .revokeDevice,
             .fetchAttachment:
            return .init(
                requestID: request.requestID, accepted: false,
                error: "operation-requires-runtime-handler"
            )
        }
    }
}

private final class DistributedMeshLocalResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DistributedMeshLocalServiceResponse?

    func set(_ value: DistributedMeshLocalServiceResponse) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> DistributedMeshLocalServiceResponse? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func readUntilEOF(
    _ descriptor: Int32, maximumBytes: Int
) -> Data? {
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while output.count <= maximumBytes {
        let count = read(descriptor, &buffer, buffer.count)
        if count == 0 { return output }
        guard count > 0 else {
            if errno == EINTR { continue }
            return nil
        }
        output.append(contentsOf: buffer.prefix(Int(count)))
    }
    return nil
}

private func peerUserID(_ descriptor: Int32) -> uid_t? {
#if canImport(Darwin)
    var userID: uid_t = 0
    var groupID: gid_t = 0
    guard getpeereid(descriptor, &userID, &groupID) == 0 else { return nil }
    return userID
#else
    // Linux production runs the service under a dedicated systemd user and
    // currently has no local GUI client. The mode-0600 socket remains the
    // boundary until a portable SO_PEERCRED adapter is introduced.
    return getuid()
#endif
}

private func distributedMeshBind(
    _ descriptor: Int32, _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int32 {
#if canImport(Darwin)
    Darwin.bind(descriptor, address, length)
#else
    Glibc.bind(descriptor, address, length)
#endif
}
