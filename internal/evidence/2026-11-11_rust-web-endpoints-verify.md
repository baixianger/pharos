# Independent verification — `rust/web-endpoints` (frontend + backend HTTP surface)

- Verifier: teammate `frontend-impl` (independent of the server store/router author; wrote only this file and the frontend commits under verification)
- Worktree: `/workspace/pharos-rust/2026-11-11_dsh-wave2/wt/web-endpoints`
- Branch: `rust/web-endpoints`
- Verified code tree: **`f9d5a9d`** (`chore(hitl): rustfmt module ordering`). During verification HEAD advanced to `00dd178` (`docs(web-endpoints): gap-doc supersession + evidence (gates, real-binary smoke)`); `git diff --stat f9d5a9d..00dd178` shows only `docs/2026-11-11_wip-salvage-gaps.md` and `internal/evidence/2026-11-11_rust-web-endpoints.md`, so all results below apply to the HEAD code tree.
- Date: 2026-11-11; smoke run window 20:57 UTC
- Binary under test: `rust/target/debug/pharos-web` sha256 `a5b59641a6e5cf0106c38311e20891d93c16b1002bb7e8d0776c3731a79ee6b0`
- Verdict: **PASS** — all five gate groups green (frontend node tests, byte-identical assets, acceptance gates, real-binary black-box smoke, restart persistence). 77/77 smoke assertions passed; no panics; no suspicious behavior. No code was modified during verification.

---

## 1. Frontend / asset gates (repo root)

```bash
node --test Tests/WebCanvas/transport.test.mjs
diff -r webui Sources/Pharos/Resources/WebCanvas
cd rust && flock /tmp/pharos-web-endpoints-cargo.lock \
  -c 'CARGO_BUILD_JOBS=3 cargo test -p pharos-web --test asset_sync'
```

Results (exit codes captured directly, not through a pipe):

| Gate | Exit | Output |
| --- | --- | --- |
| `node --test Tests/WebCanvas/transport.test.mjs` | 0 | `tests 14 / pass 14 / fail 0 / cancelled 0 / skipped 0` (`duration_ms ~490`) |
| `diff -r webui Sources/Pharos/Resources/WebCanvas` | 0 | **no output** (directories byte-identical) |
| `cargo test -p pharos-web --test asset_sync` (serialized) | 0 | `test app_and_web_assets_are_identical ... ok` → `test result: ok. 1 passed; 0 failed; 0 ignored` |

The 14 node tests cover exactly the contract wiring: config load → `sessionConfiguration`/`detail.model|mode|models`/capabilities, honest `supported:false` view, thread members/bindings/unbound candidates, PATCH config (single-field body + in-flight state + 502 `unsupportedField`), PUT thread binding (+400 surfacing), PATCH `/members/human` avatar/reset + identity load on start, attachment upload then `attachmentIds` (plus capability-false refusal with no request), `questionnaireAnswers` + `cancelled` + unchanged plain-approval body, stop/revive 502 surfacing, session commands still unavailable, approvals snapshot/reconnect regression.

Note: the cargo command must run from `rust/` (there is no root `Cargo.toml`); the `asset_sync` test itself reads `webui/` relative to the repo root.

## 2. Acceptance gates (from `rust/`, serialized one at a time)

All run under `flock /tmp/pharos-web-endpoints-cargo.lock -c 'CARGO_BUILD_JOBS=3 <cmd>'`.

| Gate | Exit | Output |
| --- | --- | --- |
| `cargo fmt --all -- --check` | 0 | zero bytes of output (nothing to format) |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | `Finished dev profile`; **0** `warning` lines, no `error` |
| `cargo test --workspace` | 0 | 41 test binaries + 18 doc-test groups = 59 `test result:` lines; summed **301 passed, 0 failed, 0 ignored, 0 filtered out** |
| `cargo build -p pharos-web` | 0 | binary built at `rust/target/debug/pharos-web` (sha256 above) |

## 3. Real-binary black-box smoke (temp data dir + random high port)

Safety: `DATA=$(mktemp -d /tmp/pharos-web-verify.XXXXXX)`, `PORT=$((20000 + RANDOM % 20000))` → **27138**, `TOK=$(openssl rand -hex 16)` (32-hex, redacted here). `--fake` is the explicit fixture mode (seed `fake-thread-1` / `fake-session-1`), so Thread/Session data is in-memory by design while the new stores are file-backed. Never touched port 3080, `~/.dsh`, `ipc.sock`, `~/.gemini`, or any user data dir.

```bash
cd /workspace/pharos-rust/2026-11-11_dsh-wave2/wt/web-endpoints
./rust/target/debug/pharos-web --fake --data-dir "$DATA" --webui-dir "$PWD/webui" \
  --addr "127.0.0.1:$PORT" --token "$TOK"          # background
```

Smoke driver: `/tmp/verify-web-smoke.sh` (plain bash+curl+jq; asserts each response code/field). Result: **PASS=77 FAIL=0, exit 0**.

### 3.1 Auth matrix + static UI

| Check | Result |
| --- | --- |
| `GET /health` no token | 200 |
| `GET /workspace.html` no token | 200, body contains `grok-ui-mockup` (real WebCanvas page) |
| `GET /api/v1/members/human` no token | 401 |
| … with `Authorization: Bearer $TOK` | 200, `memberId:"human"` |
| … with `?token=$TOK` | 200 |

