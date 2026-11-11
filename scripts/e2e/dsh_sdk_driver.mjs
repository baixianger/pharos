#!/usr/bin/env node
// Real DSH end-to-end driver for the Pharos Thread loop (task C).
//
// Boots an isolated DSH SDK-profile app (newline-delimited JSON-RPC on stdio),
// creates one session, waits until the repo DSH plugin (`integrations/dsh-plugin-pharos`)
// registered that session as a live delivery conversation on the Rust agent
// runtime, sends a real Thread message through the pharos-web HTTP API, submits
// the member-routed delivery on the runtime socket, and then verifies:
//
//   thread message -> delivery -> dsh plugin followup -> real assistant turn
//   -> plugin calls `thread.reply` -> exactly one correlated Thread reply
//
// It never fabricates a result: every assertion is checked against the real
// HTTP thread replica and the real DSH session-event notifications, and the
// assistant text written back must equal the assistant text DSH produced.
//
// Modes:
//   PHAROS_E2E_DSH_PROBE_ONLY=1  boot + create session + wait for plugin
//                                registration, print a snapshot, exit (no model turn)
//
// Env (required): PHAROS_E2E_SANDBOX, PHAROS_RUNTIME_SOCKET, PHAROS_WEB_URL, DSH_HOME
// Env (optional): PHAROS_DSH_BIN, PHAROS_DSH_PROFILE, PHAROS_E2E_DSH_PROMPT,
//                 PHAROS_E2E_DSH_TIMEOUT_MS, PHAROS_E2E_DSH_SESSION_ID
// Exit codes: 0 pass, 1 assertion/failure, 2 configuration
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import readline from 'node:readline'

const LOG = []
function log(message) {
  const line = `${new Date().toISOString()} ${message}`
  console.error(line)
  LOG.push(line)
}

function must(name) {
  const value = process.env[name]
  if (!value) {
    console.error(`dsh_sdk_driver: missing env ${name}`)
    process.exit(2)
  }
  return value
}

const SANDBOX = must('PHAROS_E2E_SANDBOX')
const RUNTIME_SOCKET = must('PHAROS_RUNTIME_SOCKET')
const WEB_URL = must('PHAROS_WEB_URL').replace(/\/+$/, '')
const DSH_HOME = must('DSH_HOME')
const DSH_BIN = process.env.PHAROS_DSH_BIN || 'dsh'
const DSH_PROFILE = process.env.PHAROS_DSH_PROFILE || 'pharos-e2e'
const PROMPT = process.env.PHAROS_E2E_DSH_PROMPT || '只回复 PONG'
const PROBE_ONLY = process.env.PHAROS_E2E_DSH_PROBE_ONLY === '1'
const TURN_TIMEOUT_MS = Number(process.env.PHAROS_E2E_DSH_TIMEOUT_MS || 240_000)
const STAMP = Date.now()
const SESSION_ID = process.env.PHAROS_E2E_DSH_SESSION_ID || `pharos-e2e-session-${STAMP}`
const THREAD_ID = `e2e-dsh-thread-${STAMP}`
const HUMAN_MEMBER = 'human-e2e'
const LOG_DIR = path.join(SANDBOX, 'logs')
const EVENT_LOG = path.join(LOG_DIR, 'dsh-session-events.jsonl')
const RESULT_FILE = path.join(SANDBOX, 'dsh-e2e-result.json')

fs.mkdirSync(LOG_DIR, { recursive: true })
fs.writeFileSync(EVENT_LOG, '')

function recordEvent(selector) {
  fs.appendFileSync(EVENT_LOG, `${JSON.stringify(selector)}\n`)
}

