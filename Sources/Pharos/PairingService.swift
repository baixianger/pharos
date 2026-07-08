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
        var peers: [Peer] = []
        for line in status.out.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                        .map(String.init).filter { !$0.isEmpty }
            guard f.count >= 2, isIPv4(f[0]), f[0] != selfIP else { continue }
            peers.append(Peer(name: f[1], ip: f[0]))
        }
        return peers
    }

    /// Validate (and bring up) a peer: SSH reachable → Tailscale IP → mesh broker
    /// running. `host` may be an SSH alias or a Tailscale IP. BLOCKING + SSH —
    /// call off the main thread.
    static func pair(host: String) -> Result {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else {
            return Result(ok: false, steps: [Step(label: "Enter or pick a Mac", ok: false)], ip: nil)
        }
        let p = MeshRemote.probe(h)
        var steps = [Step(label: "SSH reachable", ok: p.sshOK)]
        if p.sshOK { steps.append(Step(label: "Tailscale address", ok: p.ip != nil)) }
        if p.ip != nil { steps.append(Step(label: "Mesh broker running", ok: p.brokerUp)) }
        let ok = p.sshOK && p.ip != nil && p.brokerUp
        return Result(ok: ok, steps: steps, ip: p.ip)
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
