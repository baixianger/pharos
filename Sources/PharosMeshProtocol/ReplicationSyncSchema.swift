import Foundation

public struct MeshAuthorSequence: Codable, Equatable, Sendable {
    public var endpointID: MeshEndpointID
    public var sequence: UInt64

    public init(endpointID: MeshEndpointID, sequence: UInt64) {
        self.endpointID = endpointID
        self.sequence = sequence
    }

    public func validate() throws {
        guard sequence <= UInt64(Int64.max) else {
            throw MeshReplicationValidationError.sequenceOutOfRange
        }
    }
}

/// A compact anti-entropy summary. Authors are canonicalized by Endpoint ID so
/// the same logical vector always has the same encoded representation.
public struct MeshSyncVector: Codable, Equatable, Sendable {
    public static let maximumAuthors = 4_096

    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var authors: [MeshAuthorSequence]

    public init(trustGroupID: MeshTrustGroupID, membershipEpoch: UInt64,
                authors: [MeshAuthorSequence]) throws {
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.authors = authors.sorted { $0.endpointID < $1.endpointID }
        try validate()
    }

    public func validate() throws {
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max) else {
            throw MeshReplicationValidationError.membershipEpochOutOfRange
        }
        guard authors.count <= Self.maximumAuthors else {
            throw MeshReplicationValidationError.tooManyAuthors
        }
        var previous: MeshEndpointID?
        var seen: Set<MeshEndpointID> = []
        for author in authors {
            try author.validate()
            if !seen.insert(author.endpointID).inserted {
                throw MeshReplicationValidationError.duplicateAuthor
            }
            if let previous, previous > author.endpointID {
                throw MeshReplicationValidationError.authorsNotCanonical
            }
            previous = author.endpointID
        }
    }

    public func sequence(for endpointID: MeshEndpointID) -> UInt64 {
        authors.first(where: { $0.endpointID == endpointID })?.sequence ?? 0
    }
}

public struct MeshEventRangeRequest: Codable, Equatable, Sendable {
    public static let maximumLimit = 1_024

    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var authorEndpointID: MeshEndpointID
    public var afterSequence: UInt64
    public var limit: Int

    public init(trustGroupID: MeshTrustGroupID, membershipEpoch: UInt64,
                authorEndpointID: MeshEndpointID, afterSequence: UInt64,
                limit: Int = 256) {
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.authorEndpointID = authorEndpointID
        self.afterSequence = afterSequence
        self.limit = limit
    }

    public func validate() throws {
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max) else {
            throw MeshReplicationValidationError.membershipEpochOutOfRange
        }
        guard afterSequence <= UInt64(Int64.max) else {
            throw MeshReplicationValidationError.sequenceOutOfRange
        }
        guard (1 ... Self.maximumLimit).contains(limit) else {
            throw MeshReplicationValidationError.invalidRangeLimit
        }
    }
}

public enum MeshEventRangeResponseKind: String, Codable, Sendable {
    case events
    case snapshot
    case upToDate = "up-to-date"
}

public struct MeshEventRangeResponse: Codable, Equatable, Sendable {
    public var request: MeshEventRangeRequest
    public var kind: MeshEventRangeResponseKind
    public var events: [MeshReplicatedEvent]
    public var snapshot: MeshReplicaSnapshotBundle?

    public init(request: MeshEventRangeRequest, kind: MeshEventRangeResponseKind,
                events: [MeshReplicatedEvent] = [],
                snapshot: MeshReplicaSnapshotBundle? = nil) {
        self.request = request
        self.kind = kind
        self.events = events
        self.snapshot = snapshot
    }

    public func validate() throws {
        try request.validate()
        switch kind {
        case .events:
            guard snapshot == nil, !events.isEmpty, events.count <= request.limit else {
                throw MeshReplicationValidationError.invalidRangeResponse
            }
            var expected = request.afterSequence + 1
            for event in events {
                guard event.trustGroupID == request.trustGroupID,
                      event.membershipEpoch == request.membershipEpoch,
                      event.authorEndpointID == request.authorEndpointID,
                      event.authorSequence == expected else {
                    throw MeshReplicationValidationError.invalidRangeResponse
                }
                expected += 1
            }
        case .snapshot:
            guard events.isEmpty, let snapshot else {
                throw MeshReplicationValidationError.invalidRangeResponse
            }
            try snapshot.snapshot.validate()
            try snapshot.state.validate()
            guard snapshot.snapshot.trustGroupID == request.trustGroupID,
                  snapshot.snapshot.membershipEpoch == request.membershipEpoch,
                  snapshot.snapshot.authorHeads.contains(where: {
                      $0.endpointID == request.authorEndpointID &&
                          $0.sequence > request.afterSequence
                  }) else {
                throw MeshReplicationValidationError.invalidRangeResponse
            }
        case .upToDate:
            guard events.isEmpty, snapshot == nil else {
                throw MeshReplicationValidationError.invalidRangeResponse
            }
        }
    }
}

/// One field mutation for project/issue LWW registers. A tombstone is explicit
/// so deletion never depends on an ambiguous missing/null value.
public struct MeshFieldMutation: Codable, Equatable, Sendable {
    public var field: String
    public var value: Data?
    public var isDeleted: Bool

    public init(field: String, value: Data?, isDeleted: Bool = false) {
        self.field = field
        self.value = value
        self.isDeleted = isDeleted
    }

    public func validate() throws {
        guard MeshReplicationText.isSafeField(field) else {
            throw MeshReplicationValidationError.invalidField
        }
        guard isDeleted == (value == nil) else {
            throw MeshReplicationValidationError.invalidTombstone
        }
        guard value?.count ?? 0 <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshReplicationValidationError.valueTooLarge
        }
    }

    public func canonicalBytes() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(self)
    }
}

public extension MeshOperationName {
    static let fieldSetV1 = MeshOperationName(rawValue: "field.set.v1")!
    static let immutablePutV1 = MeshOperationName(rawValue: "immutable.put.v1")!
}

public enum MeshReplicationValidationError: Error, Equatable, Sendable {
    case membershipEpochOutOfRange
    case sequenceOutOfRange
    case tooManyAuthors
    case duplicateAuthor
    case authorsNotCanonical
    case invalidRangeLimit
    case invalidRangeResponse
    case invalidField
    case invalidTombstone
    case valueTooLarge
}

private enum MeshReplicationText {
    static func isSafeField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 &&
            value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)
            }
    }
}
