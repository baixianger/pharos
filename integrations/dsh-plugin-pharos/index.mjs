import { randomUUID } from 'node:crypto'
import { PharosRuntimeClient } from './runtime-client.mjs'

export const name = 'dsh-plugin-pharos-runtime'
export const inject = ['agents']

// Capabilities advertised to the Rust Agent Runtime. 'delivery.poll' makes this
// driver the runtime's delivery consumer for each registered conversation, and
// 'mesh.reply-once-v1' is the reply-once/liveness contract the runtime's DSH
// binding inspection requires before it routes a thread message to a session.
export const DRIVER_CAPABILITIES = [
  'message.send',
  'session.observe',
  'session.create',
  'delivery.poll',
  'mesh.reply-once-v1',
]

// `consumed` is only ever reported after agent.followup accepted the message:
// DSH's durable inbox owns the delivery from then on, but no assistant turn
// completion is implied by this ack.
const CONSUMED_DETAIL = 'DSH durable inbox consumed the transport delivery; assistant completion is not implied.'
const ARCHIVED_DETAIL = 'session archived and cannot receive messages'

// Optional live-E2E diagnostics. Off by default; never prints prompt bodies.
const DEBUG_ENABLED = process.env.PHAROS_PLUGIN_DEBUG === '1'
function debug(message) {
  if (DEBUG_ENABLED) process.stderr.write(`dsh-plugin-pharos-runtime[debug]: ${message}\n`)
}

// Module-level default RPC used when a caller does not pass one. It is created
// lazily so importing this module never opens a socket. apply() passes its own
// client explicitly.
let defaultRuntimeClient
function runtimeRPC(method, params) {
  defaultRuntimeClient ??= new PharosRuntimeClient()
  return defaultRuntimeClient.call(method, params)
}

// Accept either a `(method, params) => Promise` shim (canonical plugin shape,
// easy to fake in tests) or a client exposing `call(method, params)`
// (PharosRuntimeClient).
function callRuntimeRPC(rpc, method, params) {
  if (typeof rpc === 'function') return rpc(method, params)
  if (rpc && typeof rpc.call === 'function') return rpc.call(method, params)
  return Promise.reject(new TypeError('runtime RPC must be a function or expose call(method, params)'))
}

// Fresh user message, mirroring the shape the canonical dsh-plugin-pharos
// injects. The session store snapshots and freezes it on append. Built locally
// rather than through @deepseek-ai/dsh-llm so this plugin loads with zero
// installed dependencies.
export function buildUserMessage(text) {
  return {
    id: randomUUID(),
    role: 'user',
    content: [{ type: 'text', text }],
    // DSH session format v4 rejects the retired generic `kind: 'plugin'`
    // wrapper: a user message must carry its producer-owned kind. The producer
    // kind for a third-party plugin is `plugin:<package name>` (dsh 0.2.2-rc.1
    // `SessionFormatError: format v4 message requires a producer-owned source
    // kind` when `plugin` is used).
    source: { kind: `plugin:${name}`, form: 'snapshot', sections: [{ name, text }] },
  }
}

// Backwards-compatible alias: earlier plugin versions called the constructor
// `userMessage`.
const userMessage = buildUserMessage

// Render one transport payload as the prompt injected into the session. A
// structured delivery contributes its body and sender; a payload that is not
// structured JSON (or has no string body) is passed through verbatim so no
// transport detail is invented for it.
export function deliveryText(payload) {
  let value = payload
  if (typeof payload === 'string') {
    try { value = JSON.parse(payload) } catch { return payload }
  }
  if (!value || typeof value !== 'object' || typeof value.body !== 'string') {
    return typeof payload === 'string' ? payload : JSON.stringify(payload)
  }
  const sender = typeof value.sender === 'string' && value.sender ? value.sender : 'human'
  return `[Pharos Thread Message from ${sender}]\n${value.body}`
}

function optionsArchived(options) {
  if (typeof options?.isArchived === 'function') return Boolean(options.isArchived())
  return Boolean(options?.archived)
}

function errorText(error) {
  return error == null ? 'unknown error' : String(error?.message ?? error)
}

