// Delivery-loop regression suite for the Pharos DSH runtime plugin.
//
// Zero dependencies, no network, no Host Runtime: every case drives
// handleDeliveryPoll directly with a fake agent and a fake RPC shim, so the
// poll -> ack(injected) -> agent.followup -> ack(consumed) contract is verified
// without a running DSH session or Rust runtime.
import assert from 'node:assert/strict'
import test from 'node:test'

import {
  DRIVER_CAPABILITIES,
  __testing,
  apply,
  buildUserMessage,
  deliveryText,
  handleDeliveryPoll,
  inject,
  name,
} from './index.mjs'

function fakeAgent(record) {
  return {
    followup(message) {
      if (record) record.push({ method: 'agent.followup', params: message })
    },
  }
}

test('plugin contract exports stay name/inject/apply', () => {
  assert.equal(name, 'dsh-plugin-pharos-runtime')
  assert.deepEqual(inject, ['agents'])
  assert.equal(typeof apply, 'function')
})

test('driver registration advertises delivery.poll and mesh.reply-once-v1 along with existing capabilities', () => {
  assert.deepEqual(DRIVER_CAPABILITIES, [
    'message.send',
    'session.observe',
    'session.create',
    'delivery.poll',
    'mesh.reply-once-v1',
  ])
  assert.ok(DRIVER_CAPABILITIES.includes('delivery.poll'))
  assert.ok(DRIVER_CAPABILITIES.includes('mesh.reply-once-v1'))
  assert.equal(__testing.DRIVER_CAPABILITIES, DRIVER_CAPABILITIES)
})

test('handleDeliveryPoll performs poll -> injected ack -> followup -> consumed ack in order with exact payloads', async () => {
  const calls = []
  const agent = fakeAgent(calls)
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') {
      return [{ id: 'del-1', payload: JSON.stringify({ body: 'Deploy v2', sender: 'Pai' }) }]
    }
    return { ok: true }
  }

  const handled = await handleDeliveryPoll(agent, { conversationID: 'conv-123' }, rpc)

  assert.equal(handled, true)
  assert.equal(calls.length, 4, 'poll, injected ack, followup, consumed ack')
  assert.deepEqual(calls[0], { method: 'delivery.poll', params: { conversationID: 'conv-123' } })
  assert.deepEqual(calls[1], { method: 'delivery.ack', params: { deliveryID: 'del-1', state: 'injected' } })
  assert.equal(calls[2].method, 'agent.followup')
  assert.equal(calls[2].params.content[0].text, '[Pharos Thread Message from Pai]\nDeploy v2')
  assert.deepEqual(calls[3], {
    method: 'delivery.ack',
    params: { deliveryID: 'del-1', state: 'consumed', detail: __testing.CONSUMED_DETAIL },
  })
  // A consumed ack only claims durable-inbox ownership, never assistant completion.
  assert.match(__testing.CONSUMED_DETAIL, /not implied/)
})

test('a throwing agent.followup acks failed with the error detail and never claims consumed', async () => {
  const calls = []
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') return [{ id: 'del-3', payload: 'Raw prompt text' }]
    return { ok: true }
  }
  const agent = {
    followup() { throw new Error('Agent busy') },
  }

  const handled = await handleDeliveryPoll(agent, { conversationID: 'conv-3' }, rpc)

  assert.equal(handled, true)
  assert.deepEqual(calls, [
    { method: 'delivery.poll', params: { conversationID: 'conv-3' } },
    { method: 'delivery.ack', params: { deliveryID: 'del-3', state: 'injected' } },
    { method: 'delivery.ack', params: { deliveryID: 'del-3', state: 'failed', detail: 'Agent busy' } },
  ])
  assert.equal(calls.some(call => call.params?.state === 'consumed'), false)
})

test('an async followup rejection is acked failed as well', async () => {
  const calls = []
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') return [{ id: 'del-async', payload: 'hello' }]
    return { ok: true }
  }
  const agent = { followup: async () => { throw new Error('inbox locked') } }

  assert.equal(await handleDeliveryPoll(agent, 'conv-async', rpc), true)
  assert.deepEqual(calls.at(-1), {
    method: 'delivery.ack',
    params: { deliveryID: 'del-async', state: 'failed', detail: 'inbox locked' },
  })
})

