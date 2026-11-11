# Independent review & verification — `rust/web-real-sessions`

- Reviewer: teammate `reviewer` (independent; did not edit `pharos-http/` or `pharos-web/` source)
- Worktree: `/workspace/pharos-rust/2026-11-11_dsh-team/wt/web-real-sessions`
- Branch: `rust/web-real-sessions`
- Base commit: `4e381a4`; verified HEAD: `dddcc00` (tree clean before this file was created)
- Commits reviewed: `98a241f`, `788c2c8` (pharos-http), `94177a7`, `3fc4826`, `6e3de9c`, `dddcc00` (pharos-web)
- Date: 2026-11-11 (CET), gates/smoke run ~15:36–15:47
- Verdict: **PASS** — all three gates green; independent binary E2E smoke passes; requirements 1–5 met. Non-blocking findings recorded in §5 (two medium, six low, two info).

---

## 1. Stage 1 — review of committed real S1/S2 services (`pharos-http`)

Files read in full: `src/lib.rs`, `src/router.rs`, `src/error.rs`, `src/state.rs`, `src/ws.rs`,
`src/services/{thread.rs,session.rs,mod.rs,real.rs,real_thread.rs,real_session.rs,event_bus.rs}`,
`tests/real_state_http.rs`, plus upstream `pharos-thread/src/store.rs`, `pharos-session/src/service.rs`,
`pharos-goals/src/store.rs`, `pharos-store-schema/src/lib.rs`.
Diff vs base inspected with `env -u GIT_CONFIG_COUNT -u GIT_CONFIG_VALUE_0 git diff 4e381a4 --stat`.

Checks and outcome:

- **Router shape**: only the two permitted appends exist — `POST /api/v1/threads` and
  `POST /api/v1/sessions` (`router.rs:22,29` + handlers `router.rs:54-60,118-124`). No existing route,
  path, response shape or middleware was changed. ✅
- **Real Thread service** (`real_thread.rs`): backed by `SqliteThreadStore`; no fake data. Sends are
  guarded by `get_thread` first, so a send can never implicitly create a missing Thread (404 instead,
  `real_thread.rs:100-114`); default identity `human`/`Human` is explicit
  (`real_thread.rs:28-30,44-54`); `threadMessageReceived` published on send and found reply
  (`real_thread.rs:69-73,116-133`). `replyOnce` semantics preserved via the store's deterministic reply
  id: same member+target+text is idempotent, different text is `409 Conflict`
  (`store.rs` `reply_once_inner`, `real_thread.rs:203-205`).
- **Error mapping** (`real_thread.rs:191-211`, `error.rs:18-31`): `NotFound→404`, `InvalidRequest→400`,
  `Conflict→409`, `Store/adapter→502`. Matches the fixed HTTP contract. ✅
- **Real Session service** (`real_session.rs`): `unconfigured` mode is honest — list `[]`, get/history
  404, send/steer/approval/create return explicit `operationFailed` (502) with a message naming
  `--session-adapter` (`real_session.rs:32-34,112-225`); upstream `resolve_approval` also fails
  explicitly rather than faking. Live mode wraps `AdapterSessionService` and bridges events to the WS
  bus (`real_session.rs:227-262`). No fabricated sessions/turns. ✅
- **Data-dir layout** (`real.rs:91-123`): `<data-dir>/mesh/replica.sqlite3` (pharos-thread) and
  `<data-dir>/mesh/goals.sqlite3` (pharos-goals via `open_goals_db(mesh_dir)`); matches
  `pharos-store-schema::paths::{MESH_DIR, REPLICA_DB}`. No fakes are ever constructed in
  `build_real_app_state`. ✅
- **Persistence**: covered by `tests/real_state_http.rs` (create→send→reply→rebuild state same dir→data
  present) and re-verified independently by my binary smoke (§4 A/B). ✅
- **Thread-id validation** (`real_thread.rs:170-188`): trimmed, non-empty, ≤120 chars, no control
  chars, `400` on violation. Sufficient (id is only a room name, never a path). ✅
- **Panic risk**: store/session lock poisoning is mapped to errors, not `unwrap` (`store.rs::lock`,
  `real_session.rs:104-108`). The only `expect` in routers is `serde_json::to_value(...).expect("serialize")`
  on contract DTOs (practically infallible, pre-existing).
- **Fake-service boundary**: fakes remain only in `services/fake.rs`, are used only when explicitly
  requested (`--fake`) or by tests; `build_real_app_state` never references them. ✅

