import Foundation
import XCTest
@testable import PharosMeshIdentity
import PharosMeshProtocol

final class MeshTrustPairingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testTicketRoundTripAndDescriptionsRedactBearerMaterial() async throws {
        let fixture = Fixture()
        let invitation = try await fixture.inviterService.issueInvitation(
            trustGroupID: fixture.group,
            membershipEpoch: 7,
            inviterAddressTicket: "iroh-inviter-ticket",
            requestedRoles: [.controller, .replica],
            now: now
        )

        let ticket = try MeshTrustInvitationTicket.encode(invitation)
        let decoded = try MeshTrustInvitationTicket.decode(ticket)
        XCTAssertEqual(decoded, invitation)
        XCTAssertTrue(ticket.hasPrefix(MeshTrustInvitationTicket.prefix))
        XCTAssertTrue(invitation.description.contains("<redacted>"))
        XCTAssertTrue(String(reflecting: invitation).contains("<redacted>"))
        XCTAssertFalse(invitation.description.contains(invitation.nonce.base64EncodedString()))
        XCTAssertFalse(String(reflecting: invitation).contains(invitation.nonce.base64EncodedString()))

        let acceptance = try fixture.acceptorService.createAcceptance(
            for: decoded,
            acceptingAddressTicket: "iroh-acceptor-ticket",
            displayName: "  iPhone  ",
            now: now
        )
        XCTAssertTrue(acceptance.description.contains("<redacted>"))
        XCTAssertTrue(String(reflecting: acceptance).contains("<redacted>"))
        XCTAssertFalse(acceptance.description.contains(acceptance.signature.base64EncodedString()))
    }

    func testSignedInvitationAcceptanceAndSingleUseRedemption() async throws {
        let fixture = Fixture()
        let invitation = try await fixture.inviterService.issueInvitation(
            trustGroupID: fixture.group,
            membershipEpoch: 3,
            inviterAddressTicket: "iroh-inviter-ticket",
            requestedRoles: [.controller],
            now: now
        )
        let acceptance = try fixture.acceptorService.createAcceptance(
            for: invitation,
            acceptingAddressTicket: "iroh-acceptor-ticket",
            displayName: "iPhone",
            now: now
        )

        let paired = try await fixture.inviterService.redeem(
            acceptance, for: invitation, now: now
        )
        XCTAssertEqual(paired.descriptor.id, fixture.acceptor.deviceID)
        XCTAssertEqual(paired.descriptor.endpointID, try fixture.acceptor.endpointID())
        XCTAssertEqual(paired.descriptor.roles, [.controller])
        XCTAssertEqual(paired.signingPublicKey, try fixture.acceptor.signingPublicKeyBytes())
        let stored = await fixture.store.trustedDevice(
            in: fixture.group, id: fixture.acceptor.deviceID
        )
        XCTAssertEqual(stored, paired)

        await XCTAssertThrowsErrorAsync(
            try await fixture.inviterService.redeem(acceptance, for: invitation, now: now)
        ) {
            XCTAssertEqual($0 as? MeshTrustPairingError, .invitationAlreadyConsumed)
        }
    }

    func testTamperingExpiryAndEndpointKeyMismatchAreRejected() async throws {
        let fixture = Fixture()
        let invitation = try await fixture.inviterService.issueInvitation(
            trustGroupID: fixture.group,
            membershipEpoch: 2,
            inviterAddressTicket: "iroh-inviter-ticket",
            requestedRoles: [.replica],
            now: now,
            lifetimeMilliseconds: 1_000
        )

        var tampered = invitation
        tampered.inviterAddressTicket = "attacker-ticket"
        XCTAssertThrowsError(try fixture.inviterService.verifyInvitation(tampered, now: now)) {
            XCTAssertEqual($0 as? MeshTrustPairingError, .invalidSignature)
        }

        XCTAssertThrowsError(
            try fixture.inviterService.verifyInvitation(
                invitation, now: now.addingTimeInterval(1)
            )
        ) {
            XCTAssertEqual($0 as? MeshTrustPairingError, .invitationExpired)
        }

        var mismatched = invitation
        mismatched.inviterEndpointID = try fixture.acceptor.endpointID()
        mismatched.signature = try fixture.inviter.signature(
            for: mismatched.canonicalSigningBytes()
        )
        XCTAssertThrowsError(try fixture.inviterService.verifyInvitation(mismatched, now: now)) {
            XCTAssertEqual($0 as? MeshTrustPairingError, .endpointKeyMismatch)
        }

        var overflowingLifetime = invitation
        overflowingLifetime.issuedAtMilliseconds = .max
        overflowingLifetime.expiresAtMilliseconds = .min
        XCTAssertThrowsError(try overflowingLifetime.validateStructure()) {
            XCTAssertEqual(
                $0 as? MeshTrustInvitationValidationError, .invalidLifetime
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await fixture.inviterService.issueInvitation(
                trustGroupID: fixture.group,
                membershipEpoch: UInt64.max,
                inviterAddressTicket: "iroh-inviter-ticket",
                requestedRoles: [.replica],
                now: now
            )
        ) {
            XCTAssertEqual(
                $0 as? MeshTrustInvitationValidationError, .invalidMembershipEpoch
            )
        }
    }

    func testConcurrentRedemptionHasExactlyOneWinner() async throws {
        let fixture = Fixture()
        let invitation = try await fixture.inviterService.issueInvitation(
            trustGroupID: fixture.group,
            membershipEpoch: 1,
            inviterAddressTicket: "iroh-inviter-ticket",
            requestedRoles: [.replica],
            now: now
        )
        let acceptance = try fixture.acceptorService.createAcceptance(
            for: invitation,
            acceptingAddressTicket: "iroh-acceptor-ticket",
            displayName: "iPad",
            now: now
        )

        let redemptionNow = now
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        _ = try await fixture.inviterService.redeem(
                            acceptance, for: invitation, now: redemptionNow
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
    }

    private struct Fixture: Sendable {
        let group = MeshTrustGroupID()
        let inviter = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 10))
        let acceptor = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 20))
        let store = MeshMemoryInvitationUseStore()

        var inviterService: MeshTrustPairingService {
            MeshTrustPairingService(identity: inviter, invitationStore: store)
        }

        var acceptorService: MeshTrustPairingService {
            MeshTrustPairingService(
                identity: acceptor,
                invitationStore: MeshMemoryInvitationUseStore()
            )
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
