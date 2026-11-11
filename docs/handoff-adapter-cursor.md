# Handoff — S5d adapter-cursor (ADAPTER-CURSOR)

**Branch:** `rust/adapter-cursor`  
**Worktree:** `~/personal/pharos-wt/adapter-cursor`  
**Exclusive dirs:** `rust/crates/pharos-adapter-cursor/`  
**Contracts:** frozen `0.1.0` — **not edited**  
**Host:** Mac mini (`Xiangs-Mac-mini`)

## What shipped

New crate `pharos-adapter-cursor` implementing the S5a traits from
`pharos-codex-adapter::{SessionAdapter, DeliveryWorker}` against the public
Cursor `agent` CLI (version **2026.11.05-86047df**):

- **Headless drive:** `agent --print --output-format stream-json --trust --resume <chatId>`
- **`start_session`:** `agent create-chat` → chat UUID as session / vendor id
- **`send_prompt(Queue)`:** spawn CLI process in its own process group; return turn id
- **`wait_turn`:** join process, parse `result` JSON / stream-json lines, capture reply
- **`interrupt`:** SIGINT process group → `TurnStatus::Interrupted`; **never** `Completed`
  (protocol violation if vendor/result races to success after interrupt request)
- **`DeliveryWorker::dispatch`:** format Mesh-style prompt, Queue turn, map to
  `DeliveryState` (Interrupted → `Failed`)
- **Explicit unsupported (errors, not stubs):**
  - `PromptMode::Steer` — no ACP / mid-turn steer
  - `unsupported_list_chats()` — `agent ls` needs Ink raw-mode TTY
  - HITL / Goal / Todo — not advertised in manifest capabilities
- **Never** reads `~/.cursor` private DB / GUI / tokens

### Interface issue (do not block; Phase 0.x proposal)

`SessionAdapter` / `DeliveryWorker` / `AdapterError` still live in
`pharos-codex-adapter`. S5d **depends on that crate for the trait shapes** (same
location as S5a handoff). Promote into `pharos-protocol` / `pharos-api` in a
Phase 0.x contract bump so S2 is not forced to depend on the Codex package.
This stream did **not** move the traits.

## Gate commands

```sh
cd rust
cargo fmt -p pharos-adapter-cursor -- --check
cargo clippy -p pharos-adapter-cursor --all-targets -- -D warnings
cargo test -p pharos-adapter-cursor
# live (CI skips without env):
for i in 1 2 3; do
  PHAROS_RUST_ADAPTER_CURSOR_PRODUCT_PATH_TEST=1 \
    cargo test -p pharos-adapter-cursor --test product_roundtrip -- --nocapture || break
done
# → SUMMARY pass=3 fail=0 (~18–20s/run); seed+DONE Completed; interrupt=Interrupted
```

## Evidence

- `internal/evidence/2026-11-10-rust-adapter-cursor-product-roundtrip.md` (3× PASS)
- Live sidecars: `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-*/product-roundtrip.txt`

## PASS / PARTIAL / NOT-TESTED

| Item | Mark | Reason |
|---|---|---|
| One prompt round-trip → Completed with reply (`--print` / stream-json) | PASS | 3/3 live; seed marker captured |
| Resume / continue via `--resume <chatId>` on same create-chat id | PASS | seed + delivery both resumed same chat |
| DeliveryWorker → `DeliveryState::Completed` with reply | PASS | 3/3; DONE marker |
| Interrupt never `Completed` (SIGINT → Interrupted / Failed) | PASS | 3/3 `Interrupted`; synthetic delivery `Failed` |
| Steer / mid-turn | PASS (unsupported) | explicit `AdapterError` containing `unsupported` |
| `agent ls` / non-interactive inventory | PASS (unsupported) | `unsupported_list_chats()` |
| HITL / Goal / Todo through Cursor CLI | NOT-TESTED | no public CLI/ACP surface; capabilities omitted |
| `--continue` flag path (vs explicit `--resume id`) | NOT-TESTED | adapter uses `--resume <chatId>`; manual probe earlier showed `--continue` works |
| Full agent mode with tools / `--force` yolo delivery that mutates workspace | NOT-TESTED | product gate used ask-mode (no yolo) for marker replies |
| Cross-host Peer Session via Cursor CLI | NOT-TESTED | out of stream; needs S2/S3 |
| `pharos-meshd` registration of Cursor adapter | NOT-TESTED | `main.rs` captain-owned; see wiring snippet |
| Isolated credential store under SSH (`AGENT_CLI_CREDENTIAL_STORE=file`) | NOT-TESTED | mini local login store used |

## Wiring

See `docs/wiring-adapter-cursor.md`. Workspace member append is a **`wiring-local`**
commit in this branch for buildability; captain re-applies on integrate.
No `agent-runtime` `main.rs` edit.

STATUS: ADAPTER-CURSOR-DONE
