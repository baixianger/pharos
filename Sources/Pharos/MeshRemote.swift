import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Cross-host GUI networking with ZERO manual setup: reuse the existing
/// `peerHost` SSH config (Settings → Peer machine) to make the desktop app talk
/// to the peer Mac's mesh broker over Tailscale.
///
/// When this Mac has no local broker, the app SSHes to the peer to (1) learn its
/// Tailscale IP and (2) ensure a TCP broker is running there, then points
/// `MeshClient.remoteEndpoint` at it. The user never types an IP/port or starts
/// a daemon by hand — the same SSH host that powers cross-machine git-HEAD
/// comparison (Services.swift) also bootstraps the mesh.
enum MeshRemote {
    /// The agreed cross-host mesh port: the peer broker binds it, we dial it.
    static let port = 47800

    private static let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6"]

    /// Where the Pharos binary may live on the peer (tried in order by the
    /// bootstrap). `$HOME` is expanded on the peer via `eval echo`.
    private static let peerBinCandidates = [
        "/Applications/Pharos.app/Contents/MacOS/Pharos",
        "$HOME/personal/pharos/.build/debug/Pharos",
        "$HOME/pharos-mesh/Pharos",
    ]

    /// Resolve the GUI's mesh endpoint. nil ⇒ "a local broker serves — use it";
    /// else "ip:port" for the peer's broker (ensured running). BLOCKING + SSH —
    /// always call this off the main thread.
    static func resolve(peerHost: String) -> String? {
        if let fd = MeshClient.connectUDS() { close(fd); return nil }   // local broker wins
        let host = peerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        return ensurePeerBroker(host)
    }

    /// SSH to the peer: read its Tailscale IP, ensure a TCP broker is listening
    /// (start one detached if the port is closed), and confirm it's up. Returns
    /// "ip:port" on success, nil on any failure.
    private static func ensurePeerBroker(_ host: String) -> String? {
        guard let ip = peerIP(host) else { return nil }

        // Idempotent: if the TCP port is already open, this is a pure no-op;
        // otherwise find the Pharos binary and start a TCP broker (detached).
        let bins = peerBinCandidates.joined(separator: " ")
        let script = """
        if ! /usr/bin/nc -z -G2 \(ip) \(port) 2>/dev/null; then
          for b in \(bins); do
            b=$(eval echo "$b")
            if [ -x "$b" ]; then
              PHAROS_MESH_TCP=\(ip):\(port) PHAROS_MESH_TCP_INSECURE=1 \
                nohup "$b" mesh daemon >/tmp/pharos-mesh.log 2>&1 &
              break
            fi
          done
          sleep 1
        fi
        /usr/bin/nc -z -G2 \(ip) \(port) 2>/dev/null && echo UP || echo DOWN
        """
        let r = Shell.run("/usr/bin/ssh", sshOpts + ["-o", "ConnectTimeout=10", host, script])
        return r.out.hasSuffix("UP") ? "\(ip):\(port)" : nil
    }

    /// The peer's Tailscale IPv4. Primary source is the LOCAL ssh config
    /// (`ssh -G` resolves the alias to its HostName — no network, no PATH
    /// issues); fallback is the peer's Tailscale CLI by absolute path, since a
    /// non-interactive SSH PATH doesn't include `tailscale`.
    private static func peerIP(_ host: String) -> String? {
        let g = Shell.run("/usr/bin/ssh", ["-G", host])
        if g.ok {
            for line in g.out.split(separator: "\n") {
                let f = line.split(separator: " ", maxSplits: 1)
                if f.count == 2, f[0] == "hostname", isIPv4(String(f[1])) { return String(f[1]) }
            }
        }
        let ts = Shell.run("/usr/bin/ssh", sshOpts + [host,
            "for t in /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do "
            + "[ -x \"$t\" ] && \"$t\" ip -4 2>/dev/null | head -1 && break; done"])
        return (ts.ok && isIPv4(ts.out)) ? ts.out : nil
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