// ---------------------------------------------------------------------------
// Runtime JSON-RPC over the local Unix socket (one request per connection).
// ---------------------------------------------------------------------------
function runtimeCall(method, params = {}, timeoutMs = 30_000) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(RUNTIME_SOCKET)
    let buffer = ''
    const timer = setTimeout(() => {
      socket.destroy()
      reject(new Error(`runtime RPC timed out: ${method}`))
    }, timeoutMs)
    socket.setEncoding('utf8')
    socket.on('connect', () => {
      socket.write(`${JSON.stringify({ jsonrpc: '2.0', id: method, method, params })}\n`)
    })
    socket.on('data', (chunk) => {
      buffer += chunk
      const index = buffer.indexOf('\n')
      if (index === -1) return
      const line = buffer.slice(0, index)
      clearTimeout(timer)
      socket.end()
      try {
        const message = JSON.parse(line)
        if (message.error) reject(new Error(`runtime RPC ${method} failed: ${message.error.message}`))
        else resolve(message.result)
      } catch (error) {
        reject(error)
      }
    })
    socket.on('error', (error) => {
      clearTimeout(timer)
      reject(error)
    })
  })
}

async function waitForRuntime(timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs
  let lastError
  while (Date.now() < deadline) {
    try {
      return await runtimeCall('runtime.hello', {}, 2_000)
    } catch (error) {
      lastError = error
      await sleep(250)
    }
  }
  throw new Error(`runtime socket never became ready: ${lastError?.message}`)
}

