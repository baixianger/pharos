import Foundation
import PharosClientKit
import PharosMeshCore
import PharosMeshProtocol
import PharosRuntime

/// Connects the workspace to the application-owned project and Mesh stores.
@MainActor
final class DesktopPharosClientService: PharosClientService {
    private static var claimedLocalAgySessions: Set<String> = []
    private static var claimedLocalDshSessions: Set<String> = []
    private let sessions: LivePharosClientService
    private let agy: AgyLiveSessionService
    private let dsh: DshLiveSessionService
    private let store: ProjectStore
    private let mesh: DistributedMeshSupport
    private let brokerRequest: @Sendable (MeshRequest) -> MeshResponse?
    private let remoteCodexTransport: @Sendable (String, any CodexTransport) -> any CodexTransport
    private var roomCache: [String: MeshRoomInfo] = [:]
    private var memberCache: [String: MeshMemberInfo] = [:]
    private var sessionCache: [ClientSessionSummary] = []
    private var hasSessionInventory = false
    private var agySessionCache: [ClientSessionSummary] = []
    private var agyRefreshAt: Date?
    private var agyAvailable = false
    private var dshSessionCache: [ClientSessionSummary] = []
    private var dshRefreshAt: Date?
    private var dshAvailable = false
    private var remoteServices: [String: LivePharosClientService] = [:]
    private var peerServices: [String: (deviceID: MeshDeviceID, service: any PharosClientService)] = [:]
    private var peerObservers: [String: Task<Void, Never>] = [:]
    private(set) var peerSnapshots: [String: [ClientSessionSummary]] = [:]
    private var peerSessionOwners: [String: String] = [:]
    private var peerInventoryIssues: [String: [ClientSessionInventoryIssue]] = [:]
    private let peerServiceFactory: (@MainActor (MeshDeviceID, String) async throws -> any PharosClientService)?
    private(set) var remoteConnections: [String: SharedSSHConnection] = [:]
    private var remoteDshServices: [String: DshLiveSessionService] = [:]
    private(set) var remoteDshInventoryDiagnostics: [String: String] = [:]
    private(set) var remoteDshHistoryDiagnostics: [String: String] = [:]
    private(set) var remoteDshHistoryRequestCounts: [String: Int] = [:]
    private(set) var remoteCodexHistoryRequestCounts: [String: Int] = [:]
    private var remoteDshOwners: [String: (host: String, rawID: String)] = [:]
    private(set) var remoteDshSnapshots: [String: [ClientSessionSummary]] = [:]
    private var remoteDshDestinations: [String: String] = [:]
    private var pendingDshRecovery: [String: Set<String>] = [:]
    private var pendingCodexRecovery: [String: Set<String>] = [:]
    private var pendingAgyRecovery: [String: Set<String>] = [:]
    private var remoteAgyServices: [String: AgyLiveSessionService] = [:]
    private var remoteAgyOwners: [String: (host: String, rawID: String, workspace: String)] = [:]
    private(set) var remoteAgySnapshots: [String: [ClientSessionSummary]] = [:]
    private(set) var remoteAgyInventoryDiagnostics: [String: String] = [:]
    private var remoteAgyDestinations: [String: String] = [:]
    private(set) var remoteProjectPaths: [String: [UUID: String]] = [:]
    private(set) var remoteProjectPathsUnavailable: Set<String> = []
    private var remoteObservers: [String: Task<Void, Never>] = [:]
    private var remoteSessionOwners: [String: String] = [:]
    private var remoteCache: [ClientSessionSummary] = []
    private var remoteRefreshAt: Date?
    private var remoteRefreshing = false
    private struct AgyThreadWorker {
        let memberID: String
        let bridge: AgyThreadRuntimeBridge
        let task: Task<Void, Never>
    }
    private var agyThreadTasks: [String: AgyThreadWorker] = [:]
    private struct DshThreadWorker {
        let memberID: String
        let bridge: DshThreadRuntimeBridge
        let task: Task<Void, Never>
    }
    private var dshThreadTasks: [String: DshThreadWorker] = [:]

    init(store: ProjectStore, mesh: DistributedMeshSupport, sessions: LivePharosClientService = .init(),
         remoteCodexTransport: @Sendable @escaping (String, any CodexTransport) -> any CodexTransport = { _, transport in transport },
         peerServiceFactory: (@MainActor (MeshDeviceID, String) async throws -> any PharosClientService)? = nil,
         brokerRequest: @Sendable @escaping (MeshRequest) -> MeshResponse? = { MeshClient.sendIfUp($0) }) {
        self.store = store
        self.mesh = mesh
        self.sessions = sessions
        self.agy = AgyLiveSessionService { event in await sessions.publishExternalEvent(event) }
        let plugin = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.resourceURL?.appendingPathComponent("dsh-plugin-pharos/index.mjs") : nil
        self.dsh = DshLiveSessionService(host: DshWebHost(pluginModule: plugin)) { event in await sessions.publishExternalEvent(event) }
        self.brokerRequest = brokerRequest
        self.remoteCodexTransport = remoteCodexTransport
        self.peerServiceFactory = peerServiceFactory
    }

    nonisolated func events() -> AsyncStream<PharosClientEvent> { sessions.events() }
    deinit {
        remoteObservers.values.forEach { $0.cancel() }
        peerObservers.values.forEach { $0.cancel() }
        agyThreadTasks.values.forEach { $0.task.cancel() }
        dshThreadTasks.values.forEach { $0.task.cancel() }
        remoteConnections.values.forEach { $0.close() }
    }


    struct LocalAgyThreadBinding {
        let session: ClientSessionSummary
        let memberID: String
    }

    /// Use only the explicit provider Session stored in the roster. An ACP
    /// Session claimed by multiple local members is ambiguous and stays idle.
    static func explicitLocalAgyThreadBindings(_ sessions: [ClientSessionSummary], members: [String: MeshMemberInfo],
                                                local: LightSelfHost) -> [LocalAgyThreadBinding] {
        sessions.compactMap { session in
            guard session.agentType == "agy", session.id.hasPrefix("agy:"), !session.workspacePath.isEmpty else { return nil }
            let rawID = String(session.id.dropFirst(4))
            guard !rawID.isEmpty else { return nil }
            let matches = members.compactMap { key, member -> String? in
                guard !key.isEmpty, member.id == key, member.session == rawID, !member.rooms.isEmpty,
                      let host = member.host, local.matches(host),
                      ["agy", "ag", "antigravity"].contains(member.kind?.lowercased() ?? "") else { return nil }
                return key
            }
            guard matches.count == 1, let memberID = matches.first else { return nil }
            return LocalAgyThreadBinding(session: session, memberID: memberID)
        }
    }

    struct LocalDshThreadBinding {
        let session: ClientSessionSummary
        let memberID: String
    }

    /// Product-mode Host bridge bindings for DSH. Member ID must match the
    /// vendor Session exactly (DSH preferred member), and the Host must be local.
    static func explicitLocalDshThreadBindings(_ sessions: [ClientSessionSummary], members: [String: MeshMemberInfo],
                                               local: LightSelfHost) -> [LocalDshThreadBinding] {
        sessions.compactMap { session in
            guard session.agentType == "dsh", session.id.hasPrefix("dsh:") else { return nil }
            let rawID = String(session.id.dropFirst(4))
            guard !rawID.isEmpty else { return nil }
            let matches = members.compactMap { key, member -> String? in
                guard !key.isEmpty, member.id == key, !member.rooms.isEmpty,
                      let host = member.host, local.matches(host),
                      ["dsh", "deepseek", "deepseek-harness"].contains(member.kind?.lowercased() ?? ""),
                      member.session == rawID || member.id == rawID else { return nil }
                return key
            }
            guard matches.count == 1, let memberID = matches.first else { return nil }
            return LocalDshThreadBinding(session: session, memberID: memberID)
        }
    }

    private func startExplicitLocalAgyThreadBridges() {
        guard agyAvailable else { return }
        let matching = Self.explicitLocalAgyThreadBindings(agySessionCache, members: memberCache, local: .fromEnvironment())
        let wanted = Dictionary(matching.map { (String($0.session.id.dropFirst(4)), $0.memberID) }, uniquingKeysWith: { _, _ in "" })
        for (id, worker) in agyThreadTasks {
            Task { await worker.bridge.setAccepting(wanted[id] == worker.memberID) }
        }
        for binding in matching {
            let session = binding.session
            let rawID = String(session.id.dropFirst(4))
            guard wanted[rawID] == binding.memberID, agyThreadTasks[rawID] == nil, !Self.claimedLocalAgySessions.contains(rawID) else { continue }
            Self.claimedLocalAgySessions.insert(rawID)
            let service = agy, output = sessions, broker = brokerRequest, mesh = mesh
            let productMode = mesh.isProductModeEnabled
            let workspace = session.workspacePath, uiID = session.id
            let stream = output.events()
            let bridge: AgyThreadRuntimeBridge
            if productMode {
                bridge = AgyThreadRuntimeBridge(
                    binding: .init(memberID: binding.memberID, sessionID: uiID, providerSessionID: rawID),
                    send: { id, text, turn in _ = try await service.send(sessionId: id, text: text, turnID: turn) },
                    reply: { delivery, text in
                        _ = try await mesh.replyOnceChatMessage(
                            room: delivery.room, memberID: delivery.memberID,
                            originalMessageID: delivery.messageID, text: text
                        )
                    }
                )
            } else {
                bridge = AgyThreadRuntimeBridge(
                    binding: .init(memberID: binding.memberID, sessionID: uiID, providerSessionID: rawID),
                    send: { id, text, turn in _ = try await service.send(sessionId: id, text: text, turnID: turn) },
                    broker: { request in
                        guard let response = broker(request) else {
                            throw PharosClientError.connectionFailed("Mesh broker is unavailable")
                        }
                        guard response.ok else {
                            throw PharosClientError.operationFailed(response.error ?? "Mesh reply failed")
                        }
                    }
                )
            }
            let task = Task { [weak self] in
                let listener = Task {
                    for await event in stream {
                        guard !Task.isCancelled else { break }
                        await bridge.handle(event)
                    }
                }
                while !Task.isCancelled {
                    do {
                        _ = try await service.load(sessionId: rawID, workspace: workspace)
                        try await bridge.poll()
                    } catch {
                        // Keep the next poll available; accepted deliveries are
                        // not reported as completed on connection failure.
                    }
                    if await bridge.isRetiredAndIdle() { break }
                    try? await Task.sleep(for: .seconds(2))
                }
                listener.cancel()
                await bridge.shutdown()
                await MainActor.run {
                    self?.agyThreadTasks.removeValue(forKey: rawID)
                    Self.claimedLocalAgySessions.remove(rawID)
                }
            }
            agyThreadTasks[rawID] = AgyThreadWorker(memberID: binding.memberID, bridge: bridge, task: task)
        }
    }

