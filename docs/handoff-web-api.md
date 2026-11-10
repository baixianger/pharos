# Handoff — Stream S4 web-api (WEB-API)

## What was built

- `webui/` — static copy of `Sources/Pharos/Resources/WebCanvas` (`index.html`,
  `dsh-stream.css`, `dsh-stream.js`). Swift copies were **not** edited.
- `rust/crates/pharos-http` — Axum API router mounting `pharos-api` routes
  (`/health`, `/openapi.json`, `/api/v1/*`, WS `/api/v1/events`), S1/S2 service
  traits, and clearly named **fake** implementations + `FakeEventBus` pump.
- `rust/crates/pharos-web` — `pharos-web` binary composing API + `tower-http`
  static file serve; acceptance integration test.

Pinned to CONTRACTS_VERSION=0.1.0 (`pharos-api` / tag `rust-contracts-0.1.0`).
No contract edits. No adapter logic.

## Gate commands (exact) and summary

```sh
source "$HOME/.cargo/env"
cd rust
cargo fmt -p pharos-http -p pharos-web
cargo clippy -p pharos-http -p pharos-web --all-targets -- -D warnings
cargo test  -p pharos-http -p pharos-web
```

- **fmt:** applied
- **clippy:** clean with `-D warnings`
- **test:** 4 `pharos-http` + 1 acceptance (`health_openapi_static_and_ws_pump`) passed

Manual curl against `pharos-web --addr 127.0.0.1:18787`:

- `GET /health` → `{"ok":true,"contractsVersion":"0.1.0","service":"pharos-meshd"}`
- `GET /openapi.json` → OpenAPI 3.0.3 / version 0.1.0 / 10 paths
- `GET /`, `/dsh-stream.css`, `/dsh-stream.js` → HTTP 200 (1282 / 5890 / 8840 bytes)

## Evidence

- `internal/evidence/2026-11-10-rust-web-api-acceptance.md`

## PARTIAL / NOT-TESTED

- **PARTIAL:** Real S1/S2 backends — only **fake** services exercised (labeled in code + logs).
- **NOT-TESTED:** `pharos-meshd` main.rs integration (captain-owned; snippet in wiring doc).
- **NOT-TESTED:** Swift WebKit client (S6) loading this server.
- **NOT-TESTED:** Live mesh / vendor adapters (out of S4 scope).
- **NOT-TESTED:** Driving `dsh-stream.js` inside a real browser/WebKit (HTTP asset resolve only).

## Wiring notes

See `docs/wiring-web-api.md`. Captain should reconcile workspace members
`pharos-http` / `pharos-web` and optionally mount `pharos_web::app_router` in
`agent-runtime` when S1/S2 traits are ready. Until then `pharos-web` binary +
fakes are the S4 smoke path.

STATUS: WEB-API-DONE
