import Foundation

public enum MeshMigrationMode: String, Codable, CaseIterable, Sendable {
    /// The distributed replica is read-only while legacy remains authoritative.
    case shadow
    /// The distributed replica is authoritative; legacy storage is retained read-only.
    case distributed
    /// A rollback restored legacy write authority; distributed state is retained read-only.
    case rolledBack = "rolled-back"
}

public struct MeshMigrationCutoverState: Codable, Equatable, Sendable {
    public var trustGroupID: MeshTrustGroupID
    public var inventoryDigest: Data
    public var generation: UInt64
    public var mode: MeshMigrationMode
    public var updatedAt: MeshHybridTimestamp

    public init(trustGroupID: MeshTrustGroupID, inventoryDigest: Data,
                generation: UInt64, mode: MeshMigrationMode,
                updatedAt: MeshHybridTimestamp) {
        self.trustGroupID = trustGroupID
        self.inventoryDigest = inventoryDigest
        self.generation = generation
        self.mode = mode
        self.updatedAt = updatedAt
    }

    public var legacyMayWrite: Bool { mode != .distributed }
    public var distributedMayWrite: Bool { mode == .distributed }

    public func validate() throws {
        guard inventoryDigest.count == 32 else {
            throw MeshMigrationValidationError.invalidInventoryDigest
        }
        guard generation > 0, generation <= UInt64(Int64.max) else {
            throw MeshMigrationValidationError.invalidGeneration
        }
    }
}

public enum MeshMigrationValidationError: Error, Equatable, Sendable {
    case invalidInventoryDigest
    case invalidGeneration
}
