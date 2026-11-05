import Foundation
import PharosClientKit

/// Delivery receipt and acknowledgment guarantee provided by an agent backend.
public enum DeliveryGuarantee: String, Sendable, Codable, Equatable {
    /// In-process 4-phase delivery.ack loop (accepted -> injected -> consumed -> completed), e.g. dsh-plugin-pharos.
    case inProcessAck = "in_process_ack"
    /// Socket confirmed JSON-RPC confirmation + turn/started, e.g. Codex app-server daemon.
    case socketConfirmed = "socket_confirmed"
    /// ACP session/prompt stopReason confirmation, e.g. Antigravity ACP.
    case acpConfirmed = "acp_confirmed"
    /// Tmux keystroke injection without direct wire acknowledgment.
    case optimisticTui = "optimistic_tui"
}

/// Explicit capability declarations for an agent backend adapter.
public struct BackendCapabilities: Sendable, Codable, Equatable {
    public let supportsStreamingReplies: Bool
    public let supportsMidTurnSteering: Bool
    public let supportsRuntimeModelSwitch: Bool
    public let supportsStructuredApprovals: Bool
    public let supportsDirectSocketInjection: Bool
    public let supportsDurableDeliveryReceipts: Bool
    public let deliveryGuarantee: DeliveryGuarantee

    public init(
        supportsStreamingReplies: Bool,
        supportsMidTurnSteering: Bool,
        supportsRuntimeModelSwitch: Bool,
        supportsStructuredApprovals: Bool,
        supportsDirectSocketInjection: Bool,
        supportsDurableDeliveryReceipts: Bool,
        deliveryGuarantee: DeliveryGuarantee
    ) {
        self.supportsStreamingReplies = supportsStreamingReplies
        self.supportsMidTurnSteering = supportsMidTurnSteering
        self.supportsRuntimeModelSwitch = supportsRuntimeModelSwitch
        self.supportsStructuredApprovals = supportsStructuredApprovals
        self.supportsDirectSocketInjection = supportsDirectSocketInjection
        self.supportsDurableDeliveryReceipts = supportsDurableDeliveryReceipts
        self.deliveryGuarantee = deliveryGuarantee
    }
}

/// Result of connect-time version verification against docs/BACKEND-MATRIX.md.
public struct VersionCheckResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case pinned
        case compatibleWithDegradation(warning: String)
        case incompatible(error: String)
    }

    public let status: Status
    public let capabilities: BackendCapabilities
}

/// Central registry managing backend capability negotiations and version-drift safety.
public final class BackendCapabilityRegistry: Sendable {
    public static let shared = BackendCapabilityRegistry()

    public static let codexPinnedVersion = "0.166.0"
    public static let agyPinnedVersion = "1.5.1"
    public static let dshPinnedVersion = "0.2.1-rc.5"

    public static let codexDefaultCapabilities = BackendCapabilities(
        supportsStreamingReplies: true,
        supportsMidTurnSteering: true,
        supportsRuntimeModelSwitch: false, // requires graceful restart fallback
        supportsStructuredApprovals: true,
        supportsDirectSocketInjection: true,
        supportsDurableDeliveryReceipts: true,
        deliveryGuarantee: .socketConfirmed
    )

    public static let agyDefaultCapabilities = BackendCapabilities(
        supportsStreamingReplies: true,
        supportsMidTurnSteering: true,
        supportsRuntimeModelSwitch: true, // supported via ACP session/set_config_option
        supportsStructuredApprovals: true,
        supportsDirectSocketInjection: true,
        supportsDurableDeliveryReceipts: true,
        deliveryGuarantee: .acpConfirmed
    )

    public static let dshDefaultCapabilities = BackendCapabilities(
        supportsStreamingReplies: true,
        supportsMidTurnSteering: true,
        supportsRuntimeModelSwitch: true, // supported via POST /api/session/selectModel
        supportsStructuredApprovals: true,
        supportsDirectSocketInjection: true,
        supportsDurableDeliveryReceipts: true,
        deliveryGuarantee: .inProcessAck
    )

