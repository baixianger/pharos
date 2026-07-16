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
}
