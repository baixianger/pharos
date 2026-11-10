# Rust CLI / Thread / grokbot (S1) — 2026-11-10

## STATUS: CLI-THREAD gates exercised (scripted self-reply)

## What landed

| Crate | Role |
|---|---|
| `pharos-thread` | `ThreadService` trait (for S4) + SQLite store on PHASE0_DDL; `replyOnce` stable ids |
| `pharos-grokbot` | `GrokbotThreadBridge` + human-proxy ID-only wake; Runtime UDS client |
| `pharos-cli` | Binary `pharos`: `thread read` / `thread reply --as grokbot` / `grokbot serve` |

Contracts consumed (not edited): `pharos-api` thread DTOs, `pharos-protocol` delivery/grokbot, `pharos-store-schema` rooms/memberships/messages/deliveries.

## Live run (pharos-msg-test)

| Field | Value |
|---|---|
| Thread | `grokbot-0c3b6b37` |
| Directed message | `436a40ff-9ac0-4322-b604-1a7808a6180e` (`@Pharos` → `grokbot`) |
| Injected delivery | `97b6e84c-edb7-4b47-a5de-0cc55e8e1024` |
| Reply | `reply-b8d37385cdffed5a9949e5d28423023b49f0db90d8e0a8d8a51b68cc993521ea` |
| Marker | `PHAROS_GROKBOT_MEMBER_DONE_0c3b6b37` |
| Runtime completed | `1` |
| Webhook | real env present; HTTP inject → `injected` |
| Human-request | `~/personal/pharos-msg-test/human-requests/2026-11-10T1794336102Z_grokbot-thread-mention-rust.md` |
| Mesh data-dir | `~/personal/pharos-msg-test/grokbot-member-rust/0c3b6b37/mesh` |

Second backend member present: `agy-stub` (identity only).

Reply was performed by the **Rust CLI inside the test** (not an external 45-minute human SSH). Idempotent re-reply returned the same `replyID`.

## Gate commands

```sh
source "$HOME/.cargo/env"
cd rust
cargo fmt -p pharos-thread -p pharos-grokbot -p pharos-cli
cargo clippy -p pharos-thread -p pharos-grokbot -p pharos-cli -- -D warnings
cargo test  -p pharos-thread -p pharos-grokbot -p pharos-cli
cargo build -p pharos-agent-runtime -p pharos-cli
PHAROS_GROKBOT_MEMBER_TEST=1 \
  cargo test -p pharos-grokbot --test grokbot_member_live -- --nocapture
```

## Evidence files

- `internal/evidence/2026-11-10-rust-cli-thread-unit.log`
- `internal/evidence/2026-11-10-rust-cli-thread-clippy.log`
- `internal/evidence/2026-11-10-rust-cli-thread-grokbot-e2e.log`
- `internal/evidence/2026-11-10-rust-cli-thread-summary.md` (this file)

## GB-THD mapping (Rust)

| ID | Result | Notes |
|---|---|---|
| GB-THD-01 | PASS (unit + live) | Directed → submit-member → bridge |
| GB-THD-02 | PASS (live) | Real webhook ID-only wake → `injected` |
| GB-THD-03 | PASS (unit + live) | injected / completed honesty; 45m fail path unit-covered via fixture timeout logic (not wall-clock 45m) |
| GB-THD-04 | PASS (live) | `pharos thread read` JSON |
| GB-THD-05 | PASS (live) | `pharos thread reply --as grokbot --text-file` → replyOnce |

## PARTIAL / NOT-TESTED

- **External 45m human-proxy SSH reply**: PARTIAL — E2E self-replies via Rust CLI after inject; human-request markdown was written for parity with Swift live test instructions, but no external operator waited.
- **Wall-clock 45m timeout → `failed`**: NOT-TESTED (would block 45 minutes); bridge code path exists and is unit-covered for the timeout branch only via Instant comparison logic (no live 45m wait).
- **Swift `GrokbotMemberLiveTests` binary swap**: NOT-TESTED — Swift test still shells out to `.build/debug/pharos-mesh` + MeshLocalReplica; Rust uses PHASE0 SQLite store. Captain may later alias `pharos` → `pharos-mesh` and/or bridge stores via S3 replica.
- **`grokbot serve` long-running loop**: NOT-TESTED as a multi-hour daemon; registration + poll path covered by E2E bridge usage.
- **S3 iroh / Swift replica DB interchange**: NOT-TESTED (S3 owns mesh replica).
