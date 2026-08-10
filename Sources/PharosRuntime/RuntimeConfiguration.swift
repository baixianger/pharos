import Foundation
import PharosMeshCore

public enum PharosRuntimeRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case node
    case broker

    public var id: String { rawValue }
    public var displayName: String { self == .node ? "Node" : "Broker + Node" }
}

public struct PharosRuntimeConfiguration: Codable, Equatable, Sendable {
    public var role: PharosRuntimeRole
    public var remoteBrokerEndpoint: String

    public init(role: PharosRuntimeRole, remoteBrokerEndpoint: String = "") {
        self.role = role
        self.remoteBrokerEndpoint = remoteBrokerEndpoint
    }

    public var validRemoteBrokerEndpoint: String? {
        let value = remoteBrokerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return meshSplitHostPort(value) == nil ? nil : value
    }

    public func validated() throws -> Self {
        if role == .node, validRemoteBrokerEndpoint == nil {
            throw PharosRuntimeError.invalidRemoteBrokerEndpoint
        }
        return self
    }
}

public enum PharosRuntimeError: LocalizedError, Equatable {
    case invalidRemoteBrokerEndpoint
    case tailscaleUnavailable
    case helperUnavailable
    case missingBrokerCredential(String)
    case commandFailed(String)
    case brokerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRemoteBrokerEndpoint:
            return "Node mode requires a valid remote Broker endpoint (host:port)."
        case .tailscaleUnavailable:
            return "Broker mode requires this Mac to have a Tailscale IPv4 address."
        case .helperUnavailable:
            return "The pharos-mesh helper is not installed beside this Pharos build."
        case .missingBrokerCredential(let endpoint):
            return "No saved pairing credential exists for \(endpoint). Pair with that Broker again before switching."
        case .commandFailed(let message), .brokerUnavailable(let message):
            return message
        }
    }
}

/// Device-local runtime preferences. Project data never carries machine roles.
public struct PharosRuntimeConfigurationStore {
    public static let appDomain = "me.pai.pharos"
    public static let roleKey = "pharos.runtimeRole"
    public static let endpointKey = "pharos.meshServerEndpoint"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.appDomain) ?? .standard
    }

    public var isConfigured: Bool {
        defaults.string(forKey: Self.roleKey) != nil
            || defaults.bool(forKey: "pharos.hostBroker")
            || !(defaults.string(forKey: Self.endpointKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func load() -> PharosRuntimeConfiguration {
        let role = defaults.string(forKey: Self.roleKey).flatMap(PharosRuntimeRole.init(rawValue:))
            ?? (defaults.bool(forKey: "pharos.hostBroker") ? .broker : .node)
        return PharosRuntimeConfiguration(
            role: role,
            remoteBrokerEndpoint: defaults.string(forKey: Self.endpointKey) ?? ""
        )
    }

    public func save(_ configuration: PharosRuntimeConfiguration) {
        defaults.set(configuration.role.rawValue, forKey: Self.roleKey)
        defaults.set(configuration.remoteBrokerEndpoint, forKey: Self.endpointKey)
        // Rolling compatibility for builds that still read the old role flag.
        defaults.set(configuration.role == .broker, forKey: "pharos.hostBroker")
        defaults.set(true, forKey: "pharos.launchMeshAtLogin")
    }
}
