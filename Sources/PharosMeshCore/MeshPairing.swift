import Foundation

/// A short-lived invitation that lets another Pharos client configure the
/// currently active Broker without exposing whether it runs locally, on
/// another Mac, or on Linux.
public struct MeshPairingLink: Codable, Sendable, Equatable {
    public static let scheme = "pharos"
    public static let action = "pair"

    public var version: Int
    public var host: String
    public var port: UInt16
    public var brokerID: String
    public var token: String
    public var expiresAt: Double

    public init(version: Int = 1, host: String, port: UInt16, brokerID: String,
                token: String, expiresAt: Double) {
        self.version = version
        self.host = host
        self.port = port
        self.brokerID = brokerID
        self.token = token
        self.expiresAt = expiresAt
    }

    public var endpoint: String { "\(host):\(port)" }
    public var isExpired: Bool { expiresAt <= Date().timeIntervalSince1970 }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.action
        components.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "broker", value: brokerID),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "expires", value: String(Int(expiresAt))),
        ]
        return components.url
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.action else { return nil }
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
        self.init(version: version, host: host, port: port, brokerID: brokerID,
                  token: token, expiresAt: expiresAt)
    }
}
