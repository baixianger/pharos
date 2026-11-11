import Foundation

/// Which desktop client backend to use (RFC-007 Phase D / S6).
///
/// Toggle:
/// - Environment `PHAROS_CLIENT_BACKEND` = `rust-api` (default) | `desktop-mesh`
/// - Or `UserDefaults` key `pharos.clientBackend` with the same values
public enum PharosClientBackendKind: String, Sendable, Codable, Equatable {
    /// HTTP/WS ClientKit talking to the S4 Rust daemon (`pharos-web` / `pharos-meshd`).
    case rustAPI = "rust-api"
    /// Legacy in-process DesktopMesh / Runtime path (kept until Phase E).
    case desktopMesh = "desktop-mesh"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> PharosClientBackendKind {
        if let raw = environment["PHAROS_CLIENT_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let kind = PharosClientBackendKind(rawValue: raw) {
            return kind
        }
        if let raw = defaults.string(forKey: PharosAPIConfiguration.backendDefaultsKey),
           let kind = PharosClientBackendKind(rawValue: raw) {
            return kind
        }
        return .rustAPI
    }
}

/// Connection settings for the Rust HTTP/WS API (S4 base URL).
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