## 2. Stage 2 — review of `pharos-web` auth / wiring / tests

Files read in full: `src/auth.rs`, `src/lib.rs`, `src/main.rs`, `Cargo.toml`, `tests/real_sessions.rs`
plus existing `tests/acceptance.rs`, `tests/asset_sync.rs`; diff `4e381a4..HEAD` inspected.

- **Constant-time compare** (`auth.rs:59-79`): XOR fold over `max(len)` with the length XOR folded into
  the same accumulator, so mismatch position and length difference both contribute. Correct for
  empty/long/prefix cases (unit tests `matches_*`, `constant_time_eq_*` are genuine). ✅
- **401 semantics** (`auth.rs:86-140`): API routes without/with wrong token return `401` +
  `{"error":{"code":"unauthorized","message":"missing or invalid bearer token"}}`; `Bearer` scheme
  case-insensitive; `?token=` accepted (needed by browser WS); `/health` bypassed by exact path match
  (`routes::HEALTH == "/health"`, verified in `pharos-api/src/lib.rs:23`). ✅
- **No token leakage**: `AuthToken` Debug redacts (`auth.rs:64-68`); `main.rs:112-119` logs
  `auth=<bool>` and never the token; smoke greps the server log for the token → 0 occurrences (§4 E). ✅
- **Static assets unauthenticated**: the bearer layer is applied to the API router before `"/"` and the
  static fallback are appended (`lib.rs:94-107`); axum applies layers only to routes existing at
  `.layer()` time, and the smoke confirms `GET /` = 307→200 without a token while
  `GET /api/v1/threads` = 401 (§4 E). This is by design (page loads, API 401s). ✅
- **Non-loopback cannot bypass** (`lib.rs:126-134,197-209`): `validate_bind` refuses non-loopback
  without a token, and `serve_with_token` re-validates before binding (defense in depth); the CLI
  validates again (`main.rs:73`). Smoke D shows exit 1 + clear message. ✅
- **Data dir default** (`lib.rs:136-182`): `PHAROS_WEB_DATA_DIR` → macOS
  `~/Library/Application Support/Pharos` → Linux `$XDG_DATA_HOME/pharos` else
  `~/.local/share/pharos`; missing HOME is a clear error. Verified live with XDG override (§4 F) and by
  unit tests. ✅
- **CLI** (`main.rs`): `--addr` default `127.0.0.1:8787`; `--data-dir`/`PHAROS_WEB_DATA_DIR`;
  `--fake` (explicit, logs a `WARN` that data will not persist); `--token`/`PHAROS_WEB_TOKEN` (blank →
  config error); `--session-adapter none|codex` parsed with clear error; real services by default;
  warnings for non-loopback/unspecified binds. Arg/env plumbing matches the stream requirements. ✅
- **`tests/real_sessions.rs` (dddcc00)**: reviewed line by line — it uses
  `build_real_app_state` + real ephemeral HTTP servers (no `fake_app_state`), asserts no
  fake-thread-1/fake-session-1 seeds, honest 502 on session actions with a message naming
  `--session-adapter`, create→send→reply→abort→reopen same data dir→persistence, and auth
  401/401/200/200 + public `/health`/static. Assertions are real, not tautological. A short SQLite
  reopen retry loop is used after abort (pragmatic; see finding L-3 note). It is a good independent
  integration test. ✅ (Gaps it does not cover are listed in §6.)

---

## 3. Gates (`rust/`) — independently run, exact results

All commands run from `rust/` in the assigned worktree; no source edits by reviewer.

### 3.1 `cargo fmt --all -- --check`
```
$ env -u GIT_CONFIG_COUNT -u GIT_CONFIG_VALUE_0 cargo fmt --all -- --check
(no output)  FMT_EXIT=0
```

### 3.2 `CARGO_BUILD_JOBS=3 cargo clippy --workspace --all-targets -- -D warnings`
```
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 25.70s
CLIPPY_EXIT=0
```
(No warnings emitted; full log `/tmp/review-clippy.log`.)

### 3.3 `CARGO_BUILD_JOBS=3 cargo test --workspace`
```
TEST_EXIT=0    (all `test result: ok`, 0 failed, 0 ignored)
```
Per-crate counts (parsed from the run; target→package mapped via `cargo test --no-run --message-format=json`):

