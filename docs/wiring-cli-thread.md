# Wiring notes — stream S1 `cli-thread`

Merge captain owns `rust/Cargo.toml` member list reconciliation, `agent-runtime`
`main.rs`, Package.swift, packaging. This stream may only append its crates
(see wiring-local commit) and leave hooks as snippets here.

## Workspace members (already appended locally)

```toml
"crates/pharos-thread",
"crates/pharos-grokbot",
"crates/pharos-cli",
```

Optional `[workspace.dependencies]`:

```toml
pharos-thread = { path = "crates/pharos-thread" }
pharos-grokbot = { path = "crates/pharos-grokbot" }
```

## Binary

`pharos-cli` produces `pharos` (`thread read|reply`, `grokbot serve`).

Captain may symlink/alias as `pharos-mesh` for drop-in Swift CLI replacement.

## Reserved agent-runtime hooks (do **not** edit main.rs in this stream)

Suggested files the captain can add under `rust/crates/agent-runtime/src/`:

### `src/thread_service.rs` (snippet)

```rust
// Wire S4/S2 callers to the shared ThreadService.
// use pharos_thread::{open_thread_db, SqliteThreadStore, ThreadService};

pub fn open_default_thread_store(
    data_dir: &std::path::Path,
) -> Result<pharos_thread::SqliteThreadStore, pharos_thread::ThreadError> {
    pharos_thread::open_thread_db(data_dir)
}
```

### `src/grokbot_bridge.rs` (snippet)

```rust
// Optional: spawn grokbot serve loop beside Runtime when configured.
// use pharos_grokbot::{GrokbotThreadBridge, RuntimeClient, default_webhook_env_path};
//
// let client = RuntimeClient::new(socket_path);
// let bridge = GrokbotThreadBridge::with_runtime_client(
//     client,
//     Box::new(|room| store.history_for_bridge(room, 40).map_err(|e| e.to_string())),
//     host_label,
//     Some(default_webhook_env_path()),
// );
// bridge.ensure_registered()?;
// loop { bridge.poll()?; std::thread::sleep(std::time::Duration::from_millis(750)); }
```

### `main.rs` include (captain only)

```rust
mod thread_service;
mod grokbot_bridge;
```

## Trait for S4 (web stream)

```rust
use pharos_thread::ThreadService;
// S4 mounts /api/v1/threads* onto any `Arc<dyn ThreadService>`.
// Concrete: pharos_thread::SqliteThreadStore (PHASE0_DDL).
```

## Data-dir / DB path

- CLI `--data-dir` (Swift parity): mesh directory → `{data-dir}/replica.sqlite3`
- Host data-dir: `{data-dir}/mesh/replica.sqlite3`
- Resolver: `pharos_thread::resolve_db_path`
