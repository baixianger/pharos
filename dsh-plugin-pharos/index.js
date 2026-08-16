import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

// Cordis plugin contract: named exports name / inject / apply, no default export
// (a default export silently drops inject).
export const name = 'dsh-plugin-pharos'
// 'tools' registers the Pharos tools; 'agents' owns agent/pre-step processing.
export const inject = ['tools', 'agents']

function pharosBin() {
  return process.env.PHAROS_BIN || 'pharos'
}

async function runPharos(argv, signal) {
  try {
    const { stdout } = await execFileAsync(pharosBin(), argv, {
      signal,
      timeout: 30000,
      maxBuffer: 8 * 1024 * 1024,
      windowsHide: true,
    })
    return stdout.trim()
  } catch (err) {
    const detail = (err.stderr || '').trim() || err.message || String(err)
    const why = err.killed ? 'timed out after 30s' : 'exit ' + (err.code || 'error')
    throw new Error('pharos ' + argv[0] + ' failed (' + why + '): ' + detail)
  }
}

// Zero-dependency raw tool shim. Raw-registered tools own input validation but
// still receive registry-enforced output, so we never drag a second copy of
// @deepseek-ai/dsh-tools into a profile.
function pharosTool(def) {
  return {
    name: def.name,
    description: def.description,
    parameters: { type: 'object', properties: def.properties || {}, required: def.required || [] },
    output: {
      schema: def.outputSchema || { type: 'string' },
      render: def.render || function (_args, value) {
        return [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }]
      },
    },
    async execute(params, exec) {
      if (def.execute) return def.execute(params, exec)
      return runPharos(def.argv(params), exec && exec.signal)
    },
  }
}

function sessionID(agent) {
  const id = agent && agent.session && agent.session.id
  return id == null ? '' : String(id)
}

function sessionBinding(agent, cfg) {
  const memberID = sessionID(agent)
  if (!memberID) throw new Error('Pharos Mesh requires the owning DSH session identity')
  const prefix = cfg.nickPrefix || cfg.nick || process.env.PHAROS_MESH_NICK || 'dsh'
  const suffix = memberID.replace(/[^a-zA-Z0-9-]/g, '').slice(-8).toLowerCase() || 'session'
  return {
    memberID,
    nick: `${prefix}-${suffix}`,
    room: cfg.room || process.env.PHAROS_MESH_ROOM || 'pharos',
  }
}

function bindingFor(agent, cfg) {
  const binding = sessionBinding(agent, cfg)
  return binding.memberID + '|' + binding.room
}

async function ensureJoined(agent, cfg, signal, bindings) {
  const binding = sessionBinding(agent, cfg)
  const key = bindingFor(agent, cfg)
  if (bindings.has(key)) return bindings.get(key)
  const pending = reconcileBinding(binding, signal).then(() => binding).catch(error => {
    bindings.delete(key)
    throw error
  })
  bindings.set(key, pending)
  return pending
}

async function reconcileBinding(binding, signal) {
  let members = []
  try {
    const roster = JSON.parse(await runPharos(['mesh', 'who', '--json'], signal))
    members = Array.isArray(roster) ? roster : []
  } catch {
    // Older Pharos binaries have no JSON roster; join remains idempotent.
  }
  const sameSession = members.filter(member => String(member.id || '') === binding.memberID)
  for (const member of sameSession) {
    if (member.room === binding.room && member.nick === binding.nick) continue
    if (member.room && member.nick) {
      await runPharos(['mesh', 'leave', String(member.room), String(member.nick)], signal)
    }
  }
  const current = sameSession.some(member => member.room === binding.room && member.nick === binding.nick)
  if (!current) {
    await runPharos([
      'mesh', 'join', binding.room, binding.nick,
      '--session', binding.memberID, '--kind', 'dsh',
    ], signal)
  }
}

function s(description) { return { type: 'string', description } }
function i(description) { return { type: 'integer', description } }

// 'pharos mesh unread <nick> --json' prints {"nick":"...","count":0} when empty,
// or the raw unread signal (with a count field) when pending. Either way it is
// a peek — it never consumes.
function parseUnreadCount(text) {
  try {
    const count = JSON.parse(text).count
    return typeof count === 'number' ? count : 0
  } catch { return 0 }
}

// Immutable-looking fresh user message, mirroring the shape dsh-tmux-context
// injects. The session store snapshots + freezes it on append.
function buildUserMessage(text) {
  return {
    id: crypto.randomUUID(),
    role: 'user',
    content: [{ type: 'text', text }],
    source: { kind: 'plugin', plugin: name, form: 'snapshot', sections: [{ name, text }] },
  }
}

