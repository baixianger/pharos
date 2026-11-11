# Evidence — agent-runtime `thread.reply` RPC + DSH assistant reply write-back (approach B)

**Stream:** `rust/live-e2e` (task B: agent-runtime `thread.reply` RPC + dsh-plugin assistant reply write-back)
**Worktree:** `/workspace/pharos-rust/2026-11-11_dsh-wave2/wt/live-e2e` (branch `rust/live-e2e`, base `54c6ff6`)
**Host:** Linux (x86_64), no Swift/WebKit involved; Rust workspace under `rust/`, plugin under `integrations/dsh-plugin-pharos/`
**Node:** `v24.22.1`
**Date:** 2026-11-11 (UTC)

Commits (local only; no push / no rebase / no amend):

| Commit | Scope |
|---|---|
| `c43e985` | `feat(agent-runtime): thread.reply RPC for DSH reply write-back` |
| `dc42874` | `feat(dsh-plugin): write assistant answers back via thread.reply` |
| (this file) | `docs(evidence): thread.reply write-back evidence` |

`git status --porcelain` for the files this stream owns is empty at the evidence
commit; unrelated untracked files from other streams (`scripts/`,
`internal/evidence/2026-11-11_live-e2e-codex.md`) were never staged.

## Goal + selected approach (user-overridable)

Close the DSH loop: after an assistant turn completes, write the assistant's
answer back into the Thread as exactly one idempotent correlated reply.

**Selected approach B (documented as user-overridable):** the `dsh-plugin-pharos`
Node plugin — which already owns the vendor loop `delivery.poll -> ack(injected)
-> agent.followup -> ack(consumed)` — correlates the injected message with its
DSH turn and calls a **new additive Rust agent-runtime RPC `thread.reply`**.
`pharos-adapter-dsh` stays thin: no loop logic moved into the Rust adapter, no
reply posting there.

The RPC is additive and side-effect free unless called. **Override:** the
canonical alternative is the DSH mesh tool (`pharos_mesh_send`); disabling this
path is dropping the plugin's `thread.reply` call — no Rust change needed, the
existing Codex `ThreadStoreReplySink` relay is unaffected.

## Rust: `thread.reply` RPC (`rust/crates/agent-runtime/`)

Files: `src/thread_reply.rs` (new, all new logic; 10 unit tests), `src/main.rs`
(minimal wiring only: `mod thread_reply;`, Registry `thread_reply_store` field +
lazy-store `with_thread_data_dir` hook used by `Runtime::start`, capability
string, dispatch arm — diff +19/−2), `src/reply_sink.rs` (shared
`post_correlated_reply` helper + `#[cfg(test)] from_store`; existing Codex sink
behavior preserved, `ThreadError` handling now shared).

### Wire shape

Request params:

```json
{ "room": "room-name-or-id", "asMember": "member-id", "text": "assistant answer", "messageId": "original-message-id" }
```

`messageId` is optional in the JSON shape. Response mirrors the frozen
`pharos_api::ReplyThreadMessageResponse` exactly (`ok`, `thread`, `as`,
`replyId`, `replyTo`):

```json
{ "ok": true, "thread": "room-smoke", "as": "dsh-smoke-member",
  "replyId": "reply-<sha256>", "replyTo": "message-smoke" }
```

`ok: true` is only returned after the reply row persisted (no fabricated
success). `runtime.hello` advertises the new capability **`thread-reply-v1`**.

### Semantics / validation

- Lazy, refreshable store: the Host Thread replica under `--thread-data-dir`
  (web data dir convention: `<data-dir>/mesh/replica.sqlite3`) is opened on the
  first `thread.reply` call and re-resolved per call (`resolve_db_path`), so a
  `mesh/` created after runtime start is picked up rather than pinning a stale
  path. Loading the registry creates no DB.
- One idempotent reply via `pharos-thread::ThreadService::reply_message` /
  `replyOnce` stable id `(scope, room id, member, original message id)`:
  identical retry returns the **same** `replyId` and adds **no** second row.
- Conflicting `text` for the same `(room, member, messageId)` → `-32602`
  `reply conflict: <replyId> already exists ... refusing to overwrite` (never
  overwritten).
- Unknown room → explicit `Unknown thread/room: <room>` (-32602).
- Unknown `messageId`, or a message anchored in another room / not directed at
  `asMember` → explicit `messageId does not exist in that room, or it was not
  addressed to asMember` (-32602).
- Empty/whitespace `room` / `asMember` / `text`, or a blank/non-string
  `messageId` → explicit `must be a non-empty string` (-32602); `text` >
  `MAX_REPLY_BYTES` (1 MiB, the existing reply limit) → explicit error.
  Rejected calls never touch the store.
