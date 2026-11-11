import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const script = await readFile(new URL('../../Sources/Pharos/Resources/WebCanvas/transport.js', import.meta.url), 'utf8');

const settle = () => new Promise(resolve => setImmediate(resolve));
const ok = body => ({ ok: true, json: async () => body });
const fail = (status, error, statusText = 'Error') => ({ ok: false, status, statusText, json: async () => ({ error }) });
const jsonBody = call => JSON.parse(call.options.body);
// Values created inside the vm realm have a different Object.prototype.
const plain = value => JSON.parse(JSON.stringify(value));

function boot({ data = {}, respond } = {}) {
  const calls = [], snapshots = [], sockets = [];
  const window = { pharosWorkspace: { update: value => snapshots.push(value) } };
  class FakeWebSocket {
    constructor(url) { this.url = url; sockets.push(this); queueMicrotask(() => this.onopen?.()); }
  }
  const fetch = async (path, options = {}) => {
    const call = { path, method: options.method || 'GET', options };
    calls.push(call);
    const reply = respond?.(call, { snapshots, calls, data });
    if (reply) return reply;
    const key = `${call.method} ${path}`;
    return ok(key in data ? data[key] : data[path]);
  };
  vm.runInNewContext(script, {
    window, fetch,
    document: { getElementById: () => ({}) },
    matchMedia: () => ({ matches: false }),
    location: { protocol: 'http:', host: 'localhost' },
    WebSocket: FakeWebSocket, encodeURIComponent, setTimeout, clearTimeout
  });
  return { window, calls, snapshots, sockets };
}

function session(id, extra = {}) {
  return { sessionId: id, title: `Session ${id}`, agentType: 'fake', machineId: 'host-a', status: 'idle', ...extra };
}

function config(overrides = {}) {
  return {
    sessionId: 's', supported: true, supportedFields: ['model', 'mode'],
    model: 'gpt-5', mode: 'safe', models: ['gpt-5', 'gpt-6'],
    modes: [{ value: 'safe', name: 'Safe' }, { value: 'yolo', name: 'YOLO' }],
    capabilities: { attachments: true, commands: false, stop: false, revive: false },
    readonly: false, ...overrides
  };
}

function webData(overrides = {}) {
  return Object.assign({
    '/api/v1/sessions': [session('s')],
    '/api/v1/threads': [],
    '/api/v1/projects': [],
    '/api/v1/sessions/s/history': [],
    '/api/v1/sessions/s/progress': { goal: null, todos: [] },
    '/api/v1/sessions/s/config': config(),
    '/api/v1/sessions/s/attachments': { attachments: [] },
    '/api/v1/members/human': { memberId: 'human', avatarShape: 'starFlower', avatarColor: 'blue' },
    '/api/v1/approvals?state=pending': { approvals: [] }
  }, overrides);
}

test('native transport forwards actions to WebKit without HTTP', async () => {
  const calls = [];
  const window = { webkit: { messageHandlers: { pharosBridge: { postMessage: value => calls.push(value) } } } };
  vm.runInNewContext(script, { window });
  await window.pharosTransport.dispatch('send', { text: 'hello' });
  await window.pharosTransport.dispatch('sessionConfig', { id: 's', configId: 'model', value: 'gpt-5' });
  await window.pharosTransport.dispatch('cancelled', { approvalId: 'a' });
  assert.equal(calls[0].action, 'send');
  assert.equal(calls[0].payload.text, 'hello');
  assert.equal(calls[1].action, 'sessionConfig');
  assert.equal(calls[2].action, 'cancelled');
});

