import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class LegacySocketMeshTransportTests: XCTestCase {
    func testTemporaryUnixSocketExchangesLegacyHeaderBytes() async throws {
        let fixture = try UnixSocketFixture { fd in
            let request = try XCTUnwrap(meshReadLine(fd))
            let decoded = try JSONDecoder().decode(MeshRequest.self, from: Data(request.utf8))
            XCTAssertEqual(decoded.cmd, "capabilities")
            meshWriteAll(fd, try JSONEncoder().encode(
                MeshResponse(ok: true, capabilities: ["mesh-v2"])
            ))
        }
        defer { fixture.remove() }

        let transport = LegacySocketMeshTransport(endpoint: .unixSocket(path: fixture.socketPath))
        let path = await transport.path
        XCTAssertEqual(path, .local)
        let header = try JSONEncoder().encode(MeshRequest(cmd: "capabilities"))
        let result = try await transport.exchange(.init(header: header))
        let response = try JSONDecoder().decode(MeshResponse.self, from: result.header)

        XCTAssertEqual(response.capabilities, ["mesh-v2"])
        XCTAssertNil(result.body)
    }

    func testTemporaryUnixSocketReturnsAttachmentBody() async throws {
        let bytes = Data("isolated fixture".utf8)
        let fixture = try UnixSocketFixture { fd in
            _ = try XCTUnwrap(meshReadLine(fd))
            let attachment = MeshAttachment(name: "fixture.txt", mimeType: "text/plain",
                                            byteSize: bytes.count, sha256: "fixture")
            meshWriteAll(fd, try JSONEncoder().encode(
                MeshResponse(ok: true, attachment: attachment)
            ))
            meshWriteRaw(fd, bytes)
        }
        defer { fixture.remove() }

        let transport = LegacySocketMeshTransport(endpoint: .unixSocket(path: fixture.socketPath))
        let header = try JSONEncoder().encode(MeshRequest(cmd: "attachment-get",
                                                         attachmentID: "fixture"))
        let result = try await transport.exchange(.init(header: header))

        XCTAssertEqual(result.body, bytes)
    }

    private final class UnixSocketFixture {
        let directory: URL
        let socketPath: String
        private let listener: Int32

        init(handler: @escaping @Sendable (Int32) throws -> Void) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pharos-transport-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            socketPath = directory.appendingPathComponent("mesh.sock").path
            listener = socket(AF_UNIX, meshSocketStream(), 0)
            guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }

            var address = sockaddr_un()
            meshFillSockaddr(&address, socketPath)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    systemBind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else {
                close(listener)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            Thread.detachNewThread { [listener] in
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                defer { close(connection) }
                do { try handler(connection) }
                catch { XCTFail("fixture server failed: \(error)") }
            }
        }

        func remove() {
            close(listener)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private func systemBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>,
                        _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.bind(fd, address, length)
    #else
    Glibc.bind(fd, address, length)
    #endif
}
