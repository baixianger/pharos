---
summary: rust/web-endpoints API contract — thread-session bindings, session config, extended approvals, member settings/avatars, attachments, stop/revive. Mounted by pharos-http::router; persisted under the Host data dir.
status: implementation-contract
date: 2026-11-11
---

# Web endpoints contract (rust/web-endpoints)

All routes are mounted under `api_router` / `app_router_with_token`, so the
existing bearer-token auth applies (`401` without token when configured).
Error bodies keep the frozen shape `{"error":{"code":...,...},"contractsVersion":"0.1.0"}`
(`PharosApiError` codes: `invalidRequest`, `sessionNotFound`, `threadNotFound`,
`approvalNotFound`, `conflict`, `operationFailed`, plus the new
`threadBindingNotFound` / `attachmentNotFound` / `memberNotFound` /
`unsupportedField` codes added as HTTP-layer extensions — see below).

## New error codes (HTTP layer extensions, additive)

These are **server-side extension codes**; the frozen `pharos-api` enum is not
modified. They serialize as the same `{"error":{"code":"..."}}` envelope:

- `threadBindingNotFound` — 404
- `attachmentNotFound` — 404
- `memberNotFound` — 404 (malformed/over-long member ids are 400 `invalidRequest`)
- `unsupportedField` — 502, body carries `field` + `message`; used when an
  adapter genuinely cannot apply a session configuration field or an operation.

## Persistence (all under the single Host `--data-dir`)

| File | Contents | Notes |
| --- | --- | --- |
| `thread-bindings.json` | `{"version":1,"bindings":[{threadId,member,sessionId,agentType?,boundAt}]}` | atomic temp+fsync+rename; corrupt file = startup error, never silently reset |
| `member-settings.json` | `{"version":1,"members":[{memberId,displayName?,model?,mode?,avatarShape?,avatarColor?,avatar?,updatedAt?}]}` | same atomic/corrupt semantics |
| `avatars/<sha256>.<png\|jpg>` | raw avatar bytes | referenced from `member-settings.json` |
| `attachments/index.json` | `{"version":1,"attachments":[{attachmentId,sessionId,filename,contentType,sizeBytes,sha256,createdAt}]}` | same |
| `attachments/<attachmentId>` | raw attachment bytes | id = 32 lowercase hex chars |

`pending-approvals.json` keeps its existing format/version; this stream only
adds optional `decision` value `"cancelled"` and `questionnaireAnswers` to
`StoredApproval` (additive, old records still load).

## 1. Thread ↔ session bindings

- `GET /api/v1/threads/{threadId}/bindings`
  → `200 {"bindings":[{"threadId","member","sessionId","agentType"?,"boundAt"}]}`
  (404 `threadNotFound` when the Thread does not exist; empty list otherwise)
- `GET /api/v1/threads/{threadId}/bindings/{member}`
  → `200 <binding>`; 404 `threadBindingNotFound`
- `PUT /api/v1/threads/{threadId}/bindings/{member}`
  body `{"sessionId":"..."}` → `200 <binding>` (upsert)
  - 404 `threadNotFound` — unknown Thread
  - 400 `invalidRequest` — blank `sessionId`, or `member` not matching
    `[A-Za-z0-9_-]{1,40}` (this is how the UI "add a Session member" flow names
    a brand-new member; the binding itself is that member's membership, so the
    member does **not** have to pre-exist in `ThreadSummary.memberIds`)
  - 404 `sessionNotFound` — session is not in the current Session inventory
- `DELETE /api/v1/threads/{threadId}/bindings/{member}`
  → `200 {"ok":true,"threadId","member","removed":true}`; 404 `threadBindingNotFound`
- `GET /api/v1/threads/{threadId}/members`
  → `200 {"members":[{memberId, nick, agentType?, machineId?, status?, sessionId?, boundAt?, settings: <MemberSettingsView>}]}`
  `nick` = member id unless a binding exists; `agentType/status` come from the
  bound session summary when available. Settings default to
  `{memberId, avatar:null}`.