test('web transport loads session config, session attachments and the persisted human identity', async () => {
  const metadata = { attachmentId: 'att-1', sessionId: 's', filename: 'notes.txt', contentType: 'text/plain', sizeBytes: 5, sha256: 'abc', createdAt: '2026-01-01T00:00:00Z' };
  const data = webData({ '/api/v1/sessions/s/attachments': { attachments: [metadata] } });
  const { window, calls, snapshots } = boot({ data });
  window.pharosTransport.start();
  await settle();
  const state = snapshots.at(-1);

  assert.ok(calls.some(call => call.path === '/api/v1/sessions/s/config' && call.method === 'GET'), 'config is fetched with GET');
  assert.ok(calls.some(call => call.path === '/api/v1/sessions/s/attachments' && call.method === 'GET'), 'session attachments are fetched with GET');
  assert.ok(calls.some(call => call.path === '/api/v1/members/human' && call.method === 'GET'), 'human identity is fetched with GET');

  assert.deepEqual(plain(state.sessionConfiguration), [
    {
      type: 'select', id: 'model', name: 'Model', currentValue: 'gpt-5',
      options: [{ value: 'gpt-5', name: 'gpt-5' }, { value: 'gpt-6', name: 'gpt-6' }], readOnly: false
    },
    {
      type: 'select', id: 'mode', name: 'Mode', currentValue: 'safe',
      options: [{ value: 'safe', name: 'Safe' }, { value: 'yolo', name: 'YOLO' }], readOnly: false
    }
  ]);
  assert.equal(state.detail.model, 'gpt-5');
  assert.equal(state.detail.mode, 'safe');
  assert.deepEqual(plain(state.detail.models), ['gpt-5', 'gpt-6']);
  assert.equal(state.supportsTextAttachments, true, 'capability drives the composer attach menu');
  assert.equal(state.capabilities.attachments, true);
  assert.deepEqual(plain(state.identity), { shape: 'starFlower', color: 'blue' });
  assert.deepEqual(plain(state.rows[0].identity), { shape: 'starFlower', color: 'blue' });
  assert.equal(state.attachments.length, 1);
  assert.equal(state.attachments[0].filename, 'notes.txt');

  await window.pharosTransport.dispatch('send', { id: 's', tab: 'sessions', text: '/goal', requestID: 'r-cmd', files: [] });
  assert.match(snapshots.at(-1).error, /Session commands.*unavailable/);
  assert.equal(calls.filter(call => call.path.endsWith('/messages')).length, 0, 'commands never reach the message route');
});

test('web transport reports an unsupported config view honestly and never invents models', async () => {
  const unsupported = {
    sessionId: 's', supported: false, supportedFields: [], model: null, mode: null, models: [], modes: [],
    capabilities: { attachments: false, commands: false, stop: false, revive: false }, readonly: true
  };
  const data = webData({ '/api/v1/sessions/s/config': unsupported });
  const { window, calls, snapshots } = boot({ data });
  window.pharosTransport.start();
  await settle();
  const state = snapshots.at(-1);
  assert.deepEqual(plain(state.sessionConfiguration), [{ type: 'status', name: 'Configuration unavailable' }]);
  assert.equal(state.detail.model, '');
  assert.equal(state.detail.mode, '');
  assert.deepEqual(state.detail.models, []);
  assert.equal(state.supportsTextAttachments, false);
  assert.equal(state.attachments.length, 0);
  assert.equal(calls.filter(call => call.path === '/api/v1/sessions/s/attachments').length, 0, 'no attachment fetch without the capability');
});

test('web transport loads thread members, bindings and unbound binding candidates', async () => {
  const data = webData({
    '/api/v1/sessions': [session('s1'), session('s2'), session('s3')],
    '/api/v1/threads': [{ threadId: 't1', title: 'Thread', memberIds: ['human', 'bot'] }],
    '/api/v1/sessions/s1/history': [],
    '/api/v1/sessions/s1/progress': { goal: null, todos: [] },
    '/api/v1/sessions/s1/config': config({ sessionId: 's1' }),
    '/api/v1/threads/t1/messages': [],
    '/api/v1/threads/t1/members': {
      members: [
        { memberId: 'human', nick: 'human' },
        { memberId: 'bot', nick: 'Grok', agentType: 'fake', machineId: 'host-b', status: 'idle', sessionId: 's2', boundAt: '2026-01-01T00:00:00Z', settings: { memberId: 'bot', avatarShape: 'square', avatarColor: 'red' } }
      ]
    },
    '/api/v1/threads/t1/bindings': { bindings: [{ threadId: 't1', member: 'bot', sessionId: 's2' }] }
  });
  const { window, calls, snapshots } = boot({ data });
  window.pharosTransport.start();
  await settle();
  await window.pharosTransport.dispatch('selectTab', { tab: 'threads' });
  await settle();
  const state = snapshots.at(-1);

  assert.ok(calls.some(call => call.path === '/api/v1/threads/t1/members' && call.method === 'GET'), 'thread members fetched');
  assert.ok(calls.some(call => call.path === '/api/v1/threads/t1/bindings' && call.method === 'GET'), 'thread bindings fetched');
  assert.equal(state.members.length, 2);
  const bot = state.members.find(member => member.name === 'Grok');
  assert.ok(bot, 'nick is used as the member name');
  assert.equal(bot.id, 'bot');
  assert.equal(bot.agent, 'fake');
  assert.equal(bot.machine, 'host-b');
  assert.equal(bot.status, 'idle');
  assert.equal(bot.sessionId, 's2');
  assert.equal(bot.settings.avatarShape, 'square');
  assert.deepEqual(plain(bot.identity), { shape: 'square', color: 'red' }, 'persisted member avatar settings win');
  assert.equal(state.canBindThreadSession, true);
  assert.deepEqual(state.threadBindingCandidates.map(item => item.sessionId), ['s1', 's3'], 'already-bound sessions are excluded');
  assert.equal(state.threadBindings.length, 1);
});

