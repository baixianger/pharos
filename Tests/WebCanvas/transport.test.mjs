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
    '/api/v1/approvals?state=pending': { approvals: [] },
  };
  const window = { pharosWorkspace: { update: value => snapshots.push(value) } };
  let socket;
  class FakeWebSocket { constructor() { socket = this; queueMicrotask(() => this.onopen?.()); } }
  const fetch = async (path, options) => { calls.push({ path, options }); return { ok: true, json: async () => data[path] }; };
  vm.runInNewContext(script, { window, fetch, document: { getElementById: () => ({}) }, matchMedia: () => ({ matches: false }), location: { protocol: 'http:', host: 'localhost' }, WebSocket: FakeWebSocket, encodeURIComponent, setTimeout, clearTimeout });
  window.pharosTransport.start();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(snapshots.at(-1).selection, 's');
  socket.onmessage({ data: JSON.stringify({ eventType: 'approvalRequired', approval: { approvalId: 'a', sessionId: 's', availableChoices: ['allowedOnce'] } }) });
  assert.equal(snapshots.at(-1).approval.availableChoices[0], 'allowed_once');
  socket.onmessage({ data: JSON.stringify({ eventType: 'approvalWithdrawn', approvalId: 'a' }) });
  assert.equal(snapshots.at(-1).approval, null);
  await window.pharosTransport.dispatch('send', { id: 's', tab: 'sessions', text: 'hello', requestID: 'r', files: [] });
  assert.equal(JSON.parse(calls.find(c => c.path.endsWith('/messages')).options.body).requestId, 'r');
  await window.pharosTransport.dispatch('sessionConfig', {});
  assert.match(snapshots.at(-1).error, /unavailable/);
  await window.pharosTransport.dispatch('send', { id: 's', tab: 'sessions', text: '/goal', requestID: 'r2', files: [] });
  assert.match(snapshots.at(-1).error, /Session commands.*unavailable/);
  assert.equal(calls.filter(c => c.path.endsWith('/messages')).length, 1);
});

test('web transport restores pending approvals, dedupes live events, and recovers after reconnect', async () => {
  const calls = [], snapshots = [], sockets = [];
  const pending = {
    approvalId: 'a', sessionId: 's', kind: { type: 'toolCall', toolName: 'Shell' },
    availableChoices: ['allowedOnce', 'allowedAlways'], state: 'pending',
    createdAt: '2026-01-01T00:00:00Z', expiresAt: '2026-01-01T00:45:00Z',
  };
  const data = {
    '/api/v1/sessions': [{ sessionId: 's', title: 'Session', agentType: 'fake' }],
    '/api/v1/threads': [], '/api/v1/projects': [],
    '/api/v1/sessions/s/history': [], '/api/v1/sessions/s/progress': { goal: null, todos: [] },
    '/api/v1/approvals?state=pending': { approvals: [pending] },
  };
  const window = { pharosWorkspace: { update: value => snapshots.push(value) } };
  class FakeWebSocket { constructor() { sockets.push(this); queueMicrotask(() => this.onopen?.()); } }
  const fetch = async (path, options) => { calls.push({ path, options }); return { ok: true, json: async () => data[path] }; };
  vm.runInNewContext(script, { window, fetch, document: { getElementById: () => ({}) }, matchMedia: () => ({ matches: false }), location: { protocol: 'http:', host: 'localhost' }, WebSocket: FakeWebSocket, encodeURIComponent, setTimeout, clearTimeout });
  window.pharosTransport.start();
  await new Promise(resolve => setImmediate(resolve));
  const approvalsPath = '/api/v1/approvals?state=pending';
  assert.ok(calls.some(c => c.path === approvalsPath), 'approvals snapshot was fetched');
  assert.equal(snapshots.at(-1).approval.approvalId, 'a');
  assert.equal(snapshots.at(-1).approval.availableChoices[0], 'allowed_once');
  assert.equal(snapshots.at(-1).pendingApprovals.length, 1);

  sockets[0].onmessage({ data: JSON.stringify({ eventType: 'approvalUpdated', approval: { ...pending, kind: { type: 'toolCall', toolName: 'Write' } } }) });
  assert.equal(snapshots.at(-1).pendingApprovals.length, 1, 'dedupe by approvalId');
  assert.equal(snapshots.at(-1).approval.approvalId, 'a');
  assert.equal(snapshots.at(-1).approval.kind.toolName, 'Write');

  sockets[0].onmessage({ data: JSON.stringify({ eventType: 'approvalResolved', approvalId: 'a' }) });
  assert.equal(snapshots.at(-1).approval, null);
  assert.equal(snapshots.at(-1).pendingApprovals.length, 0);

  sockets[0].onmessage({ data: JSON.stringify({ eventType: 'approvalRequired', approval: pending }) });
  assert.equal(snapshots.at(-1).approval.approvalId, 'a');
  await window.pharosTransport.dispatch('resolveApproval', { choice: 'allowed_once', approvalId: 'a', sessionId: 's' });
  const posted = JSON.parse(calls.find(c => c.path === '/api/v1/sessions/s/approval').options.body);
  assert.deepEqual(posted, { approvalId: 'a', decision: 'allowedOnce' });
  assert.equal(snapshots.at(-1).approval, null);
  assert.equal(snapshots.at(-1).pendingApprovals.length, 0);

  const snapshotFetches = calls.filter(c => c.path === approvalsPath).length;
  const socketCount = sockets.length;
  sockets[0].onclose();
  assert.match(snapshots.at(-1).error, /reconnecting/);
  await new Promise(resolve => setTimeout(resolve, 400));
  assert.equal(sockets.length, socketCount + 1, 'a second WebSocket was constructed');
  assert.ok(calls.filter(c => c.path === approvalsPath).length > snapshotFetches, 'approvals snapshot reloaded on reconnect');
});
