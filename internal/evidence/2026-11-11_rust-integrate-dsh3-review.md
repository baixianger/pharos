# Independent verification — `rust/integrate-dsh3` (merge1 + final HEAD)

- Verifier: teammate `verifier` (independent; reads code only, writes only this file; no commits/pushes)
- Worktree: `/workspace/pharos-rust/2026-11-11_dsh-team/wt/integrate-dsh3`
- Branch: `rust/integrate-dsh3`, base `4e381a4` (`integrate/mesh2-into-main`)
- Date: 2026-11-11 (CET)
- Status: **COMPLETE — GO1 static review (merge1) + GO2 final verification at final HEAD `287a136`.** All three gates, node/npm checks, asset diff, binary black-box smoke (39/39 checks) and stream-completeness greps PASS on the final HEAD. See the "FINAL VERIFICATION (GO2)" section at the end. At GO1 no cargo was run (implementer was concurrently merging `rust/thread-autoreply` in the same worktree).
- Reviewed commits (pinned SHAs; merge1 reviewed via `git show` while the worktree was moving):
  - `287a136` — `Merge branch 'rust/thread-autoreply' into rust/integrate-dsh3` (final HEAD, merge2; 2 parents `adebf73` + `f158b8b`)
  - `7736b00` — `Merge branch 'rust/web-real-sessions' into rust/integrate-dsh3` (merge1; 2 parents `daa81f7` + `8a0aeb9`)
  - `adebf73` — `test(web): real-mode pending-approval restart + bearer gate` (adds `rust/crates/pharos-web/tests/real_approvals.rs`)
  - `daa81f7` = already-merged `rust/hitl-persist` (merge commit, parents `4e381a4` + `7f9c741`).

Git environment note: every git command ran with `GIT_CONFIG_COUNT`/`GIT_CONFIG_VALUE_0` unset (repo git config otherwise errors `missing config key GIT_CONFIG_KEY_0`). All commands were read-only (`show`/`diff`/`ls-tree`/`rev-parse`/`log`/`grep`).

---

## 1. Merge topology (merge1)

```
$ git rev-list --parents -n1 7736b00
7736b00ee1e17faeea86095bdcae777b5fa95c87 daa81f7aff8dcd3d69f841128437450541215c8a 8a0aeb9758a3b6c29337f2671ad009df41036ed2
$ git rev-list --parents -n1 adebf73
adebf73d0617efc61522bb8c605793c2c31a992d 7736b00ee1e17faeea86095bdcae777b5fa95c87
```

- **PASS** — `7736b00` is a true merge commit with exactly 2 parents:
  - p1 = `daa81f7` (integration branch with `hitl-persist` merged),
  - p2 = `8a0aeb9` (`rust/web-real-sessions`, WEB-REAL-SESSIONS-DONE).
- `adebf73` is a normal 1-parent commit on top (new test), not a squash/rewrite.
- `git log --first-parent` shows the expected landing sequence:
  `4e381a4` → `daa81f7` (merge hitl-persist) → `7736b00` (merge web-real-sessions) → `adebf73`.
- No fast-forward/squash/rebase artifacts. No conflict leftovers: `git ls-tree -r adebf73 | grep -E '\.orig$|\.rej$'` → none; `git grep '^(<<<<<<<|>>>>>>>|=======$)' adebf73` → none.
- No file deletions in either direction (`git diff --diff-filter=D --name-status 7736b00^1 7736b00` and `...^2 7736b00` → empty).

## 2. Semantic review — Lead's 6 declared decisions, checked independently

### (1) Real default + durable approvals in both modes — **PASS**

Final `rust/crates/pharos-web/src/lib.rs` (adebf73):

- `real_app_state(data_dir, SessionAdapterChoice)` exists exactly as declared: opens `FileApprovalService(<data-dir>/pending-approvals.json)` via `open_approval_store()`, then `build_real_app_state(RealOptions::new(data_dir).with_session_adapter(adapter))`, then re-wraps with `AppState::with_approvals(state.threads, state.sessions, state.events, Arc::new(approvals))` so the real S1/S2 services and the shared `EventBus` are kept.
- `persistent_app_state(data_dir)` is retained with the **same signature/semantics as hitl-persist**: fake S1/S2 (`FakeThreadService`/`FakeSessionService`) + durable `FileApprovalService`. `--fake` therefore still persists pending approvals (requirement), while Thread/Session data stays in-memory (documented + logged).
- `fake_app_state()` stays in-memory approvals (`InMemoryApprovalService`) — used by `acceptance.rs`/`approvals_persistence.rs` and unit tests only.
- `main.rs`: default branch calls `real_app_state(...)`, `--fake` branch calls `persistent_app_state(...)` and logs that Thread/Session will not persist but approvals still do. No silent fake substitution.
- Corrupt/unreadable store is a startup error in **both** modes (`open_approval_store` -> error; lib test `corrupt_approval_store_is_an_error_in_both_modes` also asserts the corrupt bytes are not overwritten).