| crate | passed |
|---|---|
| pharos-web | 26 (21 lib + 1 acceptance + 1 asset_sync + 3 real_sessions) |
| pharos-http | 21 (17 lib + 4 real_state_http) |
| pharos-agent-runtime | 11 |
| pharos-adapter-cursor | 10 |
| pharos-adapter-dsh | 8 |
| pharos-hitl | 8 |
| pharos-codex-adapter | 6 |
| pharos-adapter-agy | 5 |
| pharos-api | 5 |
| pharos-grokbot | 5 |
| pharos-thread | 5 |
| pharos-iroh | 4 |
| pharos-replica | 4 |
| pharos-protocol | 3 |
| pharos-agent-core | 2 |
| pharos-goals | 2 |
| pharos-mesh | 2 |
| pharos-session | 2 |
| pharos-store-schema | 2 |
| pharos-cli | 0 |
| **TOTAL** | **131 passed, 0 failed, 0 ignored** (doc-tests all 0) |

Cross-check of impl-web's claim: `cargo test -p pharos-web` → exactly 21 lib + 1 acceptance + 1
asset_sync + 3 real_sessions = **26 passed**. `cargo test -p pharos-http` → 17 lib + 4
real_state_http = **21 passed**. Claims CONFIRMED.

`git status --short --branch` before creating this file: `## rust/web-real-sessions` (clean). After
creating this file: only `?? internal/evidence/2026-11-11_rust-web-real-sessions-review.md`.

---

## 4. Independent binary E2E smoke (`target/debug/pharos-web`)

Environment: built binary `rust/target/debug/pharos-web` (`CARGO_BUILD_JOBS=3 cargo build -p pharos-web`
exit 0), free 127.0.0.1 ports, `--data-dir` under `mktemp -d /tmp/pharos-review-smoke.XXXXXX`, run from
the repo root so `webui/` resolves. All servers killed afterwards (no stray processes).

### A. Default (real) mode, fresh temp `--data-dir`
| request | result |
|---|---|
| `GET /health` | `200 {"ok":true,"contractsVersion":"0.1.0","service":"pharos-meshd"}` |
| `GET /api/v1/threads` | `200 []` (no fake-thread-1) |
| `GET /api/v1/sessions` | `200 []` (no fake-session-1) |
| `GET /api/v1/threads/fake-thread-1` | `404 {"error":{"code":"threadNotFound",...}}` |
| `GET /api/v1/sessions/fake-session-1` | `404 {"error":{"code":"sessionNotFound",...}}` |
| `POST /api/v1/threads {"threadId":"review-thread","memberIds":["human","grokbot"]}` | `200 {"threadId":"review-thread","title":"review-thread","memberIds":["grokbot","human"],...}` |
| `POST .../review-thread/messages {"text":"evidence","targetMemberIds":["grokbot"]}` | `200 {"id":"b99c05d5-…","senderId":"human","text":"evidence"}` |
| `GET .../review-thread/messages` | `200`, 1 message |
| `POST .../review-thread/reply {"asMember":"grokbot","text":"ack","messageId":"b99c05d5-…"}` | `200 {"ok":true,"replyId":"reply-d1b678d8…","replyTo":"b99c05d5-…"}` |
| `GET .../review-thread/messages` | `200`, 2 messages (human + grokbot, correlated `replyTo`) |

Data dir after writes: `mesh/replica.sqlite3` + `mesh/goals.sqlite3`. Startup log:
`pharos-web using real durable S1/S2 services … session_adapter="none"`, `fake=false`.

### B. Kill + restart the binary with the SAME `--data-dir`
- `GET /api/v1/threads` → `200 [{"threadId":"review-thread",...}]`
- `GET /api/v1/threads/review-thread` → `200`
- `GET /api/v1/threads/review-thread/messages` → `200`, 2 messages with the **same ids** as before the
  restart (`b99c05d5-…`, `reply-d1b678d8…`). **Persistence proven at binary level.**

### C. Explicit `--fake` (same data dir, fresh port)
- `GET /api/v1/threads` → `200 ["fake-thread-1"]`
- `GET /api/v1/sessions` → `200 ["fake-session-1"]`
- `GET /api/v1/threads/fake-thread-1` → `200`
- startup log contains `WARN pharos-web --fake: using in-memory FakeThreadService + FakeSessionService;
  data will NOT persist`, `fake=true`. Fake data appears only when explicitly requested.

### D. Non-loopback bind without a token must refuse to start
```
$ timeout 10 pharos-web --addr 0.0.0.0:<port> --data-dir <tmp>
EXIT_CODE=1
Error: "refusing to bind non-loopback address 0.0.0.0:33365 without a token; pass --token/PHAROS_WEB_TOKEN or bind a loopback address"
```

