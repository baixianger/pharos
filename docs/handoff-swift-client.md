# Handoff — Stream S6 swift-client (SWIFT-CLIENT)

## What was built

Phase D Swift client cutover onto the S4 Rust HTTP/WS API
(`pharos-api` CONTRACTS_VERSION **0.1.0**):

- **`HttpPharosClientService`** in `Sources/PharosClientKit/` — Foundation-only
  HTTP + WS client implementing `PharosClientService` against
  `http://127.0.0.1:<port>/api/v1/...` and `/api/v1/events`.
- **Feature flag** `PHAROS_CLIENT_BACKEND` = `rust-api` (**default**) |
  `desktop-mesh` (legacy `DesktopPharosClientService` retained; not deleted).
  Base URL: `PHAROS_API_BASE_URL` (default `http://127.0.0.1:8787`).
- **WebKit** (`PharosWebCanvasView`) loads daemon-served UI when on rust-api path.
- **WebCanvas** `dsh-stream.js`: product `resolveApproval` / history via **fetch**;
  `pharosBridge` kept only as legacy shim.
- ArchitectureBoundary assertions for the rust-api path (ClientKit + UI sources
  do not import MeshCore/Runtime). `PharosClientKitTests` added via wiring-local
  `Package.swift` so gates run without the broken tip Mesh stack.
- wiring-local `ContentView.swift` selects HTTP vs DesktopMesh.

Exclusive dirs only (+ documented wiring-local Package/ContentView). No
`PharosMesh*` / `PharosRuntime` / `rust/` edits.

## Gate commands (exact)

```sh
cd ~/personal/pharos-wt/swift-client
swift build --target PharosClientKit
swift build --target PharosClientKitTests
xcrun xctest -XCTest ArchitectureBoundaryClientKitTests \
  .build/out/Products/Debug/PharosClientKitTests.xctest

source "$HOME/.cargo/env"
cd rust && cargo build

# Smoke (msg-test isolated dir + pharos-web on 18787):
PHAROS_SMOKE_BASE_URL=http://127.0.0.1:18787 xcrun xctest \
  -XCTest HttpPharosClientLiveSmokeTests \
  .build/out/Products/Debug/PharosClientKitTests.xctest
PHAROS_SMOKE_BASE_URL=http://127.0.0.1:18787 \
  swift internal/evidence/s6-webkit-probe.swift
```

## Evidence

- `internal/evidence/2026-11-11-rust-swift-client-acceptance.md`
- `internal/evidence/s6-webkit-probe.swift`
- msg-test:
  `~/personal/pharos-msg-test/peer-phase-a/rust-swift-client-1794357524849774000/evidence/smoke-excerpt.txt`

## Feature flag

| Flag | How to toggle |
|---|---|
| `PHAROS_CLIENT_BACKEND` | `rust-api` (default) or `desktop-mesh` |
| `pharos.clientBackend` | UserDefaults same values |
| `PHAROS_API_BASE_URL` | S4 base URL (default `http://127.0.0.1:8787`) |

## PASS / PARTIAL / NOT-TESTED

| Gate | Mark |
|---|---|
| ClientKit build | **PASS** |
| ArchitectureBoundary (rust-api path / ClientKitTests) | **PASS** |
| `swift test --filter ArchitectureBoundary` (PharosTests) | **PARTIAL** — tip Mesh does not compile; see wiring |
| Full `Pharos` app target build | **PARTIAL** — pre-existing tip HostSessionSchema / sessionRPC gap |
| `cargo build` (rust/) | **PASS** |
| HTTP Thread+Session list/open/read vs pharos-web | **PASS** (S4 fakes) |
| WebKit loads daemon UI | **PASS** (headless WKWebView probe) |
| GUI app click-drive | **NOT-TESTED** (SSH / no DISPLAY; app target blocked) |

## Wiring

See `docs/wiring-swift-client.md` (Package.swift hunk, Mesh tip repair, webui sync).

STATUS: SWIFT-CLIENT-DONE
