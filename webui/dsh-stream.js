// Render Pharos canonical Session blocks in DeepSeek Harness transcript order.
(() => {
  const byId = id => document.getElementById(id);
  const stream = byId("stream-container").closest(".dsh-stream");
  const turnsList = byId("turns-list");
  const liveTurn = byId("live-turn");
  const liveReasoning = byId("live-reasoning");
  const liveAssistant = byId("live-assistant-text");
  const liveTools = byId("live-tools");
  const running = byId("dsh-running");
  const empty = byId("dsh-empty");
  const approvalSlot = byId("live-approval-slot");
  const composerDock = byId("dsh-composer-dock");
  const progress = byId("dsh-progress");
  const markdown = window.markdownit({ html: false });
  markdown.renderer.rules.image = (tokens, index, options, env, renderer) =>
    markdown.utils.escapeHtml(renderer.renderInlineAsText(tokens[index].children, options, env));
  markdown.renderer.rules.table_open = () => '<div class="dsh-table-scroll" role="region" aria-label="Table" tabindex="0"><table>';
  markdown.renderer.rules.table_close = () => '</table></div>';

  const shapes = {
    chevron: '<path d="m5.5 3.5 4 4-4 4"/>',
    think: '<path d="M7.5 2v2m0 7v2M2 7.5h2m7 0h2M3.6 3.6 5 5m5 5 1.4 1.4m0-7.8L10 5m-5 5-1.4 1.4"/><circle cx="7.5" cy="7.5" r="2.5"/>',
    terminal: '<rect x="1.5" y="2.5" width="12" height="10" rx="2"/><path d="m4 5 2 2.5L4 10m4 0h3"/>',
    tool: '<path d="m3 6 4.5-4.5L12 6l-4.5 4.5L3 6zm.5 3.5 4 4 4-4"/>',
    file: '<path d="M4 1.5h4l3 3v9H4zm4 0v3h3M6 8h3m-3 2.5h3"/>'
  };
  const statusLabel = { completed: "Completed", failed: "Failed", cancelled: "Stopped" };

  function node(tag, className, text) {
    const element = document.createElement(tag);
    element.className = className;
    if (text != null) element.textContent = text;
    return element;
  }

  function icon(name, className) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 15 15");
    svg.setAttribute("width", "14");
    svg.setAttribute("height", "14");
    svg.setAttribute("class", className);
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "1.15");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("fill", "none");
    svg.setAttribute("aria-hidden", "true");
    svg.innerHTML = shapes[name];
    return svg;
  }

  function update(change, reset = false) {
    const pinned = stream.scrollHeight - stream.scrollTop - stream.clientHeight < 70;
    change();
    liveTurn.hidden = liveReasoning.hidden && liveAssistant.hidden && liveTools.hidden && running.hidden;
    empty.hidden = !turnsList.hidden || !liveTurn.hidden || !approvalSlot.hidden;
    if (reset || pinned) stream.scrollTop = stream.scrollHeight;
  }

  function formatted(element, text) {
    element.innerHTML = markdown.render(text ?? "");
    return element;
  }

  function disclosure(className, id, glyph, label, preview, status, body) {
    const row = node("details", className);
    row.dataset.id = id;
    const header = node("summary", "disclosure-header");
    const leading = node("span", "disclosure-icon");
    leading.append(icon(glyph, "row-icon"), icon("chevron", "chevron"));
    header.append(leading, node("span", "disclosure-title", label));
    if (preview) header.append(node("span", "disclosure-separator"), node("span", "disclosure-preview", preview));
    if (status) header.append(node("span", "disclosure-status", status));
    row.append(header, body);
    return row;
  }

  function firstLine(text) {
    return text.trim().split("\n", 1)[0].replaceAll("**", "");
  }

  function reasoning(id, text, summary, duration) {
    const status = duration == null ? "" : (duration / 1000).toFixed(1) + "s";
    return disclosure("reasoning-row", id, "think", "Think", firstLine(summary || text), status,
      formatted(node("div", "reasoning-body dsh-markdown"), text || summary));
  }

  function toolRow({ id, label, glyph = "tool", preview, status, failed = false, sections }) {
    const body = node("div", "tool-body");
    for (const [name, text] of sections) {
      if (!text) continue;
      const section = node("div", "tool-section");
      section.append(node("span", "tool-label", name), node("pre", "", text));
      body.append(section);
    }
    const row = disclosure("tool-row", id, glyph, label, preview, status, body);
    if (failed) row.dataset.failed = "";
    return row;
  }

  function formatValue(value) {
    return typeof value === "string" ? value : JSON.stringify(value, null, 2);
  }

  function blockView({ blockId, kind, rawVendorPayload }, results = []) {
    switch (kind.type) {
      case "userText": {
        const row = node("div", "user-row");
        row.append(node("div", "user-bubble", kind.text));
        return row;
      }
      case "assistantText":
        return formatted(node("div", "assistant-row dsh-markdown"), kind.text);
      case "reasoning": {
        const value = kind.reasoning;
        return reasoning(blockId, value.thinking, value.summary, value.durationMs);
      }
      case "toolCall": {
        const tool = kind.toolCall;
        const input = tool.rawArguments ?? formatValue(tool.arguments);
        const preview = tool.arguments.command ?? tool.arguments.cmd ?? tool.arguments.path ?? tool.arguments.query ?? input;
        const failed = results.some(result => result.isError);
        return toolRow({
          id: blockId, label: tool.toolName, preview: formatValue(preview), failed,
          status: failed ? "Error" : "",
          sections: [["Input", input], ...results.map(result => ["Output", formatValue(result.result)])]
        });
      }
      case "toolResult": {
        const tool = kind.toolResult;
        const output = formatValue(tool.result);
        return toolRow({ id: blockId, label: tool.toolName, preview: firstLine(output), failed: tool.isError,
          status: tool.isError ? "Error" : "", sections: [["Output", output]] });
      }
      case "terminalCommand": {
        const tool = kind.terminalCommand;
        return toolRow({ id: blockId, label: "Run command", glyph: "terminal", preview: tool.command,
          status: tool.exitCode == null ? "" : "Exit " + tool.exitCode, failed: tool.exitCode != null && tool.exitCode !== 0,
          sections: [["Command", tool.command], ["Output", tool.stdout], ["Stderr", tool.stderr]] });
      }
      case "filePatch": {
        const patch = kind.filePatch;
        const vendorStatus = rawVendorPayload?.type === "fileChange" ? rawVendorPayload.status : null;
        const statuses = { completed: "Completed", declined: "Declined", failed: "Failed", inProgress: "In progress" };
        const status = typeof vendorStatus === "string" ? (statuses[vendorStatus] ?? vendorStatus) : "";
        return toolRow({ id: blockId, label: "Edit file", glyph: "file", preview: patch.path,
          status, failed: vendorStatus === "declined" || vendorStatus === "failed",
          sections: [["Diff", patch.diff]] });
      }
      case "attachment":
        return node("div", "dsh-hint", kind.attachment.filename);
    }
  }

  function turnView(turn) {
    const container = node("div", "turn-container");
    const blocks = turn.steps.flatMap(step => step.blocks);
    const calls = new Map();
    const merged = new Set();
    for (const block of blocks) {
      const { kind } = block;
      if (kind.type === "toolCall") calls.set(kind.toolCall.callId, []);
      if (kind.type === "toolResult" && calls.has(kind.toolResult.callId)) {
        calls.get(kind.toolResult.callId).push(kind.toolResult);
        merged.add(block);
      }
    }
    const entries = blocks.filter(block => !merged.has(block)).flatMap(block => {
      const view = blockView(block, calls.get(block.kind.toolCall?.callId));
      if (!view) return [];
      if (view instanceof HTMLDetailsElement) view.dataset.id = turn.turnId + ":" + view.dataset.id;
      return [{ block, view }];
    });
    const first = entries.findIndex(({ view }) => view instanceof HTMLDetailsElement);
    const last = entries.findLastIndex(({ view }) => view instanceof HTMLDetailsElement);
    const process = first < 0 ? [] : entries.slice(first, last + 1);
    if (!statusLabel[turn.status] || !process.length || process.some(({ block }) => block.kind.type === "userText")) {
      container.append(...entries.map(({ view }) => view));
      return container;
    }

    const wrapper = node("details", "turn-process");
    wrapper.dataset.id = "turn:" + turn.turnId;
    const duration = Date.parse(turn.completedAt) - Date.parse(turn.createdAt);
    const label = turn.status === "completed" && duration >= 0
      ? "Completed in " + Math.max(1, Math.round(duration / 1000)) + "s" : statusLabel[turn.status];
    const header = node("summary", "process-header", label);
    header.append(icon("chevron", "chevron"));
    const body = node("div", "process-body");
    body.append(...process.map(({ view }) => view));
    wrapper.append(header, body);
    container.append(...entries.slice(0, first).map(({ view }) => view),
      wrapper, ...entries.slice(last + 1).map(({ view }) => view));
    return container;
  }

  function setTurns(turns, reset = false) {
    update(() => {
      const expanded = new Set(reset ? [] : [...turnsList.querySelectorAll("details[open]")].map(element => element.dataset.id));
      turnsList.replaceChildren(...turns.map(turnView).filter(element => element.childElementCount));
      for (const detail of turnsList.querySelectorAll("details")) detail.open = expanded.has(detail.dataset.id);
      turnsList.hidden = !turnsList.childElementCount;
    }, reset);
  }

  function setLiveText(text) {
    update(() => {
      formatted(liveAssistant, text);
      liveAssistant.hidden = !text;
    });
  }

  function setReasoning(text, reset = false) {
    update(() => {
      const wasOpen = !reset && liveReasoning.querySelector("details")?.open;
      const row = reasoning("live-reasoning-row", text);
      row.open = Boolean(wasOpen);
      liveReasoning.replaceChildren(row);
      liveReasoning.hidden = !text;
    });
  }

  function setTools(tools, reset = false) {
    update(() => {
      const open = new Set(reset ? [] : [...liveTools.querySelectorAll("details[open]")].map(detail => detail.dataset.id));
      liveTools.replaceChildren(...tools.map(tool => {
        const row = toolRow({ id: tool.name, label: tool.name, preview: firstLine(tool.text),
          status: "Running", sections: [["Output", tool.text]] });
        row.open = open.has(tool.name);
        return row;
      }));
      liveTools.hidden = !tools.length;
    });
  }

  function setApproval(approval) {
    update(() => {
      approvalSlot.replaceChildren();
      approvalSlot.hidden = !approval;
      if (!approval) return;
      const form = node("form", "dsh-approval-card");
      const { kind } = approval;
      const questionnaire = kind.type === "structuredQuestionnaire";
      const body = node("div", "approval-body");
      const fields = [];
      form.append(node("div", "approval-strip", questionnaire ? "Input requested" : "Permission required"), body);
      body.append(node("div", "approval-title", kind.toolName ?? kind.intent ?? "Permission required"));
      if (questionnaire) {
        for (const question of kind.questions) {
          const field = node("fieldset", "approval-command");
          field.append(node("legend", "", question.question));
          for (const option of question.options) {
            const label = node("label", "approval-option");
            const input = node("input", "");
            input.type = question.isMultiSelect ? "checkbox" : "radio";
            input.name = question.id;
            input.value = option;
            label.append(input, document.createTextNode(option));
            field.append(label);
          }
          let custom;
          if (question.allowsFreeText || !question.options.length) {
            custom = node("input", "approval-free-text");
            custom.type = question.isSecret ? "password" : "text";
            custom.placeholder = question.options.length ? "Other answer" : "Type an answer";
            custom.setAttribute("aria-label", question.question);
            custom.autocomplete = "off";
            field.append(custom);
          }
          fields.push({ question, field, custom });
          body.append(field);
        }
      } else {
        if (kind.explanation) body.append(node("pre", "approval-command", kind.explanation));
        if (kind.params && Object.keys(kind.params).length) body.append(node("pre", "approval-command", formatValue(kind.params)));
        if (!kind.explanation && (!kind.params || !Object.keys(kind.params).length)) body.append(node("pre", "approval-command", "Details unavailable"));
      }
      const controls = node("div", "approval-actions");
      const choices = [["rejected", "Reject"], ["allowed_once", questionnaire ? "Submit" : "Allow once"]];
      if (!questionnaire && approval.availableChoices?.includes("cancelled")) choices.push(["cancelled", "Cancel turn"]);
      if (!questionnaire) choices.push(["allowed_always", "Always allow"]);
      const available = approval.availableChoices;
      for (const [choice, label] of choices.filter(([choice]) => !Array.isArray(available) || available.includes(choice))) {
        const button = node("button", "dsh-button" + (choice === "allowed_once" ? " primary" : ""), label);
        button.value = choice;
        controls.append(button);
      }
      form.append(controls);
      form.addEventListener("submit", event => {
        event.preventDefault();
        const choice = event.submitter?.value;
        if (!choice) return;
        const answers = Object.fromEntries(fields.map(({ question, field, custom }) => {
          const selected = [...field.querySelectorAll("input:checked")].map(input => input.value);
          const text = custom?.value.trim();
          return [question.id, text ? (question.isMultiSelect ? [...selected, text] : [text]) : selected];
        }));
        window.pharosTransport.dispatch("resolveApproval", { choice, approvalId: approval.approvalId, sessionId: approval.sessionId, answers });
      });
      approvalSlot.append(form);
    });
  }

  function setProgress(goal, todos, reset) {
    if (!progress) return;
    const open = new Set(reset ? [] : [...progress.querySelectorAll("details[open]")].map(row => row.dataset.id));
    progress.replaceChildren();
    if (goal) {
      const row = disclosure("dsh-progress-row", "goal", "think", "Goal", goal.objective, goal.status,
        node("div", "dsh-goal-text", goal.objective));
      row.open = open.has("goal");
      progress.append(row);
    }
    if (todos.length) {
      const list = node("ul", "dsh-todo-list");
      const status = { completed: ["✓", "Completed"], inProgress: ["◉", "In progress"], pending: ["○", "Pending"] };
      for (const todo of todos) {
        const [glyph, label] = status[todo.status] ?? ["–", "Unknown"];
        const item = node("li", "dsh-todo-item");
        const mark = node("span", "dsh-todo-status", glyph);
        mark.setAttribute("aria-label", label);
        mark.title = label;
        item.append(mark, node("span", "", todo.text));
        if (typeof todo.priority === "string" && todo.priority.length) {
          const priority = node("span", "dsh-todo-priority", todo.priority);
          priority.setAttribute("aria-label", "Priority: " + todo.priority);
          item.append(priority);
        }
        list.append(item);
      }
      const completed = todos.filter(todo => todo.status === "completed").length;
      const row = disclosure("dsh-progress-row", "todo", "file", "Todo", "", completed + "/" + todos.length, list);
      row.open = open.has("todo");
      progress.append(row);
    }
    progress.hidden = !progress.childElementCount;
  }

  window.pharosAPI = {
    setTurns, setLiveText, setReasoning, setApproval, setTools, setProgress,
    setTheme(isDark) {
      stream.classList.toggle("theme-light", !isDark);
      composerDock?.classList.toggle("theme-light", !isDark);
    },
    setRunning(active) { update(() => { running.hidden = !active; }); },
    setEmptyLabel(hasSelection) { update(() => { empty.textContent = hasSelection ? "No messages yet" : "Choose a session"; }); },
    setCommandResult(message) {
      const result = byId("dsh-command-result");
      update(() => { result.hidden = !message; result.textContent = message ?? ""; });
    },
    setError(message) {
      const error = byId("dsh-error");
      update(() => {
        error.hidden = !message;
        error.querySelector("span").textContent = message ?? "";
      });
    }
  };
})();
