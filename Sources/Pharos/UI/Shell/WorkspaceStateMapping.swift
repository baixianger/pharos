import Foundation
import PharosClientKit

/// Pure mappings from ClientKit wave-2 views to the `WorkspaceWebState` contract
/// consumed by `webui/workspace.js`.
///
/// They are deliberately free of UI state so they can be unit-tested without
/// WebKit: `WorkspaceWebView` only encodes the result and hands it to the page.
extension WorkspaceWebState {
    /// The honest notice the page renders ("Configuration unavailable").
    static let configurationUnavailableNotice = "Configuration unavailable"

    /// One entry of the composer's Session-configuration strip.
    ///
    /// The JSON shape mirrors `webui/transport.js` `sessionControls()` exactly:
    /// - `.select` -> `{"type":"select","id":…,"name":…,"currentValue":…,"options":[{"value","name"}],"readOnly":…}`
    /// - `.status` -> `{"type":"status","name":"Configuration unavailable"}`
    enum SessionConfigControl: Encodable, Equatable {
        struct SelectOption: Encodable, Equatable {
            let value: String
            let name: String
        }

        case select(id: String, name: String, currentValue: String, options: [SelectOption], readOnly: Bool)
        case status(name: String)

        private enum CodingKeys: String, CodingKey {
            case type, id, name, currentValue, options, readOnly
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .select(id, name, currentValue, options, readOnly):
                try container.encode("select", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(currentValue, forKey: .currentValue)
                try container.encode(options, forKey: .options)
                try container.encode(readOnly, forKey: .readOnly)
            case let .status(name):
                try container.encode("status", forKey: .type)
                try container.encode(name, forKey: .name)
            }
        }
    }

    /// `ClientSessionConfiguration` -> the selects `renderSessionConfiguration`
    /// renders. A selected Session whose configuration is genuinely unavailable
    /// (`supported == false` or a failed fetch) reports the honest notice; no
    /// selection and a not-yet-loaded view produce nothing at all.
    static func sessionConfigurationControls(
        configuration: ClientSessionConfiguration?,
        configurationLoadFailed: Bool = false
    ) -> [SessionConfigControl] {
        if configurationLoadFailed {
            return [.status(name: configurationUnavailableNotice)]
        }
        guard let configuration else { return [] }
        guard configuration.supported else {
            return [.status(name: configurationUnavailableNotice)]
        }
        let fields = configuration.supportedFields.isEmpty
            ? ["model", "mode"]
            : configuration.supportedFields
        return [
            .select(
                id: "model",
                name: "Model",
                currentValue: configuration.model ?? "",
                options: configuration.models.map { .init(value: $0, name: $0) },
                readOnly: configuration.readonly || !fields.contains("model")
            ),
            .select(
                id: "mode",
                name: "Mode",
                currentValue: configuration.mode ?? "",
                options: configuration.modes.map {
                    .init(value: $0.value, name: $0.name.isEmpty ? $0.value : $0.name)
                },
                readOnly: configuration.readonly || !fields.contains("mode")
            ),
        ]
    }

    /// `ClientSessionConfiguration` -> the `capabilities` flags `workspace.js`
    /// gates attachments and Stop/Revive on. Unknown (`nil`) is the empty map:
    /// the page then disables the capability-gated controls instead of guessing.
    static func capabilities(from configuration: ClientSessionConfiguration?) -> [String: Bool] {
        guard let configuration else { return [:] }
        return [
            "attachments": configuration.capabilities.attachments,
            "commands": configuration.capabilities.commands,
            "stop": configuration.capabilities.stop,
            "revive": configuration.capabilities.revive,
        ]
    }

    /// Session details panel values: model/mode/models come from the typed
    /// configuration view, status from the session summary.
    static func details(
        for session: ClientSessionSummary,
        configuration: ClientSessionConfiguration?
    ) -> Details {
        Details(
            sessionID: session.id,
            agent: session.agentType,
            host: session.machineId,
            status: session.status.rawValue,
            workspace: session.workspacePath,
            model: configuration?.model ?? "",
            mode: configuration?.mode ?? "",
            models: configuration?.models ?? []
        )
    }

    /// One-line presentation text for a ClientKit error (also used by the shell's
    /// action-error path).
    static func describe(_ error: Error) -> String {
        switch error as? PharosClientError {
        case .backendUnreachable(let backend, let reason): "\(backend) is unavailable. \(reason)"
        case .connectionFailed(let message), .operationFailed(let message): message
        case .sessionNotFound: "Session not found."
        case .threadNotFound: "Thread not found."
        case .approvalNotFound: "This approval is no longer active."
        case nil: error.localizedDescription
        }
    }

    /// Actionable text for a failed background load. When the configured
    /// endpoint is not a healthy Pharos backend (wrong local app on the default
    /// port, stale process, contract mismatch) the health guidance names the URL
    /// and the `PHAROS_API_BASE_URL` override instead of a bare connection error.
    static func backgroundError(
        _ error: Error,
        baseURL: URL,
        probe: BackendHealthProbe
    ) -> String {
        if let guidance = PharosBackendDiagnostics.guidance(baseURL: baseURL, probe: probe) {
            return guidance
        }
        return describe(error)
    }
}
