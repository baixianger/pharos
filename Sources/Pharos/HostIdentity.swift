import Foundation

/// Identifies the current machine, so synced project data can keep *per-host*
/// local checkout paths.
///
/// The registry (issues, logs, notes, tags …) is shared across a user's Macs via
/// iCloud, but a project's on-disk path differs per machine — `~/dev/x` on the
/// mac-mini, `~/personal/x` on the laptop. We key those paths by host so each
/// machine reads/writes only its own, and a project that isn't checked out on
/// this host simply shows as "not local here".
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
