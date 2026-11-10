# Wiring notes — S5a adapter-codex

For merge captain only. This stream did **not** edit `agent-runtime/src/main.rs`
or add a new workspace member (crate `crates/adapter-codex` already listed).

## Crate surface

- Package: `pharos-codex-adapter`
- Lib: `pharos_codex_adapter` (`rust/crates/adapter-codex/src/lib.rs`)
- Bin: `pharos-codex-adapter` (JSONL daemon-proxy bridge — unchanged contract for existing `pharos-meshd` spawn path)

New library deps (already in workspace): `pharos-protocol`, `pharos-api`, `serde`, `time`, `uuid`.

## Suggested `main.rs` hook (captain applies later)

When S2 lands `dyn SessionAdapter`, register Codex:

```rust
// agent-runtime: illustrative only — do not apply from this stream
use pharos_codex_adapter::{CodexSessionAdapter, SessionAdapter};

fn register_codex_adapter() -> Box<dyn SessionAdapter> {
    // Prefer stdio for isolated product paths; daemon proxy for shared Runtime worker.
    Box::new(CodexSessionAdapter::connect_stdio().expect("codex"))
    // or: CodexSessionAdapter::connect_daemon_proxy()
}
```

Existing Runtime Codex delivery worker that shells out to the `pharos-codex-adapter`
binary can keep working unchanged; library path is the S2-facing shape.

## Env

| Var | Role |
|---|---|
| `PHAROS_CODEX_EXECUTABLE` | Override Codex CLI path |
| `PHAROS_CODEX_ADAPTER_EXECUTABLE` | Runtime→bin helper override (existing) |
| `PHAROS_RUST_ADAPTER_CODEX_PRODUCT_PATH_TEST=1` | Gate live product round-trip test |
| `CODEX_HOME` | Must be unset for default-auth live tests (stdio child clears inherited value) |
