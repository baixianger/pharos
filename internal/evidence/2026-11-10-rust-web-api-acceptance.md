# Evidence: RFC-007 Batch 1 / Stream S4 web-api

**STREAM:** WEB-API  
**Branch:** `rust/web-api`  
**Contracts:** CONTRACTS_VERSION=0.1.0 (`rust-contracts-0.1.0` / `88f4c22`)  
**Date:** 2026-11-10

## What was exercised

All gates below used **FakeThreadService** + **FakeSessionService** + **FakeEventBus**
(labeled fake in code). No live S1/S2/mesh/adapters.

### Gate commands

```sh
source "$HOME/.cargo/env"
cd rust
cargo fmt -p pharos-http -p pharos-web
cargo clippy -p pharos-http -p pharos-web --all-targets -- -D warnings
cargo test  -p pharos-http -p pharos-web
```

**Result:** clippy clean (`-D warnings`); tests **5 passed** (4 `pharos-http` unit + 1 `pharos-web` acceptance).

Acceptance test `health_openapi_static_and_ws_pump` covers:

- `GET /health` → `ok=true`, `contractsVersion=0.1.0`, `service=pharos-meshd`
- `GET /openapi.json` → OpenAPI 3.0.3 stub from `pharos_api::openapi_stub_json()`
- Static UI: `/`, `/dsh-stream.css`, `/dsh-stream.js` all 200 (index references resolve)
- WS `GET /api/v1/events`: ready frame + **FakeEventBus** demo pump frames

### Manual curl (live `pharos-web` binary)

```sh
./rust/target/debug/pharos-web --addr 127.0.0.1:18787 --webui-dir "$PWD/webui"
curl -sS http://127.0.0.1:18787/health
# {"ok":true,"contractsVersion":"0.1.0","service":"pharos-meshd"}
curl -sS http://127.0.0.1:18787/openapi.json   # openapi 3.0.3 / 0.1.0 / 10 paths
curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' http://127.0.0.1:18787/
# 200 1282
curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' http://127.0.0.1:18787/dsh-stream.css
# 200 5890
curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' http://127.0.0.1:18787/dsh-stream.js
# 200 8840
```

Server log warned explicitly: using FakeThreadService + FakeSessionService.

## Artifacts

| Path | Role |
|---|---|
| `rust/crates/pharos-http/` | API router, S1/S2 traits, fake services, WS pump |
| `rust/crates/pharos-web/` | `pharos-web` binary + static compose |
| `webui/` | Copy of `Sources/Pharos/Resources/WebCanvas` (Swift copies untouched) |

## PARTIAL / NOT-TESTED

| Item | Mark | Reason |
|---|---|---|
| Real S1 Thread / S2 Session services | PARTIAL | Handlers mount traits; only **fake** impls exercised |
| Integration into `pharos-meshd` `main.rs` | NOT-TESTED | Captain-owned; see `docs/wiring-web-api.md` snippet |
| Swift WebKit client load (S6) | NOT-TESTED | Out of stream; assets served for later client |
| Live mesh / vendor adapters | NOT-TESTED | Explicitly out of S4 scope |
| Full browser automation of UI JS | NOT-TESTED | Asset HTTP resolve done; no Chrome/WebKit drive of `dsh-stream.js` runtime |