    public init() {}

    /// Looks up standard capability declaration for a given backend agent kind.
    public func capabilities(for backend: String) -> BackendCapabilities {
        switch backend.lowercased() {
        case "codex":
            return Self.codexDefaultCapabilities
        case "agy", "antigravity":
            return Self.agyDefaultCapabilities
        case "dsh", "deepseek":
            return Self.dshDefaultCapabilities
        default:
            return BackendCapabilities(
                supportsStreamingReplies: false,
                supportsMidTurnSteering: false,
                supportsRuntimeModelSwitch: false,
                supportsStructuredApprovals: false,
                supportsDirectSocketInjection: false,
                supportsDurableDeliveryReceipts: false,
                deliveryGuarantee: .optimisticTui
            )
        }
    }

    /// Verifies detected CLI version against the pinned capability matrix.
    public func verifyVersion(backend: String, detectedVersion: String) -> VersionCheckResult {
        let b = backend.lowercased()
        switch b {
        case "codex":
            if detectedVersion == Self.codexPinnedVersion {
                return VersionCheckResult(status: .pinned, capabilities: Self.codexDefaultCapabilities)
            }
            if isVersionAtLeast(detectedVersion, minimum: "0.141.0") {
                let msg = "[BackendMatrix] WARNING: codex version mismatch (detected \(detectedVersion), pinned \(Self.codexPinnedVersion)). Degrading to safe fallback."
                return VersionCheckResult(
                    status: .compatibleWithDegradation(warning: msg),
                    capabilities: Self.codexDefaultCapabilities
                )
            }
            return VersionCheckResult(
                status: .incompatible(error: "codex version \(detectedVersion) is below minimum 0.141.0"),
                capabilities: capabilities(for: "unknown")
            )

        case "agy", "antigravity":
            if detectedVersion == Self.agyPinnedVersion {
                return VersionCheckResult(status: .pinned, capabilities: Self.agyDefaultCapabilities)
            }
            if isVersionAtLeast(detectedVersion, minimum: "1.4.0") {
                let msg = "[BackendMatrix] WARNING: agy version mismatch (detected \(detectedVersion), pinned \(Self.agyPinnedVersion)). Degrading to safe fallback."
                return VersionCheckResult(
                    status: .compatibleWithDegradation(warning: msg),
                    capabilities: Self.agyDefaultCapabilities
                )
            }
            return VersionCheckResult(
                status: .incompatible(error: "agy version \(detectedVersion) is below minimum 1.4.0"),
                capabilities: capabilities(for: "unknown")
            )

        case "dsh", "deepseek":
            if detectedVersion == Self.dshPinnedVersion {
                return VersionCheckResult(status: .pinned, capabilities: Self.dshDefaultCapabilities)
            }
            if isVersionAtLeast(detectedVersion, minimum: "0.2.0") {
                let msg = "[BackendMatrix] WARNING: dsh version mismatch (detected \(detectedVersion), pinned \(Self.dshPinnedVersion)). Degrading to safe fallback."
                return VersionCheckResult(
                    status: .compatibleWithDegradation(warning: msg),
                    capabilities: Self.dshDefaultCapabilities
                )
            }
            return VersionCheckResult(
                status: .incompatible(error: "dsh version \(detectedVersion) is below minimum 0.2.0"),
                capabilities: capabilities(for: "unknown")
            )

        default:
            return VersionCheckResult(
                status: .incompatible(error: "Unknown backend: \(backend)"),
                capabilities: capabilities(for: "unknown")
            )
        }
    }

    private func isVersionAtLeast(_ version: String, minimum: String) -> Bool {
        let vComponents = version.split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
        let minComponents = minimum.split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
        for i in 0..<max(vComponents.count, minComponents.count) {
            let v = i < vComponents.count ? vComponents[i] : 0
            let m = i < minComponents.count ? minComponents[i] : 0
            if v > m { return true }
            if v < m { return false }
        }
        return true
    }
}
