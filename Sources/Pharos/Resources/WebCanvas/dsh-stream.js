// DSH Stream Bridge & Renderer
(function() {
  const turnsListEl = document.getElementById('turns-list');
  const liveTurnEl = document.getElementById('live-turn');
  const liveReasoningCardEl = document.getElementById('live-reasoning-card');
  const liveReasoningContentEl = document.getElementById('live-reasoning-content');
  const liveAssistantBubbleEl = document.getElementById('live-assistant-bubble');
  const liveAssistantTextEl = document.getElementById('live-assistant-text');
  const liveApprovalSlotEl = document.getElementById('live-approval-slot');
  const scrollAnchorEl = document.getElementById('scroll-anchor');

  let liveText = "";
  let liveReasoning = "";
  let isReasoningOpen = true;

  function scrollToBottom() {
    if (scrollAnchorEl) {
      scrollAnchorEl.scrollIntoView({ behavior: 'smooth' });
    }
  }

  function postToNative(action, payload) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pharosBridge) {
      window.webkit.messageHandlers.pharosBridge.postMessage({ action, payload });
    }
  }

  window.toggleLiveReasoning = function() {
    isReasoningOpen = !isReasoningOpen;
    liveReasoningContentEl.style.display = isReasoningOpen ? 'block' : 'none';
    const chevron = document.getElementById('live-reasoning-chevron');
    if (chevron) {
      chevron.textContent = isReasoningOpen ? '▼' : '▶';
    }
  };

  // Exposed API to Swift via evaluateJavaScript
  window.pharosAPI = {
    setTheme: function(isDark) {
      document.body.className = isDark ? 'theme-dark' : 'theme-light';
    },

    pushDelta: function(delta) {
      liveTurnEl.style.display = 'flex';
      liveAssistantBubbleEl.style.display = 'block';
      liveText += delta;
      liveAssistantTextEl.textContent = liveText;
      scrollToBottom();
    },

    setLiveText: function(text) {
      liveText = text || "";
      if (liveText.length > 0) {
        liveTurnEl.style.display = 'flex';
        liveAssistantBubbleEl.style.display = 'block';
        liveAssistantTextEl.textContent = liveText;
      } else {
        liveAssistantBubbleEl.style.display = 'none';
        liveAssistantTextEl.textContent = "";
        if (!liveReasoning) {
          liveTurnEl.style.display = 'none';
        }
      }
      scrollToBottom();
    },

    setReasoning: function(reasoning) {
      liveReasoning = reasoning || "";
      if (liveReasoning.length > 0) {
        liveTurnEl.style.display = 'flex';
        liveReasoningCardEl.style.display = 'block';
        liveReasoningContentEl.textContent = liveReasoning;
      } else {
        liveReasoningCardEl.style.display = 'none';
        liveReasoningContentEl.textContent = "";
        if (!liveText) {
          liveTurnEl.style.display = 'none';
        }
      }
      scrollToBottom();
    },

    completeAssistant: function() {
      liveText = "";
      liveReasoning = "";
      liveTurnEl.style.display = 'none';
      liveAssistantBubbleEl.style.display = 'none';
      liveReasoningCardEl.style.display = 'none';
      liveAssistantTextEl.textContent = "";
      liveReasoningContentEl.textContent = "";
    },

    setTurns: function(turns) {
      turnsListEl.innerHTML = '';
      if (!Array.isArray(turns)) return;

      turns.forEach(turn => {
        const turnDiv = document.createElement('div');
        turnDiv.className = 'turn-container';

        if (turn.steps && Array.isArray(turn.steps)) {
          turn.steps.forEach(step => {
            if (step.blocks && Array.isArray(step.blocks)) {
              step.blocks.forEach(block => {
                const blockEl = createBlockElement(block);
                if (blockEl) turnDiv.appendChild(blockEl);
              });
            }
          });
        }
        turnsListEl.appendChild(turnDiv);
      });
      scrollToBottom();
    },

    setApproval: function(approval) {
      liveApprovalSlotEl.innerHTML = '';
      if (!approval) return;

      let toolName = 'Permission Required';
      let summary = '';
      if (approval.kind) {
        if (approval.kind.type === 'toolPermission') {
          toolName = approval.kind.toolName || 'Tool Execution';
          summary = approval.kind.explanation || JSON.stringify(approval.kind.params || {});
        } else if (approval.kind.type === 'structuredQuestionnaire') {
          toolName = approval.kind.intent || 'Questionnaire';
          summary = (approval.kind.questions || []).map(q => q.question).join('\n');
        }
      }

      const card = document.createElement('div');
      card.className = 'dsh-approval-card';
      card.innerHTML = `
        <div class="approval-title">⚠️ Confirmation Required: ${escapeHtml(toolName)}</div>
        <div class="approval-command">${escapeHtml(summary)}</div>
        <div class="approval-actions">
          <button class="btn btn-reject" onclick="resolveApproval('rejected')">Reject</button>
          <button class="btn btn-approve" onclick="resolveApproval('allowed_once')">Allow Once</button>
          <button class="btn btn-approve" onclick="resolveApproval('allowed_always')">Always Allow</button>
        </div>
      `;
      liveApprovalSlotEl.appendChild(card);
      scrollToBottom();
    }
  };

  window.resolveApproval = function(choice) {
    postToNative('resolveApproval', { choice });
    liveApprovalSlotEl.innerHTML = '';
  };

  function createBlockElement(block) {
    if (!block || !block.kind) return null;
    const kind = block.kind;
    const type = kind.type || (kind.userText ? 'userText' : (kind.assistantText ? 'assistantText' : null));

    if (type === 'userText' || kind.userText) {
      const text = kind.text || kind.userText || '';
      const row = document.createElement('div');
      row.className = 'user-row';
      const bubble = document.createElement('div');
      bubble.className = 'message-bubble user-bubble';
      bubble.textContent = text;
      row.appendChild(bubble);
      return row;
    }

    if (type === 'assistantText' || kind.assistantText) {
      const text = kind.text || kind.assistantText || '';
      const row = document.createElement('div');
      row.className = 'assistant-row';
      const bubble = document.createElement('div');
      bubble.className = 'message-bubble assistant-bubble';
      bubble.textContent = text;
      row.appendChild(bubble);
      return row;
    }

    if (type === 'reasoning' || kind.reasoning) {
      const reasoning = kind.reasoning || {};
      const thinking = typeof reasoning === 'string' ? reasoning : (reasoning.thinking || '');
      const card = document.createElement('div');
      card.className = 'dsh-card reasoning-card';
      card.innerHTML = `
        <div class="card-header" onclick="this.nextElementSibling.style.display = this.nextElementSibling.style.display === 'none' ? 'block' : 'none'">
          <span class="icon brain-icon">🧠</span>
          <span class="title">Thinking Process</span>
          <span class="status-tag">completed</span>
          <span class="chevron">▼</span>
        </div>
        <div class="card-content">${escapeHtml(thinking)}</div>
      `;
      return card;
    }

    if (type === 'toolCall' || kind.toolCall) {
      const tc = kind.toolCall || {};
      const card = document.createElement('div');
      card.className = 'dsh-card tool-card';
      card.innerHTML = `
        <div class="tool-header">
          <span>⚡</span>
          <span class="tool-name">${escapeHtml(tc.toolName || 'tool')}</span>
          <span class="tool-status">executed</span>
        </div>
        <div class="tool-body">${escapeHtml(JSON.stringify(tc.args || tc.params || {}))}</div>
      `;
      return card;
    }

    if (type === 'terminalCommand' || kind.terminalCommand) {
      const tc = kind.terminalCommand || {};
      const card = document.createElement('div');
      card.className = 'dsh-card tool-card';
      card.innerHTML = `
        <div class="tool-header">
          <span>$</span>
          <span class="tool-name">${escapeHtml(tc.command || '')}</span>
        </div>
        <div class="tool-body">${escapeHtml(tc.output || '')}</div>
      `;
      return card;
    }

    if (type === 'filePatch' || kind.filePatch) {
      const fp = kind.filePatch || {};
      const card = document.createElement('div');
      card.className = 'dsh-card tool-card';
      card.innerHTML = `
        <div class="tool-header">
          <span>📝</span>
          <span class="tool-name">${escapeHtml(fp.filePath || fp.path || 'diff')}</span>
        </div>
        <div class="tool-body">${escapeHtml(fp.diff || '')}</div>
      `;
      return card;
    }

    return null;
  }

  function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }
})();