### (2) `spawn_approval_tap()` on all serve paths — **PASS**

- `serve_with_token()` → `let _approval_tap = state.spawn_approval_tap();` before building the router.
- `serve_ephemeral_with_token()` → same.
- `serve()` delegates to `serve_with_token(..., None)`; `serve_ephemeral()` delegates to `serve_ephemeral_with_token(..., None)`.
- Net effect: all four public entry points start exactly one tap per `AppState`. (Dropping a tokio `JoinHandle` detaches rather than cancels the task, so the tap keeps running for the lifetime of the server in all paths.)
- `serve_with_token` keeps the `validate_bind` defense-in-depth check.

### (3) Single `--data-dir` + env priority — **PASS**

- `main.rs` has exactly one `data_dir: Option<PathBuf>` arg: `#[arg(long, env = "PHAROS_WEB_DATA_DIR")]`. No second `--data-dir`-like flag.
- `resolve_data_dir(explicit)`: explicit (`--data-dir` or `PHAROS_WEB_DATA_DIR` via clap) wins → else `default_data_dir()`.
- `data_dir_from()` order: `PHAROS_WEB_DATA_DIR` (primary) → `PHAROS_DATA_DIR` (legacy compat, with distinct empty-value error) → macOS `~/Library/Application Support/Pharos` → Linux `$XDG_DATA_HOME/pharos` else `~/.local/share/pharos`; missing HOME is a clear error.
- Unit tests present in `pharos-web/src/lib.rs`: `data_dir_env_override_wins`, `data_dir_blank_override_is_an_error` (both envs), `legacy_pharos_data_dir_is_still_honored`, `primary_web_data_dir_beats_legacy_data_dir`, Linux XDG/home, macOS cfg test, `default_data_dir_reads_pharos_web_data_dir_env`.
- Same data dir feeds Thread replica (`mesh/replica.sqlite3`), goals (`mesh/goals.sqlite3`) and `pending-approvals.json` — confirmed in `real_app_state` + new e2e assertions.
- Note: the hitl-persist handoff section in `docs/handoff.md` (historical text, line ~53) says the old Linux default was `~/.local/state/pharos`; the merged binary intentionally uses `~/.local/share/pharos` (web-real-sessions default). Code + merged doc comment are consistent; only the historical handoff paragraph is stale — final handoff should state the merged behavior.

### (4) Router rebuilt from HEAD + theirs' additions, durable approval semantics kept — **PASS**

Final `pharos-http/src/router.rs` route table contains the full union:

```
/health, /openapi.json, /api/v1/events (WS),
GET  /api/v1/approvals                       <- hitl-persist (+ openapi path appended)
GET/POST /api/v1/sessions, /{id}, /{id}/history, /{id}/messages, /{id}/steer,
         /{id}/approval, /{id}/progress
GET/POST /api/v1/threads (+ POST from web-real-sessions), /{id}, /{id}/messages, /{id}/reply
GET /api/v1/projects, /api/v1/inventory/sessions
```

- `resolve_approval` handler is the hitl-persist durable version: durable `state.approvals.get()` is authoritative (unknown id → 404 `approvalNotFound`; session mismatch → 400; expired → 409), `resolve()` first-wins idempotent, then `sessions.resolve_approval`; on downstream dispatch failure it calls `revert_decision` and returns the original error (retryable). This is byte-for-byte the same logic as `daa81f7`.
- `create_session` / `create_thread` handlers and their routes are present (web-real-sessions additions); `openapi()` keeps the additive `APPROVALS_ROUTE` path block.
- Auth coverage: `app_router_with_token` builds `api_router(state)` **first** and only then applies `with_bearer_auth(api, token)`, so every API route including `GET /api/v1/approvals` and `POST /api/v1/sessions/{id}/approval` is protected; `/` and static fallback are appended after the layer and stay public; `/health` bypasses via `UNAUTHENTICATED_PATHS == ["/health"]` (constant-time compare, Debug-redacted token unchanged from web-real-sessions).
- `pharos-http/src/lib.rs` exports the union: hitl (`APPROVALS_ROUTE`, `ApprovalsQuery`, `list_approvals`, `ApprovalService`, `FileApprovalService`, `InMemoryApprovalService`, `PendingApproval*`, `ResolveApprovalResponse`) + theirs (`real` builder, `Real*`, `SessionAdapterChoice`, create requests); `services/mod.rs` registers `mod approval` + `real*` modules and re-exports both.
- `state.rs` / `approvals.rs` / `services/approval.rs` / `pharos-hitl/*` are **byte-identical to p1** (`git diff daa81f7 adebf73 -- <those paths>` → empty), i.e. the hitl-persist implementation was not rewritten or weakened by the merge.