// ---------------------------------------------------------------------------
// pharos-web HTTP API
// ---------------------------------------------------------------------------
async function http(method, route, body) {
  const response = await fetch(`${WEB_URL}${route}`, {
    method,
    headers: body === undefined ? undefined : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) {
    throw new Error(`HTTP ${method} ${route} -> ${response.status}: ${text.slice(0, 500)}`)
  }
  return text ? JSON.parse(text) : null
}

async function waitForHealth(timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs
  let lastError
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${WEB_URL}/health`)
      if (response.ok) return
      lastError = new Error(`health ${response.status}`)
    } catch (error) {
      lastError = error
    }
    await sleep(250)
  }
  throw new Error(`pharos-web never became healthy: ${lastError?.message}`)
}

// ---------------------------------------------------------------------------
// DSH SDK app client (newline-delimited JSON-RPC on stdio)
// ---------------------------------------------------------------------------
class DshClient {
  constructor() {
    this.nextId = 1
    this.pending = new Map()
    this.handlers = new Map()
    this.assistantTexts = []
    this.notifications = []
    this.closed = false
    const logStream = fs.createWriteStream(path.join(LOG_DIR, 'dsh-stderr.log'), { flags: 'a' })
    this.child = spawn(DSH_BIN, ['--profile', DSH_PROFILE], {
      env: { ...process.env, DSH_HOME, PHAROS_RUNTIME_SOCKET: RUNTIME_SOCKET },
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    this.child.on('exit', (code, signal) => {
      this.closed = true
      for (const { reject, timer } of this.pending.values()) {
        clearTimeout(timer)
        reject(new Error(`dsh exited (code=${code}, signal=${signal})`))
      }
      this.pending.clear()
      logStream.end()
      log(`dsh exited code=${code} signal=${signal}`)
    })
    this.child.stderr.pipe(logStream)
    readline.createInterface({ input: this.child.stdout }).on('line', (line) => this.onLine(line))
  }

  onLine(line) {
    let message
    try {
      message = JSON.parse(line)
    } catch {
      log(`dsh stdout non-JSON line: ${line.slice(0, 200)}`)
      return
    }
    if (message.id !== undefined && message.id !== null && (message.result !== undefined || message.error)) {
      const pending = this.pending.get(message.id)
      if (!pending) return
      this.pending.delete(message.id)
      clearTimeout(pending.timer)
      if (message.error) pending.reject(new Error(`${pending.method}: ${message.error.message}`))
      else pending.resolve(message.result)
      return
    }
    if (typeof message.method !== 'string') return
    this.notifications.push(message)
    this.captureSessionEvent(message)
    const handler = this.handlers.get(message.method)
    if (handler) handler(message.params)
  }

  captureSessionEvent(message) {
    if (message.method !== 'session.event') return
    const { sessionId, event } = message.params || {}
    if (sessionId !== SESSION_ID || !event) return
    if (event.type === 'assistant/message') {
      const text = extractText(event.data?.message?.content)
      if (text) this.assistantTexts.push({ turn: event.data?.turn, step: event.data?.step, text })
      recordEvent({
        type: event.type,
        turn: event.data?.turn,
        step: event.data?.step,
        textPreview: text.slice(0, 200),
      })
    } else if (event.type === 'turn/end') {
      recordEvent({ type: event.type, turn: event.data?.turn, reason: event.data?.reason })
    } else if (event.type === 'turn/start' || event.type === 'agent/error') {
      recordEvent({ type: event.type, data: event.data })
    }
  }

  on(method, handler) {
    this.handlers.set(method, handler)
  }

  request(method, params, timeoutMs = 30_000) {
    if (this.closed) return Promise.reject(new Error('dsh client is closed'))
    const id = this.nextId++
    const payload = { jsonrpc: '2.0', id, method, params }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`dsh request timed out: ${method}`))
      }, timeoutMs)
      this.pending.set(id, { resolve, reject, timer, method })
      this.child.stdin.write(`${JSON.stringify(payload)}\n`)
    })
  }

  async close() {
    if (this.closed) return
    try {
      this.child.stdin.end()
    } catch {}
    await new Promise((resolve) => {
      let done = false
      const finish = () => {
        if (done) return
        done = true
        resolve()
      }
      // Graceful EOF, then bounded escalation: never leave a dsh child behind.
      const termTimer = setTimeout(() => {
        try {
          this.child.kill('SIGTERM')
        } catch {}
      }, 3000)
      const killTimer = setTimeout(() => {
        try {
          this.child.kill('SIGKILL')
        } catch {}
        finish()
      }, 8000)
      this.child.once('exit', () => {
        clearTimeout(termTimer)
        clearTimeout(killTimer)
        finish()
      })
    })
  }
}

function extractText(content) {
  if (!Array.isArray(content)) return ''
  return content
    .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('\n')
    .trim()
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function assertTruthy(condition, message) {
  if (!condition) throw new Error(`assertion failed: ${message}`)
}

// ---------------------------------------------------------------------------
// Registration probe: the plugin must register the SDK session as a live,
// reply-capable delivery conversation before a delivery can be routed.
// ---------------------------------------------------------------------------
function describeRegistration(snapshot, conversationId) {
  const conversation = (snapshot?.conversations || []).find(
    (item) => item.vendorSessionID === SESSION_ID,
  )
  const driver = conversation
    ? (snapshot?.drivers || []).find((item) => item.id === conversation.driverID)
    : undefined
  return {
    conversationId: conversation?.id,
    conversationKind: conversation?.kind,
    memberID: conversation?.memberID ?? null,
    presence: conversation?.state?.presence ?? null,
    activity: conversation?.state?.activity ?? null,
    persistence: conversation?.state?.persistence ?? null,
    observedAt: conversation?.state?.observedAt ?? null,
    driverID: conversation?.driverID,
    driverCapabilities: driver?.capabilities ?? [],
    driverLastSeenAt: driver?.lastSeenAt ?? null,
    conversationIdExpected: conversationId,
  }
}

async function waitForRegistration(timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs
  let last
  while (Date.now() < deadline) {
    const snapshot = await runtimeCall('runtime.snapshot')
    last = describeRegistration(snapshot)
    if (
      last.conversationId &&
      last.conversationKind === 'dsh' &&
      last.presence === 'online' &&
      last.driverCapabilities.includes('delivery.poll')
    ) {
      return { snapshot, registration: last }
    }
    await sleep(500)
  }
  throw new Error(`dsh plugin never registered a live conversation for ${SESSION_ID}: ${JSON.stringify(last)}`)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  log(`sandbox=${SANDBOX} session=${SESSION_ID} thread=${THREAD_ID}`)
  log(`dsh-home=${DSH_HOME} runtime-socket=${RUNTIME_SOCKET} web=${WEB_URL}`)
  await waitForRuntime()
  await waitForHealth()

  const dsh = new DshClient()
  try {
    const init = await dsh.request(
      'initialize',
      { cwd: path.join(SANDBOX, 'work'), provider: 'opencode-go', model: 'deepseek-v4.1-flash' },
      120_000,
    )
    log(`dsh initialize ok: ${JSON.stringify(init)}`)

    // An unknown session id creates the Agent+Session pair without sending a
    // prompt, so the plugin registers it before any model turn happens.
    const cwd = await dsh.request('session/working-directory/get', { sessionId: SESSION_ID }, 60_000)
    log(`dsh session created: cwd=${cwd?.cwd}`)

    const { snapshot: registeredSnapshot, registration } = await waitForRegistration()
    log(`plugin registration: ${JSON.stringify(registration)}`)

    if (PROBE_ONLY) {
      const result = { mode: 'probe', sessionId: SESSION_ID, registration, snapshotSummary: summarize(registeredSnapshot) }
      fs.writeFileSync(RESULT_FILE, `${JSON.stringify(result, null, 2)}\n`)
      console.log(JSON.stringify(result, null, 2))
      log('probe-only mode complete (no model turn was requested)')
      return
    }

    const thread = await http('POST', '/api/v1/threads', {
      threadId: THREAD_ID,
      memberIds: [HUMAN_MEMBER, SESSION_ID],
    })
    log(`thread created: ${JSON.stringify(thread)}`)

    const original = await http('POST', `/api/v1/threads/${encodeURIComponent(THREAD_ID)}/messages`, {
      text: PROMPT,
      targetMemberIds: [SESSION_ID],
    })
    log(`thread message sent: id=${original.id} target=${JSON.stringify(original.targetMemberIds || original.targetMemberIds)}`)

    const submission = await runtimeCall('delivery.submit-member', {
      memberID: SESSION_ID,
      idempotencyKey: `mesh:${original.id}:${SESSION_ID}`,
      payload: JSON.stringify({
        body: PROMPT,
        room: THREAD_ID,
        messageID: original.id,
        sender: HUMAN_MEMBER,
      }),
    })
    log(`delivery submitted: ${JSON.stringify(submission)}`)
    assertTruthy(submission?.submitted === true, 'delivery.submit-member reported submitted=true')
    assertTruthy(submission?.conversationID === registration.conversationId, 'delivery routed to the registered conversation')

    // Wait for the real assistant turn + plugin write-back.
    const deadline = Date.now() + TURN_TIMEOUT_MS
    let replies = []
    let deliveryRecord = null
    while (Date.now() < deadline) {
      const messages = await http('GET', `/api/v1/threads/${encodeURIComponent(THREAD_ID)}/messages`)
      replies = (messages || []).filter((message) => message.senderId === SESSION_ID)
      if (replies.length > 0) break
      const snapshot = await runtimeCall('runtime.snapshot')
      deliveryRecord = (snapshot?.deliveries || []).find((item) => item.id === submission.deliveryID) || deliveryRecord
      await sleep(1000)
    }
    if (replies.length === 0) {
      const snapshot = await runtimeCall('runtime.snapshot')
      deliveryRecord = (snapshot?.deliveries || []).find((item) => item.id === submission.deliveryID)
      throw new Error(
        `no assistant reply appeared within ${TURN_TIMEOUT_MS}ms; delivery=${JSON.stringify(deliveryRecord)}; assistantEvents=${JSON.stringify(dsh.assistantTexts)}; notifications=${JSON.stringify(dsh.notifications.map((n) => n.method))}`,
      )
    }

    // Give the plugin a moment to (incorrectly) duplicate the reply, then assert.
    await sleep(5000)
    const finalMessages = await http('GET', `/api/v1/threads/${encodeURIComponent(THREAD_ID)}/messages`)
    replies = (finalMessages || []).filter((message) => message.senderId === SESSION_ID)
    assertTruthy(replies.length === 1, `exactly one reply from ${SESSION_ID}, got ${replies.length}: ${JSON.stringify(replies.map((r) => r.id))}`)

    const reply = replies[0]
    assertTruthy(Boolean(reply.text && reply.text.trim()), 'reply text is non-empty')
    assertTruthy(
      reply.replyTo?.messageId === original.id,
      `reply is correlated to the original message (expected ${original.id}, got ${JSON.stringify(reply.replyTo)})`,
    )

    const snapshot = await runtimeCall('runtime.snapshot')
    deliveryRecord = (snapshot?.deliveries || []).find((item) => item.id === submission.deliveryID) || deliveryRecord
    assertTruthy(deliveryRecord?.state === 'consumed', `plugin acked the delivery consumed (state=${deliveryRecord?.state}, detail=${deliveryRecord?.detail})`)

    const assistantTexts = dsh.assistantTexts.map((item) => item.text.trim()).filter(Boolean)
    assertTruthy(assistantTexts.length >= 1, `DSH produced an assistant message (got ${assistantTexts.length})`)
    assertTruthy(
      assistantTexts.includes(reply.text.trim()),
      `Thread reply text equals a real DSH assistant message (reply=${JSON.stringify(reply.text.trim().slice(0, 300))}, assistant=${JSON.stringify(assistantTexts.map((text) => text.slice(0, 300)))})`,
    )

    // Replayed delivery submit with the same idempotency key must not re-run the
    // turn nor post a second reply: the plugin only follows up queued/accepted
    // deliveries and the Thread reply id is stable.
    const replay = await runtimeCall('delivery.submit-member', {
      memberID: SESSION_ID,
      idempotencyKey: `mesh:${original.id}:${SESSION_ID}`,
      payload: JSON.stringify({
        body: PROMPT,
        room: THREAD_ID,
        messageID: original.id,
        sender: HUMAN_MEMBER,
      }),
    })
    assertTruthy(replay?.deliveryID === submission.deliveryID, 'replayed submit returns the same delivery id')
    await sleep(5000)
    const messagesAfterReplay = await http('GET', `/api/v1/threads/${encodeURIComponent(THREAD_ID)}/messages`)
    const repliesAfterReplay = (messagesAfterReplay || []).filter((message) => message.senderId === SESSION_ID)
    assertTruthy(repliesAfterReplay.length === 1, `replayed submit did not create a second reply (got ${repliesAfterReplay.length})`)

    const result = {
      mode: 'live',
      sessionId: SESSION_ID,
      threadId: THREAD_ID,
      originalMessageId: original.id,
      replyId: reply.id,
      replyText: reply.text,
      replyTo: reply.replyTo,
      delivery: { id: submission.deliveryID, state: deliveryRecord.state, detail: deliveryRecord.detail },
      assistantTurns: dsh.assistantTexts,
      registration,
    }
    fs.writeFileSync(RESULT_FILE, `${JSON.stringify(result, null, 2)}\n`)
    console.log(JSON.stringify(result, null, 2))
    log('live E2E PASS: exactly one real DSH assistant reply written back to the Thread')
  } finally {
    await dsh.close()
  }
}

function summarize(snapshot) {
  return {
    drivers: (snapshot?.drivers || []).map((driver) => ({ id: driver.id, capabilities: driver.capabilities })),
    conversations: (snapshot?.conversations || []).map((conversation) => ({
      id: conversation.id,
      vendorSessionID: conversation.vendorSessionID,
      kind: conversation.kind,
      memberID: conversation.memberID,
      state: conversation.state && { presence: conversation.state.presence, activity: conversation.state.activity },
    })),
    deliveries: (snapshot?.deliveries || []).length,
  }
}

main()
  .then(() => {
    fs.writeFileSync(path.join(LOG_DIR, 'dsh-driver.log'), `${LOG.join('\n')}\n`)
    process.exit(0)
  })
  .catch((error) => {
    log(`FAILED: ${error.stack || error.message}`)
    fs.writeFileSync(path.join(LOG_DIR, 'dsh-driver.log'), `${LOG.join('\n')}\n`)
    console.error(`dsh_sdk_driver: ${error.message}`)
    process.exit(1)
  })
