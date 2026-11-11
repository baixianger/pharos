import Foundation
import PharosClientKit

/// Composition root for the desktop client backend (RFC-007 Phase E).
///
/// Always uses `rust-api` → `HttpPharosClientService` talking to the Rust daemon.
/// The legacy `desktop-mesh` path was removed in Phase E.
@MainActor
enum PharosClientBackend {
    /// Resolved configuration (API base URL).
    static var configuration: PharosAPIConfiguration { .resolve() }

    /// Daemon-served Web UI URL for WebKit.
    static var webUIBaseURL: URL? { configuration.webUIURL }

    /// Build the HTTP client. Does not import Mesh/Runtime.
    static func makeHTTPClient(
        configuration: PharosAPIConfiguration = .resolve()
    ) -> HttpPharosClientService {
        HttpPharosClientService(configuration: configuration)
    }
}
