import Foundation
import MeshKit
import XCTest
@testable import PharosMeshIroh
import PharosMeshIdentity
import PharosMeshLifecycle
import PharosMeshProtocol
import PharosMeshReplica

final class IrohMeshTransportTests: XCTestCase {
    func testMembershipControlTimeoutCoversColdRelayBudget() {
        XCTAssertGreaterThanOrEqual(
            MeshTrustGroupLifecycle.membershipRequestTimeoutMilliseconds,
            10_000
        )
    }

    func testDuplicateConnectionCloseIsRecognizedForBoundedRetry() {
        XCTAssertTrue(IrohEndpointRuntime.isDuplicateConnectionDescription(
            "ApplicationClosed reason: duplicate connection"
        ))
        XCTAssertTrue(IrohEndpointRuntime.isDuplicateConnectionDescription(
            "IrohError { kind: Stream, message: \"Read(ConnectionLost(" +
                "ApplicationClosed(ApplicationClose { error_code: 0, " +
                "reason: b\\\"duplicate connection\\\" })))\" }"
        ))
        XCTAssertFalse(IrohEndpointRuntime.isDuplicateConnectionDescription(
            "connection refused"
        ))
        XCTAssertEqual(
            (1...7).map {
                IrohEndpointRuntime.duplicateConnectionRetryDelayMilliseconds(
                    attempt: $0
                )
            },
            [150, 300, 600, 1_000, 1_000, 1_000, 1_000]
        )
        XCTAssertEqual(
            IrohEndpointRuntime.effectiveAddressTicket(
                "bootstrap-ticket", hasEstablishedPath: false,
                isDuplicateRecovery: false
            ),
            "bootstrap-ticket"
        )
        XCTAssertNil(IrohEndpointRuntime.effectiveAddressTicket(
            "bootstrap-ticket", hasEstablishedPath: true,
            isDuplicateRecovery: false
        ))
        XCTAssertNil(IrohEndpointRuntime.effectiveAddressTicket(
            "bootstrap-ticket", hasEstablishedPath: false,
            isDuplicateRecovery: true
        ))
        XCTAssertEqual(
            IrohEndpointRuntime.bootstrapTicketAttemptTimeoutMilliseconds(
                remainingMilliseconds: 10_000
            ),
            4_500
        )
        XCTAssertEqual(
            IrohEndpointRuntime.bootstrapTicketAttemptTimeoutMilliseconds(
                remainingMilliseconds: 6_000
            ),
            3_000
        )
        let lower = MeshKit.MeshEndpointID(
            rawValue: String(repeating: "0", count: 64)
        )!
        let higher = MeshKit.MeshEndpointID(
            rawValue: String(repeating: "f", count: 64)
        )!
        XCTAssertFalse(IrohEndpointRuntime.prefersRemoteColdDial(
            localEndpointID: lower, remoteEndpointID: higher
        ))
        XCTAssertTrue(IrohEndpointRuntime.prefersRemoteColdDial(
            localEndpointID: higher, remoteEndpointID: lower
        ))
        XCTAssertEqual(
            IrohEndpointRuntime.remoteColdDialGraceMilliseconds(
                requestTimeoutMilliseconds: 10_000
            ),
            4_000
        )
        XCTAssertEqual(
            IrohEndpointRuntime.remoteColdDialGraceMilliseconds(
                requestTimeoutMilliseconds: 1_000
            ),
            400
        )
    }

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
            let statusEvents = await client.statusEvents(of: serverAddress.endpointID)
            var statusIterator = statusEvents.makeAsyncIterator()
            let initialStatus = await statusIterator.next()
            XCTAssertEqual(initialStatus?.path, .unavailable)
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
            let connectedStatus = await statusIterator.next()
            XCTAssertEqual(connectedStatus?.endpointID, serverAddress.endpointID)
            XCTAssertEqual(connectedStatus?.path, .irohDirect)

