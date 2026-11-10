# Handoff — stream S1 `cli-thread` (CLI + Thread R/W + grokbot)

Branch: `rust/cli-thread`  
Contracts: CONTRACTS_VERSION=0.1.0 (`rust-contracts-0.1.0` / `88f4c22`) — **not edited**.

## What was built

1. **`rust/crates/pharos-thread`**
   - `ThreadService` trait for S4 HTTP handlers to call
   - `SqliteThreadStore` on `PHASE0_DDL` (`rooms` / `memberships` / `messages`)
   - Product `replyOnce` with stable `reply-<sha256>` ids
   - CLI JSON shapes matching Swift `thread read` / `thread reply`

2. **`rust/crates/pharos-grokbot`**
   - Port of `GrokbotThreadBridge` (honest `injected` → `completed` | `failed`)
   - Human-proxy webhook wake (ID-only `thread-mention`; never logs key)
   - Runtime UDS JSON-RPC client for `pharos-meshd`

3. **`rust/crates/pharos-cli`**
   - Binary **`pharos`**: `thread read`, `thread reply --as grokbot --text-file`, `grokbot serve`

4. Docs: `docs/wiring-cli-thread.md` (main.rs hook snippets; captain-owned wiring)

## Gate commands (output summary)

```sh
cd rust
cargo fmt -p pharos-thread -p pharos-grokbot -p pharos-cli
cargo clippy -p pharos-thread -p pharos-grokbot -p pharos-cli --all-targets -- -D warnings
# → Finished, no warnings (includes integration tests)

cargo test -p pharos-thread -p pharos-grokbot -p pharos-cli
# → pharos-thread 5 passed; pharos-grokbot 4 unit + 1 live (skipped without gate)

cargo build -p pharos-agent-runtime -p pharos-cli
# → pharos-meshd + pharos

PHAROS_GROKBOT_MEMBER_TEST=1 \
  cargo test -p pharos-grokbot --test grokbot_member_live -- --nocapture
# → ok in ~1.86s
# Thread=grokbot-0c3b6b37 injected=97b6e84c-… reply=reply-b8d37385… completed=1
```

## Evidence

- `internal/evidence/2026-11-10-rust-cli-thread-summary.md`
- `internal/evidence/2026-11-10-rust-cli-thread-unit.log`
- `internal/evidence/2026-11-10-rust-cli-thread-clippy.log`
- `internal/evidence/2026-11-10-rust-cli-thread-grokbot-e2e.log`

## PARTIAL / NOT-TESTED

- External 45-minute human SSH reply after webhook: **PARTIAL** (test self-replies via Rust CLI; human-request file still written under msg-test).
- Wall-clock 45m → `failed`: **NOT-TESTED**.
- Drop-in replacement of Swift `GrokbotMemberLiveTests` / MeshLocalReplica: **NOT-TESTED** (Rust PHASE0 SQLite store; S3 owns replica interchange).
- Long-running `grokbot serve` daemon soak: **NOT-TESTED**.

## Wiring notes

- Local `rust/Cargo.toml` members append: `pharos-thread`, `pharos-grokbot`, `pharos-cli` (wiring-local commit; captain reconciles).
- Do **not** edit `agent-runtime/src/main.rs` here — snippets in `docs/wiring-cli-thread.md` (`thread_service.rs` / `grokbot_bridge.rs`).
- S4 should depend on `pharos_thread::ThreadService` (`Arc<dyn ThreadService>` / concrete `SqliteThreadStore`).
- Binary name is `pharos`; captain may alias as `pharos-mesh` for Swift CLI path parity.
- No contract change proposals; nothing BLOCKED-CONTRACT.

## Contract proposals

None.

STATUS: CLI-THREAD-DONE