### 3.2 Endpoint roundtrip (all 200 unless noted)

- `PATCH /api/v1/members/human` `{"displayName":"Pai","model":"gpt-5","mode":"yolo","avatarShape":"hex","avatarColor":"magenta"}` → settings view echoes all five.
- `PUT /api/v1/members/human/avatar` `{"contentType":"image/png","dataBase64":<"hello world">}` → `avatar.sizeBytes=11`, 64-hex `avatar.sha256`.
- `GET /api/v1/members/human/avatar` → 200 `image/png`, bytes byte-identical to `hello world`.
- `GET /api/v1/sessions/fake-session-1/config` → `supported:true`, `capabilities.attachments:true`, `model:"fake-1"`.
- `PATCH /api/v1/sessions/fake-session-1/config` `{"mode":"yolo"}` → 200, response `mode:"yolo"`.
- `POST /api/v1/sessions/fake-session-1/stop` → 200 `{"ok":true,…, "status":"stopped"}`.
- `POST /api/v1/sessions/fake-session-1/attachments` `{"filename":"n.txt","contentType":"text/plain","dataBase64":"aGVsbG8="}` → 200 `attachmentId` = 32 lowercase hex, `sizeBytes:5`.
- `GET /api/v1/sessions/fake-session-1/attachments` → list contains the uploaded id.
- `GET /api/v1/attachments/{id}` → 200 metadata (sha256 64 hex); `GET …/content` → 200 bytes `hello`.
- `POST /api/v1/sessions/fake-session-1/messages` `{"text":"hi","attachmentIds":["<id>"]}` → 200 (fake adapter accepts).
- `PUT /api/v1/threads/fake-thread-1/bindings/grokbot` `{"sessionId":"fake-session-1"}` → 200 binding (`member:"grokbot"`, `sessionId:"fake-session-1"`); `GET …/bindings` lists it; `GET …/members` shows `grokbot` bound to `fake-session-1` and a per-member `settings` view.
- `GET /openapi.json` → 200 and lists all new paths (`threads/{threadId}/members`, `…/bindings/{member}`, `sessions/{sessionId}/config|stop|revive|attachments`, `attachments/{attachmentId}[/content]`, `members/{memberId}[/avatar]`).

### 3.3 Honest-failure probes (never fake success)

- `PATCH /api/v1/members/human` `{"mode":"turbo"}` → **400** `{"error":{"code":"invalidRequest",…}}`.
- `GET /api/v1/attachments/00000000000000000000000000000000` → **404** `attachmentNotFound`.
- `GET /api/v1/sessions/does-not-exist/config` → **404** `sessionNotFound`.

### 3.4 On-disk artifacts (before restart, temp dir)

```
<data-dir>/attachments/10428d61bf7e3d86ad1345fe78d8c4b0
<data-dir>/attachments/index.json
<data-dir>/avatars/b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9.png
<data-dir>/member-settings.json
<data-dir>/thread-bindings.json
```

`thread-bindings.json` (`version:1`) holds `{threadId:"fake-thread-1", member:"grokbot", sessionId:"fake-session-1", agentType:"fake", boundAt}`; `member-settings.json` holds `displayName/model/mode/avatarShape/avatarColor` + avatar metadata; `attachments/index.json` holds `{attachmentId, sessionId, filename:"n.txt", contentType:"text/plain", sizeBytes:5, sha256, createdAt}`. Avatar sha256 = sha256("hello world") = `b94d27b9…efcde9`, matching the 11 stored bytes.

### 3.5 Restart persistence (kill, same `--data-dir`, same token, same port)

- `/health` 200 after restart; API still 401 without token.
- `GET /api/v1/members/human` → `model:"gpt-5"`, `mode:"yolo"`, `avatarShape:"hex"`, `avatarColor:"magenta"`, `avatar.sha256` unchanged, `sizeBytes:11`; avatar bytes still `hello world`.
- `GET /api/v1/threads/fake-thread-1/members` → `grokbot` still bound to `fake-session-1` (binding persisted).
- `GET /api/v1/sessions/fake-session-1/attachments` → uploaded attachment id still listed (attachment index/bytes persisted).
- Fake in-memory Session config re-seeds to `mode:"safe"` after restart — expected, documented `--fake` behavior (Thread/Session fixtures are not durable; only approvals + the new web-endpoint stores are).
- Server log: no `panic`, no error frames; clean two-run startup.

## 4. Observations

1. **No blocking findings.**
2. Informational/cosmetic: the server emits the `pharos-web listening …` line twice per start (once from `main.rs` after state construction, once from the serve path). Harmless, pre-existing/duplicated log, not a behavior issue.
3. The extended approval `cancelled` + `questionnaireAnswers` route was **not** re-exercised over the real binary: `--fake` has no HTTP surface to seed a pending approval, and the domain is already covered by the committed Rust integration/unit tests and the node transport test asserting the exact POST body. Recorded as not-tested-by-smoke rather than a pass.
4. Cleanup: both server processes stopped (SIGTERM); temp data dir removed; no other files touched. `git status` clean for verifier (only this new evidence file).