// A failed ack is the last-resort way to stop a delivery from stranding as
// `injected`. If that request also fails we log it (or hand it to the caller's
// hook) and keep processing the poll: throwing would abort every remaining
// delivery in the same tick.
function reportDeliveryError(options, message) {
  if (typeof options?.onError === 'function') {
    try { options.onError(message) } catch {}
    return
  }
  process.stderr.write(`dsh-plugin-pharos-runtime: ${message}\n`)
}

// One delivery poll -> the canonical 4-stage ack loop:
//   delivery.poll
//   -> ack injected     (best effort; a lost injected ack must not block followup)
//   -> agent.followup(buildUserMessage(prompt))
//   -> ack consumed     (durable inbox took ownership; assistant completion is NOT implied)
// If followup throws, the delivery is acked failed with the error detail, so a
// delivery is never left looking injected/consumed when it was not handed off.
// The consumed ack is attempted inside the same try/catch: if it fails after a
// successful followup the delivery is also acked failed (with a detail saying
// the intake may have happened), because the runtime only re-polls
// queued/accepted and would otherwise strand the message as `injected` forever.
// An archived session is acked failed with no followup. Returns true when the
// poll returned pending deliveries, false when there was nothing to do or the
// poll itself failed (no ack is sent in that case).
export async function handleDeliveryPoll(agent, binding, rpc = runtimeRPC, options = {}) {
  const conversationID = typeof binding === 'string' ? binding : binding?.conversationID
  if (!conversationID) return false

  let pending
  try {
    pending = await callRuntimeRPC(rpc, 'delivery.poll', { conversationID })
  } catch {
    return false
  }
  if (!Array.isArray(pending) || pending.length === 0) return false

  for (const delivery of pending) {
    if (!delivery || delivery.id == null) continue

    if (optionsArchived(options)) {
      try {
        await callRuntimeRPC(rpc, 'delivery.ack', {
          deliveryID: delivery.id,
          state: 'failed',
          detail: options.archivedDetail || ARCHIVED_DETAIL,
        })
      } catch {}
      continue
    }

    // Record injected before handing off: a crash or a lost ack after this
    // point must not cause a blind re-injection.
    try {
      await callRuntimeRPC(rpc, 'delivery.ack', { deliveryID: delivery.id, state: 'injected' })
    } catch {}

    // Followup + consumed ack are one unit: a lost consumed ack means the
    // delivery must be closed as failed, never left at injected.
    let handedOff = false
    let injectedMessage
    try {
      injectedMessage = buildUserMessage(deliveryText(delivery.payload))
      // Correlate BEFORE the handoff. On a real DSH host an idle agent wakes
      // synchronously inside `agent.followup(...)`, so `agent/inbox/claimed`
      // (which binds the reply to its turn) can fire before followup returns.
      // A handoff that never lands is rolled back by `onFollowupFailed`, so this
      // reserves correlation without promising a reply.
      if (typeof options?.onFollowupStarted === 'function') {
        try {
          options.onFollowupStarted({
            messageID: injectedMessage?.id,
            payload: delivery.payload,
            memberID: String(binding?.sessionID || agent?.session?.id || agent?.id || ''),
            deliveryID: delivery.id,
            conversationID,
          })
        } catch (error) {
          reportDeliveryError(
            options,
            `delivery ${delivery.id}: reply correlation failed: ${errorText(error)}`,
          )
        }
      }
      const injected = agent.followup(injectedMessage)
      if (injected && typeof injected.then === 'function') await injected
      handedOff = true
      await callRuntimeRPC(rpc, 'delivery.ack', {
        deliveryID: delivery.id,
        state: 'consumed',
        detail: CONSUMED_DETAIL,
      })
    } catch (error) {
      if (!handedOff && typeof options?.onFollowupFailed === 'function') {
        try {
          options.onFollowupFailed(injectedMessage?.id)
        } catch {}
      }
      // Never claim success. The detail distinguishes "nothing was handed
      // off" from "the intake may already own it but the ack was lost".
      const detail = handedOff
        ? `followup accepted but consumed ack failed: ${errorText(error)}`
        : errorText(error)
      try {
        await callRuntimeRPC(rpc, 'delivery.ack', {
          deliveryID: delivery.id,
          state: 'failed',
          detail,
        })
      } catch (ackError) {
        reportDeliveryError(
          options,
          `delivery ${delivery.id}: failed ack also failed: ${errorText(ackError)}`,
        )
      }
    }
  }
  return true
}

