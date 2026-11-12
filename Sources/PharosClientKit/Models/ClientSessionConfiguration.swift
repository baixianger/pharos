import Foundation

/// Typed session configuration view from `GET/PATCH /api/v1/sessions/{id}/config`.
///
/// The backend answers honestly: an adapter that cannot report configuration
/// returns `supported: false`, empty field lists and `readonly: true` — the
/// client never invents model/mode values from that empty view.
public struct ClientSessionConfiguration: Sendable, Codable, Equatable {
    /// What the configured adapter can actually do for this session.
    public struct Capabilities: Sendable, Codable, Equatable {
        public let attachments: Bool
        public let commands: Bool
        public let stop: Bool
        public let revive: Bool

        public init(
            attachments: Bool = false,
            commands: Bool = false,
            stop: Bool = false,
            revive: Bool = false
        ) {
            self.attachments = attachments
            self.commands = commands
            self.stop = stop
            self.revive = revive
        }
    }

    /// One selectable mode (`value` is what `PATCH` accepts, `name` is the label).
    public struct Mode: Sendable, Codable, Equatable, Identifiable {
        public var id: String { value }
        public let value: String
        public let name: String

        public init(value: String, name: String) {
            self.value = value
            self.name = name
        }
    }

    public let sessionId: String
    /// False when the adapter cannot report configuration (honest empty view).
    public let supported: Bool
    /// Field ids the adapter allows writing (`model`, `mode`, ...).
    public let supportedFields: [String]
    public let model: String?
    public let mode: String?
    public let models: [String]
    public let modes: [Mode]
    public let capabilities: Capabilities
    /// True when writes are impossible (nothing to change, or view-only).
    public let readonly: Bool

    public init(
        sessionId: String,
        supported: Bool,
        supportedFields: [String] = [],
        model: String? = nil,
        mode: String? = nil,
        models: [String] = [],
        modes: [Mode] = [],
        capabilities: Capabilities = Capabilities(),
        readonly: Bool = true
    ) {
        self.sessionId = sessionId
        self.supported = supported
        self.supportedFields = supportedFields
        self.model = model
        self.mode = mode
        self.models = models
        self.modes = modes
        self.capabilities = capabilities
        self.readonly = readonly
    }

    /// Copy of this view with one configuration field replaced.
    public func setting(field: String, value: String) -> ClientSessionConfiguration {
        ClientSessionConfiguration(
            sessionId: sessionId,
            supported: supported,
            supportedFields: supportedFields,
            model: field == "model" ? value : model,
            mode: field == "mode" ? value : mode,
            models: models,
            modes: modes,
            capabilities: capabilities,
            readonly: readonly
        )
    }
}
