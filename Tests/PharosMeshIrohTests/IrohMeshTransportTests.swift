import Foundation
import XCTest
@testable import PharosMeshIroh
import PharosMeshIdentity
import PharosMeshProtocol
import PharosMeshReplica

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

    func testOneConnectionCarriesRequestsInBothDirections() async throws {
        let first = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        let second = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        do {
            await first.startServing { request, _ in
                MeshTransportResponse(
                    header: Data("first".utf8), body: request.body
                )
            }
            await second.startServing { request, _ in
                MeshTransportResponse(
                    header: Data("second".utf8), body: request.body
                )
            }
            let firstAddress = try await first.localAddress()
            let secondAddress = try await second.localAddress()
            let secondToFirst = IrohMeshTransport(
                runtime: second, remote: firstAddress
            )
            let forward = try await secondToFirst.exchange(
                MeshTransportRequest(
                    header: Data("forward".utf8),
                    timeoutMilliseconds: 5_000
                )
            )
            XCTAssertEqual(forward.header, Data("first".utf8))

            // `first` reuses the incoming connection established above. The
            // initiator must accept reverse streams on that same connection.
            let firstToSecond = IrohMeshTransport(
                runtime: first, remote: secondAddress
            )
            let reverse = try await firstToSecond.exchange(
                MeshTransportRequest(
                    header: Data("reverse".utf8),
                    timeoutMilliseconds: 5_000
                )
            )
            XCTAssertEqual(reverse.header, Data("second".utf8))
        } catch {
            try? await first.close()
            try? await second.close()
            throw error
        }
        try await first.close()
        try await second.close()
    }

    func testSimultaneousDialConvergesOnOneBidirectionalConnection() async throws {
        let first = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        let second = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        do {
            await first.startServing { request, _ in
                MeshTransportResponse(header: Data("first".utf8), body: request.body)
            }
            await second.startServing { request, _ in
                MeshTransportResponse(header: Data("second".utf8), body: request.body)
            }
            let firstAddress = try await first.localAddress()
            let secondAddress = try await second.localAddress()
            let firstToSecond = IrohMeshTransport(runtime: first, remote: secondAddress)
            let secondToFirst = IrohMeshTransport(runtime: second, remote: firstAddress)

            async let forward = firstToSecond.exchange(MeshTransportRequest(
                header: Data("forward".utf8), timeoutMilliseconds: 1_000
            ))
            async let reverse = secondToFirst.exchange(MeshTransportRequest(
                header: Data("reverse".utf8), timeoutMilliseconds: 1_000
            ))
            let initial = try await (forward, reverse)
            XCTAssertEqual(initial.0.header, Data("second".utf8))
            XCTAssertEqual(initial.1.header, Data("first".utf8))
            try await Task.sleep(for: .milliseconds(50))

            // The next round must reuse the canonical survivor in both directions.
            let forwardAgain = try await firstToSecond.exchange(MeshTransportRequest(
                header: Data("forward-again".utf8), timeoutMilliseconds: 1_000
            ))
            let reverseAgain = try await secondToFirst.exchange(MeshTransportRequest(
                header: Data("reverse-again".utf8), timeoutMilliseconds: 1_000
            ))
            XCTAssertEqual(forwardAgain.header, Data("second".utf8))
            XCTAssertEqual(reverseAgain.header, Data("first".utf8))
        } catch {
            try? await first.close()
            try? await second.close()
            throw error
        }
        try await first.close()
        try await second.close()
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

    func testLocalAddressOwnsFFIStringsAfterAllocationChurn() async throws {
        let runtime = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        let address = try await runtime.localAddress()
        let expectedEndpointID = String(
            decoding: Array(address.endpointID.rawValue.utf8), as: UTF8.self
        )
        let expectedTicket = String(
            decoding: Array(address.ticket.utf8), as: UTF8.self
        )
        for index in 0..<1_000 {
            _ = Data(repeating: UInt8(truncatingIfNeeded: index), count: 4_096)
        }

        XCTAssertEqual(address.endpointID.rawValue.count, 64)
        XCTAssertEqual(address.endpointID.rawValue, expectedEndpointID)
        XCTAssertEqual(address.ticket, expectedTicket)
        XCTAssertTrue(address.ticket.hasPrefix("pharos-iroh-v1:"))
        try await runtime.close()
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

    func testAuthenticatedReplicaRPCUsesConnectionEndpointIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pharos-iroh-rpc-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = MeshTrustGroupID()
        let serverIdentity = MeshDeviceIdentity.generate()
        let clientIdentity = MeshDeviceIdentity.generate()
        let store = try DistributedMeshStore(
            databaseURL: directory.appendingPathComponent("replica.sqlite")
        )
        try await store.setMembershipEpoch(1, for: group)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pairing = MeshTrustPairingService(
            identity: serverIdentity, invitationStore: store
        )
        let invitation = try await pairing.issueInvitation(
            trustGroupID: group, membershipEpoch: 1,
            inviterAddressTicket: "isolated-server-ticket",
            requestedRoles: [.replica], now: now
        )
        let acceptance = try MeshTrustPairingService(
            identity: clientIdentity,
            invitationStore: MeshMemoryInvitationUseStore()
        ).createAcceptance(
            for: invitation, acceptingAddressTicket: "isolated-client-ticket",
            displayName: "Iroh RPC Client", now: now
        )
        _ = try await pairing.redeem(acceptance, for: invitation, now: now)

        let serverRuntime = try await IrohEndpointRuntime.bind(
            secretKey: serverIdentity.irohSecretKeyBytes(),
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        let clientRuntime = try await IrohEndpointRuntime.bind(
            secretKey: clientIdentity.irohSecretKeyBytes(),
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        do {
            let router = MeshReplicaRPCServer(store: store)
            await serverRuntime.startServing { request, remoteEndpointID in
                try await router.handle(
                    request, remoteEndpointID: remoteEndpointID
                )
            }
            let transport = IrohMeshTransport(
                runtime: clientRuntime,
                remote: try await serverRuntime.localAddress()
            )
            let vector = try await MeshReplicaRPCClient(
                transport: transport
            ).syncVector(for: group, membershipEpoch: 1)
            XCTAssertEqual(vector.trustGroupID, group)
            XCTAssertEqual(vector.membershipEpoch, 1)
            XCTAssertEqual(vector.authors, [])
        } catch {
            try? await clientRuntime.close()
            try? await serverRuntime.close()
            throw error
        }
        try await clientRuntime.close()
        try await serverRuntime.close()
    }

    func testExchangeTimeoutReturnsWithoutWaitingForAnUnresponsiveStream() async throws {
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