- `MemberNotFound` → deterministic join with `deterministic_nick(member)`
  (kind `"dsh"`; nick is display-only — unchanged existing `codex-…` prefix
  helper, shared with the Codex sink) then the same idempotent reply.
- `messageId` omitted: accepted, uses `pharos-thread`'s existing semantics
  (reply to the newest unreplied directed message) and returns the resolved
  anchor as `replyTo`. **Documented caveat:** omission is not replay-safe (a
  retried call can resolve the next unreplied message), so replay-safe callers
  must pass `messageId`; the DSH plugin always does.

## Node plugin: correlation + write-back (`integrations/dsh-plugin-pharos/`)

Files: `index.mjs` (`replyPlanFromPayload`, `createReplyRelay`,
`THREAD_REPLY_ATTEMPTS`, `handleDeliveryPoll` callback, `apply()` wiring for
`agent/inbox/claimed` + `session/event` + agent-dispose cleanup), `runtime-client.mjs`
(`threadReply({room, asMember, text, messageId})` → `call('thread.reply', …)`),
`index.test.mjs` (+10 tests), `README.md` (loop + override + caveats documented).

Flow:

```text
agent.followup(buildUserMessage(...)) accepted
  -> remember pending reply keyed by the injected buildUserMessage() id
     ({room, originalMessageID} only from structured payload JSON with non-empty
      room + messageID; otherwise nothing is remembered/guessed)
  -> agent/inbox/claimed { message.id, turn }
     -> map that exact followup message id to "<sessionID>:<turn>"
  -> session/event assistant/message { data.turn, data.message.content }
     -> remember the FINAL-ANSWER candidate: text blocks only
        (content.filter(b => b.type === 'text')), within one message joined "\n\n";
        the last message of the turn with non-empty text wins; a later
        tool-call-only message keeps the earlier non-empty text; narration /
        reasoning / tool blocks never leak; multi-step turns are NOT concatenated
  -> session/event turn/end { data.turn }
     -> exactly one thread.reply {room, asMember=session/member id, text,
        messageId=original delivery message id}, bounded retry (3 attempts,
        each failure logged), never thrown out of the event handler
```

Honesty / safety behavior:

- No anchor in payload, no assistant text, or a claim without a concrete
  session/turn anchor → explicit stderr/`onError` log, **no** `thread.reply`.
- A claimed message id the plugin did not inject (normal human turn) is ignored.
- Replayed `turn/end` does not duplicate the reply: the pending turn is drained
  synchronously before the RPC, and Rust's `replyOnce` id is idempotent anyway.
- Delivery ack semantics are unchanged: `poll -> injected -> followup ->
  consumed` (and their failed paths) are untouched; `consumed` still does not
  claim assistant completion.
- RPC failures are retried at most 3 times, logged per attempt, and an
  exhausted retry is logged as "the assistant text was not written back"; the
  event handler never crashes the loop.

### Correlation anchor — Lead question

The anchor is the **injected `buildUserMessage()` uuid**: after
`agent.followup` accepts that message, the plugin remembers it, then matches
`agent/inbox/claimed`'s `payload.message.id` against it and binds the claim's
`payload.turn` (scoped by `payload.agent.session.id`). This relies on DSH
preserving the `UserMessage.id` across append/claim (the DSH harness types show
`claimed.payload.message: UserMessage` with a stable `id`). **Not proven live
here:** the node tests simulate the event order with a fake agent/RPC shim; real
DSH Host E2E is task C. If the real run shows DSH mints/replaces the id, the
correlation will simply not fire (no fabricated reply) and the plugin logs
nothing for normal turns — that would need an id mapping change.

## Acceptance gates (exact commands/results)

All cargo commands serialized with the shared lock:

```sh
flock /tmp/pharos-livee2e-cargo.lock -c 'cd <worktree>/rust && CARGO_BUILD_JOBS=3 cargo <args>'
```

| Gate | Command | Result |
|---|---|---|
| Format | `cargo fmt --all -- --check` | **PASS** (exit 0, no diff) |
| Clippy | `cargo clippy -p pharos-agent-runtime -p pharos-adapter-dsh --all-targets -- -D warnings` | **PASS** (exit 0, no warnings) |
| Rust tests | `cargo test -p pharos-agent-runtime -p pharos-adapter-dsh` | **PASS** → `pharos-agent-runtime` **42 passed / 0 failed**, `pharos-adapter-dsh` **9 passed** lib + **1 passed** `product_roundtrip` integration, doc-tests 0 |
| Node tests | `cd integrations/dsh-plugin-pharos && node --test` (`npm test`) | **PASS** → **28 passed / 0 failed** (18 pre-existing delivery-loop/contract cases + 10 new) |
| Node syntax | `node --check index.mjs && node --check runtime-client.mjs && node --check index.test.mjs` | **PASS** |

