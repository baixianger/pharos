import Foundation

/// State of delivery receipts for a message sent over the mesh.
public enum DeliveryReceiptState: String, Sendable, Codable, Equatable {
    case pending = "pending"
    case delivered = "delivered"
    case consumed = "consumed"
    case unverifiedFallback = "unverified_fallback"
}

/// A lightweight, plain chat bubble message exchanged within a collaborative Thread roster.
/// Per RFC-006, thread messages carry plain text only, with no intermediate tool or step events.
public struct ClientThreadMessage: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let threadId: String
    public let senderId: String
    public let senderName: String
    public let senderAvatarSeed: String?
    public let text: String
    public let timestamp: Date
    public let receipt: DeliveryReceiptState
    public let attachments: [CanonicalAttachment]

    public init(
        id: String,
        threadId: String,
        senderId: String,
        senderName: String,
        senderAvatarSeed: String? = nil,
        text: String,
        timestamp: Date = Date(),
        receipt: DeliveryReceiptState = .pending,
        attachments: [CanonicalAttachment] = []
    ) {
        self.id = id
        self.threadId = threadId
        self.senderId = senderId
        self.senderName = senderName
        self.senderAvatarSeed = senderAvatarSeed
        self.text = text
        self.timestamp = timestamp
        self.receipt = receipt
        self.attachments = attachments
    }
}