### E. Token auth (`--addr 0.0.0.0:<port> --token review-secret`)
| request | result |
|---|---|
| `GET /health` (no token) | `200` |
| `GET /api/v1/threads` (no token) | `401 {"error":{"code":"unauthorized","message":"missing or invalid bearer token"}}` |
| `GET /api/v1/threads` (wrong `Bearer`) | `401` |
| `GET /api/v1/threads` (`Authorization: Bearer review-secret`) | `200` (sees persisted `review-thread`) |
| `GET /api/v1/threads?token=review-secret` | `200` |
| `GET /` (static UI, no token) | `307` → followed `200` |
| server log occurrences of `review-secret` | **0** (no token leakage) |

### F. Default data dir (no `--data-dir`; `XDG_DATA_HOME=<tmp>/xdg`, `HOME=<tmp>/home`)
- `GET /api/v1/threads` → `200 []`
- created `$XDG_DATA_HOME/pharos/mesh/replica.sqlite3` + `$XDG_DATA_HOME/pharos/mesh/goals.sqlite3`;
  startup log `data_dir=<tmp>/xdg/pharos`. Default-dir behavior confirmed.

Note (process honesty): sections A–E ran in one script; that script stopped after E because its
`set -e` intersected with `wait` returning the killed server's non-zero status. Section F was re-run
separately with identical assertions. No servers were left running; no source files were touched.

---

## 5. Findings / risks (none blocks acceptance)

### MEDIUM

