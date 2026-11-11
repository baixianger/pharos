# Handoff — Phase E (delete Swift backend modules)

## What was removed

| Area | Paths |
|---|---|
| Mesh stack | `Sources/PharosMeshProtocol`, `PharosMeshIdentity`, `PharosMeshIroh`, `PharosMeshReplica`, `PharosMeshControl`, `PharosMeshLifecycle`, `PharosMeshCore`, `Sources/PharosMesh` (exe `pharos-mesh`) |
| Runtime / adapters | `Sources/PharosRuntime`, `Sources/PharosCodexAdapter` |
| Agent contracts (Swift) | `Sources/PharosAgentCore` |
| SQLite shim | `Sources/CSQLite` |
| Backend tests | `Tests/PharosMesh*`, `Tests/PharosLightTests`, Mesh/Runtime-heavy `Tests/PharosTests/*` |
| App mesh / desktop-mesh | `DesktopPharosClientService`, `DistributedMeshSupport`, `DistributedProjectIssueProjection`, `DistributedRegistryCLI`, `MeshHooks`, `MeshSpawn`, `MeshNodeControl`, `MeshRemote`, `MeshSetupView`, `MacMeshRuntimeCoordinator`, `PairDeviceSheet`, `BrokerRegistrySync`, `BrokerSetupOnboardingView`, Swift `CLI.swift` / `LightCLI.swift` |
| Feature flag | `PHAROS_CLIENT_BACKEND=desktop-mesh` path removed; ClientKit always resolves `rust-api` |
| Packaging | No Swift `pharos-mesh` product; app Helpers + Linux image/deb install Rust `pharos` / `pharos-meshd` / `pharos-web` |

## What was kept and why

| Kept | Why |
|---|---|
| `Sources/PharosClientKit` | Canonical HTTP/WS client SDK for the Rust API |
| `Sources/Pharos` (SwiftUI + WebKit shell) | Apple client chrome; loads daemon-served Web UI |
| Sparkle | App updater |
| `Tests/PharosClientKitTests` + slim `Tests/PharosTests` | ArchitectureBoundary + ClientKit / UI unit gates |
| `RemoteLaunch.swift` (stub) | Call sites in `PharosCore` / `ProjectStore` still compile; runtime errors say launch moved to Rust |
| Local `projects.json` registry via `ProjectStore` / `PharosCore` | Device-local project list for the shell; no Mesh/Broker sync |
| Rust tree (`rust/`) | Untouched except packaging path consumers; backend is already Batches 0–3 |

**PharosAgentCore removed:** the client path only needs `PharosClientKit` DTOs. Agent delivery/session enums already live in `rust/crates/agent-core` (+ protocol crates). No remaining Swift client import required AgentCore after Runtime/CodexAdapter deletion.

## Gate commands

```sh
cd ~/personal/pharos-wt/_phase-e
swift build
swift test --filter ArchitectureBoundary
swift test --filter PharosClientKitTests

source "$HOME/.cargo/env"
cd rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Live smoke (isolated msg-test dir + headless WebKit probe): see evidence.

## PASS / PARTIAL / NOT-TESTED

| Gate | Mark |
|---|---|
| `swift build` client-only (Pharos included) | **PASS** |
| ArchitectureBoundary* (modules absent / unlinked) | **PASS** |
| ClientKit tests | **PASS** |
| `cargo fmt` / `clippy -D warnings` / `test --workspace` (88/0) | **PASS** |
| pharos-web + HTTP Thread/Session open/read | **PASS** (S4 fakes) |
| HttpPharosClientLiveSmokeTests | **PASS** |
| WebKit headless probe loads daemon UI | **PASS** |
| Rust CLI `thread read` vs HTTP fakes / empty data-dir | **PARTIAL** |
| GUI Pharos.app click smoke | **NOT-TESTED** (no DISPLAY) |
| Linux Docker artifact rebuild | **NOT-TESTED** (scripts updated) |

## Evidence

- `internal/evidence/2026-11-11-rust-phase-e-acceptance.md`
- `internal/evidence/2026-11-11-rust-phase-e-cargo.log`
- msg-test: `~/personal/pharos-msg-test/peer-phase-a/rust-phase-e-1794365267/evidence/`

## Diff scope check

`git diff --stat 379febb..HEAD` should show deletions/redirects in Swift backend areas, `Package.swift`, app callers, packaging/CI, docs, evidence — not Rust crate logic.

## Notes for merge captain / next

- Base remains `rust/integrate-b3` @ `379febb`; no FF into `integrate/mesh2-into-main`, no push.
- iOS tree still references Mesh TCP client code; out of Phase E macOS cutover scope (not in Package.swift products).
- `Scripts/test_migration_release_cycle.sh` is an intentional no-op (Swift Mesh drill retired).

STATUS: PHASE-E-DONE
