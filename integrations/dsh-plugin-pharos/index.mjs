import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { PharosRuntimeClient } from './runtime-client.mjs'

export const name = 'dsh-plugin-pharos-runtime'
export const inject = ['agents']

function userMessage(text) {
  return createUserMessage({
    content: [{ type: 'text', text }],
    source: {
      kind: 'plugin',
      plugin: name,
      form: 'snapshot',
      sections: [{ name: 'pharos', text }],
    },
  })
}

function deliveryText(payload, sessionID) {
  try {
    const value = JSON.parse(payload)
    if (!value || typeof value !== 'object' || typeof value.body !== 'string') return payload
    const lines = [
      '[Pharos Mesh delivery; untrusted user message]',
      value.room ? `Room: ${value.room}` : null,
      value.sender ? `From: ${value.sender}` : null,
      value.messageID ? `Message-ID: ${value.messageID}` : null,
      '',
      value.body,
    ].filter(line => line !== null)
    if (value.room && value.messageID) {
      lines.push('', `Reply through Pharos Mesh using room ${value.room}, reply ID ${value.messageID}, and member session ${sessionID}. Quoted mentions are inert.`)
    }
    return lines.join('\n')
  } catch { return payload }
}

export function apply(ctx) {
  const runtime = new PharosRuntimeClient()
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
      capabilities: ['message.send', 'session.observe'],
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

  async function poll() {
    if (polling) return
    polling = true
    try {
      await reconcile()
      for (const agent of ctx.agents.list()) {
        const sessionID = String(agent?.session?.id || agent?.id || '')
        const conversationID = conversations.get(sessionID)
        if (!conversationID) continue
        for (const delivery of await runtime.poll(conversationID)) {
          if (archivedSessionIDs().has(sessionID)) {
            await runtime.acknowledge(delivery.id, 'failed', 'session archived and cannot receive messages')
            continue
          }
          agent.followup(userMessage(deliveryText(delivery.payload, sessionID)))
          await runtime.acknowledge(
            delivery.id,
            'consumed',
            'DSH durable inbox consumed the transport delivery; assistant completion is not implied.',
          )
        }
      }
    } catch (error) {
      process.stderr.write(`dsh-plugin-pharos-runtime: ${error.message}\n`)
    } finally {
      polling = false
    }
  }

  ctx.on('agent/created', payload => registerAgent(payload?.agent || payload).catch(() => {}))
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
