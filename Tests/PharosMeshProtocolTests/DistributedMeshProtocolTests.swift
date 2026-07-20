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
}