### (5) All tests from both sides preserved, none weakened — **PASS (static counts)**

All test files present on either parent are present at `adebf73`, and the preserved ones are byte-identical to their parent:

| file | parent | at `adebf73` |
|---|---|---|
| `pharos-http/tests/approvals_api.rs` | p1 | IDENTICAL (8 `#[test]`/`#[tokio::test]` attrs) |
| `pharos-web/tests/approvals_persistence.rs` | p1 | IDENTICAL (2) — still valid because `persistent_app_state` keeps fake S1/S2 + durable approvals |
| `pharos-http/tests/real_state_http.rs` | p2 | IDENTICAL (4) |
| `pharos-web/tests/real_sessions.rs` | p2 | IDENTICAL (3) |
| `pharos-web/tests/acceptance.rs`, `asset_sync.rs` | base/p2 | IDENTICAL (1 + 1) |
| `webui/transport.js`, `Tests/WebCanvas/transport.test.mjs`, `Sources/.../WebCanvas/transport.js` | p1 | IDENTICAL (diff p1→merge empty) |

Test-function level union check (static name extraction):

- `pharos-http/src/router.rs`: p1 12 + p2 6 → merged **14** (4 common + 8 hitl-only + 2 theirs-only; none lost). Lead's "router 14 (hitl 8 + theirs 2)" confirmed.
- `pharos-web/src/lib.rs`: p2 10 → merged **16** (all 10 theirs tests kept + 6 new: 2 legacy/priority data-dir, 3 backend-construction incl. corrupt-store-in-both-modes, 1 approvals-token). Lead's "28 lib" is consistent once the `#[cfg(target_os = "macos")]` test is excluded on Linux: `auth.rs` 13 + `lib.rs` 16 = 29 static, minus 1 macOS-only = **28** on this box.
- Whole `pharos-http` lib: `router 14 + services/approval 3 + real 2 + real_session 4 + real_thread 8` = **31** — matches Lead's claim exactly.
- `pharos-http/tests`: `approvals_api` 8 static (claimed 9 — see F-1) + `real_state_http` 4.
- `pharos-web/tests`: `acceptance 1`, `approvals_persistence 2`, `asset_sync 1`, `real_sessions 3`, new `real_approvals 2` = 9 integration tests.
- No `#[ignore]` newly introduced (`git grep` on changed files: none); no TODO/FIXME/todo!/unimplemented! in changed `pharos-web`/`pharos-http` sources.

### (6) New `real_approvals.rs` gate — **PASS (code read; runtime at GO2)**

`rust/crates/pharos-web/tests/real_approvals.rs` (222 lines, 2 tests, both `#[tokio::test]`):

1. `real_mode_pending_approval_survives_restart` — uses `real_app_state(TempDir, SessionAdapterChoice::None)` (explicit temp data dir, so no real room/data dir is touched); asserts `mesh/replica.sqlite3` + `mesh/goals.sqlite3` exist (real backend, not fake); publishes `ClientEvent::ApprovalRequired` on the real state's `EventBus`; `serve_ephemeral` (loopback, tap spawned); asserts `GET /api/v1/approvals?state=pending` lists it and that `pending-approvals.json` was materialized in the same data dir; aborts the server, rebuilds `AppState` on the same dir (with a bounded 40×50 ms reopen retry for SQLite lock release), serves again and asserts the pending approval is still listed. Good independent gate for the merge requirement; the retry loop is pragmatic, not a weakening.
2. `approvals_routes_require_bearer_on_non_loopback_bind` — real state + `AuthToken`, reserves an ephemeral non-loopback addr via `TcpListener::bind("0.0.0.0:0")` (random port, never 3080/ipv4 fixed), asserts `validate_bind(addr, None)` is refused, starts `serve_with_token` on that wildcard bind, connects to `127.0.0.1:<port>`, waits for `/health`, then asserts `/health` 200, approvals snapshot 401 without bearer / 200 with bearer, and resolve POST 401 without bearer; aborts the server. No real room/network traffic; localhost-only requests. Matches the declared gate.

Residual observations (non-blocking): the reserve-then-bind port is a mild TOCTOU race (another process could grab the port in between; would fail loudly, not silently pass); the 150 ms sleeps after `events.publish`/`handle.abort` are small race windows; both acceptable for an integration test but worth knowing if it flakes on a loaded box. The authenticated resolve path is not asserted to succeed (in real `--session-adapter none` mode it must fail honestly — see N-2), only its auth gate.

