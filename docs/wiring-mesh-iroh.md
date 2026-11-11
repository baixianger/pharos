# Wiring notes — stream S3 mesh-iroh

Merge captain applies these hooks. This stream must **not** edit
`rust/crates/agent-runtime/src/main.rs`.

## Workspace members (already appended locally)

`rust/Cargo.toml` members (stream-local commit `wiring-local(mesh-iroh)`):

- `crates/pharos-iroh`
- `crates/pharos-replica`
- `crates/pharos-mesh`

Workspace deps added: `iroh`, `tokio`, `thiserror`, `tracing`, `rusqlite` (bundled),
`rand`; `uuid` feature `serde` enabled.

## agent-runtime hooks

Files already present (unreferenced until captain wires them):

- `rust/crates/agent-runtime/src/mesh_bridge.rs`
- `rust/crates/agent-runtime/src/replica_bridge.rs`

Suggested `main.rs` snippet:

```rust
mod mesh_bridge;
mod replica_bridge;

// After Options::parse / Runtime::start:
// if let Some(mesh_dir) = options.mesh_data_dir {
//     let runtime_socket = options.socket.clone();
//     tokio::spawn(async move {
//         let _handle = pharos_mesh::open_handle(
//             mesh_dir,
//             runtime_socket,
//             options.mesh_relay_disabled,
//         ).await.expect("mesh open");
//         // park until process exit
//         std::future::pending::<()>().await;
//     });
// }
```

Captain must also add dependencies on `pharos-mesh` / `pharos-replica` /
`pharos-iroh` to `agent-runtime/Cargo.toml` and introduce a tokio runtime if the
daemon remains sync today (or spawn a dedicated runtime thread).

## Public interfaces for S1 / S2

- `pharos_replica::ReplicaHandle`
  - `peer_host_runtime_hello`
  - `peer_host_runtime_call` (allowlist: `delivery.submit-member`)
  - `peer_sync_pull` / `peer_sync_push`
- Binary smoke tool: `pharos-mesh-node` (`init|invite|accept|serve|hello|call|…`)

## Contract note (not edited)

Phase 0 `ReplicaRpcDisposition` uses camelCase `request`/`response`/`error`.
Live Swift MeshReplicaRPC uses `request`/`success`/`failure`. Rust↔Rust XHOST
uses Phase 0 names. Bit-identical Swift wire interop needs a Phase 0.x bump —
see handoff BLOCKED-CONTRACT proposal (non-blocking for this stream’s Rust gate).