test('a consumed-ack failure after a successful followup is acked failed with a truthful detail', async () => {
  const calls = []
  const followups = []
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') {
      return [{ id: 'del-4', payload: JSON.stringify({ body: 'hi', sender: 'Pai' }) }]
    }
    // The durable inbox accepted the message, but the consumed ack is lost.
    if (method === 'delivery.ack' && params.state === 'consumed') throw new Error('socket dropped')
    return { ok: true }
  }
  const agent = { followup: message => followups.push(message) }

  // Must not throw out of the per-delivery handler.
  const handled = await handleDeliveryPoll(agent, { conversationID: 'conv-4' }, rpc)

  assert.equal(handled, true)
  assert.equal(followups.length, 1)
  assert.equal(followups[0].content[0].text, '[Pharos Thread Message from Pai]\nhi')
  assert.deepEqual(calls.map(call => `${call.method}:${call.params?.state ?? ''}`), [
    'delivery.poll:',
    'delivery.ack:injected',
    'delivery.ack:consumed',
    'delivery.ack:failed',
  ])
  assert.equal(calls[3].params.deliveryID, 'del-4')
  assert.equal(calls[3].params.state, 'failed')
  // Truthful: the intake may have happened, so the detail says so.
  assert.match(calls[3].params.detail, /followup accepted but consumed ack failed/)
  assert.match(calls[3].params.detail, /socket dropped/)
})

test('a failed failed-ack is logged and does not abort the rest of the poll', async () => {
  const calls = []
  const errors = []
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') {
      return [
        { id: 'del-bad', payload: 'first' },
        { id: 'del-good', payload: 'second' },
      ]
    }
    // The last-resort failed ack throws too (runtime gone).
    if (method === 'delivery.ack' && params.deliveryID === 'del-bad' && params.state === 'failed') {
      throw new Error('runtime gone')
    }
    return { ok: true }
  }
  const followups = []
  const agent = {
    followup(message) {
      if (message.content[0].text === 'first') throw new Error('agent busy')
      followups.push(message)
    },
  }

  const handled = await handleDeliveryPoll(agent, 'conv-double-fail', rpc, {
    onError: message => errors.push(message),
  })

  assert.equal(handled, true)
  // The second delivery still ran through its full happy path.
  assert.equal(followups.length, 1)
  assert.equal(followups[0].content[0].text, 'second')
  assert.ok(calls.some(call => call.method === 'delivery.ack'
    && call.params.deliveryID === 'del-good'
    && call.params.state === 'consumed'))
  assert.equal(errors.length, 1)
  assert.match(errors[0], /del-bad/)
  assert.match(errors[0], /failed ack also failed/)
  assert.match(errors[0], /runtime gone/)
})

test('a failed failed-ack logs to stderr when no onError hook is given', async () => {
  const chunks = []
  const originalWrite = process.stderr.write
  process.stderr.write = chunk => { chunks.push(String(chunk)); return true }
  try {
    const rpc = async (method, params) => {
      if (method === 'delivery.poll') return [{ id: 'del-stderr', payload: 'hello' }]
      if (method === 'delivery.ack' && params.state === 'failed') throw new Error('runtime gone')
      return { ok: true }
    }
    const agent = { followup: () => { throw new Error('agent busy') } }
    assert.equal(await handleDeliveryPoll(agent, 'conv-stderr', rpc), true)
  } finally {
    process.stderr.write = originalWrite
  }
  assert.equal(chunks.length, 1)
  assert.match(chunks[0], /dsh-plugin-pharos-runtime: delivery del-stderr/)
  assert.match(chunks[0], /runtime gone/)
})

test('an archived session is acked failed with detail and never followed up', async () => {
  const calls = []
  const agent = fakeAgent(calls)
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') return [{ id: 'del-a', payload: 'hello' }]
    return { ok: true }
  }

  const handled = await handleDeliveryPoll(agent, { conversationID: 'conv-a' }, rpc, { isArchived: () => true })

  assert.equal(handled, true)
  assert.deepEqual(calls.map(call => call.method), ['delivery.poll', 'delivery.ack'])
  assert.deepEqual(calls[1].params, {
    deliveryID: 'del-a',
    state: 'failed',
    detail: __testing.ARCHIVED_DETAIL,
  })
  assert.equal(calls.some(call => call.method === 'agent.followup'), false)
})

