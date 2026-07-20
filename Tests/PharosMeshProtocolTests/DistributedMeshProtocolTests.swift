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

    func testPhaseOneTransportSelectionRejectsExplicitIroh() throws {
        XCTAssertEqual(try MeshTransportPreference.legacy.resolved(irohAvailable: false), .legacy)
        XCTAssertEqual(try MeshTransportPreference.automatic.resolved(irohAvailable: false), .legacy)
        XCTAssertThrowsError(try MeshTransportPreference.iroh.resolved(irohAvailable: false)) {
            XCTAssertEqual($0 as? MeshTransportSelectionError, .irohUnavailable)
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

    func testIrohStreamFrameRoundTripsHeaderAndAttachment() throws {
        let frame = MeshStreamFrame(
            kind: .request,
            header: Data(#"{"cmd":"attachment-put"}"#.utf8),
            body: Data([0, 1, 2, 3, 255])
        )
        let encoded = try MeshStreamFrameCodec.encode(frame)

        XCTAssertEqual(encoded.prefix(4), Data("PHM1".utf8))
        XCTAssertEqual(try MeshStreamFrameCodec.decode(encoded), frame)
    }

    func testIrohStreamFrameRejectsMalformedAndOversizedLengthsBeforePayloadDecode() throws {
        let valid = try MeshStreamFrameCodec.encode(
            MeshStreamFrame(kind: .response, header: Data("{}".utf8))
        )

        XCTAssertThrowsError(try MeshStreamFrameCodec.decode(valid.dropLast())) {
            XCTAssertEqual($0 as? MeshStreamFrameError, .lengthMismatch)
        }

        var invalidKind = valid
        invalidKind[4] = 99
        XCTAssertThrowsError(try MeshStreamFrameCodec.decode(invalidKind)) {
            XCTAssertEqual($0 as? MeshStreamFrameError, .invalidKind)
        }

        var oversizedBody = valid
        let declared = UInt64(DistributedMeshProtocol.maximumBlobBytes + 1).bigEndian
        withUnsafeBytes(of: declared) { oversizedBody.replaceSubrange(12..<20, with: $0) }
        XCTAssertThrowsError(try MeshStreamFrameCodec.decode(oversizedBody)) {
            XCTAssertEqual($0 as? MeshStreamFrameError, .bodyTooLarge)
        }
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

    func testLegacyRequestGoldenJSONRemainsByteCompatible() throws {
        let fixture = try fixtureData(named: "legacy-request")
        let request = try JSONDecoder().decode(MeshRequest.self, from: fixture)
        XCTAssertEqual(request.cmd, "node-command-enqueue")
        XCTAssertEqual(request.action, "poke")
        XCTAssertEqual(request.memberID, "member-1")
        XCTAssertEqual(try canonicalLegacyJSON(request), fixture)
    }

    func testLegacyResponseGoldenJSONRemainsByteCompatible() throws {
        let fixture = try fixtureData(named: "legacy-response")
        let response = try JSONDecoder().decode(MeshResponse.self, from: fixture)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.cursor, 42)
        XCTAssertEqual(response.messages?.first?.stableID, "message-1")
        XCTAssertEqual(response.command?.action, .poke)
        XCTAssertEqual(response.command?.state, .accepted)
        XCTAssertEqual(try canonicalLegacyJSON(response), fixture)
    }

    func testLegacyMessageToleratesMissingIDTargetsAndFutureFields() throws {
        let data = Data(#"{"from":"old","room":"dev","text":"hello","ts":12,"futureField":{"v":2}}"#.utf8)
        let message = try JSONDecoder().decode(MeshMsg.self, from: data)
        XCTAssertNil(message.id)
        XCTAssertEqual(message.to, [])
        XCTAssertEqual(message.stableID, "legacy|dev|12.0|old")
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return Data(data.drop(while: { $0 == 0x0a || $0 == 0x0d || $0 == 0x20 })
            .reversed().drop(while: { $0 == 0x0a || $0 == 0x0d || $0 == 0x20 }).reversed())
    }

    private func canonicalLegacyJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
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
