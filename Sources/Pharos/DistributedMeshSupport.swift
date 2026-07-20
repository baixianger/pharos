import Foundation
import Observation
import PharosMeshCore

/// macOS owner of the shared local replica. It deliberately does not start an
/// Iroh endpoint or alter legacy Broker routing during migration; those are
/// explicit later actions using this already-stable identity and store.
@Observable
@MainActor
final class DistributedMeshSupport {
    enum State: Equatable {
        case opening
        case ready(deviceID: MeshDeviceID, endpointID: MeshEndpointID)
        case failed(String)
    }

    private(set) var state: State = .opening
    private(set) var localReplica: MeshLocalReplica?
    private(set) var activeTrustGroupID: MeshTrustGroupID?

    var isProductModeEnabled: Bool {
        ProcessInfo.processInfo.environment["PHAROS_DISTRIBUTED"] == "1"
    }

    func start() async {
        guard localReplica == nil else { return }
        state = .opening
        do {
            let replica = try await Task.detached {
                try MeshLocalReplica.openDefault()
            }.value
            localReplica = replica
            if isProductModeEnabled {
                activeTrustGroupID = try await replica.ensureActiveTrustGroup()
            }
            state = .ready(
                deviceID: replica.identity.deviceID,
                endpointID: try replica.identity.endpointID()
            )
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