test('web transport PATCHes session config with in-flight state and keeps the server view', async () => {
  const data = webData();
  let inFlightDuringPatch = null;
  const patches = [];
  const respond = (call, ctx) => {
    if (call.method === 'PATCH' && call.path === '/api/v1/sessions/s/config') {
      inFlightDuringPatch = ctx.snapshots.at(-1)?.configurationInFlight;
      patches.push(jsonBody(call));
      data['/api/v1/sessions/s/config'] = config({ model: 'gpt-6' });
      return ok(data['/api/v1/sessions/s/config']);
    }
  };
  const { window, snapshots } = boot({ data, respond });
  window.pharosTransport.start();
  await settle();
  await window.pharosTransport.dispatch('sessionConfig', { tab: 'sessions', id: 's', configId: 'model', value: 'gpt-6' });
  await settle();
  assert.deepEqual(patches, [{ model: 'gpt-6' }], 'sessionConfig PATCHes only the changed field');
  assert.equal(inFlightDuringPatch, true, 'controls are disabled while the PATCH is in flight');
  const state = snapshots.at(-1);
  assert.equal(state.configurationInFlight, false);
  assert.equal(state.detail.model, 'gpt-6');
  assert.equal(state.sessionConfiguration[0].currentValue, 'gpt-6');
});

test('web transport sends model/mode as single-field PATCH bodies and surfaces 502 unsupportedField', async () => {
  const data = webData();
  const patches = [];
  let failMode = true;
  const respond = (call) => {
    if (call.method === 'PATCH' && call.path === '/api/v1/sessions/s/config') {
      patches.push(jsonBody(call));
      if (failMode && jsonBody(call).mode) {
        return fail(502, { code: 'unsupportedField', field: 'mode', message: 'Adapter cannot change mode' }, 'Bad Gateway');
      }
      data['/api/v1/sessions/s/config'] = config({ ...data['/api/v1/sessions/s/config'], ...jsonBody(call) });
      return ok(data['/api/v1/sessions/s/config']);
    }
  };
  const { window, snapshots } = boot({ data, respond });
  window.pharosTransport.start();
  await settle();
  await window.pharosTransport.dispatch('model', { id: 's', tab: 'sessions', value: 'gpt-6' });
  await settle();
  assert.deepEqual(patches[0], { model: 'gpt-6' });
  assert.equal(snapshots.at(-1).detail.model, 'gpt-6');

  await window.pharosTransport.dispatch('mode', { id: 's', tab: 'sessions', value: 'yolo' });
  await settle();
  assert.deepEqual(patches[1], { mode: 'yolo' });
  assert.match(snapshots.at(-1).error, /502/, 'the HTTP status is surfaced');
  assert.match(snapshots.at(-1).error, /Adapter cannot change mode/, 'the server error text is surfaced');
  assert.equal(snapshots.at(-1).configurationInFlight, false);
  assert.equal(snapshots.at(-1).detail.mode, 'safe', 'a failed write never reports success');
});

