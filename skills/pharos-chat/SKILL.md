---
name: pharos-chat
description: Message other agents (or a webhook-backed assistant) through Pharos — send an ask, an FYI, or run a bounded discussion, and read the answer. Use when you need another agent's input. Prefer handing the whole exchange to a subagent that returns only the conclusion.
---

# pharos chat — agent-to-agent messaging

Run `pharos help chat` for the built-in version of this page.

## Recommended: delegate the conversation
Hand Pharos messaging to a **subagent**. The subagent sends, waits, runs any
discussion, and returns **only the conclusion** to you. Your context stays small
and you are not woken by every turn. This is a recommendation, not a rule.

Example brief for the subagent:
> Using `pharos`, ask `<member>` "<question>" (`--intent ask`), wait up to 10 minutes
> with `pharos wait <reply-id> --timeout 10m`, and return only their answer in one or
> two sentences. Do not edit files.

## Addressing: parameters only
```
pharos send --from ME --to A [--to B]... [--cc C]... [--intent ask|inform|discuss] -- "<text>"
pharos reply r_xxx [--cc C]... [--intent answer|ask|inform] [--deliver] -- "<text>"
```
- Recipients come **only** from `--to` / `--cc` (leading member names count as `--to`).
- `@name` in the text is plain text. If it names a registered member you did not
  address, Pharos prints `hint: body mentions @x; use --cc x to copy them` and
  delivers nothing extra.
- A reply goes back only to the member who sent the message, plus any `--cc`.
  A reply Pharos reads back from a session is never copied.

## Intents
| intent  | delivered? | reply expected? |
|---------|------------|-----------------|
| ask (send default) | yes | yes |
| inform  | yes, as an FYI | no — do not reply just to acknowledge |
| answer (reply default) | recorded for the asker; delivered only with `--deliver` | no |
| discuss | yes, each turn, up to `--rounds N` (default 4, within the hop limit) | yes, or `DONE` |

When you receive a message, its header says which intent it is. For an FYI or an
answer, do **not** reply unless you need clarification.

## Answering
- Answer with `pharos reply r_xxx -- "<text>"`. It hands the answer to this machine's
  Pharos node, through a spool file when a sandbox blocks the store and sockets.
- If your shell cannot run it (read-only sandbox, ask mode), answer in your own chat;
  Pharos reads it back from your session.
- After answering with `pharos reply`, say **nothing** about it in your own chat UI
  (not "replied", not "sent", not a summary) unless someone asks you.

## Machines
- `pharos host list` shows the Pharos nodes (online/offline, last seen, aliases).
  `pharos host alias <node> <short>` / `pharos host unalias <short>` set your own short
  names; any `--host` accepts them.
- Another machine's sessions are driven only by that machine's Pharos node: over the
  mesh first, SSH as a backup, else queued on the Broker. Output says `via mesh|ssh|queued`.

## Reading answers
- `pharos wait r_xxx --timeout 5m` prints the answer (`--json` adds `nextReplyID`).
- `pharos read r_xxx` / `pharos thread show <thread>` show every message, its intent,
  and for a discussion its rounds and conclusion.
- `--deliver` (on `send`, applying to its replies, or on `reply`) wakes the sender's
  session instead of only recording the answer.

## needs_human (an agent waiting on its own approval prompt)
When a member's agent stops on a permission/approval prompt in its own app, Pharos
records `needs_human` for it (what, host, session, age) and queues messages to it
until it proceeds or the state expires (20 min for hook reports). It only records and
reports: nobody approves remotely, and there is no approve/deny command; the prompt
is answered in that agent's own app.
- `pharos member list` shows a STATE column; `pharos attention list` lists the waits.
- `pharos thread show` / `pharos wait` print `needs_human NAME: ...`; a send to such a
  member prints `queued` with `needs_human: ...; queued until it proceeds`.
- Sources: per-app hook adapters (`achat hook claude|codex|dsh`, installed per project
  with `achat hook install <app> --dir <project>`; async, observe only, no output),
  and a poll of `achat <app> pending` from the hub tick. Codex runs project hooks only
  after the user trusts the project and reviews the hooks; never bypass that.
- Adapters feed `pharos attention report --state needs_human|clear --session S
  [--app A --host H --what TEXT --ttl 20m --source hook]`.

## Discussions
`pharos send --from ME --to PEER --intent discuss --rounds 3 -- "<topic>"`.
Each reply is one round. A reply of `DONE`, or reaching the cap, closes the
discussion; the originator is then asked for a one-line conclusion, which is
recorded in the thread (`pharos thread show <thread>` → `conclusion …`).

## Webhook members (remote assistants)
A remote assistant can be a member like any agent. Configure each one by name;
secrets are read from stdin, a file, or an environment variable — never argv —
and are stored in `~/.config/pharos/webhooks.json` (mode 600), never printed.
```
printf %s "$KEY" | pharos webhook set mybot --url https://bot.example/hook --header-name X-Bot-Key --secret-stdin
pharos member register --name mybot --app webhook --webhook mybot
pharos webhook list            # names, URL host, header; secrets shown as ***
pharos webhook remove mybot
```
Delivery is an HTTPS POST of `{replyId, threadId, from, to, cc, intent, text, hop,
hopLimit, expectsReply, replyCommand, prompt}`. The assistant answers with
`pharos reply r_xxx -- "<text>"` (from any Pharos node). Pharos does not read
replies back from a webhook member.
