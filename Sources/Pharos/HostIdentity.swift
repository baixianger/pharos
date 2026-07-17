import Foundation

/// Identifies the current execution Host. Portable project data lives on the
/// Broker, while checkout paths and runtime state remain local to this machine.
enum HostIdentity {
    /// A stable, human-readable key for this machine — the computer name
    /// (e.g. "mac-mini", "macbook-air"), falling back to the network hostname.
    /// Overridable via `PHAROS_HOST` for testing or unusual setups.
    static var current: String {
        if let override = ProcessInfo.processInfo.environment["PHAROS_HOST"],
           !override.isEmpty {
            return override
        }
        if let name = Host.current().localizedName, !name.isEmpty {
            return name
        }
        let hostname = ProcessInfo.processInfo.hostName
        return hostname.isEmpty ? "this-mac" : hostname
    }

    /// Stable route identity inside a private tailnet. The computer name stays
    /// presentation-only because users can rename it and macOS exposes several
    /// subtly different host-name variants.
    static var tailscaleIP: String? {
        if let override = ProcessInfo.processInfo.environment["PHAROS_TAILSCALE_IP"],
           !override.isEmpty {
            return override
        }
        return detectedTailscaleIP
    }

    private static let detectedTailscaleIP: String? = {
        let candidates = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let value = Shell.run(path, ["ip", "-4"]).out
                .split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, value.split(separator: ".").count == 4 { return value }
        }
        return nil
    }()

    static func isCurrent(host: String?, tailscaleIP: String?) -> Bool {
        if let tailscaleIP, !tailscaleIP.isEmpty, tailscaleIP == self.tailscaleIP { return true }
        return host == current
    }
}