test('web transport binds a thread session with PUT then refreshes', async () => {
  const data = webData({
    '/api/v1/threads': [{ threadId: 't1', title: 'Thread', memberIds: ['human', 'bot'] }],
    '/api/v1/threads/t1/messages': [],
    '/api/v1/threads/t1/members': { members: [{ memberId: 'human', nick: 'human' }] },
    '/api/v1/threads/t1/bindings': { bindings: [] }
  });
  let inFlightDuringPut = null;
  let putBody = null;
  const respond = (call, ctx) => {
    if (call.method === 'PUT' && call.path === '/api/v1/threads/t1/bindings/scout') {
      inFlightDuringPut = ctx.snapshots.at(-1)?.threadBindingInFlight;
      putBody = jsonBody(call);
      return ok({ threadId: 't1', member: 'scout', sessionId: 's1', boundAt: '2026-01-01T00:00:00Z' });
    }
  };
  const { window, calls, snapshots } = boot({ data, respond });
  window.pharosTransport.start();
  await settle();
  await window.pharosTransport.dispatch('selectTab', { tab: 'threads' });
  await settle();
  await window.pharosTransport.dispatch('bindThreadSession', { id: 't1', tab: 'threads', sessionId: 's1', nickname: 'scout' });
  await settle();
  const put = calls.find(call => call.path === '/api/v1/threads/t1/bindings/scout');
  assert.ok(put, 'binding uses the threaded PUT route');
  assert.equal(put.method, 'PUT');
  assert.deepEqual(putBody, { sessionId: 's1' });
  assert.equal(inFlightDuringPut, true, 'the add button is disabled while binding');
  assert.equal(snapshots.at(-1).threadBindingInFlight, false);
});

test('web transport surfaces binding failures instead of pretending the member was added', async () => {
  const data = webData({
    '/api/v1/threads': [{ threadId: 't1', title: 'Thread', memberIds: ['human'] }],
    '/api/v1/threads/t1/messages': [],
    '/api/v1/threads/t1/members': { members: [{ memberId: 'human', nick: 'human' }] },
    '/api/v1/threads/t1/bindings': { bindings: [] }
  });
  const respond = call => call.method === 'PUT'
    ? fail(400, { code: 'invalidRequest', message: 'member not in ThreadSummary.memberIds' }, 'Bad Request')
    : undefined;
  const { window, snapshots } = boot({ data, respond });
  window.pharosTransport.start();
  await settle();
  await window.pharosTransport.dispatch('selectTab', { tab: 'threads' });
  await settle();
  await window.pharosTransport.dispatch('bindThreadSession', { id: 't1', tab: 'threads', sessionId: 's1', nickname: 'scout' });
  await settle();
  assert.match(snapshots.at(-1).error, /member not in ThreadSummary\.memberIds/);
  assert.equal(snapshots.at(-1).threadBindingInFlight, false);
});

test('web transport persists avatar and reset through PATCH /members/human and reloads identity on start', async () => {
  const data = webData();
  const patches = [];
  const respond = call => {
    if (call.method === 'PATCH' && call.path === '/api/v1/members/human') {
      const body = jsonBody(call);
      patches.push(body);
      return ok({ memberId: 'human', avatarShape: body.avatarShape, avatarColor: body.avatarColor });
    }
  };
  const { window, snapshots } = boot({ data, respond });
  window.pharosTransport.start();
  await settle();
  assert.deepEqual(plain(snapshots.at(-1).identity), { shape: 'starFlower', color: 'blue' }, 'identity loaded from the member API');

  await window.pharosTransport.dispatch('avatar', { id: 's', tab: 'sessions', shape: 'hex', color: 'magenta' });
  await settle();
  assert.deepEqual(patches[0], { avatarShape: 'hex', avatarColor: 'magenta' });
  assert.deepEqual(plain(snapshots.at(-1).identity), { shape: 'hex', color: 'magenta' });
  assert.deepEqual(plain(snapshots.at(-1).rows[0].identity), { shape: 'hex', color: 'magenta' });

  await window.pharosTransport.dispatch('resetAvatar', { id: 's', tab: 'sessions' });
  await settle();
  assert.deepEqual(patches[1], { avatarShape: 'sphere', avatarColor: 'black' });
  assert.deepEqual(plain(snapshots.at(-1).identity), { shape: 'sphere', color: 'black' });
});

test('web transport uploads attachments then sends the message with attachmentIds', async () => {
  const data = webData();
  const uploads = [], messages = [];
  const respond = call => {
    if (call.method === 'POST' && call.path === '/api/v1/sessions/s/attachments') {
      const body = jsonBody(call);
      uploads.push(body);
      return ok({ attachmentId: `att-${uploads.length}`, sessionId: 's', filename: body.filename, contentType: body.contentType });
    }
    if (call.method === 'POST' && call.path === '/api/v1/sessions/s/messages') {
      messages.push(jsonBody(call));
      return ok({ turnId: 'turn-1' });
    }
  };
  const { window, snapshots } = boot({ data, respond });
  window.pharosTransport.start();
  await settle();
  await window.pharosTransport.dispatch('send', {
    id: 's', tab: 'sessions', text: 'see files', requestID: 'r1', steer: false,
    files: [
      { name: 'notes.txt', contentType: '', data: 'aGVsbG8=' },
      { name: 'report', contentType: 'text/markdown', data: 'I2hp' }
    ]
  });
  await settle();
  assert.equal(uploads.length, 2, 'every file is uploaded first');
  assert.deepEqual(uploads[0], { filename: 'notes.txt', contentType: 'text/plain', dataBase64: 'aGVsbG8=' });
  assert.deepEqual(uploads[1], { filename: 'report', contentType: 'text/markdown', dataBase64: 'I2hp' });
  assert.deepEqual(messages[0], { text: 'see files', requestId: 'r1', attachmentIds: ['att-1', 'att-2'] });
  assert.equal(snapshots.at(-1).submissionResults.s.accepted, true);
});

