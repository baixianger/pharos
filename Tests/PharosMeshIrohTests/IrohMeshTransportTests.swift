import Foundation
import XCTest
@testable import PharosMeshIroh
import PharosMeshIdentity
import PharosMeshProtocol

final class IrohMeshTransportTests: XCTestCase {
    func testAvailabilityMatchesCompiledPlatformSupport() {
#if canImport(IrohLib)
        XCTAssertTrue(MeshIrohAvailability.isAvailable)
#else
        XCTAssertFalse(MeshIrohAvailability.isAvailable)
#endif
    }

#if canImport(IrohLib)
    func testIsolatedLoopbackExchangeUsesIrohStreamFraming() async throws {
        let server = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled,
            bindAddress: "127.0.0.1:0"
        )
        let client = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled,
            bindAddress: "127.0.0.1:0"
        )
        do {
            await server.startServing { request, remoteID in
                XCTAssertFalse(remoteID.rawValue.isEmpty)
                XCTAssertEqual(request.header, Data(#"{"cmd":"echo"}"#.utf8))
                return MeshTransportResponse(
                    header: Data(#"{"ok":true}"#.utf8),
                    body: request.body
                )
            }
            let serverAddress = try await server.localAddress()
            let transport = IrohMeshTransport(runtime: client, remote: serverAddress)
            let response = try await transport.exchange(MeshTransportRequest(
                header: Data(#"{"cmd":"echo"}"#.utf8),
                body: Data([0, 1, 2, 255]),
                timeoutMilliseconds: 5_000
            ))

            XCTAssertEqual(response.header, Data(#"{"ok":true}"#.utf8))
            XCTAssertEqual(response.body, Data([0, 1, 2, 255]))
            let path = await transport.path
            XCTAssertEqual(path, .irohDirect)
        } catch {
            try? await client.close()
            try? await server.close()
            throw error
        }
        try await client.close()
        try await server.close()
    }

    func testSecretKeyRestoresStableEndpointIdentityInIsolatedEndpoints() async throws {
        let first = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled,
            bindAddress: "127.0.0.1:0"
        )
        let secret = try await first.secretKeyBytes()
        let firstID = try await first.localAddress().endpointID
        try await first.close()

        let restored = try await IrohEndpointRuntime.bind(
            secretKey: secret,
            relayPolicy: .disabled,
            bindAddress: "127.0.0.1:0"
        )
        let restoredID = try await restored.localAddress().endpointID
        try await restored.close()

        XCTAssertEqual(secret.count, 32)
        XCTAssertEqual(restoredID, firstID)
    }

    func testStoredSigningIdentityIsTheIrohEndpointIdentity() async throws {
        let identity = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 100))
        let runtime = try await IrohEndpointRuntime.bind(
            secretKey: identity.irohSecretKeyBytes(),
            relayPolicy: .disabled,
            bindAddress: "127.0.0.1:0"
        )

        let endpointID = try await runtime.localAddress().endpointID.rawValue
        let publicKeyHex = try identity.signingPublicKeyBytes()
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(endpointID, publicKeyHex)
        try await runtime.close()
    }

    func testExchangeTimeoutCancelsAnUnresponsiveIsolatedStream() async throws {
        let server = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled,
            bindAddress: "127.0.0.1:0"
        )
        let client = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled,
            bindAddress: "127.0.0.1:0"
        )
        do {
            await server.startServing { _, _ in
                try await Task.sleep(for: .seconds(5))
                return MeshTransportResponse(header: Data(#"{"ok":true}"#.utf8))
            }
            let transport = IrohMeshTransport(
                runtime: client,
                remote: try await server.localAddress()
            )

            let clock = ContinuousClock()
            let started = clock.now
            do {
                _ = try await transport.exchange(MeshTransportRequest(
                    header: Data(#"{"cmd":"slow"}"#.utf8),
                    timeoutMilliseconds: 50
                ))
                XCTFail("expected the bounded request to time out")
            } catch {
                XCTAssertEqual(error as? MeshIrohError, .timeout)
            }
            XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
        } catch {
            try? await client.close()
            try? await server.close()
            throw error
        }
        try await client.close()
        try await server.close()
    }
#endif
}
