import Foundation

/// State of delivery receipts for a message sent over the mesh.
public enum DeliveryReceiptState: String, Sendable, Codable, Equatable {
    case pending = "pending"
    case delivered = "delivered"
    case consumed = "consumed"
    case unverifiedFallback = "unverified_fallback"
    case deliveryUncertain = "delivery_uncertain"
    case deliveryRejected = "delivery_rejected"
    case deliveryMixed = "delivery_mixed"
}

/// Immutable snapshot of the message that a Thread reply refers to.
public struct ClientThreadReply: Sendable, Codable, Equatable {
    public let messageId: String
    public let senderName: String
    public let preview: String

    public init(messageId: String, senderName: String, preview: String) {
        self.messageId = messageId
        self.senderName = senderName
        self.preview = preview
    }
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
    public let replyTo: ClientThreadReply?

    public init(
        id: String,
        threadId: String,
        senderId: String,
        senderName: String,
        senderAvatarSeed: String? = nil,
        text: String,
        timestamp: Date = Date(),
        receipt: DeliveryReceiptState = .pending,
        attachments: [CanonicalAttachment] = [],
        replyTo: ClientThreadReply? = nil
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
        self.replyTo = replyTo
    }
}