test('web transport refuses attachments when the adapter capability is false', async () => {
  const data = webData({ '/api/v1/sessions/s/config': config({ capabilities: { attachments: false, commands: false, stop: false, revive: false } }) });
  const { window, calls, snapshots } = boot({ data });
  window.pharosTransport.start();
  await settle();
  await window.pharosTransport.dispatch('send', {
    id: 's', tab: 'sessions', text: 'see file', requestID: 'r2', steer: false,
    files: [{ name: 'notes.txt', contentType: 'text/plain', data: 'aGVsbG8=' }]
  });
  await settle();
  assert.match(snapshots.at(-1).error, /Attachments are unavailable/);
  assert.equal(calls.filter(call => call.path === '/api/v1/sessions/s/attachments').length, 0, 'no upload attempted');
  assert.equal(calls.filter(call => call.path.endsWith('/messages')).length, 0, 'no message sent');
  assert.equal(snapshots.at(-1).submissionResults.s.accepted, false);
});

test('web transport posts questionnaireAnswers and the cancelled decision, and keeps plain approvals unchanged', async () => {
  const data = webData();
  const approval = {
    approvalId: 'a', sessionId: 's', state: 'pending', createdAt: '2026-01-01T00:00:00Z',
    availableChoices: ['allowedOnce', 'cancelled', 'rejected'],
    kind: {
      type: 'structuredQuestionnaire',
      questions: [
        { id: 'q1', question: 'Pick', options: ['alpha', 'beta'], isMultiSelect: true, allowsFreeText: true },
        { id: 'q2', question: 'Other', options: [] }
      ]
    }
  };
  const bodies = [];
  const respond = call => {
    if (call.method === 'POST' && call.path === '/api/v1/sessions/s/approval') {
      bodies.push(jsonBody(call));
      return ok({ ok: true, approvalId: 'a', state: 'resolved', decision: jsonBody(call).decision });
    }
  };
  const { window, snapshots, sockets } = boot({ data, respond });
  window.pharosTransport.start();
  await settle();
  sockets[0].onmessage({ data: JSON.stringify({ eventType: 'approvalRequired', approval }) });
  assert.equal(snapshots.at(-1).approval.approvalId, 'a');

  await window.pharosTransport.dispatch('resolveApproval', {
    choice: 'cancelled', approvalId: 'a', sessionId: 's',
    answers: { q1: ['alpha', 'free text'], q2: ['typed answer'] }
  });
  await settle();
  assert.deepEqual(bodies[0], {
    approvalId: 'a', decision: 'cancelled',
    questionnaireAnswers: [
      { questionId: 'q1', selected: ['alpha'], text: 'free text' },
      { questionId: 'q2', selected: [], text: 'typed answer' }
    ]
  });
  assert.equal(snapshots.at(-1).approval, null);

  sockets[0].onmessage({ data: JSON.stringify({ eventType: 'approvalRequired', approval: { ...approval, kind: { type: 'toolCall', toolName: 'Shell' } } }) });
  await window.pharosTransport.dispatch('resolveApproval', { choice: 'allowed_once', approvalId: 'a', sessionId: 's' });
  await settle();
  assert.deepEqual(bodies[1], { approvalId: 'a', decision: 'allowedOnce' }, 'plain approvals keep the frozen body');
});

