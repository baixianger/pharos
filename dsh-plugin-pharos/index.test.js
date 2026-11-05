import assert from 'node:assert/strict'
import test from 'node:test'

import { __testing } from './index.js'

test('session nick hashes the complete session identity', () => {
  const first = __testing.sessionBinding({ session: { id: 'prefix-a-same-tail' } }, { nickPrefix: 'worker' })
  const second = __testing.sessionBinding({ session: { id: 'prefix-b-same-tail' } }, { nickPrefix: 'worker' })
  assert.notEqual(first.nick, second.nick)
  assert.match(first.nick, /^worker-[a-f0-9]{12}$/)
})

test('reconcile uses rooms and identity-guards stale leaves', async () => {
  const calls = []
  const runner = async argv => {
    calls.push(argv)
    if (argv[1] === 'who') return JSON.stringify([
      { id: 'session-1', nick: 'old', rooms: ['old-room'] },
      { id: 'session-1', nick: 'dsh-aabbcc', rooms: ['pharos'] },
    ])
    return ''
  }
  await __testing.reconcileBinding({ memberID: 'session-1', nick: 'dsh-aabbcc', room: 'pharos' }, undefined, runner)
  assert.deepEqual(calls, [
    ['mesh', 'who', '--json'],
    ['mesh', 'leave', 'old-room', 'old', '--member', 'session-1'],
  ])
})

test('reconcile joins when the session has no matching room alias', async () => {
  const calls = []
  const runner = async argv => {
    calls.push(argv)
    return argv[1] === 'who' ? '[]' : ''
  }
  await __testing.reconcileBinding({ memberID: 'session-1', nick: 'dsh-aabbcc', room: 'pharos' }, undefined, runner)
  assert.deepEqual(calls[1], [
    'mesh', 'join', 'pharos', 'dsh-aabbcc', '--session', 'session-1', '--kind', 'dsh',
  ])
})

test('limit rejects non-finite input and clamps valid values', () => {
  assert.equal(__testing.limitOrDefault(undefined), 100)
  assert.equal(__testing.limitOrDefault(0), 1)
  assert.equal(__testing.limitOrDefault(200), 100)
  assert.throws(() => __testing.limitOrDefault('invalid'), /finite/)
})

test('mesh send omits an absent optional mention', () => {
  const binding = { memberID: 'session-1', room: 'pharos' }
  assert.deepEqual(__testing.meshSendResult(binding), {
    delivered: true,
    from: 'session-1',
    room: 'pharos',
  })
  assert.equal(__testing.meshSendResult(binding, '@worker').mention, 'worker')
})

test('approval session events become needs_human payloads for achat hook dsh', () => {
  const waiting = new Set()
  const session = { id: 'session-1' }
  assert.equal(__testing.attentionPayload(session, { type: 'turn/end' }, waiting), null, 'no wait yet')
  assert.equal(__testing.attentionPayload(session, { type: 'approval/request', data: {} }, waiting), null)
  const asked = __testing.attentionPayload(session, { type: 'approval/asked', data: { id: 'a1', toolName: 'exec_command', reason: 'network' } }, waiting)
  assert.deepEqual(asked, { type: 'approval/asked', sessionId: 'session-1', data: { id: 'a1', toolName: 'exec_command', reason: 'network', outcome: undefined } })
  assert.equal(__testing.attentionPayload(session, { type: 'approval/decided', data: { id: 'a1', outcome: 'approved' } }, waiting).type, 'approval/decided')
  assert.equal(__testing.attentionPayload(session, { type: 'turn/end' }, waiting), null, 'already cleared')
  assert.equal(__testing.attentionPayload({ header: { id: 'session-2' } }, { type: 'approval/asked', data: {} }, waiting).sessionId, 'session-2')
})