The read-only binding surfaces are what delivery routing may consume; the
agent-runtime delivery code is **not** modified by this stream.

## 2. Session configuration

- `GET /api/v1/sessions/{sessionId}/config` → 200
  ```json
  {"sessionId":"...","supported":true,"supportedFields":["model","mode"],
   "model":"gpt-5","mode":"safe","models":["gpt-5"],
   "modes":[{"value":"safe","name":"Safe"},{"value":"yolo","name":"YOLO"}],
   "capabilities":{"attachments":false,"commands":false,"stop":false,"revive":false},
   "readonly":false}
  ```
  - 404 `sessionNotFound` — unknown session (also in the unconfigured real
    backend, where no sessions exist).
  - Adapters that cannot report configuration return
    `supported:false`, `supportedFields:[]`, `model:null`, `mode:null`,
    `models:[]`, `readonly:true` — an honest empty view, never invented values.
- `PATCH /api/v1/sessions/{sessionId}/config`
  body `{"model":"..."?, "mode":"safe"|"yolo"?}` → 200 same view
  - 404 `sessionNotFound`; 400 `invalidRequest` (empty patch, blank model,
    mode outside `safe|yolo`)
  - 502 `unsupportedField` with `{"field":"model","message":"..."}` when the
    configured adapter does not support that field. The field is **not**
    reported as saved.

## 3. Extended approval decisions (existing route, superset body)

`POST /api/v1/sessions/{sessionId}/approval`

body
```json
{"approvalId":"a1","decision":"allowedOnce|allowedAlways|rejected|cancelled",
 "questionnaireAnswers":[{"questionId":"q1","selected":["x"],"text":"..."}]}
```
`questionnaireAnswers` is optional (omit for plain approvals). `cancelled` is
the cancel-the-in-flight-turn decision.

response
```json
{"ok":true,"approvalId":"a1","state":"resolved","decision":"cancelled",
 "questionnaireAnswers":[...]?,"alreadyResolved":false}
```

Semantics (reuse `PendingApprovalStore`):
- 404 unknown approval; 400 session mismatch; 409 expired.
- idempotent first-wins: replay returns `alreadyResolved:true` with the
  effective decision/answers; a replayed different decision never overwrites.
- `cancelled` requires the approval's `availableChoices` to contain
  `"cancelled"` (400 `invalidRequest` otherwise) — the UI only offers it when
  the adapter announced it.
- questionnaire answers: each `questionId` must exist in
  `kind.questions`; each `selected` value must be one of that question's
  `options` when options are non-empty (400 `invalidRequest` otherwise). For a
  free-text question (`options: []`) `selected: []` + `text` is accepted.
  Answers are persisted alongside the decision.
- downstream session/adapter dispatch failure reverts the durable decision
  (same retryable semantics as today) — never a silent consumed decision.

## 4. Member settings / avatar

- `GET /api/v1/members/{memberId}` → 200
  ```json
  {"memberId":"grokbot","displayName":null,"model":null,"mode":null,
   "avatarShape":null,"avatarColor":null,
   "avatar":{"avatarId":"...","contentType":"image/png","sizeBytes":1234,"sha256":"...","updatedAt":"RFC3339"} | null,
   "bindings":[{"threadId":"...","sessionId":"..."}],
   "updatedAt":null}
  ```
  200 with empty settings for a valid-but-never-configured member (it is a
  settings view, not a claim that the member exists); malformed ids (empty,
  >64 chars, control chars, `/`) → 400 `invalidRequest`.
- `PATCH /api/v1/members/{memberId}` body
  `{"displayName"?,"model"?,"mode"?"safe"|"yolo","avatarShape"?,"avatarColor"?}`
  → 200 settings view. Empty patch / blank values / over-long values
  (displayName ≤80, model ≤120, shape/color ≤32) → 400 `invalidRequest`.
  Persisted; survives restart.