test('web transport POSTs stop/revive and surfaces 502 unsupported adapter errors', async () => {
  const data = webData();
  let succeedRevive = false;
  const respond = call => {
    if (call.method === 'POST' && call.path === '/api/v1/sessions/s/stop') {
      return fail(502, { code: 'unsupportedField', field: 'stop', message: 'stop is not supported by this adapter' }, 'Bad Gateway');
    }
    if (call.method === 'POST' && call.path === '/api/v1/sessions/s/revive') {
      return succeedRevive
        ? ok({ ok: true, sessionId: 's', status: 'idle' })
        : fail(502, { code: 'unsupportedField', field: 'revive', message: 'revive is not supported by this adapter' }, 'Bad Gateway');
    }
  };
  const { window, calls, snapshots } = boot({ data, respond });
  window.pharosTransport.start();
  await settle();

  await window.pharosTransport.dispatch('stop', { id: 's', tab: 'sessions' });
  await settle();
  const stop = calls.find(call => call.path === '/api/v1/sessions/s/stop');
  assert.ok(stop);
  assert.equal(stop.method, 'POST');
  assert.match(snapshots.at(-1).error, /502/);
  assert.match(snapshots.at(-1).error, /stop is not supported by this adapter/, 'the server error text is surfaced');
  assert.equal(snapshots.at(-1).detail.status, 'idle', 'a failed stop never fakes a stopped status');

  await window.pharosTransport.dispatch('revive', { id: 's', tab: 'sessions' });
  await settle();
  assert.ok(calls.some(call => call.path === '/api/v1/sessions/s/revive' && call.method === 'POST'));
  assert.match(snapshots.at(-1).error, /revive is not supported by this adapter/);

  succeedRevive = true;
  await window.pharosTransport.dispatch('revive', { id: 's', tab: 'sessions' });
  await settle();
  assert.equal(snapshots.at(-1).error, null, 'a successful lifecycle write clears the surfaced error');
});

test('web transport restores pending approvals, dedupes live events, and recovers after reconnect', async () => {
  const pending = {
    approvalId: 'a', sessionId: 's', kind: { type: 'toolCall', toolName: 'Shell' },
    availableChoices: ['allowedOnce', 'allowedAlways'], state: 'pending',
    createdAt: '2026-01-01T00:00:00Z', expiresAt: '2026-01-01T00:45:00Z'
  };
  const data = webData({ '/api/v1/approvals?state=pending': { approvals: [pending] } });
  const { window, calls, snapshots, sockets } = boot({ data });
  window.pharosTransport.start();
  await settle();
  const approvalsPath = '/api/v1/approvals?state=pending';
  assert.ok(calls.some(call => call.path === approvalsPath), 'approvals snapshot was fetched');
  assert.equal(snapshots.at(-1).approval.approvalId, 'a');
  assert.equal(snapshots.at(-1).approval.availableChoices[0], 'allowed_once');
  assert.equal(snapshots.at(-1).pendingApprovals.length, 1);

  sockets[0].onmessage({ data: JSON.stringify({ eventType: 'approvalUpdated', approval: { ...pending, kind: { type: 'toolCall', toolName: 'Write' } } }) });
  assert.equal(snapshots.at(-1).pendingApprovals.length, 1, 'dedupe by approvalId');
  assert.equal(snapshots.at(-1).approval.kind.toolName, 'Write');

  sockets[0].onmessage({ data: JSON.stringify({ eventType: 'approvalResolved', approvalId: 'a' }) });
  assert.equal(snapshots.at(-1).approval, null);
  assert.equal(snapshots.at(-1).pendingApprovals.length, 0);

  sockets[0].onmessage({ data: JSON.stringify({ eventType: 'approvalRequired', approval: pending }) });
  assert.equal(snapshots.at(-1).approval.approvalId, 'a');
  await window.pharosTransport.dispatch('resolveApproval', { choice: 'allowed_once', approvalId: 'a', sessionId: 's' });
  const posted = JSON.parse(calls.find(call => call.path === '/api/v1/sessions/s/approval').options.body);
  assert.deepEqual(posted, { approvalId: 'a', decision: 'allowedOnce' });
  assert.equal(snapshots.at(-1).approval, null);
  assert.equal(snapshots.at(-1).pendingApprovals.length, 0);

  const snapshotFetches = calls.filter(call => call.path === approvalsPath).length;
  const socketCount = sockets.length;
  sockets[0].onclose();
  assert.match(snapshots.at(-1).error, /reconnecting/);
  await new Promise(resolve => setTimeout(resolve, 400));
  assert.equal(sockets.length, socketCount + 1, 'a second WebSocket was constructed');
  assert.ok(calls.filter(call => call.path === approvalsPath).length > snapshotFetches, 'approvals snapshot reloaded on reconnect');
});
