# Grokbot Thread member E2E — 2026-11-10

## STATUS: GROKBOT-MEMBER-DONE

## What landed

- Member `grokbot` (display nick `Pharos`), webhook backend (not a local CLI Agent).
- Wake: POST ID-only `thread-mention` to `~/.config/pharos/human-proxy-webhook.env`
  (`Authorization: Bearer`). Payload keys: `kind`, `thread`, `message`, `from`, `host`.
- CLI: `pharos-mesh thread read` / `thread reply --as grokbot --text-file` → `replyOnce`.
- Honest Runtime states: webhook 2xx → `injected`; room `replyOnce` → `completed`; 45m → `failed`.

## Live run (pharos-msg-test)

| Field | Value |
|---|---|
| Thread | `grokbot-41349f97` |
| Directed message | `FEEC7B7B-BB0C-4AE6-8743-AE1ADC2E41F4` (`@Pharos` → target `grokbot`) |
| Injected delivery | `4f6afe55-03f7-4665-80c8-dbf1fd7e2721` |
| Reply | `reply-4c10d3ecd4cefa9e7ebfcd14c916ae9a13cb37475b3632bda29c45ffd3831952` |
| Marker | `PHAROS_GROKBOT_MEMBER_DONE_41349f97` |
| Runtime completed | `1` |
| Human-request | `~/personal/pharos-msg-test/human-requests/2026-11-10T132002Z_grokbot-thread-mention.md` |
| Mesh data-dir | `~/personal/pharos-msg-test/grokbot-member/41349f97/mesh` |

Second backend member present: `agy-stub` (identity only).

## Proof commands

```sh
PHAROS_GROKBOT_MEMBER_TEST=1 \
  swift test --filter GrokbotMemberLiveTests/testRealGrokbotThreadMentionReplyWhenEnabled
# unit: GrokbotThreadBridgeTests (3 passed)
# logs: internal/evidence/2026-11-10_grokbot-member-e2e.log
#       internal/evidence/2026-11-10_grokbot-unit.log
```

Idempotent re-reply returned the same `replyID`.

## Protocol

`docs/agents/grokbot/threads/2026-11-10_protocol.md`

## Matrix

`GB-THD-01` … `GB-THD-05` in `docs/BACKEND-MATRIX.md`
