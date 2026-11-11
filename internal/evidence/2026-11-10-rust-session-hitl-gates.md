# Evidence — S2 session-hitl (2026-11-10)

Host: Xiangs-MacBook-Air (darwin arm64). Worktree: `~/personal/pharos-wt/session-hitl`.
Branch: `rust/session-hitl`. Contracts: `0.1.0` (untouched).

## Unit / clippy / fmt

```sh
cd rust
cargo fmt -p pharos-session -p pharos-hitl -p pharos-goals -- --check
cargo clippy -p pharos-session -p pharos-hitl -p pharos-goals --all-targets -- -D warnings
cargo test -p pharos-session -p pharos-hitl -p pharos-goals
```

Result: **PASS** (fmt clean; clippy `-D warnings` clean; unit + goals smoke + gated live skip without env).

Notable unit coverage:

| Gate | Test | Result |
|---|---|---|
| webhook → injected | `pending::tests::webhook_success_is_injected` | PASS |
| resolve allowedOnce / denied | `pending::tests::resolve_allowed_once_and_denied` | PASS |
| 45m → failed | `pending::tests::forty_five_minutes_timeout_branch` (fake clock) | PASS |
| event JSON shapes | `events::tests::progress_and_approval_event_json_shapes` | PASS |
| dyn SessionAdapter | `service::tests::consumes_dyn_session_adapter_and_emits_progress_events` | PASS |
| Goal/Todo msg-test smoke | `msg_test_smoke::goal_todo_smoke_isolated_msg_test_dir` | PASS |

## Live Codex approval × human-proxy (×3)

Gate env: `PHAROS_RUST_SESSION_HITL_LIVE=1` (CI skips without it).
`AGENT_CLI_CREDENTIAL_STORE=file`, `CODEX_HOME` unset for auth seed copy into isolated home.

```sh
cd rust
unset CODEX_HOME
export AGENT_CLI_CREDENTIAL_STORE=file
for i in 1 2 3; do
  PHAROS_RUST_SESSION_HITL_LIVE=1 \
    cargo test -p pharos-hitl --test codex_hitl_live -- --nocapture
done
```

| Run | Session | Approval command | Bridge | Turn | Result |
|---|---|---|---|---|---|
| 1 | `01a1c766-8bc4-7b12-9670-cf0539247ab1` | `printf PHAROS_RUST_HITL_OK` | Injected (webhook 200) → allowedOnce | completed | PASS (~13s) |
| 2 | `01a1c766-bfba-7583-b257-699956f76fd0` | same | Injected → allowedOnce | completed | PASS (~11s) |
| 3 | `01a1c766-ea5a-72b2-83bc-60a1836a7570` | same | Injected → allowedOnce | completed | PASS (~12s) |

**SUMMARY pass=3 fail=0**

Raw logs: `internal/evidence/2026-11-10-rust-session-hitl-live-run{1,2,3}.log`

Human-proxy files under `~/personal/pharos-msg-test/human-requests/*_rust-air-codex-hitl.md` (+ `.done.md`).
Live self-resolves `.done.md` after inject (parity with S1 grokbot live; no wall-clock 45m operator wait).

### Live path notes (honest)

- Requires local `codex-code-mode-host` (Codex 0.167 shell path); without it shell times out and **no** `requestApproval` is emitted.
- Isolated HITL `CODEX_HOME` forces `approval_policy=on-request` (user global config is `never`).
- Deferred-approval client lives in `pharos-hitl` (adapter stdio auto-accepts; see handoff interface issue).
- `dyn SessionAdapter` consumption is covered by `pharos-session` unit tests with Codex adapter trait + FakeAdapter; live approval wire uses `CodexHitlClient` because S5a stdio auto-accepts.
