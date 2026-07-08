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
        // Already listening on TCP? Then nothing to restart.
        if let fd = meshTCPConnect(ep, timeoutSec: 2) { close(fd); return }
        MeshClient.stopLocalDaemon()                     // drop any UDS-only broker
        _ = MeshClient.send(MeshRequest(cmd: "list"))    // respawn bound to TCP
    }
}
