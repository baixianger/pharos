import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum WebSocketFrame {
    /// Encode a WebSocket frame according to RFC 6455.
    public static func encode(opcode: UInt8, payload: Data, fin: Bool = true, masked: Bool = true) -> Data {
        var frame = Data()
        let b0: UInt8 = (fin ? 0x80 : 0x00) | (opcode & 0x0F)
        frame.append(b0)

        let maskBit: UInt8 = masked ? 0x80 : 0x00
        let count = payload.count

        if count <= 125 {
            frame.append(maskBit | UInt8(count))
        } else if count <= 65535 {
            frame.append(maskBit | 126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((UInt64(count) >> (i * 8)) & 0xFF))
            }
        }

        if masked {
            let maskKey: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
            frame.append(contentsOf: maskKey)
            var maskedBytes = [UInt8](payload)
            for i in 0..<count {
                maskedBytes[i] ^= maskKey[i % 4]
            }
            frame.append(contentsOf: maskedBytes)
        } else {
            frame.append(payload)
        }

        return frame
    }

    /// Decode a WebSocket frame from buffer. Returns nil if buffer is incomplete.
    public static func decode(_ buffer: Data) -> (fin: Bool, opcode: UInt8, payload: Data, consumed: Int)? {
        guard buffer.count >= 2 else { return nil }

        let start = buffer.startIndex
        let b0 = buffer[start]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F

        let b1 = buffer[start + 1]
        let isMasked = (b1 & 0x80) != 0
        let lenIndicator = b1 & 0x7F

        var offset = 2
        var payloadLength: Int = 0

        if lenIndicator <= 125 {
            payloadLength = Int(lenIndicator)
        } else if lenIndicator == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            let hi = UInt16(buffer[start + offset])
            let lo = UInt16(buffer[start + offset + 1])
            payloadLength = Int((hi << 8) | lo)
            offset += 2
        } else { // 127
            guard buffer.count >= offset + 8 else { return nil }
            var len64: UInt64 = 0
            for i in 0..<8 {
                len64 = (len64 << 8) | UInt64(buffer[start + offset + i])
            }
            guard len64 <= UInt64(Int.max) else { return nil }
            payloadLength = Int(len64)
            offset += 8
        }

        var maskKey: [UInt8] = []
        if isMasked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[(start + offset)..<(start + offset + 4)])
            offset += 4
        }

        guard buffer.count >= offset + payloadLength else { return nil }
        let payloadStart = start + offset
        let rawPayload = buffer[payloadStart..<(payloadStart + payloadLength)]

        let unmasked: Data
        if isMasked {
            var rawBytes = [UInt8](rawPayload)
            for i in 0..<payloadLength {
                rawBytes[i] ^= maskKey[i % 4]
            }
            unmasked = Data(rawBytes)
        } else {
            unmasked = Data(rawPayload)
        }

        let consumed = offset + payloadLength
        return (fin: fin, opcode: opcode, payload: unmasked, consumed: consumed)
    }
}

