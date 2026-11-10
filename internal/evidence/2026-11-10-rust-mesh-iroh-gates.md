# Evidence: RFC-007 S3 mesh-iroh — cargo gates

**Date:** 2026-11-10  
**Host:** grok-bot (Linux box)  
**Branch:** `rust/mesh-iroh`  
**Contracts:** CONTRACTS_VERSION=0.1.0 @ 88f4c22

## Commands

```sh
source "$HOME/.cargo/env"
cd rust
cargo fmt --all   # exclusive crates only afterward; non-exclusive fmt restored
cargo clippy -p pharos-iroh -p pharos-replica -p pharos-mesh --all-targets -- -D warnings
cargo test  -p pharos-iroh -p pharos-replica -p pharos-mesh
```

## Results

- `cargo clippy … -D warnings`: **OK** (Finished)
- `cargo test`:
  - `pharos-iroh`: 4 passed (incl. PHM1 frame + iroh loopback exchange)
  - `pharos-mesh`: 1 unit + 1 integration (`peer_rpc_smoke`) passed
  - `pharos-replica`: 4 passed (schema migrate, RPC allowlist, message helpers)

## Artifacts

- Crates: `rust/crates/pharos-iroh`, `pharos-replica`, `pharos-mesh`
- Binary: `pharos-mesh-node`
- Wiring stubs: `agent-runtime/src/mesh_bridge.rs`, `replica_bridge.rs`
- Wiring notes: `docs/wiring-mesh-iroh.md`
