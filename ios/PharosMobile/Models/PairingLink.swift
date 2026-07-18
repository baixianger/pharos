import Foundation
import Observation

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
    var errorMessage: String?
    var showsError = false
    /// Drives the broker-setup wizard cover. Auto-shown on first run (no
    /// broker) and re-openable from Settings; the wizard's close button and a
    /// successful pairing both clear it.
    var showsSetupGuide = false

    func receive(_ url: URL) {
        guard let invitation = PairingLink(url: url), !invitation.isExpired else {
            errorMessage = "This pairing code is invalid or has expired."
            showsError = true
            return
        }
        errorMessage = nil
        pending = invitation
    }

    func receive(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "The scanned QR code is not a Pharos pairing link."
            showsError = true
            return
        }
        receive(url)
    }
}
