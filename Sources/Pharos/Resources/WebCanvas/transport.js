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
  const defaultIdentity = { shape: 'sphere', color: 'black' };
  // The human's avatar identity is persisted by the Rust member API
  // (`GET/PATCH /api/v1/members/human`); the workspace renders it everywhere.
  let identity = { ...defaultIdentity };
  const enc = encodeURIComponent;
  const unavailable = action => { throw new Error(`${action} is unavailable: the Rust API does not expose this operation`); };
  const attachmentTypes = {
    txt: 'text/plain', md: 'text/markdown', markdown: 'text/markdown', csv: 'text/csv',
    json: 'application/json', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', pdf: 'application/pdf'
  };
  const allowedAttachmentTypes = Object.values(attachmentTypes);
  function attachmentContentType(file) {
    const declared = String(file?.contentType ?? file?.type ?? '').split(';', 1)[0].trim().toLowerCase();
    if (allowedAttachmentTypes.includes(declared)) return declared;
    const name = String(file?.name ?? '');
    const extension = name.includes('.') ? name.split('.').pop().toLowerCase() : '';
    return attachmentTypes[extension] ?? (declared || 'application/octet-stream');
  }
  async function requestError(path, response) {
    let detail = null;
    try { detail = await response.json(); } catch { /* non-JSON error body */ }
    const server = detail?.error;
    const message = server?.message || server?.code || response.statusText || 'Request failed';
    const error = new Error(`${path}: ${response.status} ${message}`);
    error.status = response.status;
    return error;
  }
  async function request(path, body, method) {
    const options = { method: method || (body === undefined ? 'GET' : 'POST') };
    if (body !== undefined) {
      options.headers = { 'Content-Type': 'application/json' };
      options.body = JSON.stringify(body);
    }
    const response = await fetch(path, options);
    if (!response.ok) throw await requestError(path, response);
    return response.json();
  }
  function publish() { if (state && window.pharosWorkspace) window.pharosWorkspace.update({ ...state }); }
  function stableHash(text) {
    let hash = 2166136261;
    for (const char of text) hash = Math.imul(hash ^ char.codePointAt(0), 16777619);
    return hash >>> 0;
  }
  function seededIdentity(seed) {
    const avatars = window.pharosAvatars;
    const colors = avatars?.colors && typeof avatars.colors === 'object' ? Object.keys(avatars.colors) : [];
    if (!avatars?.shapes?.length || !colors.length) return { ...identity };
    const hash = stableHash(String(seed ?? ''));
    return { shape: avatars.shapes[hash % avatars.shapes.length], color: colors[(hash >>> 8) % colors.length] };
  }
  function row(item, tab) {
    const id = tab === 'sessions' ? item.sessionId : tab === 'threads' ? item.threadId : (item.projectId || item.projectPath);
    return { id, title: item.title || item.name || id, subtitle: tab === 'sessions' ? item.agentType : '', identity: { ...identity }, members: [] };
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
  // Member settings view -> the roster shape the workspace renders.
  function memberView(member) {
    const name = member?.nick || member?.memberId || '';
    const settings = member?.settings && typeof member.settings === 'object' ? member.settings : null;
    const view = {
      id: member?.memberId ?? name,
      name,
      agent: member?.agentType ?? '',
      machine: member?.machineId ?? '',
      status: member?.status ?? '',
      sessionId: member?.sessionId ?? null,
      avatarSeed: name,
      identity: seededIdentity(name),
      settings
    };
    if (typeof settings?.avatarShape === 'string' && settings.avatarShape) view.identity.shape = settings.avatarShape;
    if (typeof settings?.avatarColor === 'string' && settings.avatarColor) view.identity.color = settings.avatarColor;
    return view;
  }
  // Session config view -> the select controls the workspace renders. An honest
  // empty view (or a failed fetch) is reported as unavailable, never invented.
  function sessionControls(config) {
    if (!config || config.supported !== true) return [{ type: 'status', name: 'Configuration unavailable' }];
    const fields = Array.isArray(config.supportedFields) && config.supportedFields.length ? config.supportedFields : ['model', 'mode'];
    const models = Array.isArray(config.models) ? config.models : [];
    const modes = Array.isArray(config.modes) ? config.modes : [];
    return [
      {
        type: 'select', id: 'model', name: 'Model',
        currentValue: typeof config.model === 'string' ? config.model : '',
        options: models.map(model => ({ value: model, name: model })),
        readOnly: config.readonly === true || !fields.includes('model')
      },
      {
        type: 'select', id: 'mode', name: 'Mode',
        currentValue: typeof config.mode === 'string' ? config.mode : '',
        options: modes.filter(mode => typeof mode?.value === 'string').map(mode => ({ value: mode.value, name: mode.name || mode.value })),
        readOnly: config.readonly === true || !fields.includes('mode')
      }
    ];
  }
  function applyIdentity(member) {
    if (!member || typeof member !== 'object') return false;
    let changed = false;
    if (typeof member.avatarShape === 'string' && member.avatarShape && member.avatarShape !== identity.shape) { identity.shape = member.avatarShape; changed = true; }
    if (typeof member.avatarColor === 'string' && member.avatarColor && member.avatarColor !== identity.color) { identity.color = member.avatarColor; changed = true; }
    if (!changed) return false;
    state.identity = { ...identity };
    state.rows = (state.rows ?? []).map(item => ({ ...item, identity: { ...identity } }));
    return true;
  }
  async function loadIdentity() {
    const member = await request('/api/v1/members/human');
    if (applyIdentity(member)) publish();
  }
  async function refresh() {
    const current = ++generation;
    const tab = state.tab;
    const [sessions, threads, projects] = await Promise.all(['sessions', 'threads', 'projects'].map(x => request(`/api/v1/${x}`)));
    if (current !== generation) return;
    collections = { sessions, threads, projects };
    const rows = collections[tab].map(x => row(x, tab));
    let selection = state.selection;
    if (!rows.some(x => x.id === selection)) selection = rows[0]?.id ?? null;
    let turns = [], messages = [], progress = { goal: null, todos: [] };
    let config = null, attachments = [], members = [], bindings = [], viewError = null;
    if (selection && tab === 'sessions') {
      const [history, sessionProgress] = await Promise.all([request(`/api/v1/sessions/${enc(selection)}/history`), request(`/api/v1/sessions/${enc(selection)}/progress`)]);
      turns = (history ?? []).map(turn);
      progress = sessionProgress ?? progress;
      try {
        config = await request(`/api/v1/sessions/${enc(selection)}/config`);
      } catch (error) {
        viewError = error.message || String(error);
      }
      if (config?.capabilities?.attachments === true) {
        try {
          attachments = (await request(`/api/v1/sessions/${enc(selection)}/attachments`))?.attachments ?? [];
        } catch (error) {
          viewError ??= error.message || String(error);
        }
      }
    } else if (selection && tab === 'threads') {
      messages = ((await request(`/api/v1/threads/${enc(selection)}/messages`)) ?? []).map(m => ({ ...m, attachments: [] }));
      try {
        members = ((await request(`/api/v1/threads/${enc(selection)}/members`))?.members ?? []).map(memberView);
      } catch (error) {
        viewError = error.message || String(error);
      }
      try {
        bindings = (await request(`/api/v1/threads/${enc(selection)}/bindings`))?.bindings ?? [];
      } catch (error) {
        viewError ??= error.message || String(error);
      }
    }
    if (current !== generation) return;
    const selected = collections[tab].find(x => row(x, tab).id === selection);
    const bound = new Set(members.map(member => member.sessionId).filter(Boolean));
    const candidates = tab === 'threads' ? sessions.filter(item => !bound.has(item.sessionId)) : [];
    if (viewError) state.error = viewError;
    Object.assign(state, { rows, selection, title: selected?.title || selected?.name || 'Pharos', turns, messages,
      goal: progress?.goal ?? null, todos: progress?.todos ?? [],
      detail: selected ? {
        sessionID: selected.sessionId || '', agent: selected.agentType || '', host: selected.machineId || '', status: selected.status || '',
        workspace: selected.workspacePath || selected.projectPath || '',
        model: typeof config?.model === 'string' ? config.model : '',
        mode: typeof config?.mode === 'string' ? config.mode : '',
        models: Array.isArray(config?.models) ? config.models : []
      } : null,
      sessionConfiguration: tab === 'sessions' ? sessionControls(config) : [],
      supportsTextAttachments: tab === 'sessions' && config?.capabilities?.attachments === true,
      capabilities: tab === 'sessions' ? (config?.capabilities ?? {}) : {},
      attachments: tab === 'sessions' ? attachments : [],
      members: tab === 'threads' ? members : [],
      threadBindings: tab === 'threads' ? bindings : [],
      threadBindingCandidates: candidates,
      canBindThreadSession: tab === 'threads',
      projectHosts: selected?.trackedDevices || [], projectInventoryLoaded: !!selected?.relatedSessionIds,
      projectSessions: sessions.filter(s => selected?.relatedSessionIds?.includes(s.sessionId)) });
    syncApproval();
    publish();
  }
  // The DSH approval card sends `answers` as {questionId: [selected values]} and
  // merges free text into that list. Rebuild the contract's
  // [{questionId, selected, text?}] using the approval's own question metadata.
  function questionnaireAnswers(payload) {
    const answers = payload.answers && typeof payload.answers === 'object' ? payload.answers : {};
    const approval = (state.pendingApprovals ?? []).find(item => item.approvalId === payload.approvalId) ?? state.approval;
    const questions = Array.isArray(approval?.kind?.questions) ? approval.kind.questions : [];
    const result = [];
    for (const [questionId, values] of Object.entries(answers)) {
      if (!Array.isArray(values) || !values.length) continue;
      const question = questions.find(item => item?.id === questionId);
      const options = Array.isArray(question?.options) ? question.options : null;
      const selected = [];
      let text = '';
      for (const value of values) {
        if (typeof value !== 'string' || !value) continue;
        if (options && options.includes(value)) selected.push(value);
        else if (!options || !options.length || question?.allowsFreeText || question?.isSecret) text = value;
        else selected.push(value);
      }
      const answer = { questionId, selected };
      if (text) answer.text = text;
      result.push(answer);
    }
    return result;
  }
  async function sendMessage(payload) {
    if (payload.tab === 'sessions' && !payload.steer && String(payload.text ?? '').trimStart().startsWith('/')) unavailable('Session commands');
    const files = Array.isArray(payload.files) ? payload.files : [];
    const body = { text: payload.text };
    if (payload.requestID && !payload.steer && payload.tab === 'sessions') body.requestId = payload.requestID;
    if (files.length) {
      if (payload.tab !== 'sessions' || payload.steer) unavailable('Session attachments');
      if (state.supportsTextAttachments !== true) throw new Error('Attachments are unavailable for this Session: the adapter does not advertise attachment support');
      const attachmentIds = [];
      for (const file of files) {
        const uploaded = await request(`/api/v1/sessions/${enc(payload.id)}/attachments`, {
          filename: file?.name ?? '',
          contentType: attachmentContentType(file),
          dataBase64: file?.data ?? ''
        });
        if (!uploaded?.attachmentId) throw new Error('Attachment upload did not return an attachmentId');
        attachmentIds.push(uploaded.attachmentId);
      }
      body.attachmentIds = attachmentIds;
    }
    state.error = null;
    const suffix = payload.tab === 'threads' ? 'threads' : 'sessions';
    const endpoint = payload.steer ? 'steer' : 'messages';
    await request(`/api/v1/${suffix}/${enc(payload.id)}/${endpoint}`, body);
    state.submissionResults = { [payload.id]: { requestID: payload.requestID, accepted: true } };
    await refresh();
  }
  async function resolveApproval(payload) {
    const decisions = { allowed_once: 'allowedOnce', allowed_always: 'allowedAlways', rejected: 'rejected', cancelled: 'cancelled' };
    const decision = decisions[payload.choice];
    if (!decision) unavailable('Approval choice');
    const answers = questionnaireAnswers(payload);
    const body = { approvalId: payload.approvalId, decision };
    if (answers.length) body.questionnaireAnswers = answers;
    state.error = null;
    await request(`/api/v1/sessions/${enc(payload.sessionId)}/approval`, body);
    removeApproval(payload.approvalId);
    state.approval = null;
    await refresh();
  }
  async function updateConfiguration(action, payload) {
    const field = action === 'sessionConfig' ? payload.configId : action;
    if (field !== 'model' && field !== 'mode') throw new Error(`Unsupported Session configuration field: ${String(field)}`);
    const value = payload.value;
    if (typeof value !== 'string' || !value) throw new Error(`Choose a ${field} value first`);
    if (field === 'mode' && value !== 'safe' && value !== 'yolo') throw new Error(`Unsupported Session mode: ${value}`);
    state.error = null;
    state.configurationInFlight = true;
    publish();
    try {
      await request(`/api/v1/sessions/${enc(payload.id)}/config`, { [field]: value }, 'PATCH');
    } finally {
      state.configurationInFlight = false;
      publish();
    }
    await refresh();
  }
  async function bindThreadSession(payload) {
    const nickname = String(payload.nickname ?? '').trim();
    const sessionId = typeof payload.sessionId === 'string' ? payload.sessionId : '';
    if (!sessionId || !nickname) throw new Error('Choose a Session and a member name before binding');
    state.error = null;
    state.threadBindingInFlight = true;
    publish();
    try {
      await request(`/api/v1/threads/${enc(payload.id)}/bindings/${enc(nickname)}`, { sessionId }, 'PUT');
    } finally {
      state.threadBindingInFlight = false;
      publish();
    }
    await refresh();
  }
  async function updateIdentity(action, payload) {
    const next = action === 'resetAvatar'
      ? { ...defaultIdentity }
      : {
          shape: typeof payload.shape === 'string' && payload.shape ? payload.shape : identity.shape,
          color: typeof payload.color === 'string' && payload.color ? payload.color : identity.color
        };
    state.error = null;
    const saved = await request('/api/v1/members/human', { avatarShape: next.shape, avatarColor: next.color }, 'PATCH');
    // The PATCH response is authoritative when it carries the persisted values.
    identity.shape = typeof saved?.avatarShape === 'string' && saved.avatarShape ? saved.avatarShape : next.shape;
    identity.color = typeof saved?.avatarColor === 'string' && saved.avatarColor ? saved.avatarColor : next.color;
    state.identity = { ...identity };
    state.rows = (state.rows ?? []).map(item => ({ ...item, identity: { ...identity } }));
    publish();
  }
  async function lifecycle(action, payload) {
    state.error = null;
    await request(`/api/v1/sessions/${enc(payload.id)}/${action}`, undefined, 'POST');
    await refresh();
  }
  async function dispatch(action, payload = {}) {
    if (bridge) { bridge.postMessage({ action, payload }); return; }
    try {
      if (action === 'selectTab') { state.error = null; state.tab = payload.tab; state.selection = null; await refresh(); }
      else if (action === 'selectRow') { state.error = null; state.selection = payload.id; await refresh(); }
      else if (action === 'openProjectSession') { state.tab = 'sessions'; state.selection = payload.sessionId; await refresh(); }
      else if (action === 'dismissError') { state.error = null; publish(); }
      else if (action === 'send') await sendMessage(payload);
      else if (action === 'resolveApproval') await resolveApproval(payload);
      else if (action === 'sessionConfig' || action === 'model' || action === 'mode') await updateConfiguration(action, payload);
      else if (action === 'bindThreadSession') await bindThreadSession(payload);
      else if (action === 'avatar' || action === 'resetAvatar') await updateIdentity(action, payload);
      else if (action === 'stop' || action === 'revive') await lifecycle(action, payload);
      else unavailable(action);
    } catch (error) {
      if (action === 'send') state.submissionResults = { [payload.id]: { requestID: payload.requestID, accepted: false } };
      if (action === 'sessionConfig' || action === 'model' || action === 'mode') state.configurationInFlight = false;
      if (action === 'bindThreadSession') state.threadBindingInFlight = false;
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
    state = { tab: 'sessions', selection: null, title: 'Pharos', theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light', rows: [], identity: { ...identity }, activity: 'idle', canSend: true, detail: null, turns: [], streamingText: '', reasoningText: '', tools: [], approval: null, pendingApprovals: [], goal: null, todos: [], messages: [], members: [], sessionConfiguration: [], capabilities: {}, supportsTextAttachments: false, configurationInFlight: false, attachments: [], threadBindings: [], threadBindingCandidates: [], canBindThreadSession: false, threadBindingInFlight: false, error: null, submissionResults: {} };
    publish();
    loadApprovals().catch(error => { state.error = error.message || String(error); publish(); });
    loadIdentity().catch(error => { state.error = error.message || String(error); publish(); });
    refresh().catch(error => { state.error = error.message; publish(); });
    connect();
  }
  window.pharosTransport = Object.freeze({ dispatch, start });
})();