    /// Product Mesh only: Host-owned DSH delivery.poll → Session → replyOnce.
    /// Legacy Broker mode keeps the project plugin as the consumer.
    private func startExplicitLocalDshThreadBridges() {
        guard mesh.isProductModeEnabled, dshAvailable else {
            for (id, worker) in dshThreadTasks {
                Task { await worker.bridge.setAccepting(false) }
                _ = id
            }
            return
        }
        let matching = Self.explicitLocalDshThreadBindings(dshSessionCache, members: memberCache, local: .fromEnvironment())
        let wanted = Dictionary(matching.map { (String($0.session.id.dropFirst(4)), $0.memberID) }, uniquingKeysWith: { _, _ in "" })
        for (id, worker) in dshThreadTasks {
            Task { await worker.bridge.setAccepting(wanted[id] == worker.memberID) }
        }
        for binding in matching {
            let session = binding.session
            let rawID = String(session.id.dropFirst(4))
            guard wanted[rawID] == binding.memberID, dshThreadTasks[rawID] == nil,
                  !Self.claimedLocalDshSessions.contains(rawID) else { continue }
            Self.claimedLocalDshSessions.insert(rawID)
            let service = dsh, output = sessions, mesh = mesh
            let uiID = session.id
            let stream = output.events()
            let bridge = DshThreadRuntimeBridge(
                binding: .init(memberID: binding.memberID, sessionID: uiID, providerSessionID: rawID),
                send: { id, text, turn in _ = try await service.send(sessionId: id, text: text, turnID: turn) },
                reply: { delivery, text in
                    _ = try await mesh.replyOnceChatMessage(
                        room: delivery.room, memberID: delivery.memberID,
                        originalMessageID: delivery.messageID, text: text
                    )
                }
            )
            let task = Task { [weak self] in
                let listener = Task {
                    for await event in stream {
                        guard !Task.isCancelled else { break }
                        await bridge.handle(event)
                    }
                }
                while !Task.isCancelled {
                    do {
                        try await bridge.poll()
                    } catch {
                        // Keep the next poll available; accepted deliveries are
                        // not reported as completed on connection failure.
                    }
                    if await bridge.isRetiredAndIdle() { break }
                    try? await Task.sleep(for: .seconds(2))
                }
                listener.cancel()
                await bridge.shutdown()
                await MainActor.run {
                    self?.dshThreadTasks.removeValue(forKey: rawID)
                    Self.claimedLocalDshSessions.remove(rawID)
                }
            }
            dshThreadTasks[rawID] = DshThreadWorker(memberID: binding.memberID, bridge: bridge, task: task)
        }
    }

    static func shouldRefreshRemoteInventory(isRefreshing: Bool, lastRefresh: Date?, now: Date, hasClosedConnection: Bool) -> Bool {
        guard !isRefreshing else { return false }
        return hasClosedConnection || lastRefresh == nil || now.timeIntervalSince(lastRefresh!) >= 60
    }

