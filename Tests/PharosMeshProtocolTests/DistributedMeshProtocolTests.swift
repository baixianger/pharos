import Foundation
import XCTest
@testable import PharosMeshProtocol

final class DistributedMeshProtocolTests: XCTestCase {
    func testEndpointIDIsOpaqueButSafe() throws {
        let value = try XCTUnwrap(MeshEndpointID(rawValue: "  endpoint-public-key  "))
        XCTAssertEqual(value.rawValue, "endpoint-public-key")
        XCTAssertNil(MeshEndpointID(rawValue: ""))
        XCTAssertNil(MeshEndpointID(rawValue: "endpoint\nkey"))
    }

    func testDeviceDescriptorRoundTripsWithoutNetworkAddress() throws {
        let endpoint = try XCTUnwrap(MeshEndpointID(rawValue: "public-key"))
        let descriptor = MeshDeviceDescriptor(
            id: MeshDeviceID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            endpointID: endpoint,
            displayName: "Studio Mac",
            roles: [.controller, .host]
        )

        let data = try JSONEncoder().encode(descriptor)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("192.168."))
        XCTAssertFalse(json.lowercased().contains("tailscale"))
        XCTAssertEqual(try JSONDecoder().decode(MeshDeviceDescriptor.self, from: data), descriptor)
    }

    func testTransportRequestEnforcesBoundsAndDeadline() throws {
        try MeshTransportRequest(header: Data("{}".utf8)).validate()

        XCTAssertThrowsError(try MeshTransportRequest(header: Data()).validate()) {
            XCTAssertEqual($0 as? MeshTransportContractError, .emptyHeader)
        }
        XCTAssertThrowsError(try MeshTransportRequest(
            header: Data(repeating: 0, count: DistributedMeshProtocol.maximumHeaderBytes + 1)
        ).validate()) {
            XCTAssertEqual($0 as? MeshTransportContractError, .headerTooLarge)
        }
        XCTAssertThrowsError(try MeshTransportRequest(
            header: Data("{}".utf8),
            body: Data(repeating: 0, count: DistributedMeshProtocol.maximumBlobBytes + 1)
        ).validate()) {
            XCTAssertEqual($0 as? MeshTransportContractError, .bodyTooLarge)
        }
        XCTAssertThrowsError(try MeshTransportRequest(
            header: Data("{}".utf8), timeoutMilliseconds: 0
        ).validate()) {
            XCTAssertEqual($0 as? MeshTransportContractError, .invalidTimeout)
        }
    }

    func testConnectionSnapshotContainsPathWithoutAddress() throws {
        let snapshot = MeshConnectionSnapshot(
            peer: MeshDeviceID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
            path: .irohRelay,
            connected: true,
            lastChange: Date(timeIntervalSince1970: 1_721_467_260)
        )
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertTrue(json.contains("iroh-relay"))
        XCTAssertFalse(json.contains("host"))
        XCTAssertFalse(json.contains("port"))
    }

    func testUUIDv7GenerationRetainsTimestampPrefix() throws {
        let date = Date(timeIntervalSince1970: 1_721_467_260.123)
        let first = MeshEventID.generate(at: date)
        let second = MeshEventID.generate(at: date.addingTimeInterval(0.001))

        XCTAssertLessThan(first, second)
        XCTAssertNotNil(MeshEventID(rawValue: first.rawValue))
        XCTAssertNil(MeshEventID(rawValue: UUID()))
    }

    func testEventStructureRequiresHashChainAndSignature() throws {
        var event = makeEvent(sequence: 1)
        try event.validateStructure(requireSignature: false)

        event.previousEventHash = Data(repeating: 1, count: 32)
        XCTAssertThrowsError(try event.validateStructure(requireSignature: false)) {
            XCTAssertEqual($0 as? MeshSchemaValidationError, .invalidPreviousHash)
        }

        event = makeEvent(sequence: 2)
        XCTAssertThrowsError(try event.validateStructure(requireSignature: false)) {
            XCTAssertEqual($0 as? MeshSchemaValidationError, .invalidPreviousHash)
        }
        event.previousEventHash = Data(repeating: 2, count: 32)
        try event.validateStructure(requireSignature: false)
    }

    func testCanonicalSigningBytesAreStableAndExcludeSignature() throws {
        var event = makeEvent(sequence: 1)
        let unsigned = try event.canonicalSigningBytes()
        event.signature = Data(repeating: 7, count: 64)

        XCTAssertEqual(try event.canonicalSigningBytes(), unsigned)
        XCTAssertNotEqual(try event.canonicalBytes(), unsigned)
        XCTAssertEqual(try event.canonicalBytes(), try event.canonicalBytes())
    }

    func testHostCommandRequiresGenerationAndFutureDeadline() throws {
        let endpoint = try XCTUnwrap(MeshEndpointID(rawValue: "host-endpoint"))
        let resource = try XCTUnwrap(MeshResourceID(rawValue: "tmux/session-1"))
        var command = MeshHostCommand(
            trustGroupID: MeshTrustGroupID(), senderDeviceID: MeshDeviceID(),
            targetHostDeviceID: MeshDeviceID(), targetHostEndpointID: endpoint,
            resourceID: resource, expectedResourceGeneration: 4, action: .poke,
            idempotencyKey: "poke/session-1/4", createdAt: .init(wallTimeMilliseconds: 100),
            deadlineMilliseconds: 200
        )
        try command.validate()

        command.expectedResourceGeneration = 0
        XCTAssertThrowsError(try command.validate()) {
            XCTAssertEqual($0 as? MeshSchemaValidationError, .invalidResourceGeneration)
        }
        command.expectedResourceGeneration = 4
        command.deadlineMilliseconds = 100
        XCTAssertThrowsError(try command.validate()) {
            XCTAssertEqual($0 as? MeshSchemaValidationError, .invalidDeadline)
        }
    }

    func testReceiptStateMachineCannotReplayTerminalWork() throws {
        let resource = try XCTUnwrap(MeshResourceID(rawValue: "agent/one"))
        var receipt = MeshCommandReceipt(
            commandID: MeshCommandID(), idempotencyKey: "spawn/one",
            hostDeviceID: MeshDeviceID(), resourceID: resource, resourceGeneration: 1,
            state: .accepted, acceptedAt: .init(wallTimeMilliseconds: 10),
            updatedAt: .init(wallTimeMilliseconds: 10)
        )
        try receipt.validateTransition(to: .executing)
        XCTAssertThrowsError(try receipt.validateTransition(to: .executed))

        receipt.state = .executed
        XCTAssertTrue(receipt.state.isTerminal)
        XCTAssertThrowsError(try receipt.validateTransition(to: .executing)) {
            XCTAssertEqual($0 as? MeshSchemaValidationError, .invalidStateTransition)
        }
    }

    private func makeEvent(sequence: UInt64) -> MeshReplicatedEvent {
        MeshReplicatedEvent(
            id: .generate(at: Date(timeIntervalSince1970: 1_721_467_260)),
            trustGroupID: MeshTrustGroupID(), authorDeviceID: MeshDeviceID(),
            authorEndpointID: MeshEndpointID(rawValue: "author-endpoint")!,
            authorSequence: sequence, membershipEpoch: 1,
            hybridTimestamp: .init(wallTimeMilliseconds: 1_721_467_260_000),
            entity: MeshEntityReference(type: .message, id: "message-1")!,
            operation: MeshOperationName(rawValue: "message.create.v1")!,
            payload: Data("{\"text\":\"hello\"}".utf8), previousEventHash: nil
        )
    }
}