test('the archived flag can be a boolean and no injected ack is sent for it', async () => {
  const calls = []
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') return [{ id: 'del-b', payload: 'hello' }]
    return { ok: true }
  }

  assert.equal(await handleDeliveryPoll(fakeAgent(calls), 'conv-b', rpc, { archived: true }), true)
  assert.deepEqual(calls, [
    { method: 'delivery.poll', params: { conversationID: 'conv-b' } },
    { method: 'delivery.ack', params: { deliveryID: 'del-b', state: 'failed', detail: __testing.ARCHIVED_DETAIL } },
  ])
})

test('empty poll, missing conversationID and poll failure return false without followup or ack', async () => {
  const calls = []
  const agent = fakeAgent(calls)

  const emptyRPC = async (method, params) => {
    calls.push({ method, params })
    return method === 'delivery.poll' ? [] : {}
  }
  assert.equal(await handleDeliveryPoll(agent, { conversationID: 'conv-empty' }, emptyRPC), false)
  assert.deepEqual(calls, [{ method: 'delivery.poll', params: { conversationID: 'conv-empty' } }])

  calls.length = 0
  const mustNotCall = async () => {
    calls.push('rpc-called')
    throw new Error('must not be called')
  }
  assert.equal(await handleDeliveryPoll(agent, {}, mustNotCall), false)
  assert.equal(await handleDeliveryPoll(agent, undefined, mustNotCall), false)
  assert.equal(await handleDeliveryPoll(agent, { conversationID: '' }, mustNotCall), false)
  assert.deepEqual(calls, [])

  calls.length = 0
  const failingRPC = async () => {
    calls.push('poll-failed')
    throw new Error('socket down')
  }
  assert.equal(await handleDeliveryPoll(agent, 'conv-down', failingRPC), false)
  assert.deepEqual(calls, ['poll-failed'])

  calls.length = 0
  const malformedRPC = async method => {
    calls.push(method)
    return { deliveries: 'not-an-array' }
  }
  assert.equal(await handleDeliveryPoll(agent, 'conv-shape', malformedRPC), false)
  assert.deepEqual(calls, ['delivery.poll'])
})

test('a failed injected ack is swallowed and does not block followup or the consumed ack', async () => {
  const calls = []
  const agent = fakeAgent(calls)
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') return [{ id: 'del-2', payload: 'Raw prompt text' }]
    if (method === 'delivery.ack' && params.state === 'injected') throw new Error('injected ack lost')
    return { ok: true }
  }

  assert.equal(await handleDeliveryPoll(agent, 'conv-2', rpc), true)
  assert.deepEqual(calls.map(call => call.method), [
    'delivery.poll',
    'delivery.ack',
    'agent.followup',
    'delivery.ack',
  ])
  assert.equal(calls[1].params.state, 'injected')
  assert.equal(calls[3].params.state, 'consumed')
  assert.equal(calls[2].params.content[0].text, 'Raw prompt text')
})

test('each pending delivery gets its own injected -> followup -> consumed sequence', async () => {
  const events = []
  const rpc = async (method, params) => {
    events.push(`${method}:${params.deliveryID ?? params.conversationID}:${params.state ?? ''}`)
    if (method === 'delivery.poll') return [{ id: 'd1', payload: 'one' }, { id: 'd2', payload: 'two' }]
    return { ok: true }
  }
  const agent = {
    followup(message) { events.push(`followup:${message.content[0].text}`) },
  }

  assert.equal(await handleDeliveryPoll(agent, { conversationID: 'c' }, rpc), true)
  assert.deepEqual(events, [
    'delivery.poll:c:',
    'delivery.ack:d1:injected', 'followup:one', 'delivery.ack:d1:consumed',
    'delivery.ack:d2:injected', 'followup:two', 'delivery.ack:d2:consumed',
  ])
})

