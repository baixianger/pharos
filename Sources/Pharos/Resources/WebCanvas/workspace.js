(() => {
  const root = document.getElementById("grok-ui-mockup");
  const $ = selector => root.querySelector(selector);
  const $$ = selector => [...root.querySelectorAll(selector)];
  const app = $(".gb-app");
  const transcript = $("#thread-stream");
  const composer = $(".gb-composer");
  const input = composer.querySelector("textarea");
  const menu = $(".gb-composer-menu");
  const search = $("#roster-search");
  const overflow = $("#thread-overflow");
  const avatar = window.pharosAvatars;
  const avatarMounts = new Map();
  const drafts = new Map();
  const draftRevisions = new Map();
  const pendingSubmissions = new Map();
  const attachmentDrafts = new Map();
  const fileInput = $("#session-files");
  const attachmentList = $(".gb-attachments");
  const attachmentError = $(".gb-attachment-error");
  let fileSelectionSession = null;
  let state;
  let detailTab = "details";
  let isSteering = false;
  let pendingPermission = null;
  let threadBindingDraft = { sessionId: "", nickname: "" };
  let overflowAnchor;
  let overflowTimer;

  function refreshThreadBindingButton() {
    const button = $('[data-action=bindThreadSession]');
    if (!button) return;
    const name = threadBindingDraft.nickname.trim();
    button.disabled = !!state.threadBindingInFlight || !(state.threadBindingCandidates ?? []).some(item => item.sessionId === threadBindingDraft.sessionId) ||
      !/^[A-Za-z0-9_-]{1,40}$/.test(name) || name === "human" || name === "tester";
  }

  function el(tag, className = "", text) {
    const element = document.createElement(tag);
    element.className = className;
    if (text != null) element.textContent = text;
    return element;
  }

  function command(name, payload = {}) {
    window.pharosTransport.dispatch(name, payload);
  }

  // The Rust transport reports the Session adapter's real capability flags;
  // the native WebKit bridge (which has no `capabilities` key) keeps the
  // long-standing agent-based fallback. Never offer an upload the server will reject.
  function attachmentsAllowed() {
    if (state.capabilities && typeof state.capabilities === "object") return state.capabilities.attachments === true;
    return state.detail?.agent === "dsh" || state.supportsTextAttachments;
  }

  function stableHash(text) {
    let hash = 2166136261;
    for (const char of text) hash = Math.imul(hash ^ char.codePointAt(0), 16777619);
    return hash >>> 0;
  }

  function identity(seed) {
    const hash = stableHash(seed);
    const colors = Object.keys(avatar.colors);
    return { shape: avatar.shapes[hash % avatar.shapes.length], color: colors[(hash >>> 8) % colors.length] };
  }

  function mount(host, identity, size, seed, playing = false, activity = "idle") {
    const settings = { ...identity, size, seed, playing, state: activity, theme: state.theme };
    const key = JSON.stringify(settings);
    const previous = avatarMounts.get(host);
    if (previous?.key === key) return;
    if (previous?.seed === seed) {
      previous.mount.update(settings);
      previous.key = key;
      return;
    }
    previous?.mount.detach();
    avatarMounts.set(host, { key, seed, mount: avatar.mount(host, settings) });
  }

  function detachChildren(parent) {
    for (const [host, value] of avatarMounts) {
      if (parent.contains(host)) {
        value.mount.detach();
        avatarMounts.delete(host);
      }
    }
  }

  function hideOverflow() {
    clearTimeout(overflowTimer);
    if (!overflowAnchor) return;
    overflowAnchor.setAttribute("aria-expanded", "false");
    overflowAnchor = null;
    overflow.hidden = true;
    detachChildren(overflow);
    overflow.replaceChildren();
  }

  function scheduleOverflowClose() {
    clearTimeout(overflowTimer);
    overflowTimer = setTimeout(hideOverflow, 160);
  }

  function showOverflow(anchor, members) {
    clearTimeout(overflowTimer);
    if (overflowAnchor === anchor) return;
    hideOverflow();
    overflowAnchor = anchor;
    anchor.setAttribute("aria-expanded", "true");
    overflow.hidden = false;
    overflow.append(el("div", "thread-overflow-heading", members.length + " more " + (members.length === 1 ? "member" : "members")));
    const list = el("ul", "thread-overflow-list");
    overflow.append(list);
    members.forEach((member, index) => {
      const item = el("li", "thread-overflow-item");
      item.style.setProperty("--member-delay", Math.min(index, 10) * 32 + "ms");
      list.append(item);
      item.append(memberAvatar(member, 25), el("span", "", member.name));
    });
    const anchorRect = anchor.getBoundingClientRect();
    const panel = overflow.getBoundingClientRect();
    overflow.style.left = Math.max(8, Math.min(anchorRect.right + 9, innerWidth - panel.width - 8)) + "px";
    overflow.style.top = Math.max(8, Math.min(anchorRect.top - 6, innerHeight - panel.height - 8)) + "px";
  }

  function memberAvatar(member, size) {
    const host = el("span", "gb-avatar thread-member-avatar");
    host.style.setProperty("--member-size", size + "px");
    host.title = member.name;
    host.setAttribute("aria-hidden", "true");
    mount(host, member.identity, size, member.id);
    return host;
  }

  function threadRow(button, copy, members) {
    const group = el("div", "thread-roster-row");
    group.classList.toggle("selected", button.classList.contains("selected"));
    const grid = el("span", "thread-member-grid");
    grid.dataset.count = Math.min(members.length, 4);
    grid.setAttribute("aria-hidden", "true");
    for (const member of members.slice(0, members.length > 4 ? 3 : 4)) grid.append(memberAvatar(member, 17));
    if (members.length > 4) grid.append(el("span", "thread-grid-overflow", "…"));
    button.append(grid, copy);
    const stack = el("div", "thread-member-stack");
    stack.setAttribute("role", "group");
    stack.setAttribute("aria-label", "Members: " + members.map(member => member.name).join(", "));
    const shown = members.length > 5 ? 4 : members.length;
    for (const member of members.slice(0, shown)) stack.append(memberAvatar(member, 24));
    const remaining = members.slice(shown);
    if (remaining.length) {
      const more = el("button", "thread-members-overflow", "…");
      more.type = "button";
      more.setAttribute("aria-label", "Show " + remaining.length + " more members");
      more.setAttribute("aria-expanded", "false");
      more.setAttribute("aria-controls", "thread-overflow");
      const show = () => showOverflow(more, remaining);
      more.addEventListener("pointerenter", show);
      more.addEventListener("pointerleave", scheduleOverflowClose);
      more.addEventListener("focus", show);
      more.addEventListener("blur", scheduleOverflowClose);
      more.addEventListener("click", show);
      stack.append(more);
    }
    group.append(button, stack);
    return group;
  }

  function applyIdentity() {
    const palette = avatar.palette(state.identity.color, state.theme);
    root.style.setProperty("--gb-accent", palette.primary);
    root.style.setProperty("--gb-user-bubble", palette.bubble);
    const darkNeutral = state.theme === "dark" && ["black", "gray"].includes(state.identity.color);
    root.style.setProperty("--gb-on-accent", darkNeutral ? "#161616" : "#ffffff");
    root.style.setProperty("--gb-on-bubble", "#ffffff");
    // The reference uses one persistent animation stream per avatar role.
    mount($("#main-avatar"), { shape: "sphere", color: "black" }, 60, "ui-mark-0", true);
    const activity = state.activity ?? "idle";
    mount($(".gb-chat-pill .gb-avatar"), state.identity, 30, "ui-mark-5", activity !== "idle", activity);
    const profile = $(".gb-profile .gb-avatar");
    if (!app.classList.contains("gb-no-details")) mount(profile, state.identity, 64, "ui-mark-6", true, activity);
    else if (avatarMounts.has(profile)) {
      avatarMounts.get(profile).mount.detach();
      avatarMounts.delete(profile);
    }
  }

  function renderSidebar() {
    const list = $(".gb-bot-list");
    hideOverflow();
    detachChildren(list);
    list.replaceChildren();
    for (const row of state.rows) {
      if (!row.title.toLowerCase().includes(search.value.trim().toLowerCase())) continue;
      const selected = row.id === state.selection;
      const button = el("button", "gb-bot" + (selected ? " selected" : ""));
      button.type = "button";
      button.dataset.select = row.id;
      button.setAttribute("aria-label", state.tab === "threads" ? row.title + ", " + row.subtitle : row.title);
      button.setAttribute("aria-current", String(selected));
      const host = el("span", "gb-avatar");
      const copy = el("span", "gb-bot-copy");
      copy.append(el("span", "", row.title));
      if (row.subtitle) copy.append(el("span", "gb-muted gb-small", row.subtitle));
      if (state.tab === "threads" && row.members?.length) {
        list.append(threadRow(button, copy, row.members));
        continue;
      }
      button.append(host, copy);
      list.append(button);
      mount(host, row.identity, 36, row.id);
    }
    for (const button of $$("[data-tab]")) button.setAttribute("aria-selected", String(button.dataset.tab === state.tab));
  }

  function paragraphs(text) {
    return text.split(/\n\n+/).map(part => {
      const paragraph = el("p", "gb-message-text");
      for (const word of part.split(/(@[\w.-]+)/)) {
        paragraph.append(word.startsWith("@") ? el("strong", "gb-inline-code", word) : document.createTextNode(word));
      }
      return paragraph;
    });
  }

  function renderProject() {
    const content = $("#project-stream");
    content.replaceChildren();
    content.append(el("div", "gb-settings-label", "Sessions from known checkouts"));
    if (state.projectCheckoutUnavailableHosts?.length) {
      const warning = el("div", "gb-muted gb-small", "Checkout mapping unavailable: " + state.projectCheckoutUnavailableHosts.join(", ") + ". Sessions on these hosts may be missing.");
      warning.setAttribute("role", "status"); content.append(warning);
    }
    if (!(state.projectHosts?.length)) {
      content.append(el("div", "gb-muted gb-small", "No checkout paths available"));
      return;
    }
    if (!state.projectInventoryLoaded) {
      content.append(el("div", "gb-muted gb-small", "Loading session inventory…"));
      return;
    }
    const list = el("div", "gb-settings-group");
    for (const session of state.projectSessions ?? []) {
      const button = el("button", "gb-project-session");
      button.type = "button";
      button.dataset.action = "open-project-session";
      button.dataset.sessionId = session.sessionId;
      button.append(el("span", "", session.title), el("span", "gb-muted gb-small", session.agentType.toUpperCase() + " · " + session.machineId + (session.connectionRoute ? " · " + session.connectionRoute.toUpperCase() : "") + " · " + (session.inventoryStale ? "inventory unavailable · last known" : session.status.replaceAll("_", " "))));
      list.append(button);
    }
    content.append(list.childElementCount ? list : el("div", "gb-muted gb-small", "No matches in the current inventory"));
  }

  function renderThread(reset) {
    const pinned = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 70;
    detachChildren(transcript);
    transcript.replaceChildren();
    let previousDate;
    for (const message of state.messages) {
      const date = new Date(message.timestamp);
      const dateKey = date.toDateString();
      if (dateKey !== previousDate) {
        const label = dateKey === new Date().toDateString() ? "Today" : date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
        transcript.append(el("div", "gb-timestamp", label + ", " + date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })));
        previousDate = dateKey;
      }
      const isUser = message.senderId === "human";
      const bubble = el("div", "gb-message" + (isUser ? " user" : ""));
      if (!isUser) {
        const author = el("div", "gb-message-author");
        const host = el("span", "gb-avatar");
        const member = state.members.find(member => member.name === message.senderName || member.name === message.senderId);
        author.append(host, el("span", "", message.senderName));
        if (member) author.append(el("span", "gb-inline-code", member.agent.toUpperCase()));
        bubble.append(author);
        const seed = message.senderAvatarSeed ?? member?.avatarSeed ?? message.senderId;
        mount(host, identity(seed), 22, seed);
      }
      if (message.replyTo) {
        const quote = el("div", "gb-reply");
        quote.dataset.messageId = message.replyTo.messageId;
        quote.append(el("span", "gb-reply-author", message.replyTo.senderName),
                     el("span", "gb-reply-preview", message.replyTo.preview));
        bubble.append(quote);
      }
      bubble.append(...paragraphs(message.text));
      for (const attachment of message.attachments) bubble.append(el("span", "gb-inline-code gb-attachment", attachment.filename));
      if (isUser) {
        const receipts = { pending: "Sending…", delivered: "Delivered", consumed: "Consumed", unverified_fallback: "Unverified", delivery_uncertain: "Delivery uncertain — check before retrying", delivery_rejected: "Delivery blocked — agent identity is ambiguous", delivery_mixed: "Some deliveries blocked or uncertain — check before retrying" };
        const receipt = el("span", "gb-receipt", receipts[message.receipt]);
        bubble.append(receipt);
      }
      transcript.append(bubble);
    }
    if (!state.messages.length) transcript.append(el("div", "gb-timestamp", "No messages yet"));
    if (reset || pinned) transcript.scrollTop = transcript.scrollHeight;
  }

  function settingsRow(label, value) {
    const row = el("div", "gb-setting-row");
    row.append(el("span", "", label), el("span", "gb-muted gb-small", value));
    return row;
  }

  function renderDetails() {
    const content = $(".gb-detail-content");
    content.replaceChildren();
    for (const tab of $$("[data-detail]")) tab.classList.toggle("active", tab.dataset.detail === detailTab);
    const blocks = state.turns.flatMap(turn => turn.steps.flatMap(step => step.blocks.map(block => block.kind)));
    if (detailTab === "library") {
      const attachments = [...blocks.flatMap(block => block.attachment ? [block.attachment] : []), ...state.messages.flatMap(message => message.attachments)];
      content.append(el("div", "gb-settings-label", "Files"));
      const list = el("div", "gb-library");
      const unique = new Map(attachments.map(file => [file.id, file]));
      // Session attachments already accepted by the Rust attachment store
      // (loaded from GET /api/v1/sessions/{id}/attachments when the adapter
      // advertises attachment support).
      for (const file of state.attachments ?? []) {
        if (file?.attachmentId) unique.set("session:" + file.attachmentId, { filename: file.filename, mimeType: file.contentType });
      }
      for (const { filePatch } of blocks) {
        if (filePatch) unique.set("patch:" + filePatch.path, { filename: filePatch.path, mimeType: "File change" });
      }
      for (const file of unique.values()) {
        const row = el("div", "gb-library-item");
        row.append(el("span", "", file.filename), el("span", "gb-muted gb-small", file.mimeType));
        list.append(row);
      }
      content.append(unique.size ? list : el("div", "gb-muted gb-small", "No conversation files"));
      return;
    }
    if (detailTab === "computer") {
      if (state.tab === "sessions" && state.detail?.host) {
        const screen = el("div", "gb-vnc-preview");
        screen.dataset.vncHost = state.detail.host;
        screen.append(el("span", "", "Remote screen"), el("span", "gb-muted gb-small", "VNC preview unavailable"));
        const host = el("div", "gb-settings-group");
        host.append(settingsRow("Computer", state.detail.host));
        content.append(el("div", "gb-settings-label", "Computer"), host, screen);
      }
      content.append(el("div", "gb-settings-label", "Terminal output"));
      const log = blocks.filter(block => block.terminalCommand).map(({ terminalCommand: tool }) =>
        ["$ " + tool.command, tool.stdout, tool.stderr].filter(Boolean).join("\n"));
      const live = state.tools.find(tool => tool.name === "Terminal output");
      if (live) log.push(live.text);
      content.append(log.length ? el("pre", "gb-terminal", log.join("\n\n")) : el("div", "gb-muted gb-small", "Disconnected · no terminal output"));
      return;
    }
    if (state.tab === "threads") {
      const members = el("div", "gb-settings-group");
      for (const member of state.members) {
        const status = (member.status || "unknown").replaceAll("_", " ");
        members.append(settingsRow(member.name, member.agent.toUpperCase() + " · " + member.machine + " · " + status));
      }
      content.append(el("div", "gb-settings-label", "Members"),
        state.members.length ? members : el("div", "gb-muted gb-small", "No thread members"));
      if (state.canBindThreadSession) {
        content.append(el("div", "gb-settings-label gb-thread-binding-label", "Add existing local Session"));
        const candidates = state.threadBindingCandidates ?? [];
        if (!candidates.length) {
          content.append(el("div", "gb-muted gb-small", "No available local Sessions"));
        } else {
          const group = el("div", "gb-settings-group gb-thread-binding");
          const select = el("select", "gb-select");
          select.dataset.action = "threadBindingSession";
          select.setAttribute("aria-label", "Session to add");
          const placeholder = el("option", "", "Choose a Session…");
          placeholder.value = ""; select.append(placeholder);
          for (const candidate of candidates) {
            const option = el("option", "", candidate.agentType.toUpperCase() + " · " + candidate.title + " · " + candidate.machineId + " · " + candidate.sessionId);
            option.value = candidate.sessionId; select.append(option);
          }
          select.value = threadBindingDraft.sessionId;
          const name = el("input", "gb-select");
          name.type = "text"; name.dataset.action = "threadBindingNickname";
          name.placeholder = "Member name"; name.setAttribute("aria-label", "Member name"); name.maxLength = 40;
          name.value = threadBindingDraft.nickname;
          const add = el("button", "gb-button", state.threadBindingInFlight ? "Adding…" : "Add to Thread");
          add.type = "button"; add.dataset.action = "bindThreadSession";
          group.append(select, name, add); content.append(group);
          refreshThreadBindingButton();
        }
      }
      return;
    }
    const detail = state.detail;
    if (!detail) return;
    const configuration = el("div", "gb-settings-group");
    if (state.tab === "sessions") {
      const profile = el("div", "gb-settings-group");
      profile.append(settingsRow("Agent", detail.agent.toUpperCase()), settingsRow("Computer", detail.host));
      if (detail.status) profile.append(settingsRow("Status", detail.status.replaceAll("_", " ")));
      if (detail.sessionID) profile.append(settingsRow("Session ID", detail.sessionID));
      if (detail.workspace) profile.append(settingsRow("Workspace", detail.workspace));
      content.append(el("div", "gb-settings-label", "Session profile"), profile);
      const modelRow = el("label", "gb-setting-row");
      const select = el("select", "gb-select");
      select.dataset.action = "model";
      select.disabled = !detail.models.length;
      if (!detail.model) {
        const unknown = el("option", "", "Unknown");
        unknown.value = "";
        unknown.disabled = true;
        select.append(unknown);
      }
      for (const model of detail.models) {
        const option = el("option", "", model);
        option.value = model;
        select.append(option);
      }
      select.value = detail.model;
      modelRow.append(el("span", "", "Model"), select);
      const modeRow = el("label", "gb-setting-row");
      const toggle = el("input", "gb-toggle");
      toggle.type = "checkbox";
      toggle.checked = detail.mode === "yolo";
      toggle.dataset.action = "mode";
      modeRow.append(el("span", "", "Autonomous execution"), toggle);
      if (!detail.mode) {
        toggle.indeterminate = true;
        toggle.disabled = true;
        toggle.title = "Current mode unknown";
      }
      if (!["agy", "dsh"].includes(detail.agent.toLowerCase())) configuration.append(modelRow, modeRow);
    }
    if (state.tab !== "sessions" && detail.workspace) configuration.append(settingsRow("Workspace", detail.workspace));
    if (configuration.childElementCount) content.append(el("div", "gb-settings-label", "Configuration"), configuration);
    if (state.tab === "sessions") {
      const lifecycle = el("div", "gb-setting-row");
      for (const [action, label] of [["stop", "Stop"], ["revive", "Revive"]]) {
        const button = el("button", "gb-button", label);
        button.type = "button";
        button.dataset.action = action;
        // The Rust transport surfaces the adapter's capabilities: an operation it
        // does not advertise stays disabled instead of faking success. The native
        // bridge keeps its previously-configured fallback.
        button.disabled = state.capabilities ? state.capabilities[action] !== true : !detail.models.length;
        lifecycle.append(button);
      }
      content.append(lifecycle);
    }
  }

  function renderEditor() {
    const shapes = $(".gb-editor-shapes");
    detachChildren(shapes);
    shapes.replaceChildren();
    for (const shape of avatar.shapes) {
      const button = el("button", "gb-shape-choice");
      button.dataset.shape = shape;
      button.setAttribute("aria-label", shape + " avatar");
      button.setAttribute("aria-pressed", String(shape === state.identity.shape));
      const host = el("span", "gb-avatar");
      button.append(host);
      shapes.append(button);
      mount(host, { shape, color: state.identity.color }, 36, shape);
    }
    const colors = $(".gb-editor-colors");
    colors.replaceChildren();
    for (const [name, palette] of Object.entries(avatar.colors)) {
      const button = el("button", "gb-color");
      button.dataset.color = name;
      button.style.background = palette[state.theme];
      button.setAttribute("aria-label", name);
      button.setAttribute("aria-pressed", String(name === state.identity.color));
      colors.append(button);
    }
  }

  function closeEditor() {
    const editor = $(".gb-avatar-editor");
    editor.hidden = true;
    detachChildren(editor);
  }

  function openDetails(open) {
    app.classList.toggle("gb-no-details", !open);
    $(".gb-chat-pill").setAttribute("aria-expanded", String(open));
    if (open) renderDetails();
    else closeEditor();
    applyIdentity();
  }

  function renderSessionConfiguration() {
    const container = $("#session-config-controls");
    container.replaceChildren();
    const configs = state.tab === "sessions" ? (state.sessionConfiguration ?? []) : [];
    for (const config of configs) {
      if (config.type === "status") { container.append(el("span", "gb-session-config-notice", config.name || "Configuration unavailable")); continue; }
      if (config.type !== "select" || typeof config.id !== "string" || !Array.isArray(config.options)) continue;
      const label = el("label", "gb-session-config");
      label.append(el("span", "", (config.name || config.id) + (config.readOnly ? " · view only" : "")));
      const select = el("select", "gb-select");
      select.dataset.action = "sessionConfig";
      select.dataset.configId = config.id;
      select.disabled = state.configurationInFlight === true || config.readOnly === true;
      if (config.description) { select.title = config.description; label.title = config.description; }
      const appendOptions = (items, target) => {
        for (const item of items) {
          if (typeof item.value === "string") {
            const option = el("option", "", item.name || item.value); option.value = item.value; option.disabled = item.disabled === true; if (item.description) option.title = item.description; target.append(option);
          } else if (Array.isArray(item.options)) {
            const group = el("optgroup"); group.label = item.name || item.group || "Options"; appendOptions(item.options, group); target.append(group);
          }
        }
      };
      appendOptions(config.options, select);
      if (!select.options.length || ![...select.options].some(option => option.value === config.currentValue)) {
        const unknown = el("option", "", "Unavailable"); unknown.value = ""; unknown.disabled = true; select.prepend(unknown); select.value = "";
      } else select.value = config.currentValue;
      if (![...select.options].some(option => !option.disabled && !option.parentElement.disabled)) select.disabled = true;
      label.append(select); container.append(label);
      if (config.notice) container.append(el("span", "gb-session-config-notice", config.notice));
    }
    container.hidden = !container.childElementCount;
  }

  function resizeComposer() {
    const send = composer.querySelector("button[type=submit]");
    send.disabled = input.disabled || (!input.value.trim() && !(attachmentDrafts.get(state.selection)?.length));
    input.style.height = "";
    const expanded = input.scrollHeight > 34 || input.value.includes("\n");
    composer.classList.toggle("is-expanded", expanded);
    if (expanded) input.style.height = Math.min(input.scrollHeight, 120) + "px";
  }

  function renderAttachments() {
    const files = state.tab === "sessions" ? attachmentDrafts.get(state.selection) ?? [] : [];
    attachmentList.replaceChildren();
    files.forEach((file, index) => {
      const item = el("button", "gb-attachment", file.name + " ×");
      item.type = "button"; item.dataset.action = "remove-attachment"; item.dataset.index = String(index);
      item.setAttribute("aria-label", "Remove " + file.name); attachmentList.append(item);
    });
    attachmentList.hidden = files.length === 0;
  }
  function showAttachmentError(message) {
    attachmentError.textContent = message;
    attachmentError.hidden = !message;
  }

  function setMenu(open) {
    menu.hidden = !open;
    composer.querySelector("[data-action=composer-menu]").setAttribute("aria-expanded", String(open));
    menu.replaceChildren();
    if (!open) return;
    if (state.tab === "sessions") {
      if (attachmentsAllowed()) {
        const attach = el("button", "gb-menuitem", state.detail?.agent === "dsh" ? "Add files…" : "Add text files…");
        attach.type = "button"; attach.dataset.action = "attach-files"; menu.append(attach);
      }
      const button = el("button", "gb-menuitem", isSteering ? "Queue prompt" : "Steer current turn");
      button.dataset.action = "steering";
      menu.append(button);
    } else {
      for (const member of state.members) {
        const button = el("button", "gb-menuitem", "@" + member.name);
        button.dataset.mention = member.name;
        menu.append(button);
      }
      if (!state.members.length) menu.append(el("div", "gb-menuitem gb-muted", "No thread members"));
    }
  }

  function update(next) {
    const previous = state;
    const changed = key => JSON.stringify(previous?.[key]) !== JSON.stringify(next[key]);
    const reset = changed("selection") || changed("tab");
    if (reset) {
      showAttachmentError("");
      if (previous) drafts.set(previous.tab + ":" + previous.selection, input.value);
      input.value = drafts.get(next.tab + ":" + next.selection) ?? "";
      isSteering = false;
      threadBindingDraft = { sessionId: "", nickname: "" };
      pendingPermission = null;
      $("#permission-confirm").hidden = true;
      closeEditor();
    }
    state = next;
    for (const [id, result] of Object.entries(state.submissionResults ?? {})) {
      const pending = pendingSubmissions.get(id);
      if (!pending || pending.requestID !== result.requestID) continue;
      pendingSubmissions.delete(id);
      if (result.accepted) {
        if (pending.files) {
          const current = attachmentDrafts.get(id) ?? [];
          attachmentDrafts.set(id, current.filter(file => !pending.files.includes(file)));
        }
        const key = "sessions:" + id;
        if ((draftRevisions.get(key) ?? 0) === pending.revision) {
          if (state.tab === "sessions" && state.selection === id) {
            if (input.value === pending.text) input.value = "";
          } else if (drafts.get(key) === pending.text) {
            drafts.set(key, "");
          }
        }
      }
    }
    renderAttachments();
    root.dataset.theme = state.theme;
    if (reset || changed("rows") || changed("theme")) renderSidebar();
    if (reset || changed("sessionConfiguration") || changed("configurationInFlight")) renderSessionConfiguration();
    if (reset || changed("inventoryIssues")) {
      const issues = $("#session-inventory-issues");
      const visible = state.tab === "sessions" ? (state.inventoryIssues ?? []) : [];
      const labels = visible.map(issue => issue.agent + " sessions unavailable · " + issue.host);
      issues.replaceChildren(...labels.map(label => el("div", "", label)));
      issues.title = labels.join("\n");
      issues.setAttribute("aria-label", labels.join("; "));
      issues.hidden = !visible.length;
    }
    for (const name of $$(".gb-bot-name")) name.textContent = state.title;
    $(".gb-chat-pill").disabled = !state.selection;
    // The details panel belongs to a selection. Leaving it open with nothing
    // selected would report empty profile/member/configuration states that do
    // not exist (e.g. "No thread members" with no thread).
    if (!state.selection && !app.classList.contains("gb-no-details")) openDetails(false);
    $("#thread-stream").hidden = state.tab !== "threads" || !state.selection;
    $("#session-stream").hidden = state.tab !== "sessions";
    $("#project-stream").hidden = state.tab !== "projects" || !state.selection;
    $("#dsh-composer-dock").hidden = state.tab !== "sessions"
      || !(state.approval || state.goal || state.todos?.length);
    $("#empty-stream").hidden = state.tab === "sessions" || ((state.tab === "threads" || state.tab === "projects") && !!state.selection);
    $("#empty-stream .gb-timestamp").textContent = state.tab === "projects" && state.detail
      ? state.detail.workspace : "Choose a conversation";
    input.disabled = !state.selection || state.tab === "projects" || state.canSend === false;
    composer.querySelector("[data-action=composer-menu]").disabled = input.disabled;
    input.placeholder = input.disabled ? (state.selection && state.tab !== "projects" ? "Loading conversation…" : "No conversation selected") : (isSteering ? "Steer " : "Message ") + state.title + "…";
    resizeComposer();

    const error = $("#conversation-error");
    error.hidden = state.tab === "sessions" || !state.error;
    error.querySelector("span").textContent = state.error ?? "";
    if (state.tab === "threads" && (reset || changed("messages") || changed("theme"))) renderThread(reset);
    if (state.tab === "projects" && (reset || changed("projectHosts") || changed("projectCheckoutUnavailableHosts") || changed("projectSessions") || changed("projectInventoryLoaded"))) renderProject();
    if (state.tab === "sessions") {
      const renderer = window.pharosAPI;
      if (changed("theme")) renderer.setTheme(state.theme === "dark");
      if (reset || changed("turns")) renderer.setTurns(state.turns, reset);
      if (reset) renderer.setEmptyLabel(!!state.selection);
      if (reset || changed("streamingText")) renderer.setLiveText(state.streamingText);
      if (reset || changed("reasoningText")) renderer.setReasoning(state.reasoningText, reset);
      if (reset || changed("tools")) renderer.setTools(state.tools, reset);
      if (reset || changed("approval")) renderer.setApproval(state.approval);
      if (reset || changed("goal") || changed("todos")) renderer.setProgress(state.goal, state.todos ?? [], reset);
      if (reset || changed("activity")) renderer.setRunning(state.activity === "working");
      if (reset || changed("commandResult")) renderer.setCommandResult(state.commandResult);
      if (reset || changed("error")) renderer.setError(state.error);
    }
    applyIdentity();
    if (!app.classList.contains("gb-no-details") && (reset || changed("detail") || changed("turns") || changed("tools") || changed("messages") || changed("members") || changed("attachments") || changed("capabilities") || changed("canBindThreadSession") || changed("threadBindingInFlight") || changed("threadBindingCandidates"))) renderDetails();
    if (!$(".gb-avatar-editor").hidden && (changed("identity") || changed("theme"))) {
      renderEditor();
      if (changed("identity")) avatarMounts.get($(".gb-profile .gb-avatar"))?.mount.spin();
    }
  }

  root.addEventListener("click", event => {
    if (!state) return;
    const button = event.target.closest("button");
    const rail = $("[data-action=rail-nav]");
    if (button !== rail) rail.setAttribute("aria-expanded", "false");
    if (!button) {
      if (!menu.contains(event.target)) setMenu(false);
      return;
    }
    const { action, tab, select, detail, mention, shape, color } = button.dataset;
    if (tab) command("selectTab", { tab });
    if (select) command("selectRow", { id: select, tab: state.tab });
    if (detail) {
      detailTab = detail;
      closeEditor();
      renderDetails();
    }
    if (mention) {
      const insertion = "@" + mention + " ";
      input.setRangeText(insertion, input.selectionStart, input.selectionEnd, "end");
      input.focus();
      resizeComposer();
      setMenu(false);
    }
    if (shape || color) command("avatar", { id: state.selection, tab: state.tab, shape: shape ?? state.identity.shape, color: color ?? state.identity.color });
    switch (action) {
      case "cancelPermission":
        pendingPermission = null; $("#permission-confirm").hidden = true; input.focus(); break;
      case "confirmPermission": {
        const pending = pendingPermission;
        pendingPermission = null; $("#permission-confirm").hidden = true;
        if (pending && state.tab === "sessions" && state.selection === pending.id) command("sessionConfig", { tab: "sessions", ...pending });
        break;
      }
      case "open-project-session":
        command("openProjectSession", { sessionId: button.dataset.sessionId });
        break;
      case "compact":
        app.classList.toggle("gb-compact");
        break;
      case "rail-nav":
        rail.setAttribute("aria-expanded", String(rail.getAttribute("aria-expanded") === "false"));
        if (rail.getAttribute("aria-expanded") === "true") $("[data-tab][aria-selected=true]").focus();
        break;
      case "main-bot":
        command("selectTab", { tab: "sessions" });
        break;
      case "search":
        search.hidden = !search.hidden;
        if (!search.hidden) search.focus();
        else { search.value = ""; renderSidebar(); }
        break;
      case "details": openDetails(app.classList.contains("gb-no-details")); break;
      case "close-details": openDetails(false); break;
      case "avatar-editor":
        if ($(".gb-avatar-editor").hidden) {
          $(".gb-avatar-editor").hidden = false;
          renderEditor();
        } else closeEditor();
        break;
      case "composer-menu": setMenu(menu.hidden); break;
      case "attach-files": fileSelectionSession = state.selection; fileInput.click(); setMenu(false); break;
      case "remove-attachment": {
        const files = attachmentDrafts.get(state.selection) ?? [];
        files.splice(Number(button.dataset.index), 1); renderAttachments(); resizeComposer(); break;
      }
      case "bindThreadSession":
        command("bindThreadSession", { id: state.selection, tab: state.tab, sessionId: threadBindingDraft.sessionId, nickname: threadBindingDraft.nickname });
        break;
      case "steering":
        isSteering = !isSteering;
        input.placeholder = (isSteering ? "Steer " : "Message ") + state.title + "…";
        input.focus();
        setMenu(false);
        break;
      case "reset-avatar": command("resetAvatar", { id: state.selection, tab: state.tab }); break;
      case "stop":
      case "revive":
      case "dismissError": command(action, { id: state.selection, tab: state.tab }); break;
      case "addProject":
      case "settings": command(action); break;
    }
  });

  root.addEventListener("change", event => {
    if (event.target.dataset.action === "threadBindingSession") { threadBindingDraft.sessionId = event.target.value; refreshThreadBindingButton(); return; }
    if (event.target.dataset.action === "sessionConfig") {
      const control = event.target;
      const pending = { id: state.selection, configId: control.dataset.configId, value: control.value };
      if (pending.configId === "dsh-permission" && ["danger-full-access", "auto"].includes(pending.value)) {
        pendingPermission = pending;
        $("#permission-confirm-description").textContent = pending.value === "auto"
          ? "Auto review is experimental and uses an automated reviewer for eligible actions."
          : "Full access allows the agent to operate outside the normal sandbox. Review the Session's approval policy before continuing.";
        $("#permission-confirm").hidden = false;
        $("#permission-confirm [data-action=cancelPermission]").focus();
      } else command("sessionConfig", { tab: state.tab, ...pending });
      renderSessionConfiguration();
      return;
    }
    const control = event.target;
    const action = control.dataset.action;
    if (action === "model" || action === "mode") command(action, {
      id: state.selection, tab: state.tab, value: action === "model" ? control.value : (control.checked ? "yolo" : "safe")
    });
  });
  root.addEventListener("input", event => {
    if (event.target.dataset.action === "threadBindingNickname") { threadBindingDraft.nickname = event.target.value; refreshThreadBindingButton(); }
  });
  search.addEventListener("input", renderSidebar);
  overflow.addEventListener("pointerenter", () => clearTimeout(overflowTimer));
  overflow.addEventListener("pointerleave", scheduleOverflowClose);
  $(".gb-bot-list").addEventListener("scroll", hideOverflow);
  window.addEventListener("resize", hideOverflow);
  input.addEventListener("input", () => {
    if (state) {
      const key = state.tab + ":" + state.selection;
      draftRevisions.set(key, (draftRevisions.get(key) ?? 0) + 1);
    }
    resizeComposer();
  });
  fileInput.addEventListener("change", () => {
    if (state.tab !== "sessions" || !attachmentsAllowed() || state.selection !== fileSelectionSession) { fileInput.value = ""; return; }
    fileSelectionSession = null;
    const files = [...(attachmentDrafts.get(state.selection) ?? []), ...fileInput.files];
    fileInput.value = "";
    if (files.length > 5 || files.reduce((sum, file) => sum + file.size, 0) > 10000000) {
      showAttachmentError("Choose up to five files, 10 MB total."); return;
    }
    showAttachmentError("");
    attachmentDrafts.set(state.selection, files); renderAttachments(); resizeComposer();
  });
  input.addEventListener("keydown", event => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      composer.requestSubmit();
    }
  });
  composer.addEventListener("submit", async event => {
    event.preventDefault();
    const text = input.value.trim();
    const id = state.selection, tab = state.tab, steering = isSteering;
    const files = tab === "sessions" ? [...(attachmentDrafts.get(id) ?? [])] : [];
    if ((!text && !files.length) || input.disabled || !id) return;
    if (files.length && (steering || text.startsWith("/"))) { showAttachmentError("Attachments cannot be used with commands or steering."); return; }
    const preserve = tab === "sessions";
    if (tab === "sessions" && pendingSubmissions.has(id)) return;
    const requestID = preserve ? crypto.randomUUID() : undefined;
    if (preserve) pendingSubmissions.set(id, { requestID, text: input.value, files, revision: draftRevisions.get("sessions:" + id) ?? 0 });
    let encodedFiles = [];
    try {
      if (files.length) encodedFiles = await Promise.all(files.map(file => new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => {
          const result = String(reader.result ?? "");
          const separator = result.indexOf(",");
          const header = separator === -1 ? "" : result.slice(0, separator);
          const declared = /^data:([^;,]+)/.exec(header)?.[1];
          resolve({
            name: file.name,
            contentType: declared || file.type || "",
            data: separator === -1 ? result : result.slice(separator + 1)
          });
        };
        reader.onerror = () => reject(reader.error); reader.readAsDataURL(file);
      })));
    } catch (_) { pendingSubmissions.delete(id); if (state.selection === id && state.tab === tab) showAttachmentError("Unable to read attachment."); return; }
    if (state.selection !== id || state.tab !== tab) { pendingSubmissions.delete(id); return; }
    command("send", { id, tab, text, steer: steering, requestID, files: encodedFiles });
    if (!preserve) input.value = "";
    resizeComposer();
  });
  root.addEventListener("keydown", event => {
    if (pendingPermission && event.key === "Tab") {
      const cancel = $("#permission-confirm [data-action=cancelPermission]");
      const confirm = $("#permission-confirm [data-action=confirmPermission]");
      if (event.shiftKey && document.activeElement === cancel) { confirm.focus(); event.preventDefault(); }
      else if (!event.shiftKey && document.activeElement === confirm) { cancel.focus(); event.preventDefault(); }
      return;
    }
    if (event.key !== "Escape") return;
    if (pendingPermission) { pendingPermission = null; $("#permission-confirm").hidden = true; input.focus(); event.preventDefault(); return; }
    if (overflowAnchor) {
      hideOverflow();
      event.preventDefault();
      return;
    }
    const rail = $("[data-action=rail-nav]");
    if (rail.getAttribute("aria-expanded") === "true") {
      rail.setAttribute("aria-expanded", "false");
      rail.focus();
      return;
    }
    if (!menu.hidden) setMenu(false);
    else if (!$(".gb-avatar-editor").hidden) closeEditor();
    else if (!app.classList.contains("gb-no-details")) openDetails(false);
  });

  window.pharosWorkspace = Object.freeze({ update });
  window.pharosTransport.start();
})();