- `PUT /api/v1/members/{memberId}/avatar` body
  `{"contentType":"image/png"|"image/jpeg","dataBase64":"..."}`
  → 200 settings view with `avatar`. Decoded size must be 1..=524288 bytes;
  wrong type / bad base64 / oversize → 400 `invalidRequest`. Stored under the
  data dir; survives restart.
- `GET /api/v1/members/{memberId}/avatar` → 200 raw bytes with the stored
  `Content-Type`; 404 `attachmentNotFound` when no avatar is stored.
- `DELETE /api/v1/members/{memberId}/avatar` → `{"ok":true,"memberId"}`;
  404 `attachmentNotFound` when none.

## 5. Attachments

- `POST /api/v1/sessions/{sessionId}/attachments`
  body `{"filename":"notes.txt","contentType":"text/plain","dataBase64":"..."}`
  → 200 `{"attachmentId","sessionId","filename","contentType","sizeBytes","sha256","createdAt"}`
  - 404 `sessionNotFound` (also when the real backend has no adapter/session)
  - 400 `invalidRequest`: filename empty/`>255`/contains `/` `\` or control
    chars; contentType outside the allowlist
    (`text/plain`, `text/markdown`, `text/csv`, `application/json`,
    `image/png`, `image/jpeg`, `application/pdf`); decoded size 1..=10485760.
- `GET /api/v1/attachments/{attachmentId}` → 200 metadata; 404 `attachmentNotFound`
- `GET /api/v1/attachments/{attachmentId}/content` → 200 raw bytes
- `GET /api/v1/sessions/{sessionId}/attachments` → `{"attachments":[metadata]}`
- `POST /api/v1/sessions/{sessionId}/messages` also accepts optional
  `"attachmentIds":["..."]` (superset of the frozen `SendSessionMessageRequest`):
  ids are validated to exist and belong to the session; the service then
  either accepts them (fake in-memory service, for tests) or returns
  502 `unsupportedField` `{"field":"attachments", ...}` — never a fake success.
  Without `attachmentIds` the request is byte-identical to today.

## 6. Stop / revive

- `POST /api/v1/sessions/{sessionId}/stop` → `{"ok":true,"sessionId","status":"stopped"}`
- `POST /api/v1/sessions/{sessionId}/revive` → `{"ok":true,"sessionId","status":"idle"}`
- 404 `sessionNotFound` for unknown ids; 502 `unsupportedField`
  (`field: "stop" | "revive"`) when the configured adapter has no such
  capability. No adapter currently advertises it, so the real backend answers
  502 honestly (the UI surfaces the error and keeps the button disabled when
  `capabilities.stop/revive` are false).

## Front-end wiring (webui/ + WebCanvas, byte-identical)

`transport.js` replaces the `unavailable(...)` branches for these operations
with the routes above, populates `state.sessionConfiguration`,
`state.detail.{model,mode,models}`, `state.members`,
`state.threadBindingCandidates`, `state.canBindThreadSession`,
`state.supportsTextAttachments`, and keeps session *command* execution
unavailable (`capabilities.commands=false`). Capability-gated controls stay
disabled; an unsupported write surfaces the server error text. Identity
(shape/color) persists through `PATCH /api/v1/members/human`.

## File ownership (this stream)

- Lead: `rust/crates/pharos-hitl/`, `rust/crates/pharos-http/src/router.rs`,
  `rust/crates/pharos-http/src/services/{session.rs,approval.rs,session_config.rs}`,
  `rust/crates/pharos-http/tests/*`, `docs/`, `internal/evidence/`.
- Teammate A (server): `rust/crates/pharos-http/src/state.rs`,
  `rust/crates/pharos-http/src/services/{mod.rs,bindings.rs,member_settings.rs,attachments.rs,persist.rs,fake.rs,real_session.rs,real.rs}`,
  `rust/crates/pharos-web/src/lib.rs`, `rust/crates/pharos-web/tests/*` (own files).
- Teammate B (frontend): `webui/`, `Sources/Pharos/Resources/WebCanvas/`,
  `Tests/WebCanvas/`.
