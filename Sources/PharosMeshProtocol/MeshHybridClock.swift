import Foundation

/// A deterministic hybrid logical clock for locally-authored events and remote
/// observations. It never moves backwards when the wall clock regresses.
public struct MeshHybridClock: Codable, Equatable, Sendable {
    public private(set) var last: MeshHybridTimestamp

    public init(last: MeshHybridTimestamp = .init(wallTimeMilliseconds: 0)) {
        self.last = last
    }

    @discardableResult
    public mutating func tick(nowMilliseconds: Int64) throws -> MeshHybridTimestamp {
        if nowMilliseconds > last.wallTimeMilliseconds {
            last = MeshHybridTimestamp(wallTimeMilliseconds: nowMilliseconds)
        } else {
            last = try Self.increment(last)
        }
        return last
    }

    @discardableResult
    public mutating func observe(_ remote: MeshHybridTimestamp,
                                 nowMilliseconds: Int64) throws -> MeshHybridTimestamp {
        let wall = max(nowMilliseconds, last.wallTimeMilliseconds, remote.wallTimeMilliseconds)
        let logical: UInt32
        if wall == last.wallTimeMilliseconds && wall == remote.wallTimeMilliseconds {
            logical = max(last.logical, remote.logical)
        } else if wall == last.wallTimeMilliseconds {
            logical = last.logical
        } else if wall == remote.wallTimeMilliseconds {
            logical = remote.logical
        } else {
            last = MeshHybridTimestamp(wallTimeMilliseconds: wall)
            return last
        }
        last = try Self.increment(
            MeshHybridTimestamp(wallTimeMilliseconds: wall, logical: logical)
        )
        return last
    }

    private static func increment(_ timestamp: MeshHybridTimestamp) throws
        -> MeshHybridTimestamp {
        if timestamp.logical < UInt32.max {
            return MeshHybridTimestamp(
                wallTimeMilliseconds: timestamp.wallTimeMilliseconds,
                logical: timestamp.logical + 1
            )
        }
        guard timestamp.wallTimeMilliseconds < Int64.max else {
            throw MeshHybridClockError.overflow
        }
        return MeshHybridTimestamp(
            wallTimeMilliseconds: timestamp.wallTimeMilliseconds + 1,
            logical: 0
        )
    }
}

public enum MeshHybridClockError: Error, Equatable, Sendable {
    case overflow
}
