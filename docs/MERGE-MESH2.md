---
summary: Architecture decisions, conflict resolutions, and layering for merging PR #2 (Mesh 2.0 / feat/distributed-iroh) into main.
---

# Mesh 2.0 Integration & Architectural Layering (PR #2)

This document records the architectural reconciliation between Pharos Milestone 2 (`main`, commit `baf17dc`) and Mesh 2.0 (`origin/feat/distributed-iroh`, 113 commits of P2P Iroh, MeshKit, stable identity, and iOS replica sync).

## 1. Architectural Strategy: Two-Tier Mesh Coexistence

### Principles
1. **Preserve All M1 & M2 Features**:
   - Explicit thread rosters (DM vs Group), address adoption via `pharos ls`, `--thread` delivery fanout.
   - Persistent `CodexDaemonWatcher` WebSocket thread loop (`0600` watch file) & deduplicated `attention list`.
   - Manual model switch (`pharos member model <name> [<model>]`), graceful local restart fallback, remote node-agent forwarding, and `MODEL` table column.
   - Default YOLO permission mode with per-member `--safe` opt-out (`pharos member mode <name> safe|yolo`) and `MODE` table column.
   - Host node remote launch/revive/stop/model/mode RPC execution over UDS and mesh broker.
2. **Incorporate Mesh 2.0 Innovations**:
   - P2P transport backed by Iroh (`MeshKit`, `PharosMeshIroh`).
   - SQLite-backed local-first replica (`PharosMeshReplica`, `CSQLite`).
   - Cryptographically verifiable device identities & trust group pairing (`PharosMeshIdentity`, `PharosMeshLifecycle`).
   - P2P replicated entity sync across macOS and iOS (`DistributedMeshSupport`, `DistributedChatRegistry`).
3. **Runtime Routing & Gating**:
   - Headless broker and CLI runtime defaults to the robust, low-latency LightBroker / HostNode architecture (`legacyBrokerEnabled`).
   - Distributed Mesh mode is activated via `PHAROS_DISTRIBUTED_MESH=1` or `PHAROS_DISTRIBUTED=1` (or via GUI distributed mesh preference), routing commands (`pair`, `distributed`, `unread`, etc.) through `DistributedMeshSupport`, `DistributedPairCLI`, and `MacMeshRuntimeCoordinator`.
   - Neither stack suppresses or breaks the other.

---

## 2. File-by-File Conflict Resolutions

### Build & Packaging
- **`Package.swift`**:
  - Unified all targets:
    - Added `CSQLite`, `PharosMeshProtocol`, `PharosMeshIroh`, `PharosMeshIdentity`, `PharosMeshReplica`, `PharosMeshControl`, and `PharosMeshLifecycle`.
    - Retained `PharosMeshCore`, `PharosAgentCore`, `PharosRuntime`, `PharosCodexAdapter`, `PharosMesh`, and `Pharos` app.
    - Added test targets: `PharosLightTests`, `PharosTests`, `PharosMeshProtocolTests`, `PharosMeshIrohTests`, `PharosMeshIdentityTests`, `PharosMeshCoreTests`.
    - Added external dependencies: `swift-crypto`, `MeshKit` (0.2.1), and `Sparkle`.
- **`Scripts/package_app.sh`**:
  - Retained `cargo build` for `rust/Cargo.toml` across architectures (`arm64`, `x86_64`) to build bundled native helpers.
- **`Packaging/debian/pharos-mesh.service`**:
  - Maintained `EnvironmentFile` and `Environment=LD_LIBRARY_PATH=/opt/pharos-swift` for runtime compatibility while supporting distributed sync-serve.

### Core Mesh & Daemon
- **`Sources/PharosMeshCore/MeshBroker.swift`**:
  - Deduplicated wire structs (`MeshRequest`, `MeshEvent`, `MeshMsg`, `MeshMemberInfo`, `MeshResponse`, etc.): extracted into `PharosMeshProtocol/LegacyMeshWire.swift` and imported via `import PharosMeshProtocol`.
  - Retained `targetNodeID` helper for authoritative node binding.
  - Retained `delivery.fallbackTargets` to poke unverified deliveries.
