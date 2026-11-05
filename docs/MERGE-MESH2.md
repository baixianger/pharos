---
summary: Architecture decisions, conflict resolutions, and layering for merging PR #2 (Mesh 2.0 / feat/distributed-iroh) into main.
---

# Mesh 2.0 Integration & Architectural Layering (PR #2)

This document records the architectural reconciliation between Pharos Milestone 2 (`main`, commit `baf17dc`) and Mesh 2.0 (`origin/feat/distributed-iroh`, 113 commits of P2P Iroh, MeshKit, stable identity, and iOS replica sync), successfully concluded in merge commit `28ba87a`.

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
4. **Old UI Deprecation & Transition (PM Decision 2026-11-05)**:
   - The user decided to abandon the legacy macOS UI (Dashboard/ProjectDetail/MeshRoom/AgentSidebar/AgentWorkspaceShell) in favor of a new client modelled on the Grok Bot desktop app.
   - Old SwiftUI views were kept building cleanly for Phase 0 release packaging, but no extra effort was spent reconciling legacy view behaviors. They will be superseded in M3 by a new isolated client target.

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
  - Added cargo / local homebrew path resolution.
  - Multi-path product resolver `build_product_path` supporting both modern Xcode SPM `.build/out/Products/Release` and classical `.build/${arch}-apple-macosx/$CONF`.
  - Retained `cargo build` for `rust/Cargo.toml` across architectures (`arm64`, `x86_64`) to build bundled native helpers (`pharos-codex-adapter`, `pharos-meshd`).
- **`Packaging/debian/pharos-mesh.service`**:
  - Maintained `EnvironmentFile` and `Environment=LD_LIBRARY_PATH=/opt/pharos-swift` for runtime compatibility while supporting distributed sync-serve.

### Core Mesh & Daemon
- **`Sources/PharosMeshCore/MeshBroker.swift` & `LegacyMeshWire.swift`**:
  - Deduplicated wire structs (`MeshRequest`, `MeshEvent`, `MeshMsg`, `MeshMemberInfo`, `MeshResponse`, `MeshNodeCommand`, etc.): canonical definition in `PharosMeshProtocol/LegacyMeshWire.swift` and imported via `import PharosMeshProtocol`.
  - Augmented `LegacyMeshWire.swift` with M2 fields (`brokerLocal`, `agentRPC`, `light`, `MeshLightCommandPayload`, `MeshLightCommandResult`, and `memberID` on `MeshNodeSpawnPayload`).
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
  - Retained `validatedSSHAgentExport` to ensure valid SSH agent sockets (fixed raw string delimiter).
  - Updated `MeshSpawn.joinBrief` to accept session identity and claim flags.
- **`Sources/Pharos/MeshSpawn.swift`**:
  - Layered `MeshSpawn.spawn`: checks node-based spawn first, then distributed mesh, then informs the user if neither is available.
  - Retained interstitial classification (`bootScreenState`) recognizing YOLO mode, shortcuts, and skips update prompts.
  - Added localized `MeshSpawnControlError`.
- **`Sources/Pharos/MeshHooks.swift`**:
  - Retained local runtime state serialization (`persistRuntimeState`) for fail-open tracking.
  - Maintained `hookCommand` supporting both installed application CLI and standalone helper.

### macOS App & iOS Mobile
- **`Sources/Pharos/PharosApp.swift` & `ProjectStore.swift`**:
  - Integrated `DistributedMeshSupport` environment object alongside `ProjectStore`.
  - Cleaned up obsolete pre-M2 `legacyBrokerSection` and `meshHubHostID` assignments.
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
  - `PharosTests`: 255 tests passed (across 50 test suites), 1 skipped (`PHAROS_CODEX_INTEGRATION_TEST=1`), 0 failures. Restored `testRemotePathPrefersManagedInstallsOverUserLocalSymlinks` from `baf17dc` and `testToDiscriminatesDirectedFromBroadcast` from `344be8c`.
  - `PharosLightTests`: 254 tests passed (across 15 test suites), 0 failures.
  - `PharosMeshCoreTests`: 126 tests passed (across 11 test suites), 0 failures.
  - `PharosMeshProtocolTests`: 26 tests passed, 0 failures.
  - `PharosMeshIrohTests`: 13 tests passed, 0 failures.
  - `PharosMeshIdentityTests`: 17 tests passed, 0 failures.
  - **Total**: 691 passed, 1 skipped, 0 failures across all 6 test targets (100% green).
- **Dual-Parent Parity Verification**: Complete AST / symbol comparison of every `func test*` across `Tests/` and `ios/`:
  - Compared against `baf17dc` (main, 486 tests): **0 missing** (100% preserved).
  - Compared against `344be8c` (origin/feat/distributed-iroh, 402 tests): **0 missing** (100% preserved).
  - Current codebase test count: **695 total test functions** (exact superset of both parents). Zero tests deleted or disabled.

---

## 4. Open Items & Follow-ups (for M3)

1. **New Grok Bot-Modelled Native Client**:
   - Build a clean SwiftUI presentation layer with 3-pane layout (left: Sessions / Threads / Projects tabs; middle: unified chat; right: details pane with member info, MODEL/MODE, Library, and Computer live tmux view).
2. **Strict UI / Backend Isolation**:
   - Establish `PharosClientKit` or local daemon API with Codable DTOs so the client contains zero CLI, tmux, or persistence code.
3. **Deterministic Random Avatars**:
   - Deterministic avatar generation per session/member, with user customizability in the details pane and cross-machine mesh sync.
4. **Transport Unification**:
   - Unify LightBroker and Iroh P2P transport underneath the client API.
3. **Receipts for Remote TUI Fallback**:
   - In cross-host setups where an agent is in standalone TUI mode without daemon attachments, delivery confirmation relies on tmux capture inspection ("unverified fallback"). Adding guaranteed end-to-end receipts is Candidate #2 for M3.
