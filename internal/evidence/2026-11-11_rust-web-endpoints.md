# rust/web-endpoints — evidence (2026-11-11)

Branch `rust/web-endpoints`, worktree `/workspace/pharos-rust/2026-11-11_dsh-wave2/wt/web-endpoints`,
base `integrate/mesh2-into-main @ 54c6ff6` (= `rust/integrate-dsh3`, includes
hitl-persist / web-real-sessions / thread-autoreply). No push, no force, no
rebase/amend, no history rewrite. Other worktrees / the main checkout were not
modified.

## What was added

Contract: `docs/2026-11-11_web-endpoints-api.md`. Gap-doc update:
`docs/2026-11-11_wip-salvage-gaps.md` (new "Update 2026-11-11 — web workspace
endpoints" section supersedes the "Unavailable workspace operations" lines).

1. **Thread ↔ session bindings** — durable `thread-bindings.json` (versioned,
   atomic temp+fsync+rename, corrupt file = hard error), routes
   `GET/PUT/DELETE /api/v1/threads/{id}/bindings[/{member}]` and
   `GET /api/v1/threads/{id}/members` (replica members ∪ bound members + durable
   settings). The binding list is the read surface delivery routing can consume;
   agent-runtime delivery code was not modified.
2. **Session configuration** — `GET/PATCH /api/v1/sessions/{id}/config`
   (model/mode, supportedFields, capabilities). Honest semantics: adapters that
   cannot report configuration return an empty `supported:false` view; adapters
   that cannot apply a field return `502 unsupportedField` with `error.field`
   and the field is never reported as saved. (No current adapter advertises
   writable config, so the real backend answers honestly; the fake test service
   exercises the success path.)
3. **Extended approval decisions** — `pharos-hitl` gained `StoredDecision`
   (`+ cancelled`) and `QuestionnaireAnswer`, both persisted inside the existing
   `pending-approvals.json` (version stays 1; old records still load). The
   existing `POST /api/v1/sessions/{id}/approval` body became a wire-compatible
   superset (`questionnaireAnswers` optional, `cancelled` decision). First-wins
   idempotency, 45m expiry and revert-on-failed-dispatch semantics are reused.
4. **Member settings / avatars** — `GET/PATCH /api/v1/members/{id}` and
   `GET/PUT/DELETE /api/v1/members/{id}/avatar`. Settings + avatar bytes persist
   under the data dir (`member-settings.json`, `avatars/<sha256>.<png|jpg>`),
   survive restart; avatar limited to png/jpeg and 512 KiB.
5. **Attachments** — `POST /api/v1/sessions/{id}/attachments` (base64 JSON,
   allowlisted content types, 10 MiB decoded cap), metadata/content/list reads,
   and optional `attachmentIds` on `POST /sessions/{id}/messages` (superset of
   the frozen request, so old bodies are unchanged). Adapters that cannot
   consume attachments answer `502 unsupportedField` — no fake success.
6. **stop/revive** — `POST /api/v1/sessions/{id}/stop|revive`; no adapter
   advertises the capability, so the real backend answers
   `502 unsupportedOperation` (fake service exercises the success path).
7. **OpenAPI** — all new paths are in the `/openapi.json` output (additive; the
   frozen `pharos-api` stub/contract was not modified).
8. **Front end** — `webui/` and `Sources/Pharos/Resources/WebCanvas/` (byte
   identical; `asset_sync` green) load config/roster/identity/attachments and
   dispatch the writes; previously-unavailable buttons now call the new routes,
   capability-gated controls stay disabled, and every failure surfaces the
   server error text. Session commands and project creation remain honestly
   unavailable. No `.swift` file was changed (Swift not compiled on Linux).

## Files / crates

- `rust/crates/pharos-hitl/`: `src/decision.rs` (new), `src/approval_store.rs`,
  `src/lib.rs`.
- `rust/crates/pharos-http/`: `src/error.rs` (extension error codes),
  `src/router.rs` (single route block + openapi additions),
  `src/web_routes.rs` (new handlers), `src/services/session.rs` (capability
  trait extension), `src/services/approval.rs` (extended resolve),
  `src/services/{persist,bindings,member_settings,attachments}.rs` (new durable
  stores), `src/services/{mod,state,real,real_session,fake}.rs` (wiring),
  `tests/web_endpoints.rs` (new HTTP gate).
- `rust/crates/pharos-web/`: `src/lib.rs` (both modes wire file-backed stores),
  `tests/web_endpoints_e2e.rs` (new real-server gate).
- `webui/`, `Sources/Pharos/Resources/WebCanvas/`, `Tests/WebCanvas/transport.test.mjs`.
- Docs: `docs/2026-11-11_web-endpoints-api.md` (new),
  `docs/2026-11-11_wip-salvage-gaps.md`, `docs/handoff.md`.

## Gates (final code HEAD, run in `rust/`, `CARGO_BUILD_JOBS=3`)

- `cargo fmt --all -- --check` → exit 0.
- `cargo clippy --workspace --all-targets -- -D warnings` → exit 0, 0 warnings.
- `cargo test --workspace` → exit 0, **301 passed / 0 failed / 0 ignored,
  59 suites** (doc-tests 0). Key new/expanded counts: pharos-hitl lib 27
  (+8: decision model + store cancelled/answers/legacy-JSON tests), pharos-http
  lib 79 (+37 store/handler unit tests), `tests/web_endpoints.rs` 14 (new),
  pharos-web lib 31, `tests/web_endpoints_e2e.rs` 6 (new), asset_sync 1.
- `node --test Tests/WebCanvas/transport.test.mjs` → 14 passed / 0 failed.
- `diff -r webui Sources/Pharos/Resources/WebCanvas` → no output (byte identical).

## Real-binary black-box smoke (Lead, not part of cargo gates)

`cargo build -p pharos-web`; `./target/debug/pharos-web --fake --data-dir
<mktemp> --addr 127.0.0.1:39319 --token <random>` from repo root (temp dir only;
no 3080 / user data / `~/.dsh` touched). Observed:

- `/health` 200 and `/workspace.html` 200 without token; API 401 without token,
  200 with `Authorization: Bearer` and with `?token=`; token appears 0 times in
  server logs.
- PATCH member (displayName/model/mode/avatarShape/avatarColor) 200; avatar PUT
  200 (`sha256`/`sizeBytes` returned); avatar GET returns exact bytes +
  `Content-Type: image/png`; after kill + restart on the same data dir the
  settings and avatar bytes are still there.
- Session config GET/PATCH 200; stop 200 `status=stopped`, revive 200
  `status=idle`.
- Attachment upload 200 (sha256/size), message with `attachmentIds` 200;
  after restart the attachment index still lists it.
- Binding PUT 200 (`agentType`, `boundAt`); thread members lists the bound
  member with `sessionId` + persisted member settings.
- Honest errors: PATCH member mode `turbo` → 400 `invalidRequest`; unknown
  attachment → 404 `attachmentNotFound` (extension envelope +
  `contractsVersion:0.1.0`); unsupported adapter writes covered by automated
  tests (502 `unsupportedField`/`unsupportedOperation`).
- Data dir after restart: `attachments/<id>`, `attachments/index.json`,
  `avatars/<sha256>.png`, `member-settings.json`, `thread-bindings.json`.

Independent verification (gates re-run + node tests + real-binary smoke) by
teammate `frontend-impl` is recorded in
`internal/evidence/2026-11-11_rust-web-endpoints-verify.md`.

## Not done / not verified

- No real vendor adapter advertises session config writes, attachment message
  intake, or stop/revive, so those real-backend paths are honest 502s (only the
  explicit `--fake` test service exercises success). Real Codex/DSH end-to-end
  for these capabilities was not attempted (live vendor streams own that).
- Session **command execution** (`/…` commands) and project creation remain
  without endpoints; the UI keeps them unavailable instead of faking.
- Swift ClientKit models for the new endpoints were not added; Swift is not
  compilable on this Linux box (no `.swift` file was touched).
- A partially-failed multi-file attachment upload can leave earlier uploaded
  blobs in the data dir (no attachment DELETE endpoint); the message send is
  still not reported as sent.
- `pharos-api` frozen contract enum was deliberately not modified; extension
  error codes (`unsupportedField`/`unsupportedOperation`/`threadBindingNotFound`/
  `attachmentNotFound`/`memberNotFound`) live in the HTTP layer.
- Real WebKit/browser rendering of the new controls was not verified on macOS
  (Linux box); only node `vm` tests + Rust HTTP/e2e.