- **`Sources/PharosMesh/MeshNode.swift`**:
  - Preserved authoritative `nodeID` from `MeshNodeIdentity.current` and ownership verification.
- **`Sources/PharosMesh/main.swift`**:
  - Supported top-level async entry point.
  - Gated distributed commands behind `PHAROS_DISTRIBUTED_MESH` while preserving all `pharos-mesh` legacy commands (`serve`, `node`, `send`, `recv`, etc.).

### CLI & Agent Runtime
- **`Sources/Pharos/CLI.swift`**:
  - Retained `PharosRuntimeCoordinator().activateSavedRoute()` while enabling `DistributedRegistryCLI` when distributed mode is active.
  - Unified `pharos mesh` routing: legacy subcommands route to `LightCommands` / `MeshClient`, while distributed subcommands route to `DistributedAgentCLI` / `DistributedPairCLI`.
  - Retained full M2 help text and commands (`thread`, `member model`, `member mode`, `attention`).
- **`Sources/Pharos/RemoteLaunch.swift`**:
  - Retained `validatedSSHAgentExport` to ensure valid SSH agent sockets.
  - Updated `MeshSpawn.joinBrief` to accept session identity and claim flags.
- **`Sources/Pharos/MeshSpawn.swift`**:
  - Layered `MeshSpawn.spawn`: checks node-based spawn first, then distributed mesh, then informs the user if neither is available.
  - Retained interstitial classification (`bootScreenState`) recognizing YOLO mode, shortcuts, and skips update prompts.
- **`Sources/Pharos/MeshHooks.swift`**:
  - Retained local runtime state serialization (`persistRuntimeState`) for fail-open tracking.
  - Maintained `hookCommand` supporting both installed application CLI and standalone helper.

### macOS App & iOS Mobile
- **`Sources/Pharos/PharosApp.swift` & `ProjectStore.swift`**:
  - Integrated `DistributedMeshSupport` environment object alongside `ProjectStore`.
  - In `init`, preserved runtime role configuration while initializing distributed state.
- **`Sources/Pharos/DashboardView.swift` & `SettingsView.swift`**:
  - Integrated distributed agent removal and pairing UI with node-based stopping and broker testing.
- **`ios/` (PharosMobile)**:
  - `MeshWire.swift`: Replaced duplicate wire structs with typealiases to `PharosMeshProtocol`.
  - `AppSettings.swift`: Supported both `nodeID` and `meshDeviceID` matching.
  - `MeshTCPClient.swift`: Kept `agentRuntimeRPC` alongside transport preference options.
  - `RoomStore.swift`: Indexed members by ID while maintaining node listings and unread counts.
  - `project.pbxproj`: Regenerated via `xcodegen` from merged `project.yml`.

---

## 3. Test Coverage & Verification

- **Preserved Test Suites**:
  - `PharosTests`: All M1/M2 tests retained; additional tests from PR #2 added.
  - `PharosLightTests`: All 254 unit tests for M2 retained.
  - `PharosMeshProtocolTests`, `PharosMeshIrohTests`, `PharosMeshIdentityTests`, `PharosMeshCoreTests`: Added to SPM test suite.
- **Deleted / Disabled Tests**: None. Zero tests deleted or disabled.

---

## 4. Open Items & Follow-ups (for M3)

1. **Stack Unification**:
   - Currently, LightBroker (TCP/UDS socket broker + host node) and Mesh 2.0 (Iroh P2P + SQLite replica) coexist side-by-side. Unifying them into a single transport abstraction is Candidate #1 for M3.
2. **iOS Distributed Replica UI**:
   - Mobile app can now connect to both TCP broker and P2P replica; full UI binding for thread rosters and member modes on iOS is Candidate #3 for M3.
3. **Receipts for Remote TUI Fallback**:
   - In cross-host setups where an agent is in standalone TUI mode without daemon attachments, delivery confirmation relies on tmux capture inspection ("unverified fallback"). Adding guaranteed end-to-end receipts is Candidate #2 for M3.