1. **Real Thread/Session timestamps are not RFC3339 → the browser renders “Invalid Date”.**
   Observed over real HTTP: `GET .../messages` →
   `"timestamp":"1794411586.349847555"`, `GET /api/v1/threads` →
   `"lastActivityAt":"1794411586.380928277"` (vs fake/contract-style `"2026-11-10T00:00:00Z"`).
   `webui/workspace.js:254` does `new Date(message.timestamp)`, and `node -e` confirms
   `new Date("1794411586.380928277")` → `Invalid Date`, so every real thread message renders an
   "Invalid Date, Invalid Date" divider (and the thread's last-activity date is unusable).
   Root cause: `rust/crates/pharos-thread/src/store.rs:717-729` (`format_ts`) intentionally emits
   `"{secs}.{nanos:09}"` with a "S4 may pretty-print" TODO — pre-existing S1 code, now user-visible
   because the default path is real. Not fake data (honest), but a contract/UI defect. Minimal fix:
   format RFC3339 in `format_ts` (or map timestamps in `RealThreadService`). *Not fixed by reviewer.*
2. **Shared SQLite stores have no WAL/busy-timeout; default macOS data dir is the daemon layout.**
   `pharos-thread` opens `replica.sqlite3` with no `journal_mode=WAL`/`busy_timeout`
   (`rust/crates/pharos-thread/src/store.rs:70-83`); `pharos-goals` only sets
   `PRAGMA foreign_keys` (`rust/crates/pharos-goals/src/store.rs:17-37`). `real.rs:91-123` opens them
   under the default data dir (macOS: same `…/Pharos/mesh/` layout the app/daemon uses), so a
   concurrently running Pharos app/daemon and `pharos-web` can hit `SQLITE_BUSY` / `database is locked`.
   Not introduced by these commits, but the real web path now opens the shared store by default.
   Recommendation: WAL + `busy_timeout` in the stores, or a dedicated web data dir. Risk only when two
   processes share one data dir.
3. **Live-adapter session calls block a tokio worker while holding a `std::sync::Mutex`.**
   `RealSessionService` holds `Mutex<AdapterSessionService>` (`real_session.rs:40`) and performs the
   whole sync adapter call inside the async method; upstream `send_message` calls
   `adapter.wait_turn(..., Duration::from_secs(180))` (`pharos-session/src/service.rs:169-231`), so with
   `--session-adapter codex` a single prompt can block a runtime worker for up to 180 s and serialize
   concurrent session requests. Only affects live-codex mode (not exercised here; no codex CLI); not a
   fake-success issue. Recommendation: `spawn_blocking` / dedicated thread for adapter waits.

### LOW

1. **Unconfigured `progress` returns `200 {goal:null,todos:[]}` for any unknown session id**
   (`real_session.rs:183-200`) while `get_session`/`list_history` return 404 for the same id — an
   inconsistent "not found" signal (no fake data is fabricated; low honesty/consistency gap). No test
   covers it.
2. **`create_thread` is not atomic and is not strictly idempotent-as-documented.**
   Room + sender membership are created before `memberIds` validation, so a request with an empty/invalid
   member entry returns `400` *after* the Thread already exists (`real_thread.rs:135-154`). Also the doc
   says an existing id is "returned as-is", but `join_member` still mutates memberships of an existing
   thread (`real_thread.rs:140-153`). Cosmetic/data-hygiene, low.
3. **Retrying a successful `reply` republishes a duplicate `threadMessageReceived` WS event**
   (`real_thread.rs:116-133` always lists + publishes when the store returns the idempotent reply).
   Clients that retry could briefly duplicate the frame; harmless if clients dedupe by message id.
4. **`AuthToken::new` accepts leading/trailing whitespace but the header parser can never match it.**
   `auth.rs:40-46` only rejects blank tokens; `auth.rs:111-121` splits the header on whitespace, so a
   token configured as `--token " abc "` is unusable via `Authorization` (query `?token=` would still
   match exactly). Trivial foot-gun; suggest rejecting/trimming surrounding whitespace.
5. **`--fake` still resolves the data dir, and silently ignores `--session-adapter`.**
   `main.rs:60-63` computes a data dir before the fake branch, so `--fake` can fail with "HOME is not
   set…" although fake mode needs no data dir; `main.rs:87-94` parses but does not use
   `--session-adapter` under `--fake` (only the generic fake warning is logged). Cosmetic/UX.
6. **Web UI has no bearer-token support, so token mode is only usable by non-browser clients.**
   `webui/transport.js:11-13` `fetch()` and `:84` `new WebSocket(.../api/v1/events)` send no token;
   with `--token` (mandatory for non-loopback) the page loads but every API/WS call is 401. The
   requirement only asks for minimal server-side auth (implemented + tested), so this is a recorded
   scope gap rather than a gate failure — but the remote UI is not functional as-is.

### INFO

1. `?token=` in URLs can leak through logs/proxies/referrer; accepted trade-off for browser WebSocket
   auth and documented in `auth.rs`; current server does not log request URLs with query strings.
2. `list_projects` returns `Ok([])` although the project registry is not wired (`real_session.rs:202-206`).
   Empty is honest-ish ("invent nothing") and matches the UI's needs, but an explicit unavailable error
   would be a stronger honesty signal.

---

## 6. Requirement mapping and untested areas

| # | Requirement | Verdict |
|---|---|---|
| 1 | Default binary uses real durable Thread/Session services; honest unavailability; fakes only tests/`--fake` | ✅ (code + tests + smoke A/B/C) |
| 2 | CLI/env data dir (default under user data dir; temp dirs in tests), default bind 127.0.0.1, non-loopback requires bearer token | ✅ (main.rs/lib.rs tests; smoke D/E/F) |
| 3 | Router routes work with real services; integration test on real server with temp dir, restart → data still there | ✅ (`tests/real_state_http.rs`, `tests/real_sessions.rs`; smoke A/B) |
| 4 | Hard honesty: unsupported ops explicit error/unavailable, never fake success | ✅ (real_session unconfigured paths; smoke 404/502; no fake-success path found) |
| 5 | Gates fmt/clippy/test + clean `git status` | ✅ fmt=0, clippy=0, test 131 passed/0 failed; tree clean (only this evidence file untracked) |

Not exercised / residual gaps:
- WebSocket `?token=` auth path (HTTP query token is tested; WS shares the same middleware but no WS
  auth test exists).
- Non-loopback-refuse-to-start and `--fake` behavior are only covered by this binary smoke, not by
  automated tests.
- HTTP-level 400 (invalid threadId) / 409 (reply conflict) mapping: covered at service level by
  `real_thread.rs` unit tests, not over HTTP.
- Live `--session-adapter codex` path (no codex CLI available; deliberately not attempted).
- Unconfigured session `progress` for unknown ids (finding L-1).
- True concurrent multi-process access to the default macOS data dir (finding M-2) — architectural risk,
  not reproducible in this Linux sandbox.

## 8. Artifacts / reproduction
- Gate logs (scratch, not committed): `/tmp/review-clippy.log`, `/tmp/review-test.log`,
  `/tmp/test-artifacts.json`.
- Smoke transcript/scratch: `/tmp/review-smoke.log`, script `/tmp/review_smoke.sh`,
  data dirs `/tmp/pharos-review-smoke.*/` (server logs inside).
- This evidence file is the reviewer's only worktree write:
  `internal/evidence/2026-11-11_rust-web-real-sessions-review.md`.

## 7. Addendum — final HEAD 494435f

Re-verification of `494435f fix(web-real-sessions): RFC3339 timestamps + review follow-ups`
(on top of `dddcc00`; working tree clean except this untracked evidence file). Short re-check only,
as requested — the full Stage-2 gates are being run by the Lead in parallel.

**Diff reviewed** (`git show 494435f`, 7 files, +197/−17):
- `pharos-http/src/services/real_thread.rs`: new `normalize_timestamp` converts the store's
  `"<secs>.<nanos>"` to RFC3339 (pass-through for already-RFC3339/unparsable values) and is applied in
  `list_threads`, `get_thread`, `list_messages`, `send_message`, reply-event lookup and `create_thread`;
  `create_thread` now validates every `memberId` **before** `ensure_room` (no half-created room);
  trait doc clarified. Unit tests `normalize_timestamp_formats_store_epoch_as_rfc3339`,
  `api_timestamps_are_rfc3339`, `invalid_member_id_does_not_create_thread`.
- `pharos-web/src/auth.rs`: `AuthToken::new` trims surrounding whitespace (blank still rejected) +
  `new_trims_surrounding_whitespace_so_headers_work`.
- `pharos-web/src/main.rs`: `--fake` now warns when `--data-dir`/`PHAROS_WEB_DATA_DIR` or a non-`none`
  `--session-adapter` is ignored.
- `pharos-web/tests/real_sessions.rs`: real-mode `timestamp` asserted as RFC3339.
- `pharos-http/Cargo.toml` + `Cargo.lock`: add `time` (workspace dep).

**Focused tests** (independently run, `rust/`, `CARGO_BUILD_JOBS=3`):
```
$ cargo test -p pharos-http -p pharos-web        # TEST_EXIT=0
pharos_http  lib:   20 passed / 0 failed
real_state_http:     4 passed / 0 failed
pharos_web   lib:   22 passed / 0 failed
pharos_web   main:   0 passed
acceptance:          1 passed
asset_sync:          1 passed
real_sessions:       3 passed
=> pharos-http 24 (20+4), pharos-web 27 (22 lib + 1 acceptance + 1 asset_sync + 3 real_sessions)
```
Matches the expected counts exactly. `cargo build -p pharos-web` → exit 0 (`Finished … in 4.76s`).

**Focused runtime re-check** (fresh `mktemp -d` data dir, free 127.0.0.1 ports, binary built at
494435f, servers killed and temp dir removed afterwards):
- `POST /api/v1/threads` → `200`, `lastActivityAt:"1970-01-01T00:00:00Z"`; `POST .../messages` →
  `200`, `"timestamp":"2026-11-11T15:52:01.77811098Z"` — contains `T`, ends `Z`;
  `node new Date(...)` → `VALID_ISO=2026-11-11T15:52:01.778Z` (no longer `Invalid Date`).
- `GET /api/v1/threads/recheck-thread` → `lastActivityAt:"2026-11-11T15:52:01.77811098Z"`, same
  RFC3339 shape, node-valid.
- Invalid memberIds: `POST /api/v1/threads {"threadId":"bad-member-thread","memberIds":["human","   "]}`
  → `400 {"error":{"code":"invalidRequest","message":"memberIds must not contain empty entries"}}`,
  and `GET /api/v1/threads` → `["recheck-thread"]` only — **no half-created `bad-member-thread`**
  (fix (b) confirmed over HTTP).
- Kill + restart SAME `--data-dir`: message persists with identical id `4d520f43-…`, count 1,
  `timestamp:"2026-11-11T15:52:01.77811098Z"` still RFC3339/node-valid; `lastActivityAt` likewise.
  Data dir contains `mesh/replica.sqlite3` + `mesh/goals.sqlite3`.

**Regression assessment**: MEDIUM-1 is fixed at the API boundary (webui `new Date(...)` now receives
valid RFC3339); LOW fixes for non-atomic `create_thread`, padded-token handling and `--fake` warnings
are present. Residual known-and-unchanged items: reply retry still republishes a duplicate WS frame;
`--fake` still resolves the default data dir before the fake branch (warning only); MEDIUM-2
(SQLite WAL/busy-timeout on the shared data dir) and MEDIUM-3 (live codex adapter blocking a worker)
are untouched/out of scope; webui still has no token support. None of these blocks acceptance.

**Verdict at 494435f: PASS** (focused re-check; no source edits, no commits, no stray processes).
