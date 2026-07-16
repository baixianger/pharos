import Foundation

/// Desktop pairing: discover the Macs on your tailnet and validate a peer for
/// cross-host use (git-HEAD comparison + mesh chat rooms) in one flow, so the
/// user never hand-configures an SSH host or broker address. Builds on the same
/// SSH + Tailscale plumbing as MeshRemote; Foundation-only so it can move into a
/// CLI-core target later.
enum PairingService {

    struct Peer: Identifiable, Hashable {
        let name: String        // Tailscale machine name
        let ip: String          // Tailscale IPv4
        var id: String { ip }
    }

    /// One validated pairing step, for the UI checklist.
    struct Step: Identifiable { let label: String; let ok: Bool; var id: String { label } }

    struct Result {
        let ok: Bool
        let steps: [Step]
        let ip: String?
        let hostIdentity: String?
    }

    /// Absolute path to the Tailscale CLI (not on a GUI process's PATH).
    private static func tailscaleBin() -> String? {
        for p in ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                  "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// This Mac's own Tailscale IPv4 (for the hub to bind its broker to).
    static func selfTailscaleIP() -> String? {
        guard let bin = tailscaleBin() else { return nil }
        let ip = Shell.run(bin, ["ip", "-4"]).out.split(separator: "\n").first.map(String.init) ?? ""
        return isIPv4(ip) ? ip : nil
    }

    /// The tailnet's Macs except this one (self excluded by its own Tailscale IP).
    static func discoverPeers() -> [Peer] {
        guard let bin = tailscaleBin() else { return [] }
        let selfIP = Shell.run(bin, ["ip", "-4"]).out
            .split(separator: "\n").first.map(String.init) ?? ""
        let status = Shell.run(bin, ["status"])
        guard status.ok else { return [] }
        return parsePeers(status.out, excluding: selfIP)
    }

    /// Tailscale status also contains phones, Linux nodes, and long-offline
    /// machines. The settings control promises "Macs", and legacy migration
    /// must not spend five-second SSH timeouts probing irrelevant devices.
    static func parsePeers(_ status: String, excluding selfIP: String) -> [Peer] {
        var peers: [Peer] = []
        for line in status.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                        .map(String.init).filter { !$0.isEmpty }
            guard f.count >= 4, isIPv4(f[0]), f[0] != selfIP,
                  f.contains("macOS"), !f.contains(where: { $0.hasPrefix("offline") }) else { continue }
            peers.append(Peer(name: f[1], ip: f[0]))
        }
        return peers
    }

    /// One-time bridge from the pre-2026-07-08 pairing preference, which kept
    /// the peer's macOS ComputerName separately in `pharos.peerHostKey`. The
    /// newer chat-only pairing stores the Tailscale IP in `peerHost`; without a
    /// migration, an upgraded installation can look unpaired and remote pokes
    /// silently lose their route even though the old peer is still reachable.
    ///
    /// The injected probe keeps matching deterministic in tests. Production
    /// probes only discovered Tailscale peers over BatchMode SSH and accepts an
    /// exact ComputerName match — never guesses between machines.
    static func peer(matchingLegacyComputerName legacy: String,
                     among peers: [Peer],
                     computerName: (Peer) -> String?) -> Peer? {
        let wanted = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return peers.first { peer in
            guard let found = computerName(peer)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return found.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    static func recoverLegacyPeer(named legacy: String) -> Peer? {
        peer(matchingLegacyComputerName: legacy, among: discoverPeers()) { peer in
            let r = Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                                                peer.ip,
                                                "scutil --get ComputerName 2>/dev/null || hostname -s"])
            return r.ok ? r.out : nil
        }
    }

    /// Validate an execution Host. Broker reachability is intentionally absent:
    /// Hosts run agents; the separately configured Broker coordinates them.
    /// `host` may be an SSH alias or a Tailscale IP. BLOCKING + SSH — call off
    /// the main thread.
    static func pair(host: String) -> Result {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else {
            return Result(ok: false, steps: [Step(label: "Enter or pick a Host", ok: false)],
                          ip: nil, hostIdentity: nil)
        }
        let options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        let ssh = Shell.run("/usr/bin/ssh", options + [h, "true"])
        guard ssh.ok else {
            return Result(ok: false, steps: [Step(label: "SSH reachable", ok: false)],
                          ip: isIPv4(h) ? h : nil, hostIdentity: nil)
        }
        let identityProbe = Shell.run("/usr/bin/ssh", options + [h,
            "scutil --get ComputerName 2>/dev/null || hostname"])
        let identity = identityProbe.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = Shell.run("/usr/bin/ssh", options + [h,
            #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"; command -v tmux >/dev/null && command -v pharos >/dev/null"#])
        let hasIdentity = identityProbe.ok && !identity.isEmpty
        let steps = [
            Step(label: "SSH reachable", ok: true),
            Step(label: "Host identity", ok: hasIdentity),
            Step(label: "Pharos CLI and tmux", ok: tools.ok)
        ]
        return Result(ok: hasIdentity && tools.ok, steps: steps,
                      ip: isIPv4(h) ? h : nil, hostIdentity: hasIdentity ? identity : nil)
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
