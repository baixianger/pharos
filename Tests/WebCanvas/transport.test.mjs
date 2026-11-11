import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const script = await readFile(new URL('../../Sources/Pharos/Resources/WebCanvas/transport.js', import.meta.url), 'utf8');

test('native transport forwards actions to WebKit without HTTP', async () => {
  const calls = [];
  const window = { webkit: { messageHandlers: { pharosBridge: { postMessage: value => calls.push(value) } } } };
  vm.runInNewContext(script, { window });
  await window.pharosTransport.dispatch('send', { text: 'hello' });
  assert.equal(calls[0].action, 'send');
  assert.equal(calls[0].payload.text, 'hello');
});

test('web transport reads Rust data and makes unavailable operations visible', async () => {
  const calls = [], snapshots = [];
  const data = {
    '/api/v1/sessions': [{ sessionId: 's', title: 'Session', agentType: 'fake' }],
    '/api/v1/threads': [], '/api/v1/projects': [],
    '/api/v1/sessions/s/history': [], '/api/v1/sessions/s/progress': { goal: null, todos: [] },
    '/api/v1/sessions/s/messages': { turnId: 't' },
  };
  const window = { pharosWorkspace: { update: value => snapshots.push(value) } };
  class FakeWebSocket { constructor() {} }
  const fetch = async (path, options) => { calls.push({ path, options }); return { ok: true, json: async () => data[path] }; };
  vm.runInNewContext(script, { window, fetch, document: { getElementById: () => ({}) }, matchMedia: () => ({ matches: false }), location: { protocol: 'http:', host: 'localhost' }, WebSocket: FakeWebSocket, encodeURIComponent });
  window.pharosTransport.start();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(snapshots.at(-1).selection, 's');
  await window.pharosTransport.dispatch('send', { id: 's', tab: 'sessions', text: 'hello', requestID: 'r', files: [] });
  assert.equal(JSON.parse(calls.find(c => c.path.endsWith('/messages')).options.body).requestId, 'r');
  await window.pharosTransport.dispatch('sessionConfig', {});
  assert.match(snapshots.at(-1).error, /unavailable/);
  await window.pharosTransport.dispatch('send', { id: 's', tab: 'sessions', text: '/goal', requestID: 'r2', files: [] });
  assert.match(snapshots.at(-1).error, /Session commands.*unavailable/);
  assert.equal(calls.filter(c => c.path.endsWith('/messages')).length, 1);
});
