# Handoff — Stream S3 mesh-iroh (MESH-IROH)

## What was built

Rust mesh / iroh / replica foundations for RFC-007 Batch 1:

| Crate | Role |
|---|---|
| `pharos-iroh` | Iroh endpoint + PHM1 frame codec (`me.pai.pharos/mesh/1`) |
| `pharos-replica` | PHASE0 SQLite replica + **`ReplicaHandle`** Peer RPC (`host.runtime.hello/call`, `replica.sync.pull/push`) + Unix Runtime client |
| `pharos-mesh` | Trust invite/accept, node identity, CLI binary **`pharos-mesh-node`** |

Agent-runtime stubs (captain wires): `src/mesh_bridge.rs`, `src/replica_bridge.rs`.  
Wiring notes: `docs/wiring-mesh-iroh.md`.

## Gate commands (summary)

```sh
cd rust
cargo clippy -p pharos-iroh -p pharos-replica -p pharos-mesh --all-targets -- -D warnings
# → OK

cargo test -p pharos-iroh -p pharos-replica -p pharos-mesh
# → pharos-iroh 4; pharos-mesh 1+integration; pharos-replica 4 — all passed

./Scripts/smoke-mesh-iroh-box.sh
# → BOX_HEADLESS_PEER_CALL_OK + TRUST_PAIRING_OK

# mini↔air (scratch mesh-iroh-peer clones, msg-test data dirs)
# → XHOST_MINI_TO_AIR_OK a9eb0bb8-…
# → XHOST_AIR_TO_MINI_OK d30dd812-…
```

## Evidence

- `internal/evidence/2026-11-10-rust-mesh-iroh-gates.md`
- `internal/evidence/2026-11-10-rust-mesh-iroh-box-headless.md`
- `internal/evidence/2026-11-10-rust-mesh-iroh-xhost.md`

## PARTIAL / NOT-TESTED

- **NOT-TESTED:** Far-host Agy inject + replyOnce room visibility (Swift product XHOST). Proven: Peer `delivery.submit-member` equivalent → Runtime `queued`.
- **NOT-TESTED:** Live Swift MeshReplicaRPC bit-compat (disposition `success`/`failure` vs Phase 0 `response`/`error`).
- **NOT-TESTED:** Full signed CRDT event log / blob chunk sync (Phase 0 tables + message pull/push only).
- **PARTIAL:** Trust pairing is Rust-native `pharos-trust1:` invite/accept smoke, not production Swift QR ticket decode.
- **PARTIAL:** `agent-runtime` hooks exist as files only; `main.rs` not edited (captain).

## Contract proposal (non-blocking)

If Swift wire interop is required before cutover, propose Phase 0.x bump aligning `ReplicaRpcDisposition` serde names with Swift (`success`/`failure`) or adding an explicit wire-compat alias. Marked here only — contracts not edited.

## Wiring notes for captain

1. Keep/reconcile `rust/Cargo.toml` members: `pharos-iroh`, `pharos-replica`, `pharos-mesh` (+ workspace deps in `wiring-local` commit).
2. `mod mesh_bridge; mod replica_bridge;` in `agent-runtime` + optional tokio mesh spawn (see `docs/wiring-mesh-iroh.md`).
3. S1/S2 should depend on `pharos_replica::ReplicaHandle` for Peer delivery / host.runtime.call.

STATUS: MESH-IROH-DONE
