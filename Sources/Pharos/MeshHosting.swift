import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Hub mode: make THIS Mac's local mesh broker reachable by other Macs over
/// Tailscale, so they can pair to it for shared chat rooms. Toggled from
/// Settings → Machines and re-applied on launch. The spoke side is MeshRemote;
/// this is the hub side.
enum MeshHosting {
    /// Bind (or unbind) the local broker's TCP listener to match `hosting`.
    /// Blocking (tailscale lookup + broker restart) — call off the main thread.
    static func apply(hosting: Bool) {
        guard hosting else {
            MeshClient.hostTCPEndpoint = nil
            MeshClient.stopLocalDaemon()                 // drop the TCP listener
            _ = MeshClient.send(MeshRequest(cmd: "list"))// respawn UDS-only
            return
        }
        guard let ip = PairingService.selfTailscaleIP() else {
            MeshClient.hostTCPEndpoint = nil             // no Tailscale → can't host
            return
        }
        let ep = "\(ip):\(MeshRemote.port)"
        MeshClient.hostTCPEndpoint = ep
        MeshPaths.setDialEndpointFile(nil)               // a hub never dials out
        // Already listening on TCP? Then nothing to restart.
        if let fd = meshTCPConnect(ep, timeoutSec: 2) { close(fd); return }
        MeshClient.stopLocalDaemon()                     // drop any UDS-only broker
        _ = MeshClient.send(MeshRequest(cmd: "list"))    // respawn bound to TCP
    }

    /// Satellite self-heal (Pharos#5): a Mac with hub mode OFF should never run
    /// a TCP-bound broker — one left behind (old pairing probes used to start
    /// them) hijacks this machine's GUI and agents into an islanded room set.
    /// Detect and stop it; whatever needs a local broker later respawns UDS-only.
    static func demoteStrayHub() {
        guard let ip = PairingService.selfTailscaleIP() else { return }
        let ep = "\(ip):\(MeshRemote.port)"
        guard let fd = meshTCPConnect(ep, timeoutSec: 1) else { return }   // no TCP broker — fine
        close(fd)
        MeshClient.stopLocalDaemon()
    }
}
