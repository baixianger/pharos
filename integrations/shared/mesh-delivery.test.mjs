import assert from 'node:assert/strict'
import { chmod, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { decodeMeshDelivery, renderChannelDelivery, sendMeshReply } from './mesh-delivery.mjs'

test('plain deliveries remain backward compatible', () => {
  assert.deepEqual(decodeMeshDelivery('hello'), { body: 'hello' })
})

test('structured delivery preserves the route needed for an unambiguous reply', () => {
  const delivery = decodeMeshDelivery(JSON.stringify({
    body: 'review this', room: 'runtime', messageID: 'msg-42', sender: 'alice', replyToID: 'msg-7',
  }))
  assert.deepEqual(delivery, {
    body: 'review this', room: 'runtime', messageID: 'msg-42', sender: 'alice', replyToID: 'msg-7',
  })
  assert.match(renderChannelDelivery(delivery), /Message-ID: msg-42/)
})

test('reply invocation uses argument boundaries and stable session identity', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'pharos-reply-'))
  const executable = path.join(directory, 'pharos')
  const output = path.join(directory, 'args.json')
  await writeFile(executable, '#!/bin/sh\nprintf "%s\\n" "$@" > "$PHAROS_TEST_OUTPUT"\n')
  await chmod(executable, 0o700)
  await sendMeshReply({
    room: 'one room', messageID: 'msg-42', text: 'hello; not shell', memberID: 'session-1', targets: ['alice'],
  }, { executable, env: { PHAROS_TEST_OUTPUT: output } })
  const args = (await readFile(output, 'utf8')).trim().split('\n')
  assert.deepEqual(args, ['mesh', 'send', 'hello; not shell', '@alice', '--room', 'one room', '--reply', 'msg-42', '--member', 'session-1'])
})