// ─── Thread reply write-back (approach B) ────────────────────────────────────
//
// The DSH plugin owns the vendor loop, so it is also the only layer that can
// correlate an injected delivery with the assistant turn that answered it:
//
//   followup(user message)                     (delivery handoff)
//   -> agent/inbox/claimed { message.id, turn } (message opens/joins a turn)
//   -> session/event assistant/message { data.turn, data.message.content }
//   -> session/event turn/end { data.turn }
//   -> thread.reply { room, asMember, text, messageId }
//
// The Rust side (additive `thread.reply` RPC, capability `thread-reply-v1`)
// owns the stable replyOnce id, so a replayed turn/end or a bounded retry can
// never duplicate the Thread row. This is deliberately user-overridable: the
// canonical alternative is the DSH mesh tool (`pharos_mesh_send`); dropping
// this hook's `thread.reply` call disables write-back without touching Rust.
//
// Honesty rules: a reply is only posted when (a) the delivery payload named a
// room + original message anchor, (b) DSH claimed that exact followup message
// into a concrete turn, and (c) that turn produced non-empty assistant text.
// Anything else is logged explicitly and nothing is written.
//
// Final-answer selection: a DSH turn may commit several assistant messages (one
// per step: narration, tool-call steps, then the answer). The reply text is the
// text of the LAST assistant/message of the turn that has non-empty text — never
// a concatenation of intermediate narration — and a later tool-only message
// leaves the earlier non-empty text in place.

const REPLY_RPC_ATTEMPTS = 3
export const THREAD_REPLY_ATTEMPTS = REPLY_RPC_ATTEMPTS

// Extract the reply anchor from a delivery payload. Only structured JSON with a
// non-empty `room` and `messageID` (camelCase `messageId` accepted too) is
// correlatable; anything else is left alone so we never guess a room or anchor.
export function replyPlanFromPayload(payload) {
  let value = payload
  if (typeof payload === 'string') {
    try { value = JSON.parse(payload) } catch { return null }
  }
  if (!value || typeof value !== 'object') return null
  const room = typeof value.room === 'string' ? value.room.trim() : ''
  const raw = value.messageID ?? value.messageId
  const messageID = typeof raw === 'string' ? raw.trim() : ''
  if (!room || !messageID) return null
  return { room, originalMessageID: messageID }
}

// Text blocks of ONE assistant message, joined with a blank line. Non-text
// blocks (reasoning, tool calls, images) are never relayed. Empty/whitespace
// blocks are dropped.
function assistantMessageText(content) {
  return content
    .filter(block => block?.type === 'text')
    .map(block => String(block.text ?? ''))
    .filter(text => text.trim())
    .join('\n\n')
}

function turnKey(sessionID, turn) {
  return `${sessionID}:${turn}`
}

