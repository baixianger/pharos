import Foundation

/// Binary framing used on one Iroh QUIC stream. A stream carries exactly one
/// request or response, so the fixed prefix can be validated before any JSON or
/// attachment bytes enter the application layer.
public enum MeshStreamFrameKind: UInt8, Sendable {
    case request = 1
    case response = 2
}

public struct MeshStreamFrame: Equatable, Sendable {
    public var kind: MeshStreamFrameKind
    public var header: Data
    public var body: Data?

    public init(kind: MeshStreamFrameKind, header: Data, body: Data? = nil) {
        self.kind = kind
        self.header = header
        self.body = body
    }
}

public enum MeshStreamFrameError: Error, Equatable, Sendable {
    case truncatedPrefix
    case invalidMagic
    case invalidKind
    case nonzeroReservedBytes
    case emptyHeader
    case headerTooLarge
    case bodyTooLarge
    case lengthMismatch
}

public enum MeshStreamFrameCodec {
    public static let prefixByteCount = 20
    public static let maximumFrameBytes = prefixByteCount
        + DistributedMeshProtocol.maximumHeaderBytes
        + DistributedMeshProtocol.maximumBlobBytes

    private static let magic: [UInt8] = [0x50, 0x48, 0x4d, 0x31] // PHM1

    public static func encode(_ frame: MeshStreamFrame) throws -> Data {
        try validate(headerCount: frame.header.count, bodyCount: frame.body?.count ?? 0)

        var bytes = Data(capacity: prefixByteCount + frame.header.count + (frame.body?.count ?? 0))
        bytes.append(contentsOf: magic)
        bytes.append(frame.kind.rawValue)
        bytes.append(contentsOf: [0, 0, 0])
        append(UInt32(frame.header.count), to: &bytes)
        append(UInt64(frame.body?.count ?? 0), to: &bytes)
        bytes.append(frame.header)
        if let body = frame.body { bytes.append(body) }
        return bytes
    }

    public static func decode(_ data: Data) throws -> MeshStreamFrame {
        guard data.count >= prefixByteCount else { throw MeshStreamFrameError.truncatedPrefix }
        let bytes = [UInt8](data.prefix(prefixByteCount))
        guard Array(bytes[0..<4]) == magic else { throw MeshStreamFrameError.invalidMagic }
        guard let kind = MeshStreamFrameKind(rawValue: bytes[4]) else {
            throw MeshStreamFrameError.invalidKind
        }
        guard bytes[5] == 0, bytes[6] == 0, bytes[7] == 0 else {
            throw MeshStreamFrameError.nonzeroReservedBytes
        }

        let headerCount = Int(readUInt32(bytes, at: 8))
        let bodyLength = readUInt64(bytes, at: 12)
        guard bodyLength <= UInt64(Int.max) else { throw MeshStreamFrameError.bodyTooLarge }
        let bodyCount = Int(bodyLength)
        try validate(headerCount: headerCount, bodyCount: bodyCount)
        guard prefixByteCount + headerCount + bodyCount == data.count else {
            throw MeshStreamFrameError.lengthMismatch
        }

        let headerStart = data.startIndex + prefixByteCount
        let headerEnd = headerStart + headerCount
        let header = Data(data[headerStart..<headerEnd])
        let body = bodyCount == 0 ? nil : Data(data[headerEnd..<data.endIndex])
        return MeshStreamFrame(kind: kind, header: header, body: body)
    }

    private static func validate(headerCount: Int, bodyCount: Int) throws {
        guard headerCount > 0 else { throw MeshStreamFrameError.emptyHeader }
        guard headerCount <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshStreamFrameError.headerTooLarge
        }
        guard bodyCount <= DistributedMeshProtocol.maximumBlobBytes else {
            throw MeshStreamFrameError.bodyTooLarge
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
