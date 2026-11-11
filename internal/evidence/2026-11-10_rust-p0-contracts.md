# Evidence: RFC-007 Batch 0 / Phase 0 contracts

**STATUS: RUST-P0-DONE**

## Commands

```sh
source "$HOME/.cargo/env"
cd rust
cargo check -p pharos-api -p pharos-protocol -p pharos-store-schema
cargo test  -p pharos-api -p pharos-protocol -p pharos-store-schema
```

Result: check OK; tests 5 + 3 + 2 passed.

## Artifacts

- `rust/crates/pharos-protocol` — delivery/session enums, replica RPC IDs, grokbot wake
- `rust/crates/pharos-store-schema` — SCHEMA_VERSION=1, PHASE0_DDL
- `rust/crates/pharos-api` — routes, DTOs, ClientEvent, OpenAPI stub
- `docs/rfc-007-contracts.md`
- `docs/GOAL-RUST-BACKEND.md`
- Local tag: `rust-contracts-0.1.0`

## Non-goals confirmed

No CLI, HTTP server, mesh/iroh impl, or vendor adapters in this batch.
