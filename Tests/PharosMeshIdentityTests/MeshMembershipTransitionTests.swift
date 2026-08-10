import XCTest
@testable import PharosMeshIdentity
import PharosMeshProtocol

final class MeshMembershipTransitionTests: XCTestCase {
    func testThreeControllerTransitionRequiresAndVerifiesTwoVotes() throws {
        let group = MeshTrustGroupID()
        let a = MeshDeviceIdentity.generate()
        let b = MeshDeviceIdentity.generate()
        let c = MeshDeviceIdentity.generate()
        let roster = try [
            paired(a, name: "A"), paired(b, name: "B"), paired(c, name: "C"),
        ]
        let controllers = roster.map(MeshMembershipControllerIdentity.init)
        let proposal = try MeshMembershipTransitionSigner.propose(
            trustGroupID: group, previousEpoch: 7, identity: a,
            previousControllers: controllers, roster: roster
        )

        XCTAssertThrowsError(try proposal.verifySignature()) {
            XCTAssertEqual(
                $0 as? MeshMembershipTransitionError,
                .insufficientQuorum(required: 2, actual: 1)
            )
        }

        let certified = try MeshMembershipTransitionSigner.certify(
            proposal,
            approvals: [try MeshMembershipTransitionSigner.approve(proposal, with: b)]
        )
        XCTAssertNoThrow(try certified.verifySignature())
        XCTAssertEqual(certified.version, MeshMembershipTransition.quorumVersion)
        XCTAssertEqual(certified.approvals?.map(\.deviceID), [b.deviceID])
    }

    func testDuplicateAndNonControllerApprovalsAreRejected() throws {
        let group = MeshTrustGroupID()
        let a = MeshDeviceIdentity.generate()
        let b = MeshDeviceIdentity.generate()
        let outsider = MeshDeviceIdentity.generate()
        let roster = try [paired(a, name: "A"), paired(b, name: "B")]
        let proposal = try MeshMembershipTransitionSigner.propose(
            trustGroupID: group, previousEpoch: 1, identity: a,
            previousControllers: roster.map(MeshMembershipControllerIdentity.init),
            roster: roster
        )
        let approval = try MeshMembershipTransitionSigner.approve(proposal, with: b)

        XCTAssertThrowsError(
            try MeshMembershipTransitionSigner.certify(
                proposal, approvals: [approval, approval]
            )
        ) {
            XCTAssertEqual(
                $0 as? MeshMembershipTransitionError, .invalidSignature
            )
        }
        XCTAssertThrowsError(
            try MeshMembershipTransitionSigner.approve(proposal, with: outsider)
        ) {
            XCTAssertEqual(
                $0 as? MeshMembershipTransitionError, .authorNotController
            )
        }
    }

    func testApprovalCannotBeReplayedOntoDifferentRoster() throws {
        let group = MeshTrustGroupID()
        let a = MeshDeviceIdentity.generate()
        let b = MeshDeviceIdentity.generate()
        let c = MeshDeviceIdentity.generate()
        let originalRoster = try [
            paired(a, name: "A"), paired(b, name: "B"), paired(c, name: "C"),
        ]
        let controllers = originalRoster.map(MeshMembershipControllerIdentity.init)
        let first = try MeshMembershipTransitionSigner.propose(
            trustGroupID: group, previousEpoch: 3, identity: a,
            previousControllers: controllers, roster: originalRoster
        )
        let approval = try MeshMembershipTransitionSigner.approve(first, with: b)
        let conflicting = try MeshMembershipTransitionSigner.propose(
            trustGroupID: group, previousEpoch: 3, identity: a,
            previousControllers: controllers,
            roster: Array(originalRoster.dropLast())
        )

        XCTAssertThrowsError(
            try MeshMembershipTransitionSigner.certify(
                conflicting, approvals: [approval]
            )
        ) {
            XCTAssertEqual(
                $0 as? MeshMembershipTransitionError, .invalidSignature
            )
        }
    }

    private func paired(
        _ identity: MeshDeviceIdentity, name: String
    ) throws -> MeshPairedDevice {
        MeshPairedDevice(
            descriptor: MeshDeviceDescriptor(
                id: identity.deviceID,
                endpointID: try identity.endpointID(),
                displayName: name,
                roles: [.controller, .replica]
            ),
            signingPublicKey: try identity.signingPublicKeyBytes(),
            addressTicket: "test-\(identity.deviceID.rawValue.uuidString)"
        )
    }
}