## 3. `Cargo.lock` — union, not hand-spliced (static) — **PASS (to be confirmed by `git status` clean after cargo at GO2)**

- Package count identical to both parents: p1 472 / p2 472 / `adebf73` 472. No duplicate `name@version` entries in the final lock.
- `git diff 7736b00^1 7736b00 -- rust/Cargo.lock` = only the pharos-http dependency block (adds `pharos-codex-adapter`, `pharos-goals`, `pharos-session`, `pharos-store-schema`, `pharos-thread`, `thiserror 2.0.21`) + pharos-web dev-dep `tower`; `git diff 7736b00^2 7736b00 -- rust/Cargo.lock` = only `pharos-hitl` added to pharos-http. i.e. exact union of both parents' dependency sets, no version/package removals.
- TOML `Cargo.toml` diffs are the same union: pharos-http deps = p1 (`pharos-hitl`, `time`) ∪ p2 (real S1/S2 crates + `thiserror`); pharos-web `Cargo.toml` at merge is identical to p2 (serde_json dep + tower dev-dep already there).
- Limitation: a lock can only be *proven* freshly generated by running cargo. GO2 will run the gates normally and require `git status` clean afterwards — if the lock were stale or hand-broken, cargo would rewrite it and dirty the tree, which the GO2 check will catch.

## 4. Findings

No blocking or functional-loss findings in merge1. Recorded items:

- **F-1 (info, claim vs static count):** Lead's GO1 message says `approvals_api` = 9 tests; static count at `adebf73` (and at parent `daa81f7`) is **8** `#[test]`/`#[tokio::test]` attributes. The file is byte-identical to the hitl-persist parent, so this is a reporting-number discrepancy, not a merge weakening. GO2 runtime count will settle it.
- **F-2 (low, doc consistency):** merged behavior intentionally uses Linux `$XDG_DATA_HOME/pharos` else `~/.local/share/pharos`; the historical HITL-PERSIST-DONE handoff paragraph (and the legacy env name discussion) still mentions `~/.local/state/pharos`. Final `docs/handoff.md` should state the merged single-data-dir default (already true for `PHAROS_WEB_DATA_DIR`/`PHAROS_DATA_DIR` priority).
- **N-1 (info, edge case, not merge-introduced):** an explicitly empty `--data-dir`/`PHAROS_WEB_DATA_DIR=""` reaches `resolve_data_dir` as `Some("")` and is not rejected there (only the injected `data_dir_from` helper rejects empty env values). Extremely unlikely misconfiguration; no security impact; not worth changing in this merge-only branch.
- **N-2 (info, cross-stream semantics):** in default real mode with `--session-adapter none`, an authenticated `POST /api/v1/sessions/{id}/approval` records the durable decision then the real session service returns an explicit `operationFailed` (502), so the durable decision is reverted and the approval remains pending/retryable. That is the intended hitl-persist "failed dispatch must not consume the approval" semantics and the real-session "never fake success" rule; it is not a regression, but it means approvals cannot be *resolved* through the default real web binary until a live adapter is configured. GO2 binary smoke should record this honestly rather than trying to force a 200.
- **N-3 (info, pre-existing, inherited):** the web-real-sessions reviewer's non-blocking items (no SQLite WAL/busy_timeout on the shared data dir; `webui/transport.js` has no bearer-token support so token mode is API-only for the browser; reply retry may duplicate one WS frame) are unchanged by this merge; not merge defects.

## 5. GO2 plan (not yet executed)

On the final HEAD after merge2 (`rust/thread-autoreply`) is committed and the worktree is clean:

1. Claim task-3/task-4 on the task board, `git status` clean check first (my own evidence file will be the only untracked file afterwards — will state that explicitly), topology check of both merge commits (2 parents each, no rebase/squash), `git log --first-parent`.
2. Gates in `rust/`: `cargo fmt --all -- --check`, `CARGO_BUILD_JOBS=3 cargo clippy --workspace --all-targets -- -D warnings`, `CARGO_BUILD_JOBS=3 cargo test --workspace` — record exit codes + per-crate counts; verify `git status` clean after (lock/format consistency).
3. Extra: `cd integrations/dsh-plugin-pharos && npm test` (or `node --test`); `cd Tests/WebCanvas && node --test`; `diff -r webui Sources/Pharos/Resources/WebCanvas` (must be empty/ex 0).
4. Binary smoke with `cargo build -p pharos-web`, temp `mktemp -d` data dir, random 127.0.0.1 port:
   - real mode (default, no `--fake`): seeded-but-valid versioned `pending-approvals.json` in the temp dir (black-box durable snapshot) → `GET /api/v1/approvals?state=pending` lists it → kill + restart same `--data-dir` → still listed; plus real-mode honest behavior: `/api/v1/threads` empty (no fake ids), create thread/send/reply round-trip if useful; `--fake` explicit WARN path.
   - `--token` + non-loopback `0.0.0.0:<random>`: `/api/v1/approvals` no bearer 401, with bearer 200, `/health` 200, no-token `0.0.0.0` refuses to start (exit 1), token absent from logs.
   - Caveat to state honestly: there is no public HTTP endpoint that *creates* a pending approval; tap creation is covered by integration tests (`real_approvals`, `approvals_persistence`, `approvals_api`) and the seeded-file black-box only covers durability/snapshot. No real rooms / 3080 / `ipc.sock` / `~/.gemini` touched.
