# Evidence: RFC-007 Phase E — delete Swift backend modules

**STREAM:** PHASE-E  
**Branch:** `rust/phase-e`  
**Base tip:** `379febb` (rust/integrate-b3)  
**Contracts:** CONTRACTS_VERSION=0.1.0  
**Date:** 2026-11-11  
**Host:** Mac mini (SSH; `DISPLAY` empty)

## What was removed

Swift backend modules (via `git rm`):

- `Sources/PharosMesh*` (Protocol, Identity, Iroh, Replica, Control, Lifecycle, Core, exe `PharosMesh`)
- `Sources/PharosRuntime`
- `Sources/PharosCodexAdapter`
- `Sources/PharosAgentCore` (see handoff — client does not need it)
- `Sources/CSQLite`
- Matching Mesh/Light test targets

App-side mesh / legacy desktop-mesh:

- `DesktopPharosClientService`, `DistributedMeshSupport`, MeshHooks/Spawn/Node/Remote/Setup, Broker* mesh UI, Swift `CLI.swift` / `LightCLI.swift`, etc.

Packaging redirect: Linux/macOS helpers now install Rust `pharos` / `pharos-meshd` / `pharos-web` (no Swift `pharos-mesh` product).

## Gate commands (exact) and results

### 1) Swift client-only package

```sh
cd ~/personal/pharos-wt/_phase-e
swift build
# Build complete! PASS (Pharos app target included)

swift test --filter ArchitectureBoundary
# PharosTests ArchitectureBoundaryTests 4/4 PASS
# PharosClientKitTests ArchitectureBoundaryClientKitTests 4/4 PASS

swift test --filter PharosClientKitTests
# PharosTests PharosClientKitTests 8/8 PASS
# PharosClientKitTests suite PASS (live smoke skipped without env)
```

Boundary asserts: removed backend dirs absent; `Package.swift` has no Mesh/Runtime targets; sources do not `import` removed modules; only `rust-api` backend remains.

### 2) Rust workspace (Linux CI surface)

```sh
source "$HOME/.cargo/env"
cd rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Log: `internal/evidence/2026-11-11-rust-phase-e-cargo.log`  
Unit tests: **88 passed / 0 failed** (matches prior integrate tip). fmt + clippy `-D warnings` green.

### 3) A–D regression smoke (msg-test isolated)

State dir:

`~/personal/pharos-msg-test/peer-phase-a/rust-phase-e-1794365267/`

```sh
./rust/target/debug/pharos-web --addr 127.0.0.1:18788 \
  --webui-dir "$PWD/Sources/Pharos/Resources/WebCanvas"
```

- `GET /health` → ok / 0.1.0 / pharos-meshd  
- Thread `fake-thread-1` open + messages read (S4 fakes)  
- Session `fake-session-1` open  
- `HttpPharosClientLiveSmokeTests` with `PHAROS_SMOKE_BASE_URL=http://127.0.0.1:18788` → PASS  
- Headless WebKit probe (`internal/evidence/s6-webkit-probe.swift`) → `webkit_probe ok=true detail=Pharos Session Stream|object`  
- Rust CLI `pharos thread read --thread fake-thread-1 --data-dir <isolated>` → **thread not found** (CLI reads local replica store, not HTTP fakes) → PARTIAL  
- GUI Pharos.app click-drive → **NOT-TESTED** (`DISPLAY` empty; binary built at `.build/out/Products/Debug/Pharos`)

Excerpts:  
`$STATE/evidence/smoke-excerpt.txt`, `webkit-probe.txt`, `pharos-web.log`

## PASS / PARTIAL / NOT-TESTED

| Gate | Mark |
|---|---|
| `swift build` (Pharos + ClientKit) | **PASS** |
| ArchitectureBoundary* | **PASS** |
| ClientKit unit tests | **PASS** |
| `cargo fmt/clippy/test` (88/0) | **PASS** |
| pharos-web UI + HTTP Thread/Session | **PASS** (S4 fakes; honest) |
| HttpPharosClientLiveSmokeTests | **PASS** |
| WebKit headless probe | **PASS** |
| Rust CLI thread read vs HTTP fakes | **PARTIAL** |
| Full GUI app window smoke | **NOT-TESTED** |
| Linux Docker/deb rebuild on mini | **NOT-TESTED** (scripts updated; docker build not run this turn) |

## Manual steps remaining

1. On a window-server session: start `pharos-web`, launch `Pharos.app` with `PHAROS_API_BASE_URL=http://127.0.0.1:<port>`, open Thread + Session in UI.  
2. Optional: seed an isolated replica under msg-test and re-run `pharos thread read` against that data-dir.  
3. Optional: `Scripts/build_linux_artifacts.sh amd64` to verify Docker Rust-only image.
