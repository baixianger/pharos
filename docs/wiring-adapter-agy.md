# Wiring notes — S5c adapter-agy

For merge captain only. This stream added a **wiring-local** workspace member so
the crate builds in-tree; captain should keep or re-apply the member append when
landing the stream. This stream did **not** edit `agent-runtime/src/main.rs`.

## Crate surface

- Package: `pharos-adapter-agy`
- Path: `rust/crates/pharos-adapter-agy/`
- Lib: `pharos_adapter_agy`

Deps: `pharos-protocol`, `pharos-api`, `serde`, `serde_json`, `uuid`.

## Workspace member (wiring-local already applied on this branch)

```toml
# rust/Cargo.toml members — captain owns permanent list
"crates/pharos-adapter-agy",
```

Optional workspace.dependency (not required; path member is enough):

```toml
pharos-adapter-agy = { path = "crates/pharos-adapter-agy" }
```

## Suggested `main.rs` hook (captain applies later)

When S2 lands `dyn SessionAdapter`, register Agy:

```rust
// agent-runtime: illustrative only — do not apply from this stream
use pharos_adapter_agy::{AgySessionAdapter, SessionAdapter};

fn register_agy_adapter() -> Box<dyn SessionAdapter> {
    Box::new(AgySessionAdapter::connect().expect("agy acp"))
}
```

Note: `SessionAdapter` / `DeliveryWorker` are **mirrored** in this crate from
S5a `pharos-codex-adapter` until a Phase 0.x contract bump promotes them.

## Env

| Var | Role |
|---|---|
| `PHAROS_AGY_EXECUTABLE` | Override Agy CLI path |
| `PHAROS_RUST_ADAPTER_AGY_PRODUCT_PATH_TEST=1` | Gate live ACP smoke test |
| `PHAROS_AGY_TEST_MODEL` | Live-test model id for `session/set_config_option` (default `gemini-3.8-flash`) |
