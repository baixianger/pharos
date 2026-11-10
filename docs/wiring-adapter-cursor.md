# Wiring notes — S5d adapter-cursor

For merge captain only. This stream may include a clearly labeled **`wiring-local`**
commit that appends the workspace member so the crate builds in this worktree.
Captain should re-apply (or squash) that member append on the integrate branch.

## Crate surface

- Package: `pharos-adapter-cursor`
- Lib: `pharos_adapter_cursor` (`rust/crates/pharos-adapter-cursor/src/lib.rs`)
- Path: `rust/crates/pharos-adapter-cursor/` (RFC-007 §6.1 exclusive dir)

Depends on: `pharos-codex-adapter` (for shared `SessionAdapter` / `DeliveryWorker`
traits until Phase 0.x promotion), `pharos-api`, `pharos-protocol`, `serde_json`,
`uuid`.

## Workspace member (captain)

Add to `rust/Cargo.toml` members if not present:

```toml
"crates/pharos-adapter-cursor",
```

Optional workspace.dependency:

```toml
pharos-adapter-cursor = { path = "crates/pharos-adapter-cursor" }
```

## Suggested `main.rs` hook (captain applies later)

When S2 lands `dyn SessionAdapter`, register Cursor:

```rust
// agent-runtime: illustrative only — do not apply from this stream
use pharos_adapter_cursor::{CursorSessionAdapter, SessionAdapter};

fn register_cursor_adapter() -> Box<dyn SessionAdapter> {
    Box::new(CursorSessionAdapter::connect().expect("cursor agent CLI"))
}
```

Do **not** invent ACP / JSON-RPC for Cursor — the adapter shells the public
`agent` CLI (`--print` / `stream-json` / `--resume`). Never read `~/.cursor` DB.

## Env

| Var | Role |
|---|---|
| `PHAROS_CURSOR_AGENT_EXECUTABLE` | Override Cursor `agent` CLI path |
| `PHAROS_RUST_ADAPTER_CURSOR_PRODUCT_PATH_TEST=1` | Gate live product round-trip test |
| `AGENT_CLI_CREDENTIAL_STORE=file` | Required under SSH when keychain is locked (see continuous-goal addendum) |
| `CURSOR_API_KEY` | Optional; default login store is fine on mini |