    func refreshRemoteSessionsIfNeeded(force: Bool = false) async {
        let hasClosedConnection = remoteConnections.values.contains { !$0.isRunning }
        guard !remoteRefreshing, force || Self.shouldRefreshRemoteInventory(isRefreshing: remoteRefreshing, lastRefresh: remoteRefreshAt,
                                                now: Date(), hasClosedConnection: hasClosedConnection) else { return }
        remoteRefreshing = true
        defer { remoteRefreshing = false }
        remoteRefreshAt = Date()
        let config = LightHostsFile.standard().load()
        peerInventoryIssues = peerInventoryIssues.filter { config.peerDeviceIDs[$0.key] != nil }
        for host in Array(peerServices.keys) where
            config.peerDeviceIDs[host]?.lowercased() != peerServices[host]?.deviceID.rawValue.uuidString.lowercased() {
            peerObservers.removeValue(forKey: host)?.cancel()
            peerServices.removeValue(forKey: host)
            peerSnapshots.removeValue(forKey: host)
        }
        for host in Array(remoteConnections.keys) where config.ssh[host] == nil {
            remoteObservers.removeValue(forKey: host)?.cancel()
            remoteServices.removeValue(forKey: host)
            remoteConnections.removeValue(forKey: host)
            pendingCodexRecovery.removeValue(forKey: host)
            pendingAgyRecovery.removeValue(forKey: host)
        }
        for host in Array(remoteDshDestinations.keys) where config.ssh[host] == nil {
            pendingCodexRecovery.removeValue(forKey: host)
            pendingAgyRecovery.removeValue(forKey: host)
            remoteDshDestinations.removeValue(forKey: host)
            remoteDshSnapshots.removeValue(forKey: host)
            remoteDshServices.removeValue(forKey: host)
            remoteDshInventoryDiagnostics.removeValue(forKey: host)
            pendingDshRecovery.removeValue(forKey: host)
        }
        for host in Array(remoteAgyDestinations.keys) where config.ssh[host] == nil {
            remoteAgyDestinations.removeValue(forKey: host)
            remoteAgySnapshots.removeValue(forKey: host)
            remoteAgyServices.removeValue(forKey: host)
            remoteAgyInventoryDiagnostics.removeValue(forKey: host)
            pendingAgyRecovery.removeValue(forKey: host)
        }
        let local = LightSelfHost.fromEnvironment()
        var found: [ClientSessionSummary] = []
        var owners: [String: String] = [:]
        var peerOwners: [String: String] = [:]
        var dshOwners: [String: (host: String, rawID: String)] = [:]
        var restoredSessionIDs = Set<String>()
        var agyOwners: [String: (host: String, rawID: String, workspace: String)] = [:]
        var projectPaths: [String: [UUID: String]] = [:]
        var unavailableProjectPaths = Set<String>()
        for host in Set(config.ssh.keys).union(config.peerDeviceIDs.keys).sorted() {
            let destination = config.ssh[host] ?? ""
            guard !local.matches(host), destination.isEmpty || !local.matches(destination) else { continue }
            var peerManagedAgents: Set<String> = []
            var peerProjectAvailable = false
            if let rawID = config.peerDeviceIDs[host], let uuid = UUID(uuidString: rawID),
               config.peerDeviceIDs.values.filter({ $0.lowercased() == rawID.lowercased() }).count == 1 {
                let deviceID = MeshDeviceID(rawValue: uuid)
                let previouslyConnected = peerServices[host] != nil
                do {
                    let service: any PharosClientService
                    if let existing = peerServices[host] { service = existing.service }
                    else {
                        let prefix = "peer:\(uuid.uuidString.lowercased()):codex:"
                        if let peerServiceFactory { service = try await peerServiceFactory(deviceID, prefix) }
                        else { service = try await mesh.remoteSessionClient(for: deviceID, sessionIDPrefix: prefix) }
                    }
                    if !previouslyConnected, let remote = service as? MeshRemoteHostSessionClient {
                        try await remote.verifyEventProtocol()
                    }
                    // Projects remain usable even if every Agent inventory is
                    // unavailable; fetching checkout data is independent.
                    if let projects = service as? any HostProjectCheckoutReporting,
                       let paths = try? await projects.fetchHostProjectCheckouts() {
                        projectPaths[host] = paths
                        peerProjectAvailable = true
                    }
                    guard let remote = service as? any HostSessionInventorySnapshotReporting else {
                        throw PharosClientError.operationFailed("Peer does not support atomic Session inventory")
                    }
                    let snapshot = try await remote.fetchHostSessionInventorySnapshot()
                    let entries = snapshot.sessions
                    let report = snapshot.status
                    let supported = Set(report.supportedAgents).intersection(["codex", "dsh", "agy"])
                    let unavailable = Set(report.unavailableAgents)
                    peerInventoryIssues[host] = unavailable.sorted().map {
                        ClientSessionInventoryIssue(host: host, agent: "\($0.uppercased()) via Peer")
                    }
                    let prior = peerSnapshots[host] ?? []
                    let sticky = Set(prior.map(\.agentType)).intersection(unavailable)
                    peerManagedAgents = supported.subtracting(unavailable).union(sticky)
                    if !previouslyConnected {
                        peerServices[host] = (deviceID, service)
                        let stream = service.events(), output = sessions
                        peerObservers[host] = Task {
                            for await event in stream {
                                guard !Task.isCancelled else { break }
                                await output.publishExternalEvent(event)
                            }
                        }
                    }
                    var projected = entries.filter { peerManagedAgents.contains($0.agentType) && !sticky.contains($0.agentType) }
                        .map { Self.remoteSummary($0, host: host, route: "peer", stale: false) }
                    projected += prior.filter { sticky.contains($0.agentType) }
                        .map { Self.remoteSummary($0, host: host, route: "peer", stale: true) }
                    peerSnapshots[host] = projected
                    found.append(contentsOf: projected)
                    for entry in projected { peerOwners[entry.id] = host }
                } catch where previouslyConnected {
                    peerInventoryIssues[host] = [.init(host: host, agent: "Peer")]
                    // Existing peer sessions stay bound to that route. An
                    // uncertain action must never be replayed over SSH.
                    let stale = (peerSnapshots[host] ?? []).map { Self.remoteSummary($0, host: host, route: "peer", stale: true) }
                    peerSnapshots[host] = stale
                    found.append(contentsOf: stale)
                    for entry in stale { peerOwners[entry.id] = host }
                    peerManagedAgents = Set(stale.map(\.agentType))
                } catch {
                    peerInventoryIssues[host] = [.init(host: host, agent: "Peer")]
                    // Initial read-only discovery failed; SSH may be used.
                }
            } else if config.peerDeviceIDs[host] != nil {
                peerInventoryIssues[host] = [.init(host: host, agent: "Peer mapping")]
            }
            if peerManagedAgents.contains("agy") {
                remoteAgyInventoryDiagnostics.removeValue(forKey: host)
            }
            guard !destination.isEmpty else {
                if !peerProjectAvailable { unavailableProjectPaths.insert(host) }
                continue
            }
            if let previous = remoteDshDestinations[host], previous != destination {
                pendingCodexRecovery.removeValue(forKey: host)
                pendingAgyRecovery.removeValue(forKey: host)
            }
            let connection: SharedSSHConnection
            if let existing = remoteConnections[host], existing.destination == destination, existing.isRunning {
                connection = existing
            } else {
                let previousConnection = remoteConnections[host]
                if previousConnection?.destination == destination {
                    pendingDshRecovery[host, default: []].formUnion(remoteDshSnapshots[host]?.map(\.id) ?? [])
                    pendingCodexRecovery[host, default: []].formUnion(remoteSessionOwners.compactMap { $0.value == host ? $0.key : nil })
                    pendingAgyRecovery[host, default: []].formUnion(remoteAgySnapshots[host]?.map(\.id) ?? [])
                } else if previousConnection != nil {
                    pendingDshRecovery.removeValue(forKey: host)
                    pendingCodexRecovery.removeValue(forKey: host)
                    pendingAgyRecovery.removeValue(forKey: host)
                }
                remoteObservers.removeValue(forKey: host)?.cancel()
                remoteServices.removeValue(forKey: host)
                remoteDshServices.removeValue(forKey: host)
                remoteAgyServices.removeValue(forKey: host)
                remoteConnections.removeValue(forKey: host)
                do {
                    connection = try await Task.detached {
                        if let previousConnection, previousConnection.destination == destination {
                            previousConnection.close()
                            guard previousConnection.waitUntilStopped() else {
                                throw PharosClientError.backendUnreachable(backend: "ssh", reason: "Previous shared connection did not close")
                            }
                        }
                        return try SharedSSHConnection(destination: destination)
                    }.value
                    remoteConnections[host] = connection
                } catch {
                    if !peerProjectAvailable { unavailableProjectPaths.insert(host) }
                    applyRemoteDshInventory(host: host, destination: destination, result: .failure(error)) {
                        DshWebHost(remoteHost: destination)
                    }
                    if let entries = remoteDshSnapshots[host] {
                        let prefix = RemoteCodexTransport.prefix(host).replacingOccurrences(of: ":codex:", with: ":dsh:")
                        for entry in entries where entry.id.hasPrefix(prefix) {
                            dshOwners[entry.id] = (host, String(entry.id.dropFirst(prefix.count)))
                            found.append(Self.remoteSummary(entry, host: host, route: "ssh", stale: entry.inventoryStale == true))
                        }
                    }
                    markRemoteAgyInventoryFailed(host: host, destination: destination, error: error)
                    if let entries = remoteAgySnapshots[host] {
                        let prefix = RemoteCodexTransport.prefix(host).replacingOccurrences(of: ":codex:", with: ":agy:")
                        for entry in entries where entry.id.hasPrefix(prefix) {
                            agyOwners[entry.id] = (host, String(entry.id.dropFirst(prefix.count)), entry.workspacePath)
                            found.append(Self.remoteSummary(entry, host: host, route: "ssh", stale: entry.inventoryStale == true))
                        }
                    }
                    continue
                }
            }
            let checkoutTask: Task<[UUID: String]?, Never>? = peerProjectAvailable ? nil : Task.detached {
                try? RemoteProjectPaths.read(destination: destination, connection: connection)
            }
            prepareRemoteAgyDestination(host: host, destination: destination)
            if !peerManagedAgents.contains("codex") { do {
                let service: LivePharosClientService
                if let existing = remoteServices[host] { service = existing }
                else {
                    let transport = try await Task.detached {
                        try RemoteCodexTransport(destination: destination, hostID: host, connection: connection)
                    }.value
                    service = LivePharosClientService(transport: remoteCodexTransport(host, transport), machineID: host)
                    remoteServices[host] = service
                    let stream = service.events()
                    let output = sessions
                    remoteObservers[host] = Task {
                        for await event in stream {
                            guard !Task.isCancelled else { break }
                            await output.publishExternalEvent(event)
                        }
                    }
                }
                let entries = try await service.fetchSessions()
                let current = Set(entries.map(\.id))
                restoredSessionIDs.formUnion((pendingCodexRecovery.removeValue(forKey: host) ?? []).filter { current.contains($0) })
                found.append(contentsOf: entries.map { Self.remoteSummary($0, host: host, route: "ssh", stale: false) })
                for entry in entries { owners[entry.id] = host }
            } catch {
                remoteObservers.removeValue(forKey: host)?.cancel()
                remoteServices.removeValue(forKey: host)
            } }
            if !peerManagedAgents.contains("dsh") {
            let dshResult: Result<[LightSessionEntry], Error>
            do {
                let entries = try await Task.detached {
                    try SessionInventoryCollector.queryACP(bin: "/usr/bin/ssh", timeout: 20,
                        arguments: try connection.commandArguments("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin /opt/homebrew/bin/dsh --profile acp"), app: "dsh")
                }.value
                dshResult = .success(entries)
            } catch { dshResult = .failure(error) }
            applyRemoteDshInventory(host: host, destination: destination, result: dshResult) {
                DshWebHost(remoteHost: destination, sharedConnection: connection)
            }
            if case .success = dshResult, remoteDshServices[host] != nil {
                let current = Set(remoteDshSnapshots[host]?.map(\.id) ?? [])
                restoredSessionIDs.formUnion((pendingDshRecovery.removeValue(forKey: host) ?? []).filter { current.contains($0) })
            }
            if let entries = remoteDshSnapshots[host] {
                let prefix = RemoteCodexTransport.prefix(host).replacingOccurrences(of: ":codex:", with: ":dsh:")
                for entry in entries where entry.id.hasPrefix(prefix) {
                    dshOwners[entry.id] = (host, String(entry.id.dropFirst(prefix.count)))
                    found.append(Self.remoteSummary(entry, host: host, route: "ssh", stale: entry.inventoryStale == true))
                }
            }
            }
            if !peerManagedAgents.contains("agy") {
            do {
                guard !destination.isEmpty, !destination.hasPrefix("-"), !destination.contains("\n") else {
                    throw PharosClientError.operationFailed("Invalid remote Antigravity host")
                }
                let arguments = try connection.commandArguments("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin /opt/homebrew/bin/agy acp --stdio")
                let entries = try await Task.detached {
                    try SessionInventoryCollector.queryACP(bin: "/usr/bin/ssh", timeout: 20, arguments: arguments, app: "agy")
                }.value
                registerRemoteAgy(host: host, entries: entries) {
                    _ = connection // Keep the shared connection alive for the ACP child.
                    return AgyAcpProcessTransport(executableURL: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments)
                }
                let current = Set(remoteAgySnapshots[host]?.map(\.id) ?? [])
                restoredSessionIDs.formUnion((pendingAgyRecovery.removeValue(forKey: host) ?? []).filter { current.contains($0) })
            } catch {
                markRemoteAgyInventoryFailed(host: host, destination: destination, error: error)
            }
            if let entries = remoteAgySnapshots[host] {
                let prefix = RemoteCodexTransport.prefix(host).replacingOccurrences(of: ":codex:", with: ":agy:")
                for entry in entries {
                    guard entry.id.hasPrefix(prefix) else { continue }
                    agyOwners[entry.id] = (host, String(entry.id.dropFirst(prefix.count)), entry.workspacePath)
                    found.append(Self.remoteSummary(entry, host: host, route: "ssh", stale: entry.inventoryStale == true))
                }
            }
            }
            if let checkoutTask {
                if let paths = await checkoutTask.value { projectPaths[host] = paths }
                else { unavailableProjectPaths.insert(host) }
            }
        }
        remoteCache = found
        remoteSessionOwners = owners
        peerSessionOwners = peerOwners
        remoteDshOwners = dshOwners
        remoteAgyOwners = agyOwners
        remoteProjectPaths = projectPaths
        remoteProjectPathsUnavailable = unavailableProjectPaths
        for id in restoredSessionIDs { await sessions.publishExternalEvent(.sessionConnectionRestored(sessionId: id)) }
    }

