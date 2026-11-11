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

## Driver capabilities

`registerDriver` advertises `message.send`, `session.observe`, `session.create`,
`delivery.poll`, and `mesh.reply-once-v1`. The rust runtime requires the last two
before it treats this plugin as the delivery consumer for a DSH session.

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
