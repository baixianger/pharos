// One boundary for native WebKit and the Rust HTTP/WS API.
(() => {
  const bridge = window.webkit?.messageHandlers?.pharosBridge;
  let state;
  let collections = { sessions: [], threads: [], projects: [] };
  let generation = 0;
  let socketGeneration = 0;
  let reconnectTimer = null;
  let reconnectDelay = 200;
  const disconnected = 'Live updates disconnected; reconnecting…';
  const identity = { shape: 'sphere', color: 'black' };
  const enc = encodeURIComponent;
  const unavailable = action => { throw new Error(`${action} is unavailable: the Rust API does not expose this operation`); };
  async function request(path, body) {
    const response = await fetch(path, body === undefined ? {} : {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
    });
    if (!response.ok) throw new Error(`${path}: ${response.status} ${response.statusText}`);
    return response.json();
  }
  function publish() { if (state && window.pharosWorkspace) window.pharosWorkspace.update({ ...state }); }
  function row(item, tab) {
    const id = tab === 'sessions' ? item.sessionId : tab === 'threads' ? item.threadId : (item.projectId || item.projectPath);
    return { id, title: item.title || item.name || id, subtitle: tab === 'sessions' ? item.agentType : '', identity, members: [] };
  }
  function turn(t) {
    return { ...t, steps: (t.assistantText || []).length ? [{ stepId: `${t.turnId}-step1`, stepNumber: 1, status: 'completed', blocks: t.assistantText.map((text, i) => ({ blockId: `${t.turnId}-${i}`, kind: { type: 'assistantText', text } })) }] : [] };
  }
  function normalizeApproval(approval) {
    const choices = { allowedOnce: 'allowed_once', allowedAlways: 'allowed_always' };
    return { ...approval, availableChoices: approval.availableChoices?.map(choice => choices[choice] || choice) };
  }
  function upsertApproval(approval) {
    const normalized = normalizeApproval(approval);
    const index = state.pendingApprovals.findIndex(item => item.approvalId === normalized.approvalId);
    if (index === -1) state.pendingApprovals.push(normalized);
    else state.pendingApprovals[index] = normalized;
  }
  function removeApproval(approvalId) {
    state.pendingApprovals = state.pendingApprovals.filter(item => item.approvalId !== approvalId);
  }
  function pickApproval() {
    if (!state.selection) return null;
    const pending = state.pendingApprovals.filter(item => item.sessionId === state.selection);
    pending.sort((a, b) => String(a.createdAt || '').localeCompare(String(b.createdAt || '')));
    return pending[0] ?? null;
  }
  function syncApproval() { state.approval = pickApproval(); }
  async function loadApprovals() {
    const snapshot = await request('/api/v1/approvals?state=pending');
    state.pendingApprovals = (Array.isArray(snapshot?.approvals) ? snapshot.approvals : []).map(normalizeApproval);
    syncApproval();
    publish();
  }
  async function refresh() {
    const current = ++generation;
    const [sessions, threads, projects] = await Promise.all(['sessions', 'threads', 'projects'].map(x => request(`/api/v1/${x}`)));
    if (current !== generation) return;
    collections = { sessions, threads, projects };
    const rows = collections[state.tab].map(x => row(x, state.tab));
    let selection = state.selection;
    if (!rows.some(x => x.id === selection)) selection = rows[0]?.id ?? null;
    let turns = [], messages = [], progress = { goal: null, todos: [] };
    if (selection && state.tab === 'sessions') {
      [turns, progress] = await Promise.all([request(`/api/v1/sessions/${enc(selection)}/history`), request(`/api/v1/sessions/${enc(selection)}/progress`)]);
      turns = turns.map(turn);
    } else if (selection && state.tab === 'threads') {
      messages = (await request(`/api/v1/threads/${enc(selection)}/messages`)).map(m => ({ ...m, attachments: [] }));
    }
    if (current !== generation) return;
    const selected = collections[state.tab].find(x => row(x, state.tab).id === selection);
    Object.assign(state, { rows, selection, title: selected?.title || selected?.name || 'Pharos', turns, messages,
      goal: progress?.goal ?? null, todos: progress?.todos ?? [],
      detail: selected ? { sessionID: selected.sessionId || '', agent: selected.agentType || '', host: selected.machineId || '', status: selected.status || '', workspace: selected.workspacePath || selected.projectPath || '', model: '', mode: '', models: [] } : null,
      projectHosts: selected?.trackedDevices || [], projectInventoryLoaded: !!selected?.relatedSessionIds,
      projectSessions: sessions.filter(s => selected?.relatedSessionIds?.includes(s.sessionId)) });
    syncApproval();
    publish();
  }
  async function dispatch(action, payload = {}) {
    if (bridge) { bridge.postMessage({ action, payload }); return; }
    try {
      if (action === 'selectTab') { state.error = null; state.tab = payload.tab; state.selection = null; await refresh(); }
      else if (action === 'selectRow') { state.error = null; state.selection = payload.id; await refresh(); }
      else if (action === 'openProjectSession') { state.tab = 'sessions'; state.selection = payload.sessionId; await refresh(); }
      else if (action === 'dismissError') { state.error = null; publish(); }
      else if (action === 'send') {
        if (payload.files?.length) unavailable('Session attachments');
        if (payload.tab === 'sessions' && !payload.steer && payload.text.trimStart().startsWith('/')) unavailable('Session commands');
        state.error = null;
        const suffix = payload.tab === 'threads' ? 'threads' : 'sessions';
        const endpoint = payload.steer ? 'steer' : 'messages';
        await request(`/api/v1/${suffix}/${enc(payload.id)}/${endpoint}`, { text: payload.text, ...(payload.requestID && !payload.steer && suffix === 'sessions' ? { requestId: payload.requestID } : {}) });
        state.submissionResults = { [payload.id]: { requestID: payload.requestID, accepted: true } };
        await refresh();
      } else if (action === 'resolveApproval') {
        if (Object.values(payload.answers || {}).some(v => v.length)) unavailable('Questionnaire answers');
        const decision = { allowed_once: 'allowedOnce', allowed_always: 'allowedAlways', rejected: 'rejected' }[payload.choice];
        if (!decision) unavailable('Approval choice');
        await request(`/api/v1/sessions/${enc(payload.sessionId)}/approval`, { approvalId: payload.approvalId, decision });
        removeApproval(payload.approvalId);
        state.approval = null;
        await refresh();
      } else unavailable(action);
    } catch (error) {
      if (action === 'send') state.submissionResults = { [payload.id]: { requestID: payload.requestID, accepted: false } };
      state.error = error.message || String(error); publish();
    }
  }
  async function refreshLive() {
    try {
      await loadApprovals();
      await refresh();
    } catch (error) {
      state.error = error.message || String(error);
      publish();
    }
  }
  function scheduleReconnect() {
    if (reconnectTimer !== null) return;
    const delay = reconnectDelay;
    reconnectDelay = Math.min(reconnectDelay * 2, 10000);
    reconnectTimer = setTimeout(() => { reconnectTimer = null; connect(); }, delay);
  }
  function connect() {
    if (bridge || !state) return;
    const current = ++socketGeneration;
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${scheme}//${location.host}/api/v1/events`);
    ws.onopen = () => {
      if (current !== socketGeneration) return;
      reconnectDelay = 200;
      if (state.error === disconnected) state.error = null;
      publish();
      refreshLive();
    };
    ws.onmessage = message => {
      if (current !== socketGeneration) return;
      try {
        const event = JSON.parse(message.data);
        if ((event.eventType === 'approvalRequired' || event.eventType === 'approvalUpdated') && event.approval) {
          upsertApproval(event.approval);
          syncApproval();
          publish();
        } else if (event.eventType === 'approvalWithdrawn' || event.eventType === 'approvalResolved') {
          removeApproval(event.approvalId);
          syncApproval();
          publish();
        }
      } catch { state.error = 'Invalid live event received'; publish(); }
      refresh().catch(error => { state.error = error.message; publish(); });
    };
    ws.onclose = () => {
      if (current !== socketGeneration) return;
      state.error = disconnected;
      publish();
      scheduleReconnect();
    };
  }
  function start() {
    if (bridge || !document.getElementById('grok-ui-mockup')) return;
    state = { tab: 'sessions', selection: null, title: 'Pharos', theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light', rows: [], identity, activity: 'idle', canSend: true, detail: null, turns: [], streamingText: '', reasoningText: '', tools: [], approval: null, pendingApprovals: [], goal: null, todos: [], messages: [], members: [], error: null, submissionResults: {} };
    publish();
    loadApprovals().catch(error => { state.error = error.message || String(error); publish(); });
    refresh().catch(error => { state.error = error.message; publish(); });
    connect();
  }
  window.pharosTransport = Object.freeze({ dispatch, start });
})();