export function apply(ctx, config) {
  const cfg = config || {}
  const bindings = new Map()

  const tools = [
    pharosTool({
      name: 'pharos_list',
      description: 'List every project Pharos manages, as machine-readable JSON.',
      argv: function () { return ['list', '--json'] },
    }),

    pharosTool({
      name: 'pharos_mesh_send',
      description: 'Post a message to a Pharos mesh room, optionally @mentioning an agent.',
      properties: {
        text: s('Message body to post to the room.'),
        room: s('Room name to post into.'),
        mention: s('Optional agent nick to @mention (without the @).'),
      },
      required: ['text'],
      outputSchema: {
        type: 'object',
        properties: {
          delivered: { type: 'boolean', description: 'Broker accepted the message into the mailbox.' },
          from: s('Exact current DSH session identity.'),
          room: s('Room receiving the message.'),
          mention: s('Optional mentioned agent nick, without the @.'),
        },
        required: ['delivered', 'from', 'room'],
      },
      argv: function (p) {
        const args = ['mesh', 'send', p.text]
        if (p.mention) args.push(p.mention.charAt(0) === '@' ? p.mention : '@' + p.mention)
        args.push('--room', p.room)
        return args
      },
      async execute(p, exec) {
        const binding = await ensureJoined(exec && exec.agent, cfg, exec && exec.signal, bindings)
        if (p.text == null || String(p.text).trim() === '') throw new Error('pharos_mesh_send requires non-empty text')
        if (p.room && p.room !== binding.room) throw new Error('pharos_mesh_send cannot cross the current session room boundary')
        const args = ['mesh', 'send', p.text]
        if (p.mention) args.push(p.mention.charAt(0) === '@' ? p.mention : '@' + p.mention)
        args.push('--room', binding.room, '--member', binding.memberID)
        await runPharos(args, exec && exec.signal)
        return { delivered: true, from: binding.memberID, room: binding.room, mention: p.mention ? String(p.mention).replace(/^@/, '') : null }
      },
    }),

    pharosTool({
      name: 'pharos_mesh_recv',
      description: "Drain this agent's Pharos mesh mailbox and return unread messages.",
      properties: {
        nick: s("Optional override; the current session's unique Pharos nick is used by default."),
        limit: i('Maximum messages to drain, clamped to 1..100.'),
      },
      outputSchema: {
        type: 'object',
        properties: {
          member: s('Exact current DSH session identity.'),
          nick: s('Current session alias.'),
          messages: s('Raw drained mailbox output.'),
        },
        required: ['member', 'nick', 'messages'],
      },
      argv: function (p) { return ['mesh', 'recv', p.nick] },
      async execute(p, exec) {
        const binding = await ensureJoined(exec && exec.agent, cfg, exec && exec.signal, bindings)
        const limit = p.limit == null ? 100 : Math.max(1, Math.min(100, Math.trunc(Number(p.limit))))
        const text = await runPharos([
          'mesh', 'recv', p.nick || binding.nick, '--member', binding.memberID, '--limit', String(limit),
        ], exec && exec.signal)
        return { member: binding.memberID, nick: binding.nick, messages: text }
      },
    }),

    pharosTool({
      name: 'pharos_mesh_who',
      description: 'Show only the current DSH session member and its live Pharos presence state.',
      outputSchema: {
        type: 'object',
        properties: { member: { type: 'object' } },
        required: ['member'],
      },
      async execute(_p, exec) {
        const binding = await ensureJoined(exec && exec.agent, cfg, exec && exec.signal, bindings)
        let members = []
        try { members = JSON.parse(await runPharos(['mesh', 'who', '--json'], exec && exec.signal)) } catch {}
        return { member: Array.isArray(members) ? members.find(member => String(member.id || '') === binding.memberID) || null : null }
      },
    }),

    pharosTool({
      name: 'pharos_issue_add',
      description: 'Create a Pharos issue on a project.',
      properties: {
        project: s('Project name.'),
        title: s('Issue title.'),
        body: s('Optional longer description.'),
        priority: s('Optional priority (low/medium/high/none).'),
      },
      required: ['project', 'title'],
      argv: function (p) {
        const args = ['issue', 'add', p.project, p.title]
        if (p.body) args.push('--body', p.body)
        if (p.priority) args.push('--priority', p.priority)
        return args
      },
    }),

    pharosTool({
      name: 'pharos_issue_list',
      description: 'List Pharos issues for a project, as machine-readable JSON.',
      properties: { project: s('Project name.') },
      required: ['project'],
      argv: function (p) { return ['issue', 'list', p.project, '--json'] },
    }),

    pharosTool({
      name: 'pharos_update_add',
      description: "Append a progress note to a project's Pharos log.",
      properties: {
        project: s('Project name.'),
        text: s('The note text.'),
        issue: i('Optional issue number to attach the note to.'),
      },
      required: ['project', 'text'],
      argv: function (p) {
        const args = ['update', 'add', p.project, p.text]
        if (p.issue != null) args.push('--issue', String(p.issue))
        return args
      },
    }),
  ]

  for (const tool of tools) ctx.tools.register(tool)

  ctx.accessor('pharosMesh', {
    get: () => ({
      bindingFor: agent => sessionBinding(agent, cfg),
      ensureJoined: (agent, signal) => ensureJoined(agent, cfg, signal, bindings),
    }),
  })

  // Inbound: surface pending @mentions at the start of the next turn — the
  // in-process equivalent of the Claude/Codex Stop hook. Peek (never consume)
  // so an aborted turn cannot drop a mailbox, then prepend an instruction.
  ctx.on('agent/pre-step', async function ({ agent, step, signal }, next) {
    const decision = await next()
    if (decision.kind === 'reject' || (signal && signal.aborted) || step !== 1) return decision
    let binding
    try { binding = await ensureJoined(agent, cfg, signal, bindings) }
    catch { return decision }
    let text
    try { text = await runPharos(['mesh', 'unread', binding.nick, '--json'], signal) }
    catch { return decision }
    const count = parseUnreadCount(text)
    if (count <= 0) return decision
    const prompt = 'You have ' + count + ' unread Pharos mesh message(s). Run pharos_mesh_recv to read them, then reply in room ' + JSON.stringify(binding.room) + ' with pharos_mesh_send.'
    return { kind: 'enter', messages: [buildUserMessage(prompt), ...decision.messages] }
  }, { prepend: true })

  ctx.on('agent/disposed', ({ agent }) => {
    let binding
    try { binding = sessionBinding(agent, cfg) } catch { return }
    bindings.delete(bindingFor(agent, cfg))
    void runPharos(['mesh', 'leave', binding.room, binding.nick]).catch(() => {})
  })
}
