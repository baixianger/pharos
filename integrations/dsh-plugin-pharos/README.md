# Pharos DSH Runtime Plugin

This plugin registers every live DSH `agent.session.id` as an independent
Pharos conversation. It polls the Rust Agent Runtime delivery queue over the
local JSON-RPC socket and uses `agent.followup()` for durable enqueue and
wakeup.

The Web process is only a container. Process IDs, display names, and tmux names
are never used as provider session identity. A delivery acknowledged as
`consumed` means DSH's durable inbox took ownership of the transport message;
it does not claim that an assistant turn completed.

## Delivery loop (PIT-DS-05)

`poll -> delivery.poll -> ack(injected) -> agent.followup(...) -> ack(consumed)`:

1. `delivery.poll` for the registered conversation. A missing conversation, an
   empty poll, or a failed poll is a no-op (returns `false`; nothing is acked).
2. ack `injected` before the handoff, best effort: a lost injected ack must not
   block the injection, and a crash after it must not re-inject blindly.
3. `agent.followup(buildUserMessage(deliveryText(payload)))`. Structured payloads
   render as `[Pharos Thread Message from <sender>]\n<body>`; anything else is
   injected verbatim.
4. ack `consumed` only after the durable inbox accepted the message. If
   `followup` throws (sync or async), or the `consumed` ack itself fails after a
   successful followup, the delivery is acked `failed` with a truthful detail
   instead, so it never strands at `injected` (the runtime only re-polls
   queued/accepted). A lost `failed` ack is logged and does not abort the poll.
   An archived session is acked `failed` without a followup.

The loop is exported as `handleDeliveryPoll(agent, binding, rpc, options)` so it
can be tested with a fake agent and RPC shim. `options.onError(message)` receives
last-resort `failed`-ack errors (default: stderr). `__testing` exposes the
helpers.

## Assistant reply write-back (`thread.reply`, approach B)

The delivery loop only takes ownership of the *inbound* message. The assistant's
answer is written back into the Thread by this plugin, which is the only layer
that can correlate an injected delivery with the DSH turn that answered it:

```text
followup(user message)
  -> agent/inbox/claimed            { message.id, turn }
  -> session/event assistant/message{ data.turn, data.message.content }
  -> session/event turn/end         { data.turn }
  -> thread.reply { room, asMember, text, messageId }
```

* The reply anchor (`room` + original `messageID`) is read from the structured
  delivery payload. Non-JSON payloads, or payloads without both fields, are
  never guessed at: no `thread.reply` is sent for them.
* `agent/inbox/claimed` maps the exact `buildUserMessage()` id that
  `agent.followup` injected to its turn. A claimed message the plugin did not
  inject is a normal human turn and is ignored.
* At `turn/end`, the **final answer of that turn** is sent **once** with
  `asMember` = the conversation member id (the session id) and `messageId` = the
  original delivery message id. Final-answer selection is the text of the last
  `assistant/message` event of that turn that has non-empty text (its text
  blocks, `content.filter(block => block.type === 'text')`, joined with a blank
  line); a later tool-call-only message keeps the earlier non-empty text. A
  multi-step turn therefore never concatenates narration/intermediate commentary
  into the reply, and reasoning/tool blocks never leak. An empty/absent assistant
  text logs an explicit error and sends nothing.
* `thread.reply` is retried at most 3 times on RPC failure (each attempt logged
  to stderr via `options.onError`); an exhausted retry is logged and never
  crashes the turn. The Rust runtime owns the stable `replyOnce` reply id, so a
  replayed `turn/end` or a retried RPC cannot duplicate the Thread row (a
  conflicting text for the same anchor is rejected by Rust, not overwritten).
* A delivery ack is unchanged by this path: `poll -> injected -> followup ->
  consumed` stays the delivery contract; `consumed` still does not claim
  assistant completion.

Approach B is additive and deliberately user-overridable: the Rust side is a
new `thread.reply` RPC (`thread-reply-v1` in `runtime.hello`) and the Rust DSH
adapter stays thin. The canonical alternative is the DSH mesh tool
(`pharos_mesh_send`); disabling write-back is just dropping the plugin's
`thread.reply` call, with no Rust change required.

Replay-safe callers must pass `messageId`. Omitting it is accepted by the RPC
but resolves the newest unreplied directed message server-side, so an identical
retried call need not return the same `replyId`.

## Driver capabilities

`registerDriver` advertises `message.send`, `session.observe`, `session.create`,
`delivery.poll`, and `mesh.reply-once-v1`. The rust runtime requires the last two
before it treats this plugin as the delivery consumer for a DSH session. The
reply write-back additionally needs the runtime's `thread-reply-v1` capability
(reported by `runtime.hello`); the plugin calls it directly and never fabricates
a successful write-back when the RPC is unavailable.

## Install

Install this package into the selected DSH profile, then add the row from
`cordis.patch.yml`. The package has no runtime dependencies: the runtime client
is local (`runtime-client.mjs`) and user messages are built locally, so it loads
without installing `@deepseek-ai/dsh-llm`.

        dsh plugin --profile web add file:/absolute/path/to/dsh-plugin-pharos
        # then add the row from cordis.patch.yml to the profile patch layer

## Tests

Zero dependencies, no network, no running Host Runtime:

        node --test
        # or: npm test

28 cases: the 18 delivery-loop/contract regressions plus thread reply
write-back coverage (exact `thread.reply` params from claimed turn + final-answer
text, multi-step final-answer selection, replayed `turn/end` dedupe, no
assistant text / no anchor skips, bounded RPC retries and exhausted-retry
logging, runtime-client param shape).
