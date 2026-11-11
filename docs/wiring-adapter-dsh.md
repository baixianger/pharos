# Wiring notes — S5b adapter-dsh

For merge captain only. This stream added workspace member
`crates/pharos-adapter-dsh` in a **wiring-local** commit so the crate builds in
this worktree. Captain should keep/rebase that member append; do **not** expect
this stream to edit `agent-runtime/src/main.rs`.

## Crate surface

- Package: `pharos-adapter-dsh`
- Lib: `pharos_adapter_dsh` (`rust/crates/pharos-adapter-dsh/src/lib.rs`)
- Implements shared traits from `pharos-codex-adapter::{SessionAdapter, DeliveryWorker}`
  (current location; contract-bump proposal lives in handoff — do not move here)

Deps: `pharos-api`, `pharos-protocol`, `pharos-codex-adapter`, `reqwest` (blocking),
`serde`, `serde_json`, `uuid`.

## Suggested `main.rs` hook (captain applies later)

When S2 lands `dyn SessionAdapter`, register DSH behind an isolated Host home:

```rust
// agent-runtime: illustrative only — do not apply from this stream
use pharos_adapter_dsh::{DshSessionAdapter, SessionAdapter};
use std::path::PathBuf;

fn register_dsh_adapter(dsh_home: PathBuf, workspace: PathBuf) -> Box<dyn SessionAdapter> {
    Box::new(
        DshSessionAdapter::connect_isolated(&dsh_home, &workspace).expect("dsh"),
    )
}
```

## Env

| Var | Role |
|---|---|
| `PHAROS_DSH_EXECUTABLE` | Override `dsh` binary path |
| `OPENCODE_GO_API_KEY` | Optional; else read from seeded `~/.dsh/.credentials.yaml` copy |
| `PHAROS_RUST_ADAPTER_DSH_PRODUCT_PATH_TEST=1` | Gate live product round-trip test |
| `DSH_HOME` | Set **only** on the spawned Host child to the isolated home — never point at the 3080 Host |

## Safety

- Spawn: `--port 0 --host 127.0.0.1 --no-open` under msg-test `DSH_HOME`.
- Never read/write the 3080 Host token, `ipc.sock`, or `dsh workspace.json`.
- Never log connect tokens / cookies / API keys.
