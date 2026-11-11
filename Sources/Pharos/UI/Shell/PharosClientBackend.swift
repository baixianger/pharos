import Foundation
import PharosClientKit

/// Feature-flagged composition root for the desktop client backend (RFC-007 S6).
///
/// Default: `rust-api` → `HttpPharosClientService` talking to S4 `http://127.0.0.1:<port>/`.
/// Legacy: `desktop-mesh` → caller supplies `DesktopPharosClientService` (kept until Phase E).
///
/// Toggle: env `PHAROS_CLIENT_BACKEND` = `rust-api` | `desktop-mesh`
/// (or UserDefaults `pharos.clientBackend`). Base URL: `PHAROS_API_BASE_URL`.
@MainActor
enum PharosClientBackend {
    /// Resolved configuration (backend kind + API base URL).
    static var configuration: PharosAPIConfiguration { .resolve() }

    /// Whether the app should use the Rust HTTP/WS path (default).
    static var usesRustAPI: Bool {
        configuration.backendKind == .rustAPI
    }

    /// Daemon-served Web UI URL for WebKit (nil when on legacy desktop-mesh path).
    static var webUIBaseURL: URL? {
        usesRustAPI ? configuration.webUIURL : nil
    }

    /// Build the HTTP client for the rust-api path. Does not import Mesh/Runtime.
    static func makeHTTPClient(
        configuration: PharosAPIConfiguration = .resolve()
    ) -> HttpPharosClientService {
        HttpPharosClientService(configuration: configuration)
    }
}
