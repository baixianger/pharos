import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshProtocol

final class DistributedMeshLocalServiceTests: XCTestCase {
    func testSameUserClientReceivesCorrelatedHealth() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = fixtureStatus()
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { request in
            .init(requestID: request.requestID, status: status)
        }
        try server.start()
        defer { server.stop() }

        let response = try DistributedMeshLocalServiceClient(
            dataDirectory: directory
        ).request(.health)

        XCTAssertEqual(response.status, status)
        XCTAssertTrue(response.accepted)
    }

    func testExpiredRequestIsRejectedBeforeHandler() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { request in
            XCTFail("expired request reached handler")
            return .init(requestID: request.requestID)
        }
        try server.start()
        defer { server.stop() }

        let request = DistributedMeshLocalServiceRequest(
            operation: .status, deadlineMilliseconds: 1
        )
        let response = try rawExchange(request, directory: directory)

        XCTAssertFalse(response.accepted)
        XCTAssertEqual(
            response.error,
            DistributedMeshLocalServiceError.expiredRequest.localizedDescription
        )
    }

    func testStopRemovesSocketAndClientFailsBoundedly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { .init(requestID: $0.requestID) }
        try server.start()
        let socketURL = server.socketURL
        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertThrowsError(try DistributedMeshLocalServiceClient(
            dataDirectory: directory
        ).request(.health)) { error in
            XCTAssertEqual(
                error as? DistributedMeshLocalServiceError, .cannotConnect
            )
        }
    }

    func testSocketPathLimitFailsBeforeBind() throws {
        let directory = URL(
            fileURLWithPath: "/" + String(repeating: "a", count: 110),
            isDirectory: true
        )
        XCTAssertThrowsError(try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { .init(requestID: $0.requestID) }) { error in
            XCTAssertEqual(
                error as? DistributedMeshLocalServiceError, .socketPathTooLong
            )
        }
    }

    func testDifferentUserIsRejectedWithoutReachingHandler() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory,
            allowedUserID: getuid() &+ 1
        ) { request in
            XCTFail("different-UID request reached handler")
            return .init(requestID: request.requestID)
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(
            try DistributedMeshLocalServiceClient(
                dataDirectory: directory
            ).request(.health)
        ) { error in
            XCTAssertEqual(
                error as? DistributedMeshLocalServiceError, .invalidFrame
            )
        }
    }

    func testClientRejectsOversizedPayloadBeforeConnecting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try DistributedMeshLocalServiceClient(
            dataDirectory: directory
        )

        XCTAssertThrowsError(
            try client.request(
                .status,
                payload: Data(
                    repeating: 0x41,
                    count: DistributedMeshLocalServicePaths
                        .maximumControlFrameBytes
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DistributedMeshLocalServiceError,
                .requestTooLarge
            )
        }
    }

    func testUnknownOperationIsRejectedBeforeHandler() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { request in
            XCTFail("unknown operation reached handler")
            return .init(requestID: request.requestID)
        }
        try server.start()
        defer { server.stop() }

        let requestID = UUID()
        let json = """
        {"protocolVersion":1,"requestID":"\(requestID.uuidString)",\
        "operation":"future-operation","deadlineMilliseconds":\
        \(Int64(Date().timeIntervalSince1970 * 1_000) + 5_000)}
        """
        XCTAssertThrowsError(
            try rawHeaderExchange(Data(json.utf8), directory: directory)
        )
    }

    func testStartReplacesStaleSocketAndCreatesPrivateSocket() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = try DistributedMeshLocalServicePaths.socketURL(
            dataDirectory: directory
        )
        try Data("stale".utf8).write(to: socketURL)
        let status = fixtureStatus()
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { .init(requestID: $0.requestID, status: status) }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: socketURL.path
        )
        XCTAssertEqual(
            attributes[.type] as? FileAttributeType, .typeSocket
        )
        XCTAssertEqual(
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1)
                & 0o777,
            0o600
        )
        XCTAssertNotNil(
            try DistributedMeshLocalServiceClient(
                dataDirectory: directory
            ).request(.health).status
        )
    }

    func testSyncNowSetsOneConsumableSchedulingHint() {
        let status = fixtureStatus()
        let control = DistributedMeshLocalServiceControl(status: status)
        let request = DistributedMeshLocalServiceRequest(operation: .syncNow)

        let response = control.response(to: request)

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.status, status)
        XCTAssertTrue(control.consumeImmediateSyncRequest())
        XCTAssertFalse(control.consumeImmediateSyncRequest())
    }

    func testStatusDecodesLegacyPayloadWithoutExplicitProtocolVersion()
        throws {
        let status = fixtureStatus()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(status)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "protocolVersion")

        let decoded = try JSONDecoder().decode(
            DistributedMeshLocalServiceStatus.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.protocolVersion)
        XCTAssertEqual(decoded.deviceID, status.deviceID)
        XCTAssertEqual(decoded.endpointID, status.endpointID)
    }

    func testAsyncRuntimeOperationReturnsCorrelatedPayload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = Data("runtime-result".utf8)
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { request in
            await Task.yield()
            return .init(
                requestID: request.requestID, payload: expected
            )
        }
        try server.start()
        defer { server.stop() }

        let response = try DistributedMeshLocalServiceClient(
            dataDirectory: directory
        ).request(.locateAgent)

        XCTAssertEqual(response.payload, expected)
    }

    func testInvitationClientSendsTypedRolesAndDecodesURL() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = URL(string: "pharos://mesh/invite#test-ticket")!
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { request in
            XCTAssertEqual(request.operation, .issueInvitation)
            let value = try? JSONDecoder().decode(
                DistributedMeshInvitationRequest.self,
                from: request.payload ?? Data()
            )
            XCTAssertEqual(value?.requestedRoles, [.controller, .host])
            return .init(
                requestID: request.requestID,
                payload: try? JSONEncoder().encode(expected.absoluteString)
            )
        }
        try server.start()
        defer { server.stop() }

        let value = try DistributedMeshLocalServiceClient(
            dataDirectory: directory
        ).issueInvitation(requestedRoles: [.controller, .host])

        XCTAssertEqual(value, expected)
    }

    func testRevokeClientSendsTypedDeviceAndDecodesEpoch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deviceID = MeshDeviceID(
            rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { request in
            XCTAssertEqual(request.operation, .revokeDevice)
            let value = try? JSONDecoder().decode(
                DistributedMeshRevokeDeviceRequest.self,
                from: request.payload ?? Data()
            )
            XCTAssertEqual(value?.deviceID, deviceID)
            XCTAssertEqual(value?.localDisplayName, "Test Mac")
            return .init(
                requestID: request.requestID,
                payload: try? JSONEncoder().encode(UInt64(12))
            )
        }
        try server.start()
        defer { server.stop() }

        let epoch = try DistributedMeshLocalServiceClient(
            dataDirectory: directory
        ).revokeDevice(deviceID, localDisplayName: "Test Mac")

        XCTAssertEqual(epoch, 12)
    }

    func testAttachmentFetchClientSendsMetadataWithoutBlobBytes()
        throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = MeshAttachment(
            id: "attachment-id",
            name: "diagram.png",
            mimeType: "image/png",
            byteSize: 1_024,
            sha256: String(repeating: "a", count: 64)
        )
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { request in
            XCTAssertEqual(request.operation, .fetchAttachment)
            let value = try? JSONDecoder().decode(
                MeshAttachment.self,
                from: request.payload ?? Data()
            )
            XCTAssertEqual(value, attachment)
            XCTAssertLessThan(
                request.payload?.count ?? .max,
                attachment.byteSize
            )
            return .init(requestID: request.requestID)
        }
        try server.start()
        defer { server.stop() }

        try DistributedMeshLocalServiceClient(
            dataDirectory: directory
        ).fetchAttachment(attachment)
    }

    func testLongRuntimeRequestDoesNotBlockHealthDiagnostics()
        async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = fixtureStatus()
        let server = try DistributedMeshLocalServiceServer(
            dataDirectory: directory
        ) { request in
            if request.operation == .fetchAttachment {
                try? await Task.sleep(for: .milliseconds(500))
            }
            return .init(requestID: request.requestID, status: status)
        }
        try server.start()
        defer { server.stop() }
        let client = try DistributedMeshLocalServiceClient(
            dataDirectory: directory
        )
        let attachment = MeshAttachment(
            name: "fixture.bin",
            mimeType: "application/octet-stream",
            byteSize: 1,
            sha256: String(repeating: "b", count: 64)
        )
        let slowRequest = Task.detached {
            try client.fetchAttachment(attachment)
        }
        try await Task.sleep(for: .milliseconds(50))

        let started = ContinuousClock.now
        XCTAssertNotNil(try client.request(.health).status)
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(200))
        try await slowRequest.value
    }

    private func rawExchange(
        _ request: DistributedMeshLocalServiceRequest, directory: URL
    ) throws -> DistributedMeshLocalServiceResponse {
        try rawHeaderExchange(
            JSONEncoder().encode(request), directory: directory
        )
    }

    private func rawHeaderExchange(
        _ header: Data, directory: URL
    ) throws -> DistributedMeshLocalServiceResponse {
        let socketURL = try DistributedMeshLocalServicePaths.socketURL(
            dataDirectory: directory
        )
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(descriptor) }
        var address = sockaddr_un()
        meshFillSockaddr(&address, socketURL.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(
                    descriptor, $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let data = try MeshStreamFrameCodec.encode(.init(
            kind: .request, header: header
        ))
        _ = data.withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }
        shutdown(descriptor, SHUT_WR)
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(.EIO) }
            responseData.append(contentsOf: buffer.prefix(Int(count)))
        }
        let frame = try MeshStreamFrameCodec.decode(responseData)
        return try JSONDecoder().decode(
            DistributedMeshLocalServiceResponse.self, from: frame.header
        )
    }

    private func fixtureStatus() -> DistributedMeshLocalServiceStatus {
        .init(
            buildID: "test", processID: 42, startedAtMilliseconds: 100,
            deviceID: MeshDeviceID(
                rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            endpointID: MeshEndpointID(rawValue: "endpoint-test")!,
            trustGroupID: MeshTrustGroupID(
                rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ),
            membershipEpoch: 7, networkState: .online
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pharos-local-service-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