5. Completeness grep for all three streams (hitl-persist, web-real-sessions, thread-autoreply) on the final HEAD.
6. Append results to this file and message the Lead with per-item PASS/FAIL, commands, counts and issues. `git status` clean immediately after the gates, before writing the evidence update (file will then be untracked; Lead commits it).

## 6. Verdict (merge1, static)

**PASS so far.** Merge1 is a genuine 2-parent merge with no deletions/conflict leftovers; both streams' semantics, tests and assets are preserved (hitl-side files byte-identical to p1, theirs-side test files byte-identical to p2, router/lib test union with nothing lost); the declared 6-point semantic merge is implemented as described; `Cargo.lock` is a valid dependency union. Runtime gates and the real-mode/token black-box smoke remain to be executed at GO2 and are explicitly **not** claimed here.

---

# FINAL VERIFICATION (GO2) — final HEAD `287a136fb274f781baae11c8e7782b5eb4795058`

- Verifier: teammate `verifier`, independent; run ~17:15–17:2x UTC on 2026-11-11.
- This section supersedes the "runtime pending" caveats in §5/§6. No source edits, no commits, no pushes, no branch/worktree changes by the verifier.
- Only writes by the verifier: this evidence file (untracked; Lead commits it), `rust/target` build cache, and scratch files under `/tmp` (`/tmp/verify-dsh3-gates.log`, `/tmp/verify-dsh3-smoke.log`, `/tmp/pharos-dsh3-smoke.sh`). All smoke data dirs were `mktemp -d /tmp/pharos-dsh3-verify.*` and were removed; no temp dirs or servers left behind.
- Lead's/implementer's reported numbers that I had to independently confirm: fmt/clippy exit 0, test 222 passed / 57 suites, npm 18 passed, WebCanvas 3 passed, `diff -r` empty, clean tree. **Independently reproduced exactly (below).**

## G0. Final HEAD topology, history and cleanliness — PASS

```
$ git rev-parse HEAD                 -> 287a136fb274f781baae11c8e7782b5eb4795058
$ git rev-list --parents -n1 287a136 -> 287a136… adebf73… f158b8b…      (2 parents, merge2 = thread-autoreply)
$ git rev-list --parents -n1 7736b00 -> 7736b00… daa81f7… 8a0aeb9…      (2 parents, merge1 = web-real-sessions)
$ git rev-list --parents -n1 daa81f7 -> daa81f7… 4e381a4… 7f9c741…      (2 parents, hitl-persist landing)
$ git log --merges --oneline 4e381a4..HEAD
  287a136 Merge branch 'rust/thread-autoreply' into rust/integrate-dsh3
  7736b00 Merge branch 'rust/web-real-sessions' into rust/integrate-dsh3
  daa81f7 Merge branch 'rust/hitl-persist' into rust/integrate-dsh3
```

- **PASS** — all three landings are true 2-parent merge commits (`--no-ff`); first-parent chain `4e381a4 → daa81f7 → 7736b00 → adebf73 → 287a136`; no squash/rebase/amend artifacts.
- `git rev-parse --git-dir` contains no `MERGE_HEAD` and no `rebase-*` dirs. No `.orig`/`.rej` files; conflict-marker grep on tracked non-md files = 0 matches.
- merge2 commit message records only `# Conflicts: docs/handoff.md` (resolution = pre-merge `adebf73` version, as documented by implementer). `docs/handoff.md` at HEAD contains **0** `THREAD-AUTOREPLY-DONE` occurrences — this matches the Lead's explicit instruction that the final unified handoff (INTEGRATE-DSH3-DONE + THREAD-AUTOREPLY section) is written by the Lead at the end; **not counted as a failure** here, only a reminder.
- `git status --porcelain` = exactly one line: `?? internal/evidence/2026-11-11_rust-integrate-dsh3-review.md` (this file). `git diff --stat HEAD` empty (0 tracked modifications). `git status` and `HEAD` unchanged after all gates and smoke runs.
- `rust/Cargo.lock` unchanged by `cargo` during the gates (no rewrite), every `test result:` line is `ok` → the merged/generated lock is consistent.
- merge2 static preservation: every thread-autoreply-side file is byte-identical to its parent `f158b8b` (`agent-runtime/src/main.rs`, `agent-runtime/Cargo.toml`, `adapter-codex/src/{codex.rs,lib.rs,reply.rs,transport/*}`, `adapter-codex/tests/recorded_dispatch.rs`, `agent-runtime/src/reply_sink.rs`, `pharos-adapter-dsh/src/*`, `integrations/dsh-plugin-pharos/{index.mjs,index.test.mjs,README.md,package.json,package-lock.json}`), and every merge1-side test/source file is byte-identical to `adebf73` (`pharos-web/src/lib.rs`, `pharos-http/src/router.rs`, `tests/{real_approvals,approvals_persistence,approvals_api}.rs`). No deletions vs either parent. Lock diff vs parents = dependency-list union only (`pharos-agent-runtime` + `pharos-api`/`pharos-codex-adapter`/`pharos-thread`; pharos-http/pharos-web blocks as in §3); 472 packages in p1/p2/final, 0 duplicate `name@version`.

