# Wiring notes — Stream S4 web-api

Merge captain owns `rust/crates/agent-runtime/src/main.rs` and final
`rust/Cargo.toml` reconciliation. This stream appended only its own workspace
members / deps in a `wiring-local(web-api): …` commit.

## Workspace members already appended (local)

```toml
"crates/pharos-http",
"crates/pharos-web",
```

Plus `[workspace.dependencies]` entries: `pharos-http`, `pharos-web`, `axum`,
`tokio`, `tower`, `tower-http`, `async-trait`, `futures-util`, `tracing`,
`tracing-subscriber`, `clap`, `reqwest`, `tokio-tungstenite`, `http-body-util`.

## Suggested `pharos-meshd` hook (do **not** apply in this stream)

```rust
// agent-runtime/src/main.rs — captain applies when integrating S4
//
// Option A: spawn pharos-web routes inside the daemon process:
//   use pharos_http::{AppState, EventBus, api_router, FakeSessionService, FakeThreadService};
//   use pharos_web::{app_router, resolve_webui_dir};
//   let events = EventBus::new(64);
//   let state = AppState::new(
//       std::sync::Arc::new(FakeThreadService::new(events.clone())), // replace with S1
//       std::sync::Arc::new(FakeSessionService::new(events.clone())), // replace with S2
//       events,
//   );
//   let webui = resolve_webui_dir(None)?;
//   let http = app_router(state, &webui);
//   // axum::serve(...) alongside existing UDS JSON-RPC
//
// Option B: run `pharos-web` as a sibling binary for Phase A/D smoke, then
// fold Option A once S1/S2 traits are available from those crates.
```

## Runtime env

| Var | Purpose |
|---|---|
| `PHAROS_WEB_ADDR` | Listen socket (default `127.0.0.1:8787`) |
| `PHAROS_WEBUI_DIR` | Absolute/relative path to static `webui/` |

Package the repo-root `webui/` directory next to the daemon (schema path
convention `pharos_store_schema::paths::WEBUI_DIR`).

## Trait swap when S1/S2 land

Replace `FakeThreadService` / `FakeSessionService` with the real
`Arc<dyn ThreadService>` / `Arc<dyn SessionService>` from those streams. Keep
`EventBus` as the WS fan-out (or adapt to S2's event emitter if they publish
one).