// Correlate injected deliveries -> assistant turns -> one `thread.reply` each.
// `rpc` is a `(method, params) => Promise` shim or a client exposing
// `call(method, params)`. `onError(message)` receives every skipped/failed
// write-back (default: stderr). Returning objects are exported for tests; the
// production wiring lives in apply().
export function createReplyRelay({ rpc, onError, maxAttempts = REPLY_RPC_ATTEMPTS } = {}) {
  const attempts = Number.isInteger(maxAttempts) && maxAttempts > 0 ? maxAttempts : REPLY_RPC_ATTEMPTS
  // followup user-message id -> { room, originalMessageID, asMember }
  const pendingByMessage = new Map()
  // "<sessionID>:<turn>" -> [{ room, originalMessageID, asMember }, ...]
  const pendingByTurn = new Map()
  // "<sessionID>:<turn>" -> final-answer text of the latest assistant message
  // with non-empty text (multi-step turns overwrite, never concatenate).
  const latestTextByTurn = new Map()

  function report(message) {
    if (typeof onError === 'function') {
      try { onError(message) } catch {}
      return
    }
    process.stderr.write(`dsh-plugin-pharos-runtime: ${message}\n`)
  }

  // Reserve a reply owed by a delivery about to be handed to DSH. Reserved
  // before `agent.followup(...)` because an idle DSH agent claims the message
  // synchronously; `onFollowupFailed` rolls it back when the handoff fails.
  function onFollowupStarted({ messageID, payload, memberID } = {}) {
    if (messageID === undefined || messageID === null) return false
    const plan = replyPlanFromPayload(payload)
    if (!plan) return false
    pendingByMessage.set(String(messageID), { ...plan, asMember: String(memberID ?? '') })
    debug(`reply reserved for delivery message ${messageID} room ${plan.room} anchor ${plan.originalMessageID}`)
    return true
  }

  // The followup never reached DSH: no assistant turn can own that message.
  function onFollowupFailed(messageID) {
    if (messageID === undefined || messageID === null) return false
    return pendingByMessage.delete(String(messageID))
  }

  // The followup message left the inbox inside turn N: remember which turn owes
  // the reply. A claimed message we did not inject is a normal human turn.
  function onClaimed({ messageID, sessionID, turn } = {}) {
    if (messageID === undefined || messageID === null) return false
    const pending = pendingByMessage.get(String(messageID))
    if (!pending) {
      debug(`claimed message ${messageID} has no reserved reply (normal human turn)`)
      return false
    }
    pendingByMessage.delete(String(messageID))
    debug(`claimed message ${messageID} -> session ${sessionID} turn ${turn}`)
    if (!sessionID || turn === undefined || turn === null) {
      report(`delivery message ${messageID} was claimed without a session/turn anchor; not writing a thread reply`)
      return false
    }
    const key = turnKey(sessionID, turn)
    const entries = pendingByTurn.get(key) ?? []
    entries.push({ ...pending, asMember: pending.asMember || String(sessionID), sessionID: String(sessionID), turn })
    pendingByTurn.set(key, entries)
    return true
  }

  async function deliver(entry, text) {
    const params = {
      room: entry.room,
      asMember: entry.asMember,
      text,
      messageId: entry.originalMessageID,
    }
    if (!params.room || !params.asMember || !String(params.text ?? '').trim() || !params.messageId) {
      report(`refusing to fabricate a thread reply (room=${params.room || '<empty>'} asMember=${params.asMember || '<empty>'} messageId=${params.messageId || '<empty>'})`)
      return false
    }
    let lastError
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        await callRuntimeRPC(rpc, 'thread.reply', params)
        return true
      } catch (error) {
        lastError = error
        report(`thread.reply attempt ${attempt}/${attempts} failed for room ${entry.room} message ${entry.originalMessageID}: ${errorText(error)}`)
      }
    }
    report(`thread.reply failed after ${attempts} attempts for room ${entry.room} message ${entry.originalMessageID}; the assistant text was not written back: ${errorText(lastError)}`)
    return false
  }

  async function deliverTurn(turn, pending, text) {
    if (!String(text ?? '').trim()) {
      report(`turn ${turn} ended without assistant text; not writing a thread reply for ${pending.length} delivery message(s)`)
      return false
    }
    const results = await Promise.all(pending.map(entry => deliver(entry, text)))
    return results.every(Boolean)
  }

  // Handle one committed session event. `assistant/message` only remembers text
  // for turns that actually owe a reply; `turn/end` drains and posts it.
  //
  // Final-answer selection: a DSH turn can have several steps (tool calls plus
  // narration), so the reply is the text of the LAST assistant/message event of
  // the turn that has non-empty text — a later tool-only step keeps the earlier
  // non-empty text instead of concatenating intermediate commentary/narration.
  //
  // Returns a promise for `turn/end` (awaitable in tests; the live handler
  // ignores it) and never rejects.
  function onSessionEvent(session, event) {
    try {
      const sessionID = String(session?.id ?? '')
      if (!sessionID || !event || typeof event.type !== 'string') return undefined
      const turn = event?.data?.turn
      const key = turnKey(sessionID, turn)
      if (event.type === 'assistant/message') {
        if (!pendingByTurn.has(key)) return undefined
        const content = event?.data?.message?.content
        if (!Array.isArray(content)) return undefined
        const text = assistantMessageText(content)
        if (text.trim()) latestTextByTurn.set(key, text)
        return undefined
      }
      if (event.type !== 'turn/end') return undefined
      const text = latestTextByTurn.get(key) ?? ''
      latestTextByTurn.delete(key)
      const pending = pendingByTurn.get(key)
      debug(`turn/end ${key}: ${pending?.length ?? 0} reserved reply(ies)`)
      if (!pending || pending.length === 0) return undefined
      pendingByTurn.delete(key)
      const endKind = event?.data?.reason?.kind
      if (endKind !== undefined && endKind !== 'completed') {
        report(`turn ${turn} ended with reason ${String(endKind)}; relaying its committed assistant text`)
      }
      return deliverTurn(turn, pending, text).catch(error => {
        report(`turn ${turn}: thread reply write-back failed: ${errorText(error)}`)
        return false
      })
    } catch (error) {
      report(`session/event handler failed: ${errorText(error)}`)
      return undefined
    }
  }

  // Drop correlation state for a disposed agent session (no leak on long runs).
  function onAgentDisposed(agentOrSessionID) {
    const sessionID = String(
      typeof agentOrSessionID === 'string'
        ? agentOrSessionID
        : (agentOrSessionID?.session?.id || agentOrSessionID?.id || ''),
    )
    if (!sessionID) return
    for (const [messageID, plan] of pendingByMessage) {
      if (plan.asMember === sessionID) pendingByMessage.delete(messageID)
    }
    const prefix = `${sessionID}:`
    for (const key of [...pendingByTurn.keys()]) if (key.startsWith(prefix)) pendingByTurn.delete(key)
    for (const key of [...latestTextByTurn.keys()]) if (key.startsWith(prefix)) latestTextByTurn.delete(key)
  }

  function pendingCounts() {
    return { messages: pendingByMessage.size, turns: pendingByTurn.size, texts: latestTextByTurn.size }
  }

  return {
    onFollowupFailed,
    onFollowupStarted,
    onClaimed,
    onSessionEvent,
    onAgentDisposed,
    pendingCounts,
    replyPlanFromPayload,
  }
}