## G1. Gates on final HEAD (`rust/`, `CARGO_BUILD_JOBS=3`) — PASS

Log: `/tmp/verify-dsh3-gates.log` (scratch). Commands and exits:

| command | exit | key output |
|---|---|---|
| `cargo fmt --all -- --check` | **0** | no output |
| `CARGO_BUILD_JOBS=3 cargo clippy --workspace --all-targets -- -D warnings` | **0** | `Finished dev profile`; 0 `warning` lines |
| `CARGO_BUILD_JOBS=3 cargo test --workspace` | **0** | **222 passed / 0 failed / 0 ignored**, 57 suites (`test result:` lines), doc-tests 0 |

Per-binary counts parsed from the log (149 targets incl. empty ones; full list in the log):

| target | kind | passed |
|---|---|---|
| pharos_http | lib | 31 |
| approvals_api | tests/approvals_api.rs | 9 |
| real_state_http | tests/real_state_http.rs | 4 |
| pharos_web | lib | 28 |
| real_approvals | tests/real_approvals.rs | 2 |
| approvals_persistence | tests/approvals_persistence.rs | 2 |
| real_sessions | tests/real_sessions.rs | 3 |
| acceptance / asset_sync | tests | 1 / 1 |
| pharos_meshd (agent-runtime) | src/main.rs | 32 (incl. 5 `reply_sink` unit tests) |
| pharos_codex_adapter | lib + recorded_dispatch | 19 + 8 |
| pharos_adapter_dsh | lib | 9 |
| pharos_hitl | lib | 19 |
| pharos_thread / pharos_session | lib | 5 / 2 |

`222 = 31+9+4+28+2+2+3+1+1+32+19+8+9+19+5+2+…` (sum verified against every `test result:` line; no failures/ignored anywhere). This matches the implementer's reported `222 passed` / `57 suites` exactly — independently reproduced.

## G2. Node / npm / asset sync — PASS

- `cd integrations/dsh-plugin-pharos && npm test` → exit 0, **tests 18 / pass 18 / fail 0** (`node --test`, 18 ✔ lines; index.test.mjs covers poll→injected→followup→consumed, followup throw→failed, consumed-ack throw→failed, failed-ack failure caught, archived, empty poll, payload render, capabilities).
- `cd Tests/WebCanvas && node --test` → exit 0, **tests 3 / pass 3 / fail 0** (native transport forward, web transport reads Rust data, pending approvals restore/dedupe/reconnect).
- `diff -r webui Sources/Pharos/Resources/WebCanvas` → **exit 0, no output**; 12 files on each side; `transport.js` sha256 identical (`07f3cb8d…`).

## G3. Real binary black-box smoke — PASS (39/39 checks)

Build: `CARGO_BUILD_JOBS=3 cargo build -p pharos-web` → exit 0, `rust/target/debug/pharos-web` (108,260,416 bytes). Focused integration test as the tap-creation substitute: `cargo test -p pharos-web --test real_approvals -- --nocapture` → **2 passed / 0 failed** (`real_mode_pending_approval_survives_restart`, `approvals_routes_require_bearer_on_non_loopback_bind`). Full smoke log: `/tmp/verify-dsh3-smoke.log`, script `/tmp/pharos-dsh3-smoke.sh` (scratch).