test('a delivery absent from a later poll is never followed up twice', async () => {
  let polls = 0
  const followups = []
  const acks = []
  const rpc = async (method, params) => {
    if (method === 'delivery.poll') {
      polls += 1
      return polls === 1 ? [{ id: 'del-once', payload: JSON.stringify({ body: 'once' }) }] : []
    }
    acks.push(params)
    return { ok: true }
  }
  const agent = { followup: message => followups.push(message) }

  assert.equal(await handleDeliveryPoll(agent, 'conv-once', rpc), true)
  assert.equal(await handleDeliveryPoll(agent, 'conv-once', rpc), false)
  assert.equal(polls, 2)
  assert.equal(followups.length, 1)
  assert.deepEqual(acks.map(ack => `${ack.deliveryID}:${ack.state}`), [
    'del-once:injected',
    'del-once:consumed',
  ])
})

test('the RPC adapter may be a client exposing call(method, params)', async () => {
  const calls = []
  const followups = []
  const client = {
    async call(method, params) {
      calls.push({ method, params })
      if (method === 'delivery.poll') return [{ id: 'del-c', payload: 'hello' }]
      return { ok: true }
    },
  }

  assert.equal(await handleDeliveryPoll({ followup: message => followups.push(message) }, { conversationID: 'conv-c' }, client), true)
  assert.deepEqual(calls.map(call => call.method), ['delivery.poll', 'delivery.ack', 'delivery.ack'])
  assert.equal(followups.length, 1)
})

test('deliveryText renders structured payloads and passes anything else through verbatim', () => {
  assert.equal(
    deliveryText(JSON.stringify({ body: 'Deploy v2', sender: 'Pai' })),
    '[Pharos Thread Message from Pai]\nDeploy v2',
  )
  assert.equal(
    deliveryText(JSON.stringify({ body: 'hello' })),
    '[Pharos Thread Message from human]\nhello',
  )
  assert.equal(
    deliveryText(JSON.stringify({ body: 'hi', sender: '' })),
    '[Pharos Thread Message from human]\nhi',
  )
  assert.equal(deliveryText('Raw prompt text'), 'Raw prompt text')
  assert.equal(deliveryText('{not json'), '{not json')
  assert.equal(deliveryText(JSON.stringify({ sender: 'Pai' })), '{"sender":"Pai"}')
  assert.equal(deliveryText(JSON.stringify({ body: 42 })), '{"body":42}')
  assert.equal(deliveryText({ body: 'object body', sender: 'Ada' }), '[Pharos Thread Message from Ada]\nobject body')
})

test('buildUserMessage builds the canonical plugin snapshot shape locally', () => {
  const message = buildUserMessage('hello')
  assert.match(message.id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  assert.deepEqual(Object.keys(message), ['id', 'role', 'content', 'source'])
  assert.equal(message.role, 'user')
  assert.deepEqual(message.content, [{ type: 'text', text: 'hello' }])
  assert.deepEqual(message.source, {
    kind: 'plugin',
    plugin: name,
    form: 'snapshot',
    sections: [{ name, text: 'hello' }],
  })
  assert.notEqual(buildUserMessage('hello').id, message.id)

  assert.equal(typeof __testing.userMessage, 'function')
  assert.equal(__testing.userMessage('x').content[0].text, 'x')
  assert.equal(__testing.userMessage('x').role, 'user')
  assert.equal(__testing.handleDeliveryPoll, handleDeliveryPoll)
  assert.equal(__testing.buildUserMessage, buildUserMessage)
  assert.equal(__testing.deliveryText, deliveryText)
})

test('a malformed delivery without an id is skipped so no bogus ack is sent', async () => {
  const calls = []
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'delivery.poll') return [null, { id: 'del-ok', payload: 'hello' }]
    return { ok: true }
  }
  const followups = []

  assert.equal(await handleDeliveryPoll({ followup: message => followups.push(message) }, 'conv-mixed', rpc), true)
  assert.equal(followups.length, 1)
  assert.deepEqual(
    calls.filter(call => call.method === 'delivery.ack').map(call => call.params.deliveryID),
    ['del-ok', 'del-ok'],
  )
})