            // After one ticket-assisted bootstrap, the same authenticated
            // connection is addressable by stable Endpoint ID alone.
            let identityOnly = IrohMeshTransport(
                runtime: client,
                remoteEndpointID: serverAddress.endpointID
            )
            let identityOnlyResponse = try await identityOnly.exchange(
                MeshTransportRequest(
                    header: Data(#"{"cmd":"echo"}"#.utf8),
                    body: Data("identity-only".utf8),
                    timeoutMilliseconds: 5_000
                )
            )
            XCTAssertEqual(identityOnlyResponse.body, Data("identity-only".utf8))
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

    func testConcurrentColdRequestsShareFirstConnection() async throws {
        let server = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        let client = try await IrohEndpointRuntime.bind(
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        do {
            await server.startServing { request, _ in
                try await Task.sleep(for: .milliseconds(30))
                return MeshTransportResponse(
                    header: Data("ok".utf8), body: request.body
                )
            }
            let transport = IrohMeshTransport(
                runtime: client, remote: try await server.localAddress()
            )
            async let synchronization = transport.exchange(
                MeshTransportRequest(
                    header: Data("sync".utf8), body: Data("vector".utf8),
                    timeoutMilliseconds: 1_000
                )
            )
            async let presence = transport.exchange(
                MeshTransportRequest(
                    header: Data("presence".utf8), body: Data("lease".utf8),
                    timeoutMilliseconds: 1_000
                )
            )
            let responses = try await (synchronization, presence)
            XCTAssertEqual(responses.0.body, Data("vector".utf8))
            XCTAssertEqual(responses.1.body, Data("lease".utf8))
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

    func testJoinedControllerCanPublishSignedDepartureBeforeDeactivation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pharos-iroh-lifecycle-\(UUID().uuidString)", isDirectory: true
        )
        let inviterRoot = root.appendingPathComponent("inviter", isDirectory: true)
        let joinerRoot = root.appendingPathComponent("joiner", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inviter = try MeshLocalReplica.openIsolated(rootURL: inviterRoot)
        let joiner = try MeshLocalReplica.openIsolated(rootURL: joinerRoot)
        let group = try await MeshTrustGroupLifecycle.createPersonalMesh(
            replica: inviter
        )
        let inviterRuntime = try await IrohEndpointRuntime.bind(
            secretKey: inviter.identity.irohSecretKeyBytes(),
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        let joinerRuntime = try await IrohEndpointRuntime.bind(
            secretKey: joiner.identity.irohSecretKeyBytes(),
            relayPolicy: .disabled, bindAddress: "127.0.0.1:0"
        )
        do {
            let inviterAddress = try await inviterRuntime.localAddress()
            let joinerAddress = try await joinerRuntime.localAddress()
            let router = MeshReplicaRPCServer(
                store: inviter.store,
                hostIdentity: inviter.identity,
                localAuthorRoles: [.controller, .replica],
                allowedTrustGroupID: group,
                restrictToAllowedTrustGroup: true
            )
            await inviterRuntime.startServing { request, remoteEndpointID in
                if let pairing = try? MeshTrustPairingRPCRequest.decode(request.header) {
                    guard pairing.acceptance.acceptingEndpointID == remoteEndpointID else {
                        throw MeshTrustPairingError.endpointKeyMismatch
                    }
                    let certified = try await MeshTrustGroupLifecycle
                        .certifyJoiningDevice(
                            invitation: pairing.invitation,
                            acceptance: pairing.acceptance,
                            replica: inviter,
                            runtime: inviterRuntime,
                            localAddress: inviterAddress,
                            displayName: "Inviting controller"
                        )
                    return MeshTransportResponse(
                        header: try MeshTrustPairingRPCResponse(
                            acceptedDeviceID: certified.pairedDevice.descriptor.id
                        ).encoded(),
                        body: try certified.transition.canonicalBytes()
                    )
                }
                return try await router.handle(
                    request, remoteEndpointID: remoteEndpointID
                )
            }

            let invitation = try await MeshTrustPairingService(
                identity: inviter.identity,
                invitationStore: inviter.store
            ).issueInvitation(
                trustGroupID: group,
                membershipEpoch: 1,
                inviterAddressTicket: inviterAddress.ticket,
                requestedRoles: [.controller, .replica]
            )
            let joinedGroup = try await MeshTrustGroupLifecycle.join(
                invitation,
                replica: joiner,
                runtime: joinerRuntime,
                localAddress: joinerAddress,
                displayName: "Joining controller",
                inviterDisplayName: "Inviting controller",
                replacingExisting: false
            )
            XCTAssertEqual(joinedGroup, group)
            XCTAssertEqual(try joiner.activeTrustGroup(), group)
            let inviterJoinedEpoch = try await inviter.store.membershipEpoch(for: group)
            let joinerJoinedEpoch = try await joiner.store.membershipEpoch(for: group)
            XCTAssertEqual(inviterJoinedEpoch, 2)
            XCTAssertEqual(joinerJoinedEpoch, 2)
            let joinedPeers = try await inviter.store.trustedDevices(
                in: group, membershipEpoch: 2
            )
            XCTAssertEqual(joinedPeers.map(\.descriptor.id), [joiner.identity.deviceID])

            // A response can be lost after the inviter commits epoch 2. The
            // same signature-bound device must be able to retry the still-valid
            // invitation and recover the already-certified transition without
            // advancing membership or consuming another invitation.
            let retryAcceptance = try MeshTrustPairingService(
                identity: joiner.identity, invitationStore: joiner.store
            ).createAcceptance(
                for: invitation,
                acceptingAddressTicket: joinerAddress.ticket,
                displayName: "Joining controller"
            )
            let recovered = try await MeshTrustGroupLifecycle
                .certifyJoiningDevice(
                    invitation: invitation,
                    acceptance: retryAcceptance,
                    replica: inviter,
                    runtime: inviterRuntime,
                    localAddress: inviterAddress,
                    displayName: "Inviting controller"
            )
            XCTAssertEqual(recovered.pairedDevice.descriptor.id, joiner.identity.deviceID)
            XCTAssertEqual(recovered.transition.nextEpoch, 2)
            let recoveredEpoch = try await inviter.store.membershipEpoch(for: group)
            XCTAssertEqual(recoveredEpoch, 2)

            let result = try await MeshTrustGroupLifecycle.leaveCurrentMesh(
                replica: joiner,
                runtime: joinerRuntime,
                localAddress: joinerAddress,
                displayName: "Joining controller"
            )
            XCTAssertEqual(result.archivedGroupID, group)
            XCTAssertEqual(result.nextMembershipEpoch, 3)
            XCTAssertEqual(result.acknowledgements, 1)
            XCTAssertNil(try joiner.activeTrustGroup())
            let inviterEpoch = try await inviter.store.membershipEpoch(for: group)
            let joinerEpoch = try await joiner.store.membershipEpoch(for: group)
            let survivingPeers = try await inviter.store.trustedDevices(
                in: group, membershipEpoch: 3
            )
            XCTAssertEqual(inviterEpoch, 3)
            XCTAssertEqual(joinerEpoch, 3)
            XCTAssertTrue(survivingPeers.isEmpty)
        } catch {
            try? await joinerRuntime.close()
            try? await inviterRuntime.close()
            throw error
        }
        try await joinerRuntime.close()
        try await inviterRuntime.close()
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