Honest black-box boundary: there is **no public HTTP endpoint that creates a pending approval** (approvals are produced by adapters/session events into `EventBus`). Creation-path durability is therefore covered by integration tests (`real_approvals`, `approvals_persistence`, `approvals_api`), while the binary smoke covers durability/snapshot/auth with a *valid versioned* store pre-seeded into a temp data dir (simulating a previous process's durable state) and, in `--fake` mode, an actual durable **write** via the resolve endpoint. No real room/daemon data was used.

**A. real mode (default, non `--fake`)** — temp `--data-dir`, `127.0.0.1:<random>`; 17/17 checks PASS:
- `/health` 200; `/api/v1/threads` and `/api/v1/sessions` = 200 with **no** `fake-thread-1`/`fake-session-1` (real backend default confirmed; startup log `using real durable S1/S2 services`, `session_adapter="none"`, `fake=false`).
- `GET /api/v1/approvals?state=pending` 200 lists the seeded approval (`state=pending`); `sessionId` filter excludes other sessions; `state=resolved` → 400 `invalidRequest`.
- Data dir contains `mesh/replica.sqlite3`, `mesh/goals.sqlite3`, `pending-approvals.json` (single data dir).
- `POST /api/v1/sessions/smoke-session-1/approval` in real mode without a live adapter → **502** `{"error":{"code":"operationFailed","message":"no live session adapter configured; restart pharos-web with --session-adapter codex"}}`, and the durable decision is **reverted** → snapshot still lists the approval (retryable; matches intended hitl design, see N-2).
- Kill + restart same `--data-dir` (new port): `GET /api/v1/approvals?state=pending` 200, approval still listed (file on disk remains a valid `version:1` envelope). Startup log confirms real mode again.

**B. `--fake` mode** — temp `--data-dir`, 9/9 checks PASS:
- startup WARN "using in-memory FakeThreadService + FakeSessionService; Thread/Session data will NOT persist (pending approvals still persist)"; `GET /api/v1/threads` exposes the explicit `fake-thread-1` fixture (fakes only when requested).
- Seeded pending approval is listed from the same data-dir store.
- `POST /api/v1/sessions/fake-session-1/approval` → **200** `{"ok":true,"approvalId":"smoke-approval-1","state":"resolved","decision":"allowedOnce","alreadyResolved":false}`; pending snapshot empty; on-disk store shows `"state": "resolved"` + `"decision": "allowedOnce"`; kill + restart same data dir → pending empty (durable **write** path proven black-box in fake mode).

**C. `--token` + non-loopback `0.0.0.0:<random high port>`** — 10/10 PASS:
- `/health` no token → 200; `GET /api/v1/approvals?state=pending` no token → 401 `{"error":{"code":"unauthorized",…}}`; wrong bearer → 401; correct `Authorization: Bearer` → 200 and lists the approval; `?token=` → 200; another API route (`/api/v1/threads`) no token → 401; static `/` → 307 public (`/health` + static unauthenticated, API protected).
- Server log occurrences of the token string = **0** (no leakage).

**D. non-loopback bind without token** — `--addr 0.0.0.0:<port>` (no token) → exit code **1** with `Error: "refusing to bind non-loopback address 0.0.0.0:<port> without a token; pass --token/PHAROS_WEB_TOKEN or bind a loopback address"`.

**E. corrupt `pending-approvals.json`** — startup exit **1** with `pending approval store … approval store data is corrupt: … missing field 'type' …`; corrupt bytes on disk preserved unchanged (never silently reset/truncated).

Notes for honesty:
- My **first** smoke attempt failed because I hand-wrote the seed without `ApprovalKind`'s internal tag (`#[serde(tag = "type")]`), i.e. the server correctly refused a corrupt store (`missing field 'type'`, exit nonzero). After fixing the seed format to the real serialization, all 39 checks passed. This is recorded because it demonstrates the fail-loud behavior rather than a product defect.
- Fake-mode resolve needs an existing fake fixture session id (`fake-session-1`); with an unknown session id it returns 404 `sessionNotFound` and reverts the durable decision (also consistent with the failed-dispatch semantics).
- Environment: no default data dirs were created (`~/.local/share/pharos` and `~/.local/state/pharos` do not exist), no touch of `~/personal/pharos-msg-test`, port 3080, `ipc.sock` or `~/.gemini`. A pre-existing `pharos-meshd` process under `/home/box/personal/pharos-msg-test/` and a `:3080` listener are part of the box environment — not started by me and not connected to. No leftover `pharos-web` processes after the run; all smoke temp dirs removed.

## G4. Three-stream completeness on final HEAD — PASS

| stream | capability | location on HEAD |
|---|---|---|
| hitl-persist | `FileApprovalService` / durable store | `rust/crates/pharos-http/src/services/approval.rs:253+`; exported in `services/mod.rs` + `lib.rs` |
| | `<data-dir>/pending-approvals.json` | `pharos-web/src/lib.rs:37` `PENDING_APPROVALS_FILE`, used by `open_approval_store` / `real_app_state` / `persistent_app_state` |
| | `GET /api/v1/approvals` | `pharos-http/src/approvals.rs:17` `APPROVALS_ROUTE` + `list_approvals`, mounted in `api_router` (`router.rs:24`), openapi path appended |
| | `spawn_approval_tap` | `pharos-http/src/state.rs:55`; called by `pharos-web/src/lib.rs:307,329` (`serve_with_token`/`serve_ephemeral_with_token`, both serve paths) |
| web-real-sessions | real backend by default | `pharos-web/src/main.rs` default branch `real_app_state(...)`; `build_real_app_state` in `pharos-http/src/services/real.rs` |
| | `--fake` explicit | `main.rs` `#[arg(long)] fake`; fake branch → `persistent_app_state` + WARN |
| | data dir | one `--data-dir` with `env = "PHAROS_WEB_DATA_DIR"`; `PHAROS_DATA_DIR` legacy in `data_dir_from`; unit tests for priority |
| | token auth | `pharos-web/src/auth.rs` (`AuthToken`, `require_bearer`, `with_bearer_auth`), `validate_bind`; wired in `app_router_with_token` |
| | real S1/S2 | `services/real_thread.rs`, `services/real_session.rs`, builder in `services/real.rs` |
| thread-autoreply | Codex reply selection | `adapter-codex/src/reply.rs` (`inspect_turn_reply`, `final_answer_text`, `ReplyInspection`); `recorded_dispatch.rs` 8 tests |
| | reply sink | `agent-runtime/src/reply_sink.rs` (`HostReplySink`, `ThreadStoreReplySink`); wired via `mod reply_sink` + `use reply_sink::…` and `inspect_turn_reply` in `agent-runtime/src/main.rs` |
| | dsh plugin loop | `integrations/dsh-plugin-pharos/index.mjs`: `delivery.poll` → `delivery.ack injected` → `agent.followup(buildUserMessage(...))` → `delivery.ack consumed`; failure/archived → `failed`; `index.test.mjs` 18 tests |
| | driver capabilities | `pharos-adapter-dsh/src/adapter.rs:22` `RUNTIME_DRIVER_CAPABILITIES = &["delivery.poll","mesh.reply-once-v1"]` |

## G5. Findings / caveats (no blockers)

- **F-1 resolved.** Lead's `approvals_api = 9` was correct; my GO1 static regex counted 8 because the 9th test (`concurrent_decisions_resolve_exactly_once`) uses a flavored `#[tokio::test(...)]`. Runtime count on final HEAD = **9**.
- **F-2 (doc, low).** Historical HITL-PERSIST handoff paragraph still mentions Linux default `~/.local/state/pharos`; merged binary intentionally uses `$XDG_DATA_HOME/pharos` else `~/.local/share/pharos` (code + doc comments consistent). The Lead's final unified handoff should state the merged data-dir/env priority so the stale paragraph is not read as current behavior.
- **N-2 (info, confirmed live).** In default real mode (`--session-adapter none`) an authenticated approval POST durably resolves and then fails the downstream session dispatch with 502 `operationFailed`, reverting the durable decision → approval stays pending/retryable. Intended "never fake success" + "failed dispatch must not consume" semantics, not a regression; approvals can only be *resolved* through the web binary once a live adapter is configured.
- **Known/accepted:** `THREAD-AUTOREPLY-DONE` section absent from `docs/handoff.md` (Lead writes final unified handoff per instructions); not a merge failure.
- **Inherited non-blocking items (unchanged by merge, already documented by the streams):** no SQLite WAL/busy_timeout on the shared data dir (multi-process `SQLITE_BUSY` risk); `webui/transport.js` has no bearer-token support (token mode is API-only for the browser); reply retry can republish one duplicate WS frame. Live Codex/vendor E2E and real-room messaging were not run (not possible/not permitted here); Swift cannot be compiled on Linux and was not touched.
- No functional loss, no test weakening and no hand-spliced lock issue found. Test suite only grew (workspace total 222 passed; all pre-merge test files preserved byte-identically).

## G6. Verdict — PASS

Final HEAD `287a136` passes independent final verification: genuine 2-parent merge history (3 landings, no rebase/squash), clean tree apart from this untracked evidence file, `fmt`/`clippy -D warnings`/`test --workspace` all exit 0 with **222 passed / 0 failed / 0 ignored (57 suites)** independently reproduced, npm **18/18**, WebCanvas **3/3**, `diff -r` asset sync clean, black-box smoke **39/39** (real-mode approval durability across restart, fake-mode durable write, token/non-loopback 401/200/health matrix, no-token bind refusal, corrupt-store fail-loud), and all three streams' key capabilities present on the final HEAD. No blockers.

