# GOAL: Pharos Rust backend migration (RFC-007)

Owner decision 2026-11-10 19:06 (user): use RFC-007 defaults, do Phase 0, then run streams in parallel. Pharos PM (Grok Bot) accepts work in batches.

## End goal
One standalone Rust backend (`pharos-meshd`, may be renamed later) that owns mesh/sync, Runtime, Thread, Session, HITL, Goal/Todo, the CLI, and a built-in web server that serves the same Web UI the app's WebKit view loads, plus HTTP/WS API. Swift = SwiftUI + WebKit client only. The box (Linux, no Swift) runs the full backend.

## Batches and acceptance gates (PM verifies each before the next starts)
- **Batch 0, Phase 0 contracts** (mini, pharos-dev-cursor, single agent): pharos-api, pharos-protocol, pharos-store-schema; `cargo check` on the three; no deps on adapter/CLI/web; CONTRACTS_VERSION=0.1.0; local tag rust-contracts-0.1.0. STATUS: RUST-P0-DONE.
- **Batch 1** (parallel): S3 mesh-iroh (box), S1 cli-thread (mini), S4 web-api (mini), S5a adapter-codex (air). Gates: per RFC-007 table (XHOST via Rust mesh, grokbot E2E + thread read/reply parity in Rust CLI, /health + OpenAPI + static UI, Codex product round-trip).
- **Batch 2** (parallel): S5b adapter-dsh (box), S5c adapter-agy (box/air), S5d adapter-cursor (mini/air), S2 session-hitl (air). Gates per RFC-007.
- **Batch 3**: S6 Swift client → API (mini), then merge captain integration, then Phase E deletions only after all gates green.

## Rules (all agents)
- Each stream: own git worktree `~/personal/pharos-wt/<stream>` on branch `rust/<stream>`, own tmux `pharos-rust-<stream>`, exclusive dirs per RFC-007 §6.1. Cross-stream needs go through contracts (Phase 0.x bump).
- Merge captain = the mini `pharos-dev-cursor` agent; only it touches workspace Cargo.toml member list, agent-runtime main.rs, Package.swift, packaging.
- Every stream writes `STATUS: <STREAM>-DONE` in its worktree `docs/handoff-<stream>.md` with evidence paths under `internal/evidence/2026-*-rust-<stream>-*.md`. Honest partial/untested marks; no faked success.
- No push / PR / force / history rewrite without the user. Real messages only in pharos-msg-test (and mirrors). Never touch company MacBook Pro, the 3080 dsh Host, its token, ipc.sock, ~/.gemini app state, dsh workspace.json. Never print secrets.