    private static func remoteSummary(_ s: ClientSessionSummary, host: String, route: String, stale: Bool) -> ClientSessionSummary {
        ClientSessionSummary(sessionId: s.sessionId, machineId: host, agentType: s.agentType,
            workspacePath: s.workspacePath, title: s.title, status: stale ? .unknown : s.status,
            latestMessagePreview: s.latestMessagePreview, updatedAt: s.updatedAt, avatarSeed: s.avatarSeed,
            rawVendorPayload: s.rawVendorPayload, inventoryStale: stale || s.inventoryStale == true,
            connectionRoute: route)
    }

    private func remoteService(for sessionId: String) throws -> (any PharosClientService)? {
        if sessionId.hasPrefix("peer:") {
            guard let host = peerSessionOwners[sessionId], let service = peerServices[host]?.service else {
                throw PharosClientError.backendUnreachable(backend: "peer", reason: "Remote session host is unavailable")
            }
            return service
        }
        guard sessionId.hasPrefix("remote:"), sessionId.contains(":codex:") else { return nil }
        guard let host = remoteSessionOwners[sessionId], let service = remoteServices[host] else {
            throw PharosClientError.backendUnreachable(backend: "codex", reason: "Remote session host is unavailable")
        }
        return service
    }

    private func remoteDshService(for sessionId: String) throws -> (DshLiveSessionService, String)? {
        guard sessionId.hasPrefix("remote:"), sessionId.contains(":dsh:") else { return nil }
        guard let owner = remoteDshOwners[sessionId], let service = remoteDshServices[owner.host] else {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "Remote session host is unavailable")
        }
        return (service, owner.rawID)
    }

    private func remoteAgyService(for sessionId: String) throws -> (AgyLiveSessionService, String, String)? {
        guard sessionId.hasPrefix("remote:"), sessionId.contains(":agy:") else { return nil }
        guard let owner = remoteAgyOwners[sessionId], let service = remoteAgyServices[owner.host] else {
            throw PharosClientError.backendUnreachable(backend: "agy", reason: "Remote session host is unavailable")
        }
        return (service, owner.rawID, owner.workspace)
    }

    // A failed inventory is not evidence that an open Session disappeared.
    // Keep the last known summaries (whose activity is unknown) and the owning
    // service until a successful refresh or a destination change replaces them.
    func applyRemoteDshInventory(host: String, destination: String,
                                 result: Result<[LightSessionEntry], Error>,
                                 factory: () -> any DshSessionHosting) {
        if let previous = remoteDshDestinations[host], previous != destination {
            remoteDshServices.removeValue(forKey: host)
            remoteDshSnapshots.removeValue(forKey: host)
            remoteDshOwners = remoteDshOwners.filter { $0.value.host != host }
            pendingDshRecovery.removeValue(forKey: host)
        }
        remoteDshDestinations[host] = destination
        switch result {
        case .failure(let error):
            let failure = error as NSError
            remoteDshInventoryDiagnostics[host] = "error-\(failure.domain)-\(failure.code)-\(failure.userInfo["processState"] as? String ?? "unknown")"
            remoteDshSnapshots[host] = remoteDshSnapshots[host]?.map { entry in
                ClientSessionSummary(sessionId: entry.id, machineId: entry.machineId, agentType: entry.agentType,
                    workspacePath: entry.workspacePath, title: entry.title, status: .unknown,
                    latestMessagePreview: entry.latestMessagePreview, updatedAt: entry.updatedAt,
                    avatarSeed: entry.avatarSeed, rawVendorPayload: entry.rawVendorPayload, inventoryStale: true)
            }
        case .success(let entries):
            remoteDshInventoryDiagnostics[host] = "count-\(entries.count)"
            let prefix = RemoteCodexTransport.prefix(host).replacingOccurrences(of: ":codex:", with: ":dsh:")
            if remoteDshServices[host] == nil {
                let output = sessions
                remoteDshServices[host] = DshLiveSessionService(host: factory(), sessionIDPrefix: prefix) {
                    await output.publishExternalEvent($0)
                }
            }
            remoteDshOwners = remoteDshOwners.filter { $0.value.host != host }
            remoteDshSnapshots[host] = entries.map { entry in
                let id = prefix + entry.id
                remoteDshOwners[id] = (host, entry.id)
                return ClientSessionSummary(sessionId: id, machineId: host, agentType: "dsh",
                    workspacePath: entry.cwd ?? "", title: entry.title ?? "DeepSeek Harness", status: .unknown,
                    updatedAt: entry.lastActive ?? .distantPast, avatarSeed: id)
            }
        }
    }

    private func prepareRemoteAgyDestination(host: String, destination: String) {
        if let previous = remoteAgyDestinations[host], previous != destination {
            remoteAgyServices.removeValue(forKey: host)
            remoteAgySnapshots.removeValue(forKey: host)
            remoteAgyOwners = remoteAgyOwners.filter { $0.value.host != host }
            pendingAgyRecovery.removeValue(forKey: host)
        }
        remoteAgyDestinations[host] = destination
    }

    func markRemoteAgyInventoryFailed(host: String, destination: String, error: Error) {
        prepareRemoteAgyDestination(host: host, destination: destination)
        let failure = error as NSError
        remoteAgyInventoryDiagnostics[host] = "error-\(failure.domain)-\(failure.code)"
        remoteAgySnapshots[host] = remoteAgySnapshots[host]?.map { entry in
            ClientSessionSummary(sessionId: entry.id, machineId: entry.machineId, agentType: entry.agentType,
                workspacePath: entry.workspacePath, title: entry.title, status: .unknown,
                latestMessagePreview: entry.latestMessagePreview, updatedAt: entry.updatedAt,
                avatarSeed: entry.avatarSeed, rawVendorPayload: entry.rawVendorPayload, inventoryStale: true)
        }
    }

    func registerRemoteAgy(host: String, entries: [LightSessionEntry],
                           factory: @escaping @Sendable () -> AgyAcpProcessTransport) {
        remoteAgyInventoryDiagnostics[host] = "count-\(entries.count)"
        let prefix = RemoteCodexTransport.prefix(host).replacingOccurrences(of: ":codex:", with: ":agy:")
        if remoteAgyServices[host] == nil {
            let output = sessions
            remoteAgyServices[host] = AgyLiveSessionService(factory: factory, sessionIDPrefix: prefix) {
                await output.publishExternalEvent($0)
            }
        }
        remoteAgyOwners = remoteAgyOwners.filter { $0.value.host != host }
        remoteAgySnapshots[host] = entries.map { entry in
            let id = prefix + entry.id
            remoteAgyOwners[id] = (host, entry.id, entry.cwd ?? "")
            return ClientSessionSummary(sessionId: id, machineId: host, agentType: "agy",
                workspacePath: entry.cwd ?? "", title: entry.title ?? "Antigravity", status: .unknown,
                updatedAt: entry.lastActive ?? .distantPast, avatarSeed: id)
        }
    }

    func fetchSessionInventoryIssues() async -> [ClientSessionInventoryIssue] {
        let sshIssues = remoteAgyInventoryDiagnostics.compactMap { host, status in
            status.hasPrefix("error-") ? ClientSessionInventoryIssue(host: host, agent: "Antigravity") : nil
        }
        return (sshIssues + peerInventoryIssues.values.flatMap { $0 }).sorted {
            ($0.host, $0.agent) < ($1.host, $1.agent)
        }
    }

    func fetchSessions() async throws -> [ClientSessionSummary] {
        var codexError: Error?
        let codex: [ClientSessionSummary]
        do { codex = try await sessions.fetchSessions() }
        catch { codex = []; codexError = error }
        if agyRefreshAt == nil || Date().timeIntervalSince(agyRefreshAt!) >= 60 {
            agyRefreshAt = Date()
            do {
                let entries = try await Task.detached {
                    try SessionInventoryCollector.queryACP(bin: "/opt/homebrew/bin/agy", timeout: 15)
                }.value
                agySessionCache = entries.map {
                    ClientSessionSummary(sessionId: "agy:" + $0.id, machineId: ProcessInfo.processInfo.hostName,
                        agentType: "agy", workspacePath: $0.cwd ?? "", title: $0.title ?? "Antigravity",
                        status: .unknown, updatedAt: $0.lastActive ?? .distantPast, avatarSeed: "agy:" + $0.id)
                }
                agyAvailable = true
            } catch {
                agyAvailable = false
            }
        }
        if dshRefreshAt == nil || Date().timeIntervalSince(dshRefreshAt!) >= 60 {
            dshRefreshAt = Date()
            do {
                let entries = try await Task.detached {
                    try SessionInventoryCollector.queryACP(bin: "/opt/homebrew/bin/dsh", timeout: 20,
                                                            arguments: ["--profile", "acp"], app: "dsh")
                }.value
                dshSessionCache = entries.map {
                    ClientSessionSummary(sessionId: "dsh:" + $0.id, machineId: ProcessInfo.processInfo.hostName,
                        agentType: "dsh", workspacePath: $0.cwd ?? "", title: $0.title ?? "DeepSeek Harness",
                        status: .unknown, updatedAt: $0.lastActive ?? .distantPast, avatarSeed: "dsh:" + $0.id)
                }
                dshAvailable = true
            } catch {
                dshAvailable = false
            }
        }
        await refreshRemoteSessionsIfNeeded()
        if let codexError, !agyAvailable && !dshAvailable && remoteCache.isEmpty { throw codexError }
        sessionCache = (codex + agySessionCache + dshSessionCache + remoteCache).sorted { $0.updatedAt > $1.updatedAt }
        hasSessionInventory = true
        startExplicitLocalAgyThreadBridges()
        startExplicitLocalDshThreadBridges()
        return sessionCache
    }
    func fetchSessionHistory(sessionId: String) async throws -> [CanonicalTurn] {
        if let (remote, id, workspace) = try remoteAgyService(for: sessionId) {
            guard !workspace.isEmpty else { throw PharosClientError.operationFailed("Antigravity did not provide this session's workspace") }
            return try await remote.load(sessionId: id, workspace: workspace)
        }
        if let (remote, id) = try remoteDshService(for: sessionId) {
            remoteDshHistoryRequestCounts[sessionId, default: 0] += 1
            do {
                let result = try await remote.history(sessionId: id)
                remoteDshHistoryDiagnostics[sessionId] = "success-\(result.count)"
                return result
            } catch {
                switch error {
                case PharosClientError.backendUnreachable(_, let reason):
                    let known = ["Remote event connection closed", "Could not open remote DSH tunnel", "DSH Host did not announce a loopback endpoint"]
                    remoteDshHistoryDiagnostics[sessionId] = known.contains(reason) ? reason : "backend-unreachable-other"
                case PharosClientError.operationFailed(let reason):
                    let known = ["DSH did not return a session snapshot", "DSH interaction stream did not become ready", "DSH history exceeds the current page limit"]
                    remoteDshHistoryDiagnostics[sessionId] = known.contains(reason) ? reason : "operation-failed-other"
                default:
                    remoteDshHistoryDiagnostics[sessionId] = "error-\(String(reflecting: type(of: error)))-\((error as NSError).code)"
                }
                throw error
            }
        }
        if let remote = try remoteService(for: sessionId) {
            remoteCodexHistoryRequestCounts[sessionId, default: 0] += 1
            return try await remote.fetchSessionHistory(sessionId: sessionId)
        }
        if sessionId.hasPrefix("agy:") {
            guard let summary = agySessionCache.first(where: { $0.id == sessionId }),
                  !summary.workspacePath.isEmpty else {
                throw PharosClientError.operationFailed("Antigravity did not provide this session's workspace")
            }
            return try await agy.load(
                sessionId: String(sessionId.dropFirst(4)), workspace: summary.workspacePath
            )
        }
        if sessionId.hasPrefix("dsh:") {
            return try await dsh.history(
                sessionId: String(sessionId.dropFirst(4))
            )
        }
        return try await sessions.fetchSessionHistory(sessionId: sessionId)
    }
    func fetchSessionConfiguration(sessionId: String) async throws -> [JSONValue]? {
        if sessionId.hasPrefix("peer:"), let remote = try remoteService(for: sessionId) {
            return try await remote.fetchSessionConfiguration(sessionId: sessionId)
        }
        if let (remote, id, _) = try remoteAgyService(for: sessionId) {
            return await remote.capabilities(sessionId: id)?.session["configOptions"]?.arrayValue
        }
        if sessionId.hasPrefix("agy:") {
            return await agy.capabilities(sessionId: String(sessionId.dropFirst(4)))?.session["configOptions"]?.arrayValue
        }
        if let (remote, id) = try remoteDshService(for: sessionId) { return try await remote.configuration(sessionId: id) }
        if sessionId.hasPrefix("dsh:") { return try await dsh.configuration(sessionId: String(sessionId.dropFirst(4))) }
        return nil
    }
    func supportsSessionTextAttachments(sessionId: String) async -> Bool {
        if sessionId.hasPrefix("peer:"), let remote = try? remoteService(for: sessionId) {
            return await remote.supportsSessionTextAttachments(sessionId: sessionId)
        }
        if let (remote, id, _) = try? remoteAgyService(for: sessionId) { return await remote.supportsEmbeddedText(sessionId: id) }
        if sessionId.hasPrefix("agy:") { return await agy.supportsEmbeddedText(sessionId: String(sessionId.dropFirst(4))) }
        return false
    }
    func setSessionConfiguration(sessionId: String, configId: String, value: String) async throws -> [JSONValue] {
        if sessionId.hasPrefix("peer:"), let remote = try remoteService(for: sessionId) {
            return try await remote.setSessionConfiguration(sessionId: sessionId, configId: configId, value: value)
        }
        if configId == "dsh-model" || configId == "dsh-permission" {
            if let (remote, id) = try remoteDshService(for: sessionId) {
                if configId == "dsh-permission" { return try await remote.setPermissionConfiguration(sessionId: id, value: value) }
                _ = try await remote.setModelConfiguration(sessionId: id, value: value)
                return try await remote.configuration(sessionId: id) ?? []
            }
            if sessionId.hasPrefix("dsh:") {
                let id = String(sessionId.dropFirst(4))
                if configId == "dsh-permission" { return try await dsh.setPermissionConfiguration(sessionId: id, value: value) }
                _ = try await dsh.setModelConfiguration(sessionId: id, value: value)
                return try await dsh.configuration(sessionId: id) ?? []
            }
        }
        let result: AgySessionCapabilities
        if let (remote, id, _) = try remoteAgyService(for: sessionId) {
            result = try await remote.setConfiguration(sessionId: id, configId: configId, value: value)
        } else if sessionId.hasPrefix("agy:") {
            result = try await agy.setConfiguration(sessionId: String(sessionId.dropFirst(4)), configId: configId, value: value)
        } else {
            throw PharosClientError.operationFailed("Session configuration is unavailable")
        }
        guard let options = result.session["configOptions"]?.arrayValue else {
            throw PharosClientError.operationFailed("Antigravity did not return Session configuration")
        }
        return options
    }
    func fetchSessionProgress(sessionId: String) async throws -> CanonicalSessionProgress? {
        if let (remote, id, _) = try remoteAgyService(for: sessionId) { return await remote.progress(sessionId: id) }
        if let (remote, id) = try remoteDshService(for: sessionId) { return await remote.progress(sessionId: id) }
        if let remote = try remoteService(for: sessionId) { return try await remote.fetchSessionProgress(sessionId: sessionId) }
        if sessionId.hasPrefix("agy:") { return await agy.progress(sessionId: String(sessionId.dropFirst(4))) }
        if sessionId.hasPrefix("dsh:") { return await dsh.progress(sessionId: String(sessionId.dropFirst(4))) }
        return try await sessions.fetchSessionProgress(sessionId: sessionId)
    }
    func fetchSessionApproval(sessionId: String) async throws -> CanonicalApprovalRequest? {
        if let (remote, id, _) = try remoteAgyService(for: sessionId) { return await remote.pendingApproval(sessionId: id) }
        if let (remote, id) = try remoteDshService(for: sessionId) { return await remote.pendingApproval(sessionId: id) }
        if let remote = try remoteService(for: sessionId) { return try await remote.fetchSessionApproval(sessionId: sessionId) }
        if sessionId.hasPrefix("dsh:") { return await dsh.pendingApproval(sessionId: String(sessionId.dropFirst(4))) }
        if sessionId.hasPrefix("agy:") { return await agy.pendingApproval(sessionId: String(sessionId.dropFirst(4))) }
        return try await sessions.fetchSessionApproval(sessionId: sessionId)
    }
    func executeSessionCommand(sessionId: String, line: String) async throws -> SessionCommandResult? {
        if let (remote, id) = try remoteDshService(for: sessionId) {
            return try await remote.executeCommand(sessionId: id, line: line)
        }
        if sessionId.hasPrefix("dsh:") {
            return try await dsh.executeCommand(sessionId: String(sessionId.dropFirst(4)), line: line)
        }
        if sessionId.hasPrefix("agy:") || (sessionId.hasPrefix("remote:") && sessionId.contains(":agy:")) { return nil }
        if let remote = try remoteService(for: sessionId) {
            return try await remote.executeSessionCommand(sessionId: sessionId, line: line)
        }
        if !sessionId.hasPrefix("remote:") {
            return try await sessions.executeSessionCommand(sessionId: sessionId, line: line)
        }
        return nil
    }

    func sendSessionMessage(sessionId: String, text: String) async throws -> CanonicalTurn {
        if let (remote, id, _) = try remoteAgyService(for: sessionId) { return try await remote.send(sessionId: id, text: text) }
        if let (remote, id) = try remoteDshService(for: sessionId) { return try await remote.send(sessionId: id, text: text) }
        if let remote = try remoteService(for: sessionId) { return try await remote.sendSessionMessage(sessionId: sessionId, text: text) }
        if sessionId.hasPrefix("agy:") {
            return try await agy.send(sessionId: String(sessionId.dropFirst(4)), text: text)
        }
        if sessionId.hasPrefix("dsh:") {
            return try await dsh.send(sessionId: String(sessionId.dropFirst(4)), text: text)
        }
        return try await sessions.sendSessionMessage(sessionId: sessionId, text: text)
    }
    func sendSessionMessage(sessionId: String, text: String, files: [SessionFileUpload], requestId: String) async throws -> CanonicalTurn {
        if sessionId.hasPrefix("peer:"), let remote = try remoteService(for: sessionId) {
            return try await remote.sendSessionMessage(sessionId: sessionId, text: text, files: files, requestId: requestId)
        }
        if files.isEmpty {
            if let (remote, id, _) = try remoteAgyService(for: sessionId) { return try await remote.sendTextAwaitingResponse(sessionId: id, text: text, turnID: requestId) }
            if sessionId.hasPrefix("agy:") { return try await agy.sendTextAwaitingResponse(sessionId: String(sessionId.dropFirst(4)), text: text, turnID: requestId) }
            return try await sendSessionMessage(sessionId: sessionId, text: text)
        }
        if let (remote, id, _) = try remoteAgyService(for: sessionId) { return try await remote.sendEmbeddedText(sessionId: id, text: text, files: files, turnID: requestId) }
        if sessionId.hasPrefix("agy:") { return try await agy.sendEmbeddedText(sessionId: String(sessionId.dropFirst(4)), text: text, files: files, turnID: requestId) }
        let target: (DshLiveSessionService, String)
        if let remote = try remoteDshService(for: sessionId) { target = remote }
        else if sessionId.hasPrefix("dsh:") { target = (dsh, String(sessionId.dropFirst(4))) }
        else { throw PharosClientError.operationFailed("Attachments are unavailable for this agent") }
        var staged: [DshStagedFile] = []
        for file in files { staged.append(try await target.0.stageFile(sessionId: target.1, data: file.data, name: file.name)) }
        return try await target.0.send(sessionId: target.1, text: text, files: staged, requestId: requestId)
    }
    func steerSession(sessionId: String, text: String) async throws {
        if try remoteAgyService(for: sessionId) != nil { throw PharosClientError.operationFailed("Antigravity session steering is not connected") }
        if let (remote, id) = try remoteDshService(for: sessionId) { try await remote.steer(sessionId: id, text: text); return }
        if let remote = try remoteService(for: sessionId) { try await remote.steerSession(sessionId: sessionId, text: text); return }
        if sessionId.hasPrefix("dsh:") {
            try await dsh.steer(sessionId: String(sessionId.dropFirst(4)), text: text)
            return
        }
        guard !sessionId.hasPrefix("agy:") else { throw PharosClientError.operationFailed("Antigravity session steering is not connected") }
        try await sessions.steerSession(sessionId: sessionId, text: text)
    }
    func resolveSessionApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        if let (remote, id, _) = try remoteAgyService(for: sessionId) { try await remote.resolve(sessionId: id, approvalId: approvalId, decision: decision); return }
        if let (remote, id) = try remoteDshService(for: sessionId) { try await remote.resolve(sessionId: id, approvalId: approvalId, decision: decision); return }
        if let remote = try remoteService(for: sessionId) { try await remote.resolveSessionApproval(sessionId: sessionId, approvalId: approvalId, decision: decision); return }
        if sessionId.hasPrefix("agy:") {
            try await agy.resolve(sessionId: String(sessionId.dropFirst(4)), approvalId: approvalId, decision: decision)
            return
        }
        if sessionId.hasPrefix("dsh:") {
            try await dsh.resolve(sessionId: String(sessionId.dropFirst(4)), approvalId: approvalId, decision: decision)
            return
        }
        try await sessions.resolveSessionApproval(sessionId: sessionId, approvalId: approvalId, decision: decision)
    }

    func fetchProjects() async throws -> [ClientProjectSummary] {
        Self.projectSummaries(projects: store.projects, sessions: hasSessionInventory ? sessionCache : nil,
                              localHost: .fromEnvironment(), localMachine: ProcessInfo.processInfo.hostName,
                              remotePaths: remoteProjectPaths, unavailableHosts: remoteProjectPathsUnavailable)
    }

    static func projectSummaries(projects: [Project], sessions: [ClientSessionSummary]?,
                                 localHost: LightSelfHost, localMachine: String,
                                 remotePaths: [String: [UUID: String]] = [:], unavailableHosts: Set<String> = []) -> [ClientProjectSummary] {
        func normalized(_ path: String?) -> String? {
            guard let path, path.hasPrefix("/"), !path.isEmpty else { return nil }
            return (path as NSString).standardizingPath
        }
        let localRoots = projects.compactMap { project -> (UUID, String)? in
            normalized(project.localPath).map { (project.id, $0) }
        }
        let ids = Set(projects.map(\.id))
        let remoteRoots = remotePaths.mapValues { paths in
            paths.compactMap { id, path -> (UUID, String)? in
                guard ids.contains(id), let root = normalized(path) else { return nil }
                return (id, root)
            }
        }
        var grouped: [UUID: [ClientSessionSummary]] = [:]
        for session in sessions ?? [] {
            guard let path = normalized(session.workspacePath) else { continue }
            let roots = localHost.matches(session.machineId) ? localRoots : (remoteRoots[session.machineId] ?? [])
            let matches = roots.filter { _, root in path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
            guard let length = matches.map({ $0.1.count }).max() else { continue }
            let nearest = matches.filter { $0.1.count == length }
            guard nearest.count == 1 else { continue }
            grouped[nearest[0].0, default: []].append(session)
        }
        return projects.map { project in
            let related = grouped[project.id] ?? []
            var devices = remoteRoots.compactMap { host, roots in roots.contains(where: { $0.0 == project.id }) ? host : nil }
            if normalized(project.localPath) != nil { devices.append(localMachine) }
            return ClientProjectSummary(projectPath: project.localPath ?? "", name: project.name,
                trackedDevices: devices.sorted(),
                activeSessionsCount: related.filter { $0.status == .working || $0.status == .needsHuman }.count,
                projectId: project.id.uuidString, relatedSessionIds: sessions == nil ? nil : related.map(\.id),
                checkoutUnavailableHosts: unavailableHosts.isEmpty ? nil : unavailableHosts.sorted())
        }
    }

    func fetchThreads() async throws -> [ClientThreadSummary] {
        let rooms: [MeshRoomInfo]
        if mesh.isProductModeEnabled {
            rooms = try await mesh.chatRooms()
            var members: [String: MeshMemberInfo] = [:]
            for room in rooms {
                for member in try await mesh.chatMemberInfos(in: room) { members[member.id] = member }
            }
            memberCache = members
        } else {
            async let list = request(MeshRequest(cmd: "list"))
            async let roster = request(MeshRequest(cmd: "who"))
            let (roomResponse, rosterResponse) = try await (list, roster)
            rooms = roomResponse.rooms ?? []
            memberCache = Dictionary((rosterResponse.members ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        }
        roomCache = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        startExplicitLocalAgyThreadBridges()
        startExplicitLocalDshThreadBridges()
        return rooms.map { room in
            let ids = room.memberIDs.isEmpty ? room.members : room.memberIDs
            let members = ids.filter { id in
                let nick = memberCache[id]?.nick ?? id
                return nick != "human" && nick != "tester"
            }
            return ClientThreadSummary(threadId: room.id, title: room.name, memberIds: members, lastActivityAt: .distantPast)
        }
    }

    func supportsThreadSessionBinding() async -> Bool {
        if mesh.isProductModeEnabled {
            // Distributed product mode uses the Host-owned binder + room join,
            // not legacy Broker capabilities.
            return true
        }
        return (try? await request(MeshRequest(cmd: "capabilities")).capabilities?.contains("thread-session-binding-v1")) == true
    }
    func threadSessionBindingCandidates() async -> [ClientSessionSummary] {
        let local = LightSelfHost.fromEnvironment()
        if mesh.isProductModeEnabled {
            var candidates: [ClientSessionSummary] = []
            if agyAvailable {
                candidates += agySessionCache.filter {
                    $0.id.hasPrefix("agy:") && $0.agentType == "agy"
                        && !$0.workspacePath.isEmpty && $0.inventoryStale != true
                        && local.matches($0.machineId)
                }
            }
            if dshAvailable {
                candidates += dshSessionCache.filter {
                    $0.id.hasPrefix("dsh:") && $0.agentType == "dsh"
                        && $0.inventoryStale != true && local.matches($0.machineId)
                }
            }
            candidates += sessionCache.filter {
                $0.agentType == "codex" && !$0.id.hasPrefix("remote:")
                    && $0.inventoryStale != true && local.matches($0.machineId)
            }
            return candidates
        }
        var candidates = agyAvailable ? agySessionCache.filter { $0.id.hasPrefix("agy:") && $0.agentType == "agy" && !$0.workspacePath.isEmpty && $0.inventoryStale != true && local.matches($0.machineId) } : []
        guard let capabilities = try? await request(MeshRequest(cmd: "capabilities")).capabilities else { return candidates }
        let hello = try? await Self.threadBindingRuntime("runtime.hello", params: [:])
        if dshAvailable, let hello, capabilities.contains("thread-session-binding-dsh-v1"),
           (hello["capabilities"] as? [String])?.contains("delivery-inspect-v1") == true {
            let localDSH = dshSessionCache.filter { $0.id.hasPrefix("dsh:") && $0.agentType == "dsh" && $0.inventoryStale != true && local.matches($0.machineId) }
            let ids = localDSH.map { String($0.id.dropFirst(4)) }
            var available = Set<String>()
            var complete = true
            for start in stride(from: 0, to: ids.count, by: 300) {
                let batch = Array(ids[start..<min(start + 300, ids.count)])
                guard let inspected = try? await Self.threadBindingRuntime("delivery.inspect-members", params: ["memberIDs": batch]),
                      let routes = inspected["routes"] as? [[String: Any]], routes.count == batch.count else { complete = false; break }
                available.formUnion(routes.compactMap { Self.availableDshBindingID($0) })
            }
            if complete {
                candidates += localDSH.filter { available.contains(String($0.id.dropFirst(4))) }
            }
        }
        if let hello, capabilities.contains("thread-session-binding-codex-v1"),
           let status = try? await Self.threadBindingRuntime("codex.status", params: [:]),
           Self.supportsCodexThreadBinding(status: status, hello: hello) {
            candidates += sessionCache.filter { !$0.id.hasPrefix("remote:") && $0.agentType == "codex" && $0.inventoryStale != true && local.matches($0.machineId) }
        }
        if capabilities.contains("thread-session-binding-remote-dsh-v1") {
            for host in remoteDshSnapshots.keys.sorted() {
                let sessions = (remoteDshSnapshots[host] ?? []).filter {
                    $0.agentType == "dsh" && $0.inventoryStale != true && remoteDshOwners[$0.id]?.host == host
                }
                guard !sessions.isEmpty, let connection = remoteConnections[host],
                      let node = try? await remoteDshNode(host: host) else { continue }
                let ids = sessions.compactMap { remoteDshOwners[$0.id]?.rawID }
                guard ids.count == sessions.count else { continue }
                var eligible = Set<String>(), complete = true
                for start in stride(from: 0, to: ids.count, by: 300) {
                    let batch = Array(ids[start..<min(start + 300, ids.count)])
                    guard let flags = try? await inspectRemoteDsh(nodeID: node.id, sessionIDs: batch), flags.count == batch.count else {
                        complete = false; break
                    }
                    for (id, allowed) in zip(batch, flags) where allowed { eligible.insert(id) }
                }
                if complete {
                    candidates += sessions.filter { session in
                        guard let owner = remoteDshOwners[session.id], owner.host == host,
                              eligible.contains(owner.rawID), remoteConnections[host] === connection, connection.isRunning,
                              remoteDshSnapshots[host]?.contains(where: { $0.id == session.id && $0.inventoryStale != true }) == true else { return false }
                        return true
                    }
                }
            }
        }
        return candidates
    }

    static func matchedRemoteDshNode(identity: RemoteMeshIdentity.Identity, nodes: [MeshNodeInfo], now: Date = Date()) -> MeshNodeInfo? {
        let normalized: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
        let matches = nodes.filter {
            $0.id.lowercased() == identity.nodeID.lowercased() && normalized($0.host) == normalized(identity.host)
                && !normalized($0.host).isEmpty && $0.brokerLocal != true
                && (-5...70).contains(now.timeIntervalSince1970 - $0.lastSeen)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func remoteDshNode(host: String) async throws -> MeshNodeInfo {
        guard let connection = remoteConnections[host], connection.isRunning,
              remoteDshDestinations[host] == connection.destination else {
            throw PharosClientError.backendUnreachable(backend: "mesh", reason: "Remote host connection is unavailable")
        }
        let identity = try await Task.detached { try RemoteMeshIdentity.read(connection: connection) }.value
        let nodes = try await request(MeshRequest(cmd: "node-roster")).nodes ?? []
        guard remoteConnections[host] === connection, connection.isRunning,
              remoteDshDestinations[host] == connection.destination,
              let node = Self.matchedRemoteDshNode(identity: identity, nodes: nodes) else {
            throw PharosClientError.operationFailed("No unique online Mesh node matches the remote host")
        }
        return node
    }

    private struct RemoteDshInspectionReply: Decodable {
        struct Result: Decodable { let eligible: [Bool] }
        let jsonrpc: String
        let id: String
        let result: Result
    }

    static func decodeRemoteDshInspection(_ text: String, expectedID: String, count: Int) -> [Bool]? {
        guard let data = text.data(using: .utf8),
              let reply = try? JSONDecoder().decode(RemoteDshInspectionReply.self, from: data),
              reply.jsonrpc == "2.0", reply.id == expectedID,
              reply.result.eligible.count == count else { return nil }
        return reply.result.eligible
    }

    private func inspectRemoteDsh(nodeID: String, sessionIDs: [String]) async throws -> [Bool] {
        guard !sessionIDs.isEmpty, sessionIDs.count <= 300 else { throw PharosClientError.operationFailed("Invalid DSH inspection batch") }
        let rpcID = UUID().uuidString
        let rpc: [String: Any] = ["jsonrpc": "2.0", "id": rpcID, "method": "delivery.inspect-dsh-bindings", "params": ["sessionIDs": sessionIDs]]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: rpc), as: UTF8.self)
        let deadline = Date().addingTimeInterval(15)
        let response = try await request(MeshRequest(cmd: "node-command-enqueue", payload: payload, nodeID: nodeID,
            action: MeshNodeCommandAction.agentRPC.rawValue, idempotencyKey: "dsh-binding-inspect:" + UUID().uuidString,
            deadline: deadline.timeIntervalSince1970, maxAttempts: 1))
        guard let command = response.command, command.nodeID == nodeID, command.action == .agentRPC else {
            throw PharosClientError.operationFailed("Remote DSH inspection was not queued")
        }
        while Date() < deadline && !Task.isCancelled {
            let current = try await request(MeshRequest(cmd: "node-command-get", nodeID: nodeID, commandID: command.id)).command
            guard let current, current.nodeID == nodeID, current.id == command.id else { throw PharosClientError.operationFailed("Remote inspection command disappeared") }
            if current.state.isTerminal {
                guard current.state == .succeeded, let text = current.result,
                      let flags = Self.decodeRemoteDshInspection(text, expectedID: rpcID, count: sessionIDs.count) else {
                    throw PharosClientError.operationFailed("Remote DSH inspection failed")
                }
                return flags
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PharosClientError.operationFailed("Remote DSH inspection timed out")
    }

    static func availableDshBindingID(_ route: [String: Any]) -> String? {
        guard route["eligible"] as? Bool == true, route["replyCapable"] as? Bool == true, route["kind"] as? String == "dsh",
              let member = route["memberID"] as? String, !member.isEmpty, route["vendorSessionID"] as? String == member else { return nil }
        return member
    }

    static func supportsCodexThreadBinding(status: [String: Any], hello: [String: Any]) -> Bool {
        status["transport"] as? String == "rust-runtime" && (hello["capabilities"] as? [String])?.contains("codex-thread-id-v1") == true
    }

    private nonisolated static func threadBindingRuntime(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let raw = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params])
        let response = try await Task.detached {
            let request = String(decoding: raw, as: UTF8.self)
            return try method == "delivery.inspect-members" ? AgentRuntimeClient.sendLocalDriverRequest(request) : AgentRuntimeClient.send(request)
        }.value
        guard let data = response.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else { throw PharosClientError.operationFailed("Invalid Agent Runtime response") }
        return result
    }

    static func validateCodexRuntimeBeforeBinding(_ conversations: [[String: Any]], providerID: String) throws {
        let known = conversations.filter { $0["vendorSessionID"] as? String == providerID && $0["kind"] as? String == "codex" }
        guard known.count <= 1, known.allSatisfy({ $0["driverID"] as? String == "codex:app-server" && $0["ownership"] as? String == "managed" }) else {
            throw PharosClientError.operationFailed("Codex Session ownership is ambiguous in Agent Runtime")
        }
    }

    static func verifiedCodexRuntimeMember(_ conversations: [[String: Any]], providerID: String) throws -> String {
        try validateCodexRuntimeBeforeBinding(conversations, providerID: providerID)
        let matches = conversations.filter { $0["vendorSessionID"] as? String == providerID && $0["kind"] as? String == "codex" && $0["driverID"] as? String == "codex:app-server" && $0["ownership"] as? String == "managed" }
        guard matches.count == 1, let conversationID = matches[0]["id"] as? String, !conversationID.isEmpty else {
            throw PharosClientError.operationFailed("Codex Session was not uniquely registered")
        }
        let candidate = (matches[0]["memberID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? providerID
        guard !conversations.contains(where: { ($0["memberID"] as? String == candidate || (($0["memberID"] as? String)?.isEmpty != false && $0["vendorSessionID"] as? String == candidate)) && $0["id"] as? String != conversationID }) else {
            throw PharosClientError.operationFailed("Another Runtime conversation already claims this member")
        }
        return candidate
    }

    /// Host-owned product-mode bind: verify local inventory + Runtime uniqueness,
    /// then join the durable distributed room membership. Does not start legacy
    /// Broker wakeup or claim Agent consumption.
    private func bindDistributedThreadSession(
        session: ClientSessionSummary, room: MeshRoomInfo, nickname: String
    ) async throws {
        let inventory = sessionCache + dshSessionCache + agySessionCache
        let binder = MeshHostThreadBinder(
            inventory: { inventory },
            runtime: { method, params in
                try AgyThreadRuntimeBridge.localRuntime(method, params)
            }
        )
        let existing = (try? await mesh.chatMembers(in: room)) ?? []
        let sameSession = existing.filter { member in
            member.id == session.id
                || member.id == String(session.id.dropFirst(4))
                || (session.agentType == "codex" && member.id == session.id)
        }
        guard sameSession.count <= 1 else {
            throw PharosClientError.operationFailed("Multiple members already claim this Session")
        }
        let requestedMemberID = sameSession.first?.id
        let bound = try await binder.bind(
            hostSessionID: session.id, agentKind: session.agentType,
            memberID: requestedMemberID
        )
        if let already = sameSession.first, already.id != bound.memberID {
            throw PharosClientError.operationFailed("The room member does not match the Host Thread binding")
        }
        try await mesh.joinChatMember(bound.memberID, nick: nickname, in: room)
    }

    func bindThreadSession(threadId: String, sessionId: String, nickname: String) async throws {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 40,
              name.unicodeScalars.allSatisfy({ ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" as String).unicodeScalars.contains($0) }),
              name != "human", name != "tester" else {
            throw PharosClientError.operationFailed("Use 1–40 letters, numbers, underscores or hyphens for the member name")
        }
        let candidates = await threadSessionBindingCandidates()
        guard let session = candidates.first(where: { $0.id == sessionId }) else {
            throw PharosClientError.operationFailed("The selected Session is unavailable for Thread binding")
        }
        let room = try await lookupRoom(threadId)
        if mesh.isProductModeEnabled {
            try await bindDistributedThreadSession(session: session, room: room, nickname: name)
            _ = try await fetchThreads()
            return
        }
        if session.agentType == "dsh", session.id.hasPrefix("remote:") {
            guard let owner = remoteDshOwners[sessionId], !owner.rawID.isEmpty,
                  session.inventoryStale != true, session.machineId == owner.host,
                  let connection = remoteConnections[owner.host], connection.isRunning else {
                throw PharosClientError.operationFailed("The remote DSH Session is no longer available")
            }
            let node = try await remoteDshNode(host: owner.host)
            guard try await inspectRemoteDsh(nodeID: node.id, sessionIDs: [owner.rawID]) == [true],
                  remoteConnections[owner.host] === connection, connection.isRunning,
                  remoteDshOwners[sessionId]?.host == owner.host, remoteDshOwners[sessionId]?.rawID == owner.rawID,
                  remoteDshSnapshots[owner.host]?.contains(where: { $0.id == sessionId && $0.inventoryStale != true }) == true else {
                throw PharosClientError.operationFailed("The remote DSH Session is no longer available for Thread delivery")
            }
            // The Broker checks the node, host, member and nickname again
            // while holding its membership lock.
            _ = try await request(MeshRequest(cmd: "join-session", room: room.name, nick: name, memberID: owner.rawID,
                session: owner.rawID, host: node.host, kind: "dsh", nodeID: node.id))
            _ = try await fetchThreads()
            return
        }
        let isAgy = session.agentType == "agy"
        let isDsh = session.agentType == "dsh"
        let providerID = (isAgy || isDsh) ? String(session.id.dropFirst(4)) : session.id
        guard !providerID.isEmpty else { throw PharosClientError.operationFailed("Session ID is empty") }
        var runtimeMemberID: String?
        if isDsh {
            let result = try await Self.threadBindingRuntime("delivery.inspect-members", params: ["memberIDs": [providerID]])
            guard let route = (result["routes"] as? [[String: Any]])?.first, Self.availableDshBindingID(route) == providerID else {
                throw PharosClientError.operationFailed("This DSH Session is no longer available for Thread delivery")
            }
            runtimeMemberID = providerID
        } else if !isAgy {
            let before = try await Self.threadBindingRuntime("runtime.snapshot", params: [:])
            let beforeConversations = before["conversations"] as? [[String: Any]] ?? []
            try Self.validateCodexRuntimeBeforeBinding(beforeConversations, providerID: providerID)
            let read = try await Self.threadBindingRuntime("codex.thread.read", params: ["threadId": providerID])
            guard (read["thread"] as? [String: Any])?["id"] as? String == providerID else {
                throw PharosClientError.operationFailed("Codex Runtime returned a different Session")
            }
            let snapshot = try await Self.threadBindingRuntime("runtime.snapshot", params: [:])
            let conversations = snapshot["conversations"] as? [[String: Any]] ?? []
            runtimeMemberID = try Self.verifiedCodexRuntimeMember(conversations, providerID: providerID)
        }
        let roster = try await request(MeshRequest(cmd: "who"))
        let local = LightSelfHost.fromEnvironment()
        let existing = Set((roster.members ?? []).compactMap { member -> String? in
            guard member.session == providerID, let host = member.host, local.matches(host),
                  (isAgy ? ["agy", "ag", "antigravity"].contains(member.kind?.lowercased() ?? "") : member.kind?.lowercased() == (isDsh ? "dsh" : "codex")), !member.rooms.isEmpty else { return nil }
            return member.id
        })
        guard existing.count <= 1 else { throw PharosClientError.operationFailed("Multiple members already claim this Session") }
        if let runtimeMemberID, let already = existing.first, runtimeMemberID != already {
            throw PharosClientError.operationFailed("The room member does not match the Agent Runtime binding")
        }
        let memberID = existing.first ?? runtimeMemberID ?? UUID().uuidString.lowercased()
        _ = try await request(MeshRequest(cmd: "join-session", room: room.name, nick: name, memberID: memberID,
                                          session: providerID, host: ProcessInfo.processInfo.hostName, kind: isAgy ? "agy" : (isDsh ? "dsh" : "codex")))
        _ = try await fetchThreads()
    }

    func fetchMemberDetail(name: String) async throws -> ClientMemberDetail {
        let matches = memberCache[name].map { [$0] } ?? memberCache.values.filter { $0.nick == name }
        guard let member = matches.first, matches.count == 1 else {
            throw PharosClientError.operationFailed("Member is unavailable or ambiguous")
        }
        return ClientMemberDetail(name: member.nick, agent: member.kind ?? "agent",
            machine: member.host ?? "unknown", model: "", mode: "",
            status: member.state ?? "unknown", tmuxSession: member.session, avatarSeed: member.id)
    }

    func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage] {
        let room = try await lookupRoom(threadId)
        let messages: [MeshMsg]
        if mesh.isProductModeEnabled {
            messages = try await mesh.chatMessages(in: room, limit: 200)
        } else {
            messages = try await request(MeshRequest(cmd: "history", room: room.name, limit: 200)).messages ?? []
        }
        return messages.map { convert($0, threadId: threadId) }
    }

    func sendThreadMessage(threadId: String, text: String) async throws -> ClientThreadMessage {
        let room = try await lookupRoom(threadId)
        let targets = Self.mentions(in: text)
        if mesh.isProductModeEnabled {
            let message = try await mesh.sendChatMessage(text, in: room, to: targets)
            return convert(message, threadId: threadId)
        }
        let submitted = Date()
        let response = try await request(MeshRequest(cmd: "say", room: room.name, nick: "human", text: text,
                                                    to: targets.isEmpty ? nil : targets))
        if let message = response.messages?.first { return convert(message, threadId: threadId) }
        // Older Brokers acknowledge without returning the committed message ID.
        // Match only a unique recent entry; never retry a potentially committed send.
        let history = try? await fetchThreadMessages(threadId: threadId)
        let matches = history?.filter { $0.senderName == "human" && $0.text == text && $0.timestamp >= submitted.addingTimeInterval(-2) } ?? []
        if matches.count == 1 { return matches[0] }
        return ClientThreadMessage(id: UUID().uuidString, threadId: threadId, senderId: "human",
                                   senderName: "human", text: text, timestamp: submitted, receipt: .unverifiedFallback)
    }

    private func lookupRoom(_ id: String) async throws -> MeshRoomInfo {
        if let room = roomCache[id] { return room }
        _ = try await fetchThreads()
        guard let room = roomCache[id] else { throw PharosClientError.threadNotFound(id) }
        return room
    }

    private func request(_ request: MeshRequest) async throws -> MeshResponse {
        let send = brokerRequest
        let response = await Task.detached { send(request) }.value
        guard let response else { throw PharosClientError.connectionFailed("Mesh broker is unavailable") }
        guard response.ok else { throw PharosClientError.operationFailed(response.error ?? "Mesh request failed") }
        return response
    }

    private func convert(_ message: MeshMsg, threadId: String) -> ClientThreadMessage {
        let senderID = message.from == "human" ? "human" : (message.authorMemberID ?? message.from)
        let attachments = (message.attachments ?? []).map {
            CanonicalAttachment(id: $0.id, filename: $0.name, mimeType: $0.mimeType,
                                sizeBytes: Int64($0.byteSize), uri: $0.id)
        }
        let reply = message.replyTo.map { ClientThreadReply(messageId: $0.messageID, senderName: $0.from, preview: $0.preview) }
        return ClientThreadMessage(id: message.stableID, threadId: threadId, senderId: senderID,
            senderName: message.from, senderAvatarSeed: message.authorMemberID, text: message.text,
            // Room history confirms persistence, not delivery to any recipient.
            timestamp: message.date, receipt: !message.uncertainTargetMemberIDs.isEmpty && !message.rejectedTargetMemberIDs.isEmpty ? .deliveryMixed
                : !message.uncertainTargetMemberIDs.isEmpty ? .deliveryUncertain
                : (!message.rejectedTargetMemberIDs.isEmpty ? .deliveryRejected : .unverifiedFallback),
            attachments: attachments, replyTo: reply)
    }

    private static func mentions(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?:^|\s)@([a-zA-Z0-9_\-]+)"#)
        let value = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: value.length)).compactMap {
            let name = value.substring(with: $0.range(at: 1))
            return seen.insert(name).inserted ? name : nil
        }
    }

    func setMemberMode(name: String, mode: String) async throws { try await sessions.setMemberMode(name: name, mode: mode) }
    func setMemberModel(name: String, model: String) async throws { try await sessions.setMemberModel(name: name, model: model) }
    func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws { try await sessions.setMemberAvatar(name: name, avatar: avatar) }
    func stopMember(name: String) async throws { try await sessions.stopMember(name: name) }
    func reviveMember(name: String) async throws { try await sessions.reviveMember(name: name) }
}