New Rust unit tests (`thread_reply::tests`, 10): capability in `runtime.hello`;
idempotent replay → same `replyId`, one row, visible via `store.cli_read` with
`reply_to` pointing at the original; conflicting text rejected without
overwrite; empty/whitespace room/member/text + blank `messageId` + oversized
text rejected before touching the store; unknown room; unknown / cross-room
messageId; unknown member auto-join with deterministic nick then idempotent
replay; omitted-`messageId` store-anchor semantics + no-unreplied error; lazy
store open / later Host DB pickup (registry load creates no replica).

New node tests (10): runtime-client param shape (incl. omitted `messageId`);
payload-anchor parser; exactly one `thread.reply` with final-answer text only
(multi-step narration/interim ignored); tool-only last message keeps earlier
non-empty text; replayed `turn/end`/late `assistant/message` no duplicate; no
assistant text logged + not written; payload without room/messageID and
unclaimed human turn write nothing; claimed without session/turn anchor logged
and not guessed; transient RPC failure retried (2 fails → success, 3 attempts,
2 logs); exhausted retries bounded at 3, logged, no crash.

### Extra black-box smoke: real `pharos-meshd` binary over stdio

Built `cargo build -p pharos-agent-runtime` (`pharos-meshd`), seeded a temp
`<data-dir>/mesh/replica.sqlite3` (room `room-smoke`, human message
`message-smoke` directed at `dsh-smoke-member`, member not yet joined), then ran:

```sh
./target/debug/pharos-meshd --stdio --data-dir <tmp>/runtime --thread-data-dir <tmp>/mesh
```

with `runtime.hello`, two identical `thread.reply`, a conflicting `thread.reply`,
and an unknown-room `thread.reply`. Actual stdout:

```json
{"jsonrpc":"2.0","id":1,"result":{"capabilities":[...,"thread-reply-v1"],"protocolVersion":1,...}}
{"jsonrpc":"2.0","id":2,"result":{"as":"dsh-smoke-member","ok":true,"replyId":"reply-66057e81…c25f5","replyTo":"message-smoke","thread":"room-smoke"}}
{"jsonrpc":"2.0","id":3,"result":{"as":"dsh-smoke-member","ok":true,"replyId":"reply-66057e81…c25f5","replyTo":"message-smoke","thread":"room-smoke"}}
{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Invalid params: reply conflict: reply-66057e81…c25f5 already exists with different text; refusing to overwrite"}}
{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"Unknown thread/room: no-such-room"}}
```

SQLite after the run: exactly **2** rows — the original (`human-smoke`,
`reply_to=[]`) and one reply (`author_member_id=dsh-smoke-member`,
`reply_to_message_id=message-smoke`, text `smoke answer`); the auto-join
membership was created. Exit code 0, stderr empty. This independently proves
dispatch, capability, stable id, no duplicate row, conflict rejection, unknown
room, auto-join and persistence on the real binary (not just unit tests).

## Caveats / not verified

- **No real DSH Host E2E here.** The plugin tests drive a fake agent + RPC shim;
  the live `agent/inbox/claimed` message-id-preservation assumption (above) and
  real `session/event` ordering are task C's real-run proof. If DSH does not
  preserve the injected message id, correlation simply does not fire (nothing is
  fabricated).
- `--thread-data-dir` must be the Thread-replica directory (Host convention
  `<data-dir>/mesh`); how the supervisor/launcher passes it (and whether the web
  data dir and runtime share the same `replica.sqlite3`) is unchanged from the
  handoff open questions and was not verified with a real supervisor.
- DSH turn-end reasons other than `completed` (aborted/error/max-tokens/…):
  the plugin currently relays the last committed assistant text and logs the
  reason; it does not drop non-`completed` turns. Documented behavior, not
  exercised against a real DSH error turn.
- Multiple deliveries claimed into the same turn post the same final answer to
  each original message anchor (each with its own stable `replyOnce` id); the
  single-delivery case is what is tested.
- No WAL/busy_timeout on the shared SQLite replica (pre-existing limitation):
  concurrent writer contention from web/CLI is still possible.
- No changes to frozen `pharos-api`, `pharos-http`, `pharos-protocol`,
  `pharos-replica`, Swift/WebCanvas, `webui/`, `scripts/e2e/`, `docs/handoff.md`.
  No push, no tag.