export function apply(ctx) {
  const runtime = new PharosRuntimeClient()
  // Assistant-reply write-back: correlate delivery followups to their DSH turn
  // and post one idempotent `thread.reply` per turn (approach B). Errors are
  // logged to stderr and never break the delivery poll loop.
  const replyRelay = createReplyRelay({
    rpc: (method, params) => runtime.call(method, params),
    onError: message => process.stderr.write(`dsh-plugin-pharos-runtime: ${message}\n`),
  })
  const driverID = `dsh:${process.pid}`
  const conversations = new Map()
  const stateSequences = new Map()
  const lastStateReports = new Map()
  const registrations = new Map()
  let polling = false

  // dsh "archive" is a durable hide flag in the workspace registry
  // (archivedSessionIds), not process termination: an archived session can
  // still run in the background. Read the set directly so Pharos never
  // advertises an archived session as running/idle.
  function archivedSessionIDs() {
    const registry = ctx.get?.('workspaceRegistry')
    const ids = registry?.archivedSessionIds ?? []
    return new Set(Array.from(ids, String))
  }

  async function registerDriver() {
    await runtime.registerDriver({
      driverID,
      kind: 'dsh',
      version: process.env.DSH_VERSION || 'plugin',
      capabilities: DRIVER_CAPABILITIES,
    })
  }

  async function registerAgent(agent) {
    const sessionID = String(agent?.session?.id || agent?.id || '')
    if (!sessionID) return
    if (conversations.has(sessionID)) {
      await reportAgentState(agent, agent?.status || 'idle')
      return
    }
    if (registrations.has(sessionID)) {
      await registrations.get(sessionID)
      return
    }
    const registration = (async () => {
      const conversation = await runtime.registerConversation({
        driverID,
        vendorSessionID: sessionID,
        memberID: sessionID,
        kind: 'dsh',
        title: `DSH ${sessionID.slice(0, 8)}`,
        projectPath: agent?.session?.meta?.cwd,
      })
      conversations.set(sessionID, conversation.id)
      await reportAgentState(agent, agent?.status || 'idle')
    })()
    registrations.set(sessionID, registration)
    try { await registration } finally { registrations.delete(sessionID) }
  }

  async function reportAgentState(agent, rawStatus) {
    const sessionID = String(agent?.session?.id || agent?.id || '')
    const conversationID = conversations.get(sessionID)
    if (!conversationID) return
    const status = String(rawStatus)
    const archived = archivedSessionIDs().has(sessionID)
    const stateKey = status + '|' + (archived ? 'archived' : 'live')
    const previous = lastStateReports.get(sessionID)
    if (previous?.key === stateKey && Date.now() - previous.at < 30_000) return
    const sequence = (stateSequences.get(sessionID) || 0) + 1
    stateSequences.set(sessionID, sequence)
    await runtime.updateConversationState({
      conversationID,
      presence: archived ? 'offline' : 'online',
      activity: archived ? 'idle' : (rawStatus === 'running' ? 'running' : 'idle'),
      attention: 'none',
      persistence: archived ? 'archived' : 'persistent',
      source: 'nativeProtocol',
      sourceEpoch: driverID,
      sequence,
      vendorRawState: archived ? 'archived' : status,
    })
    lastStateReports.set(sessionID, { key: stateKey, at: Date.now() })
  }

  async function reconcile() {
    await registerDriver()
    for (const agent of ctx.agents.list()) await registerAgent(agent)
  }

  // Advertise the DSH agent-preset roster to the Host Runtime so a launcher can
  // discover launch modes through the runtime rather than hardcoding them. The
  // roster re-reads disk on every call (DSH discovery semantics), so throttle
  // to 30s: authoring a preset while running still surfaces within a moment.
  let optionsLastPushed = 0
  async function pushLaunchOptions() {
    const presets = ctx.get?.('agentPresets')
    if (!presets?.list) return
    try {
      const roster = await presets.list()
      const options = (Array.isArray(roster) ? roster : []).map(preset => ({
        id: preset.id,
        label: preset.name ?? preset.id,
        detail: preset.description ?? '',
        extraArgs: '',
      }))
      await runtime.launchOptions({ driverID, kind: 'dsh', options })
      optionsLastPushed = Date.now()
    } catch (error) {
      process.stderr.write(`dsh-plugin-pharos-runtime: launch options: ${error.message}\n`)
    }
  }

  // Consume queued launch requests (Pharos New Session -> runtime RPC). Each
  // request creates a fresh DSH session whose creation header records the preset
  // (meta.agentPreset) and whose scoped world mounts it via recompose during
  // unpublished setup — the same path the web app's agentPreset.select uses.
  //
  // The session id is reserved on claim and carried by the request record, so a
  // crash between claim and completion re-claims the SAME id instead of minting
  // a second session. agents.create is keyed by that caller-supplied sessionId,
  // so a re-claimed id that already exists is marked completed, not recreated.
  async function handleLaunchRequests() {
    const presets = ctx.get?.('agentPresets')
    if (!presets?.recompose || typeof ctx.agents?.create !== 'function') return
    let requests
    try { requests = await runtime.launchPoll('dsh') } catch { return }
    for (const request of requests ?? []) {
      const launchID = request.id
      const presetID = request.presetID || ''
      const projectPath = request.projectPath || undefined
      const sessionID = request.sessionID || randomUUID()
      const live = (ctx.agents.list?.() ?? []).some(agent =>
        String(agent?.session?.id || agent?.id || '') === sessionID)
      try {
        await runtime.launchAck({ launchID, state: 'accepted', sessionID })
        if (live) {
          // Created before a crash; the re-claimed request needs no second session.
          await runtime.launchAck({ launchID, state: 'completed', sessionID })
          continue
        }
        await ctx.agents.create({
          sessionId: sessionID,
          meta: { cwd: projectPath, ...(presetID ? { agentPreset: presetID } : {}) },
          setup: async (agentCtx) => {
            if (presetID) await presets.recompose(agentCtx, presetID)
          },
        })
        await runtime.launchAck({ launchID, state: 'completed', sessionID })
      } catch (error) {
        // A create collision means a prior attempt already made this session
        // (crash between create and ack) — mark it completed, not failed.
        const reclaimed = sessionID && /already (exists|registered)|duplicate/i.test(String(error?.message))
        await runtime.launchAck({
          launchID,
          state: reclaimed ? 'completed' : 'failed',
          detail: reclaimed ? 'reclaimed existing session' : error?.message,
          sessionID,
        })
      }
    }
  }

  async function poll() {
    if (polling) return
    polling = true
    try {
      await reconcile()
      if (optionsLastPushed === 0 || Date.now() - optionsLastPushed > 30_000) {
        await pushLaunchOptions()
      }
      await handleLaunchRequests()
      for (const agent of ctx.agents.list()) {
        const sessionID = String(agent?.session?.id || agent?.id || '')
        const conversationID = conversations.get(sessionID)
        if (!conversationID) continue
        // The runtime only returns pending deliveries, so a delivery that was
        // already acked (or vanished) is never followed up a second time here.
        await handleDeliveryPoll(agent, { conversationID, sessionID }, runtime, {
          isArchived: () => archivedSessionIDs().has(sessionID),
          onFollowupStarted: replyRelay.onFollowupStarted,
          onFollowupFailed: replyRelay.onFollowupFailed,
        })
      }
    } catch (error) {
      process.stderr.write(`dsh-plugin-pharos-runtime: ${error.message}\n`)
    } finally {
      polling = false
    }
  }

  ctx.on('agent/created', payload => registerAgent(payload?.agent || payload).catch(() => {}))
  // Reply correlation (approach B): `agent/inbox/claimed` tells us which turn
  // claimed the followup user message we injected; `session/event` carries the
  // turn's committed assistant text and its end. The relay only writes back for
  // deliveries that carried a room + original message anchor and produced text.
  ctx.on('agent/inbox/claimed', payload => {
    const agent = payload?.agent
    replyRelay.onClaimed({
      messageID: payload?.message?.id,
      sessionID: String(agent?.session?.id || agent?.id || ''),
      turn: payload?.turn,
    })
  })
  ctx.on('session/event', (session, event) => {
    void replyRelay.onSessionEvent(session, event)
  })
  ctx.on('agent/status', payload => {
    const agent = payload?.agent || payload
    reportAgentState(agent, payload?.status || agent?.status || 'idle').catch(() => {})
  })
  ctx.on('agent/disposed', payload => {
    const agent = payload?.agent || payload
    const sessionID = String(agent?.session?.id || agent?.id || '')
    const conversationID = conversations.get(sessionID)
    if (conversationID) {
      const sequence = (stateSequences.get(sessionID) || 0) + 1
      runtime.updateConversationState({
        conversationID, presence: 'offline', activity: 'idle', attention: 'none',
        persistence: 'persistent', source: 'nativeProtocol', sourceEpoch: driverID,
        sequence, vendorRawState: 'disposed',
      }).catch(() => {})
    }
    conversations.delete(sessionID)
    stateSequences.delete(sessionID)
    lastStateReports.delete(sessionID)
    registrations.delete(sessionID)
    replyRelay.onAgentDisposed(sessionID)
  })

  // Event-driven archive refresh: 'domain/changed' fires on every workspace
  // state write (create/delete/attach/reorder/archive). Filter to the
  // workspace-root put (table === '') and re-report live state, which reads
  // archivedSessionIds fresh. The 30s archive-aware dedup keeps this cheap.
  ctx.on('domain/changed', change => {
    if (change?.domain !== 'workspace' || change?.table !== '' || change?.operation !== 'put') return
    for (const agent of ctx.agents.list()) {
      reportAgentState(agent, agent?.status || 'idle').catch(() => {})
    }
  })

  ctx.effect(() => {
    const timer = setInterval(() => { void poll() }, 750)
    void poll()
    return () => clearInterval(timer)
  }, 'dsh-plugin-pharos-runtime.poll')
}

// Canonical-plugin style testing surface. Named exports stay name/inject/apply
// for the Cordis plugin contract; these helpers exist so the delivery loop can
// be exercised with a fake agent and RPC shim, without a running Host Runtime.
export const __testing = {
  ARCHIVED_DETAIL,
  CONSUMED_DETAIL,
  DRIVER_CAPABILITIES,
  THREAD_REPLY_ATTEMPTS,
  buildUserMessage,
  createReplyRelay,
  deliveryText,
  handleDeliveryPoll,
  replyPlanFromPayload,
  userMessage,
}
