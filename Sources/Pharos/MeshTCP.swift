import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Cross-host TCP transport
//
// The mesh broker normally serves a LOCAL unix socket. When `PHAROS_MESH_TCP`
// is set it ALSO listens on TCP, and clients on another Mac dial that address
// (over Tailscale) instead of their own UDS — so a single broker hosts a chat
// room spanning machines. There is NO token auth: Tailscale is the trust
// boundary, so binding requires an explicit `PHAROS_MESH_TCP_INSECURE=1`
// opt-in, and the endpoint should name a Tailscale IP (not 0.0.0.0) so the
// port isn't exposed to the whole LAN. Same newline-JSON wire protocol as UDS,
// so `handle(cfd)` drives either transport unchanged.

/// Split "host:port" (host may be empty → bind any). IPv6 literals unsupported
/// (Tailscale hands out v4 too; keep it simple).
func meshSplitHostPort(_ s: String) -> (host: String, port: String)? {
    guard let idx = s.lastIndex(of: ":") else { return nil }
    let host = String(s[s.startIndex..<idx])
    let port = String(s[s.index(after: idx)...])
    guard !port.isEmpty, UInt16(port) != nil else { return nil }
    return (host, port)
}

/// Connect to a remote broker with a bounded timeout (a hung dial must never
/// stall a Stop hook's turn-end). Returns a connected blocking fd, or nil.
func meshTCPConnect(_ endpoint: String, timeoutSec: Double = 5) -> Int32? {
    guard let (host, port) = meshSplitHostPort(endpoint) else { return nil }
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    let node = host.isEmpty ? "127.0.0.1" : host
    let rc = node.withCString { np in port.withCString { sp in getaddrinfo(np, sp, &hints, &res) } }
    guard rc == 0, let first = res else { return nil }
    defer { freeaddrinfo(res) }

    var cur: UnsafeMutablePointer<addrinfo>? = first
    while let p = cur {
        let fd = socket(p.pointee.ai_family, p.pointee.ai_socktype, p.pointee.ai_protocol)
        if fd >= 0 {
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let cr = Darwin.connect(fd, p.pointee.ai_addr, p.pointee.ai_addrlen)
            if cr == 0 {
                _ = fcntl(fd, F_SETFL, flags)                 // restore blocking
                return fd
            }
            if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, Int32(timeoutSec * 1000)) > 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 {
                        _ = fcntl(fd, F_SETFL, flags)         // restore blocking
                        return fd
                    }
                }
            }
            close(fd)
        }
        cur = p.pointee.ai_next
    }
    return nil
}

/// Bind + listen a TCP socket for the broker. host empty → any interface
/// (INADDR_ANY); otherwise bind that address specifically (e.g. the Tailscale
/// IP). Returns the listening fd, or nil on failure.
func meshTCPListen(_ endpoint: String) -> Int32? {
    guard let (host, port) = meshSplitHostPort(endpoint) else { return nil }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_PASSIVE
    var res: UnsafeMutablePointer<addrinfo>?
    let rc: Int32 = port.withCString { sp in
        if host.isEmpty {
            return getaddrinfo(nil, sp, &hints, &res)
        } else {
            return host.withCString { np in getaddrinfo(np, sp, &hints, &res) }
        }
    }
    guard rc == 0, let info = res else { return nil }
    defer { freeaddrinfo(res) }

    let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { return nil }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    guard bind(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { close(fd); return nil }
    guard listen(fd, 64) == 0 else { close(fd); return nil }
    return fd
}
