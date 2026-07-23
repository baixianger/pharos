import Foundation
import Observation
import PharosMeshProtocol

struct PendingDeviceInvitation: Identifiable {
    let invitation: MeshTrustInvitation
    var id: String {
        invitation.trustGroupID.rawValue.uuidString + ":" +
            invitation.inviterDeviceID.rawValue.uuidString
    }
}

struct PairingLink: Sendable, Equatable, Identifiable {
    var version: Int
    var host: String
    var port: UInt16
    var brokerID: String
    var token: String
    var expiresAt: Double

    var id: String { token }
    var endpoint: String { "\(host):\(port)" }
    var isExpired: Bool { expiresAt <= Date().timeIntervalSince1970 }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "pharos",
              components.host?.lowercased() == "pair" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { return nil }
            values[item.name] = value
        }
        guard let version = values["v"].flatMap(Int.init), version == 1,
              let host = values["host"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty, !host.contains("\n"), !host.contains("\r"),
              let port = values["port"].flatMap(UInt16.init),
              let brokerID = values["broker"], !brokerID.isEmpty,
              let token = values["token"], token.count >= 20,
              let expiresAt = values["expires"].flatMap(Double.init) else { return nil }
        self.version = version
        self.host = host
        self.port = port
        self.brokerID = brokerID
        self.token = token
        self.expiresAt = expiresAt
    }
}

@Observable
@MainActor
final class PairingCoordinator {
    var pending: PairingLink?
    var pendingDevice: PendingDeviceInvitation?
    var errorMessage: String?
    var showsError = false
    /// Drives the personal-Mesh setup cover. It is auto-shown until this
    /// device creates or joins a trust group and remains reopenable later.
    var showsSetupGuide = false

    func receive(_ url: URL) {
        if let invitation = try? MeshTrustInvitationLink.decode(url) {
            errorMessage = nil
            // Device confirmation has one app-level presenter. Close the
            // onboarding cover before publishing the pending invitation so
            // SwiftUI never tries to stack the same sheet from two levels.
            showsSetupGuide = false
            pendingDevice = PendingDeviceInvitation(invitation: invitation)
            return
        }
        guard let invitation = PairingLink(url: url), !invitation.isExpired else {
            errorMessage = "This pairing code is invalid or has expired."
            showsError = true
            return
        }
        errorMessage = nil
        pending = invitation
    }

    func receive(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invitation = try? MeshTrustInvitationTicket.decode(trimmed) {
            errorMessage = nil
            showsSetupGuide = false
            pendingDevice = PendingDeviceInvitation(invitation: invitation)
            return
        }
        guard let url = URL(string: trimmed) else {
            errorMessage = "The scanned QR code is not a Pharos pairing link."
            showsError = true
            return
        }
        receive(url)
    }
}