public final class WebSocketUDSConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var readBuffer = Data()
    private var fragmentedPayload = Data()

    public init(socketPath: String, timeout: TimeInterval = 5) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CodexDaemonError.unavailable("failed to create socket: errno=\(errno)")
        }

        #if canImport(Darwin)
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
            throw CodexDaemonError.unavailable("socket path too long")
        }

        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = socketPath.withCString { cstr in
                strncpy(ptr, cstr, maxLen - 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(fd, $0, addrLen)
                #else
                Glibc.connect(fd, $0, addrLen)
                #endif
            }
        }

        guard connectRes == 0 else {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
            throw CodexDaemonError.unavailable("connect failed for \(socketPath): errno=\(errno)")
        }

        self.fd = fd

        // HTTP Upgrade handshake
        let keyBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let wsKey = Data(keyBytes).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(wsKey)\r\nSec-WebSocket-Version: 13\r\n\r\n"

        try rawSendLocked(Data(request.utf8))

        // Read response until \r\n\r\n
        let deadline = Date().addingTimeInterval(timeout)
        var headerData = Data()
        var upgraded = false

        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 1024)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(max(1, Int(deadline.timeIntervalSinceNow * 1000)))
            let pollRet = poll(&pfd, 1, remMs)
            if pollRet <= 0 { break }

            #if canImport(Darwin)
            let n = Darwin.read(fd, &chunk, chunk.count)
            #else
            let n = Glibc.read(fd, &chunk, chunk.count)
            #endif

            if n > 0 {
                headerData.append(chunk, count: n)
                if let delimiterRange = headerData.range(of: Data("\r\n\r\n".utf8)) {
                    let headerString = String(decoding: headerData[..<delimiterRange.lowerBound], as: UTF8.self)
                    guard headerString.contains("101") else {
                        close()
                        throw CodexDaemonError.protocolError("HTTP upgrade rejected: \(headerString)")
                    }
                    let excess = headerData[delimiterRange.upperBound...]
                    self.readBuffer.append(contentsOf: excess)
                    upgraded = true
                    break
                }
            } else if n == 0 {
                break
            }
        }

        guard upgraded else {
            close()
            throw CodexDaemonError.protocolError("HTTP upgrade timed out or disconnected")
        }
    }

    deinit {
        close()
    }

    public func sendText(_ s: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let frame = WebSocketFrame.encode(opcode: 0x1, payload: Data(s.utf8), fin: true, masked: true)
        try rawSendLocked(frame)
    }

    public func receiveText(deadline: Date) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        while Date() < deadline {
            if let decoded = WebSocketFrame.decode(readBuffer) {
                readBuffer.removeSubrange(0..<decoded.consumed)

                if decoded.opcode == 0x9 { // Ping -> Answer with Pong
                    let pong = WebSocketFrame.encode(opcode: 0x0A, payload: decoded.payload, fin: true, masked: true)
                    try rawSendLocked(pong)
                    continue
                } else if decoded.opcode == 0x8 { // Close
                    closeLocked()
                    return nil
                } else if decoded.opcode == 0x1 { // Text
                    fragmentedPayload = decoded.payload
                    if decoded.fin {
                        let text = String(data: fragmentedPayload, encoding: .utf8)
                        fragmentedPayload.removeAll()
                        return text
                    }
                    continue
                } else if decoded.opcode == 0x0 { // Continuation
                    fragmentedPayload.append(decoded.payload)
                    if decoded.fin {
                        let text = String(data: fragmentedPayload, encoding: .utf8)
                        fragmentedPayload.removeAll()
                        return text
                    }
                    continue
                } else {
                    continue
                }
            }

            guard fd >= 0 else { throw CodexDaemonError.unavailable("socket closed") }

            let rem = deadline.timeIntervalSinceNow
            guard rem > 0 else { return nil }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(Int(rem * 1000) + 1, Int(Int32.max)))
            let pollRet = poll(&pfd, 1, remMs)
            if pollRet == 0 {
                return nil
            } else if pollRet < 0 {
                if errno == EINTR { continue }
                throw CodexDaemonError.unavailable("poll error: errno=\(errno)")
            }

            var chunk = [UInt8](repeating: 0, count: 8192)
            #if canImport(Darwin)
            let n = Darwin.read(fd, &chunk, chunk.count)
            #else
            let n = Glibc.read(fd, &chunk, chunk.count)
            #endif

            if n > 0 {
                readBuffer.append(chunk, count: n)
            } else if n == 0 {
                closeLocked()
                throw CodexDaemonError.unavailable("connection closed by server")
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw CodexDaemonError.unavailable("read error: errno=\(errno)")
            }
        }

        return nil
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    /// Caller holds `lock` (NSLock is not recursive).
    private func closeLocked() {
        if fd >= 0 {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
            fd = -1
        }
    }

    private func rawSendLocked(_ data: Data) throws {
        guard fd >= 0 else { throw CodexDaemonError.unavailable("socket closed") }
        var sent = 0
        try data.withUnsafeBytes { rawPtr in
            while sent < data.count {
                let chunkPtr = rawPtr.baseAddress!.advanced(by: sent)
                let remaining = data.count - sent
                #if canImport(Darwin)
                let n = Darwin.send(fd, chunkPtr, remaining, 0)
                #else
                let n = Glibc.send(fd, chunkPtr, remaining, Int32(MSG_NOSIGNAL))
                #endif
                if n > 0 {
                    sent += n
                } else if n < 0 {
                    if errno == EINTR { continue }
                    throw CodexDaemonError.unavailable("send error: errno=\(errno)")
                } else {
                    throw CodexDaemonError.unavailable("socket closed on send")
                }
            }
        }
    }
}
