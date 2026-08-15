import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

// Cordis plugin contract: named exports name / inject / apply, no default export
// (a default export silently drops inject).
export const name = 'dsh-plugin-pharos'
export const inject = ['tools']

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
      schema: { type: 'string' },
      render: function (_args, value) { return [{ type: 'text', text: value }] },
    },
    async execute(params, exec) {
      return runPharos(def.argv(params), exec && exec.signal)
    },
  }
}

function s(description) { return { type: 'string', description } }
function i(description) { return { type: 'integer', description } }

export function apply(ctx) {
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
      required: ['text', 'room'],
      argv: function (p) {
        const args = ['mesh', 'send', p.text]
        if (p.mention) args.push(p.mention.charAt(0) === '@' ? p.mention : '@' + p.mention)
        args.push('--room', p.room)
        return args
      },
    }),

    pharosTool({
      name: 'pharos_mesh_recv',
      description: "Drain this agent's Pharos mesh mailbox and return unread messages.",
      properties: { nick: s("This agent's mesh nick.") },
      required: ['nick'],
      argv: function (p) { return ['mesh', 'recv', p.nick] },
    }),

    pharosTool({
      name: 'pharos_mesh_who',
      description: 'List Pharos mesh members and their live presence states.',
      argv: function () { return ['mesh', 'who'] },
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
}
