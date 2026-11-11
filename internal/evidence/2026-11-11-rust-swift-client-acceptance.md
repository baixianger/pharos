# Evidence: RFC-007 Batch 3 / Stream S6 swift-client

**STREAM:** SWIFT-CLIENT  
**Branch:** `rust/swift-client`  
**Base tip:** `9b5434f` (RUST-B2-MERGED / integrate-b2)  
**Contracts:** CONTRACTS_VERSION=0.1.0  
**Date:** 2026-11-11  
**Host:** Mac mini (SSH session; `DISPLAY` empty)

## What shipped (code)

| Area | Change |
|---|---|
| `PharosClientKit` | `HttpPharosClientService` + `PharosAPIConfiguration` / backend kind + API wire mappers |
| `Sources/Pharos/UI` | `PharosClientBackend`, WebKit loads daemon URL, shell `onAddProject` |
| `WebCanvas/dsh-stream.js` | Product approval/history via `fetch` to `/api/v1/...`; `pharosBridge` shim only |
| `ContentView.swift` | wiring-local: default `rust-api` HTTP client; `desktop-mesh` behind flag |
| `Package.swift` | wiring-local: `PharosClientKitTests` target |
| Tests | ArchitectureBoundary rust-api path assertions + live HTTP smoke (env-gated) |

## Gate commands (exact) and results

### 1) Swift client targets

```sh
cd ~/personal/pharos-wt/swift-client
swift build --target PharosClientKit
# Build complete! PASS

swift build --target PharosClientKitTests
xcrun xctest -XCTest ArchitectureBoundaryClientKitTests \
  .build/out/Products/Debug/PharosClientKitTests.xctest
# 3 tests, 0 failures PASS
```

```sh
swift build --target Pharos
# FAIL — pre-existing tip Mesh break (HostSessionSchema / sessionRPC), outside S6 dirs
# See docs/wiring-swift-client.md
```

```sh
swift test --filter ArchitectureBoundary
# FAIL to compile — same tip Mesh break blocks PharosTests
# Equivalent ClientKit filter above PASS
```

### 2) Rust untouched

```sh
source "$HOME/.cargo/env"
cd rust && cargo build
# Finished `dev` profile … PASS (S6 did not edit rust/)
```

### 3) Desktop / headless smoke (msg-test)

Isolated state dir:

`~/personal/pharos-msg-test/peer-phase-a/rust-swift-client-1794357524849774000/`

```sh
./rust/target/debug/pharos-web --addr 127.0.0.1:18787 \
  --webui-dir "$PWD/Sources/Pharos/Resources/WebCanvas"
```

Exercised (FakeThreadService + FakeSessionService — labeled fake in S4):

- `GET /health` → ok / 0.1.0 / pharos-meshd
- List + open Thread `fake-thread-1` + read messages
- List + open Session `fake-session-1` + send + read history
- `HttpPharosClientLiveSmokeTests` with `PHAROS_SMOKE_BASE_URL=http://127.0.0.1:18787` → PASS
- WebKit probe (`internal/evidence/s6-webkit-probe.swift`) loaded daemon UI:
  `webkit_probe ok=true detail=Pharos Session Stream|object`
- Full GUI app launch / click drive: **not** run (SSH, no `DISPLAY`; tip `Pharos` target does not build)

Log/excerpt:  
`~/personal/pharos-msg-test/peer-phase-a/rust-swift-client-1794357524849774000/evidence/smoke-excerpt.txt`

## Feature flag

- Name: `PHAROS_CLIENT_BACKEND` (`rust-api` default, `desktop-mesh` legacy)
- Base URL: `PHAROS_API_BASE_URL` (default `http://127.0.0.1:8787`)

## PASS / PARTIAL / NOT-TESTED

| Item | Mark | Reason |
|---|---|---|
| `swift build --target PharosClientKit` | PASS | |
| ArchitectureBoundary (ClientKit / rust-api sources) | PASS | 3/3 via PharosClientKitTests |
| `swift test --filter ArchitectureBoundary` (PharosTests) | PARTIAL | Tip Mesh does not compile; equivalent ClientKit tests pass |
| `swift build --target Pharos` (full app) | PARTIAL | Pre-existing missing HostSessionSchema + MeshCore sessionRPC at tip |
| `cargo build` (rust/) | PASS | Untouched |
| HTTP list/open/read Thread+Session vs pharos-web | PASS | curl + HttpPharosClientLiveSmokeTests |
| WebKit loads daemon UI | PASS | Headless WKWebView probe over SSH |
| GUI Pharos.app click smoke | NOT-TESTED | No DISPLAY; app target does not build on tip |
| Real S1/S2 (non-fake) backends | PARTIAL | Smoke used S4 fakes (honest) |
| Package.swift unlink Mesh from app | NOT-TESTED | Phase E / captain |

## Manual steps (GUI) when window server available + Mesh tip fixed

1. Captain lands HostSessionSchema (+ MeshCore fixes); `swift build --target Pharos` green.
2. Start `pharos-web` (or meshd HTTP) with msg-test state dir; note port.
3. `PHAROS_CLIENT_BACKEND=rust-api PHAROS_API_BASE_URL=http://127.0.0.1:<port> ./Scripts/dev.sh`
4. Confirm WebKit canvas loads daemon root; select Thread + Session; send/read once.
