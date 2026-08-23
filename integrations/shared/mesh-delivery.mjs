import { spawn } from 'node:child_process'
import { access } from 'node:fs/promises'
import { constants } from 'node:fs'
import path from 'node:path'

export function decodeMeshDelivery(payload) {
  if (typeof payload !== 'string') throw new TypeError('delivery payload must be a string')
  let value
  try { value = JSON.parse(payload) } catch { return { body: payload } }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return { body: payload }

  const body = stringField(value.body) || stringField(value.text)
  if (!body) return { body: payload }
  return {
    body,
    room: stringField(value.room),
    messageID: stringField(value.messageID) || stringField(value.messageId),
    sender: stringField(value.sender),
    replyToID: stringField(value.replyToID) || stringField(value.replyToId),
  }
}

export function renderChannelDelivery(delivery) {
  const lines = []
  if (delivery.room) lines.push(`Room: ${delivery.room}`)
  if (delivery.sender) lines.push(`From: ${delivery.sender}`)
  if (delivery.messageID) lines.push(`Message-ID: ${delivery.messageID}`)
  if (delivery.replyToID) lines.push(`Reply-To: ${delivery.replyToID}`)
  lines.push('', delivery.body)
  return lines.join('\n').trim()
}

export async function sendMeshReply({ room, messageID, text, memberID, targets = [] }, options = {}) {
  requireString(room, 'room')
  requireString(messageID, 'messageID')
  requireString(text, 'text')
  if (memberID !== undefined) requireString(memberID, 'memberID')
  if (!Array.isArray(targets) || targets.some(target => typeof target !== 'string' || !target.trim())) {
    throw new TypeError('targets must be an array of non-empty strings')
  }

  const executable = options.executable || await resolvePharosExecutable(options)
  const args = ['mesh', 'send', text, ...targets.map(target => `@${target}`),
    '--room', room, '--reply', messageID]
  if (memberID) args.push('--member', memberID)
  return run(executable, args, options.env)
}

export async function resolvePharosExecutable(options = {}) {
  const candidates = [
    options.env?.PHAROS_EXECUTABLE,
    process.env.PHAROS_EXECUTABLE,
    '/Applications/Pharos.app/Contents/MacOS/Pharos',
    path.resolve(process.cwd(), '.build/debug/pharos'),
  ].filter(Boolean)
  for (const candidate of candidates) {
    try { await access(candidate, constants.X_OK); return candidate } catch {}
  }
  return 'pharos'
}

function run(executable, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'] })
    let stdout = ''; let stderr = ''
    child.stdout.on('data', chunk => { stdout += chunk })
    child.stderr.on('data', chunk => { stderr += chunk })
    child.on('error', reject)
    child.on('close', code => {
      if (code === 0) resolve({ stdout: stdout.trim(), stderr: stderr.trim() })
      else reject(new Error(stderr.trim() || stdout.trim() || `pharos exited with status ${code}`))
    })
  })
}

function stringField(value) { return typeof value === 'string' && value.trim() ? value : undefined }
function requireString(value, name) {
  if (typeof value !== 'string' || !value.trim()) throw new TypeError(`${name} must be a non-empty string`)
}
