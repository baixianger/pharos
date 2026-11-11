import Foundation

/// Desktop client backend kind (RFC-007 Phase E).
///
/// Only the Rust HTTP/WS path remains. Legacy `desktop-mesh` was removed.
public enum PharosClientBackendKind: String, Sendable, Codable, Equatable {
    /// HTTP/WS ClientKit talking to the Rust daemon (`pharos-web` / `pharos-meshd`).
    case rustAPI = "rust-api"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> PharosClientBackendKind {
        // Accept legacy env/defaults values but always resolve to rust-api.
        _ = environment["PHAROS_CLIENT_BACKEND"]
        _ = defaults.string(forKey: PharosAPIConfiguration.backendDefaultsKey)
        return .rustAPI
    }
}

/// Connection settings for the Rust HTTP/WS API.
public struct PharosAPIConfiguration: Sendable, Equatable {
    public static let backendDefaultsKey = "pharos.clientBackend"
    public static let baseURLDefaultsKey = "pharos.apiBaseURL"
    public static let defaultBaseURLString = "http://127.0.0.1:8787"
    public static let contractsVersion = "0.1.0"

    public var baseURL: URL
    public var backendKind: PharosClientBackendKind

    public init(baseURL: URL, backendKind: PharosClientBackendKind = .rustAPI) {
        self.baseURL = baseURL
        self.backendKind = backendKind
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> PharosAPIConfiguration {
        let kind = PharosClientBackendKind.resolve(environment: environment, defaults: defaults)
        let rawURL =
            environment["PHAROS_API_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? defaults.string(forKey: baseURLDefaultsKey)
            ?? defaultBaseURLString
        let url = URL(string: rawURL) ?? URL(string: defaultBaseURLString)!
        return PharosAPIConfiguration(baseURL: url, backendKind: kind)
    }

    public var webUIURL: URL { baseURL }
    public var healthURL: URL { baseURL.appendingPathComponent("health") }
    public var eventsWebSocketURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let scheme = (components.scheme?.lowercased() == "https") ? "wss" : "ws"
        components.scheme = scheme
        components.path = "/api/v1/events"
        return components.url ?? baseURL.appendingPathComponent("api/v1/events")
    }

    public func apiURL(_ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(trimmed)
    }
}
