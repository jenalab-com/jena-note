'use strict';

// The AI panel. A request carries the document as text, and its answer comes back as advice or as a
// revised text. A revision is applied as small edits, so the formatting around unchanged words stays.

const aiPanel = document.getElementById('ai-panel');
const aiSplitter = document.getElementById('ai-splitter');
const aiMessagesView = document.getElementById('ai-messages');
const aiTranscript = document.getElementById('ai-transcript');
const aiLoading = document.getElementById('ai-loading');
const aiInput = document.getElementById('ai-input');
const aiSelectionLabel = document.getElementById('ai-selection');
const aiModelPicker = document.getElementById('ai-model');
const aiSendButton = document.getElementById('ai-send');
const aiUsageStatus = document.getElementById('ai-usage-status');
const aiUsagePopover = document.getElementById('ai-usage-popover');
const AI_MIN_WIDTH = 260;
const AI_MAX_WIDTH = 600;
const AI_MAX_DIFF = 4000000;
const AI_CUSTOM_MODEL = '\u0000custom';

const aiConversations = new Map();
let aiConversation = null;
let aiKey = null;
let aiUntitledCount = 0;
let aiBusy = false;
let aiRequestId = 0;
let aiPending = null;
let aiSelection = null;
let aiProvider = 'claude';
let aiModel = '';
let aiMetadataId = 0;
let aiMetadataState = { models: [], quotas: [], usageAvailable: false, refreshing: false, failed: false };
let aiMetadataProvider = null;
let aiCountdownTimer = 0;

// MARK: - Text and positions

/// One editable place: a block, or a table cell. Its characters come with where each one lives.
function aiPartMap(element) {
  const segments = [];
  let text = '';
  const walk = node => {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        segments.push({ node: child, start: text.length, length: child.length });
        text += child.data;
      } else if (child.nodeType !== Node.ELEMENT_NODE || child.classList.contains('note-label')) {
        continue;
      } else if (child.tagName === 'BR') {
        // A trailing break in a block is only there to give an empty line height.
        if (child.nextSibling || element.tagName === 'PRE') {
          segments.push({ node, child, start: text.length, length: 1 });
          text += '\n';
        }
      } else if (child.tagName === 'IMG' || child.classList.contains('note-ref')) {
        // The same mark macOS has in its document string. Text cannot rebuild what it stands for.
        segments.push({ node, child, start: text.length, length: 1 });
        text += '￼';
      } else {
        walk(child);
      }
    }
  };
  walk(element);
  // A code block keeps a final line break so its last line can hold the caret. It is not content.
  if (element.tagName === 'PRE' && text.endsWith('\n') && segments.length > 0) {
    text = text.slice(0, -1);
    const last = segments[segments.length - 1];
    last.length -= 1;
    if (last.length === 0) segments.pop();
  }
  return { element, segments, text };
}

function aiTextMap() {
  const parts = [];
  let text = '';
  const add = (element, separator, fixed) => {
    const part = aiPartMap(element);
    part.start = text.length;
    part.fixed = fixed;
    parts.push(part);
    text += part.text + separator;
  };
  const blocks = [...root.children];
  blocks.forEach((block, blockIndex) => {
    const end = blockIndex < blocks.length - 1 ? '\n' : '';
    if (block.tagName === 'TABLE') {
      const rows = [...block.querySelectorAll('tr')];
      rows.forEach((row, rowIndex) => {
        const cells = [...row.querySelectorAll('th, td')];
        cells.forEach((cell, cellIndex) => {
          const separator = cellIndex < cells.length - 1 ? '\t' : rowIndex < rows.length - 1 ? '\n' : end;
          add(cell, separator, true);
        });
      });
    } else {
      add(block, end, block.tagName === 'HR');
    }
  });
  return { parts, text };
}

function aiPartAt(map, offset) {
  // The earliest place that holds this offset: the end of one block before the start of the next.
  for (const part of map.parts) {
    if (offset <= part.start + part.text.length) return part;
  }
  return map.parts[map.parts.length - 1];
}

function aiPosition(map, offset) {
  const part = aiPartAt(map, offset);
  const inside = Math.max(0, offset - part.start);
  let last = null;
  for (const segment of part.segments) {
    if (inside <= segment.start + segment.length) {
      if (segment.child) {
        const index = [...segment.node.childNodes].indexOf(segment.child);
        return { node: segment.node, offset: inside <= segment.start ? index : index + 1 };
      }
      return { node: segment.node, offset: inside - segment.start };
    }
    last = segment;
  }
  if (last && !last.child) return { node: last.node, offset: last.length };
  return { node: part.element, offset: part.element.childNodes.length };
}

// MARK: - Revisions

/// Smallest set of replacements turning one text into another, at most `limit` units of work.
function aiDiff(before, after, limit = AI_MAX_DIFF) {
  let prefix = 0;
  const shorter = Math.min(before.length, after.length);
  while (prefix < shorter && before.charCodeAt(prefix) === after.charCodeAt(prefix)) prefix++;
  // Never cut through a surrogate pair.
  if (prefix > 0 && before.charCodeAt(prefix - 1) >= 0xD800 && before.charCodeAt(prefix - 1) <= 0xDBFF) prefix--;
  let suffix = 0;
  while (suffix < shorter - prefix && before.charCodeAt(before.length - 1 - suffix) === after.charCodeAt(after.length - 1 - suffix)) suffix++;
  if (suffix > 0) {
    const code = before.charCodeAt(before.length - suffix);
    if (code >= 0xDC00 && code <= 0xDFFF) suffix--;
  }
  const a = [...before.slice(prefix, before.length - suffix)];
  const b = [...after.slice(prefix, after.length - suffix)];
  if (a.length === 0 && b.length === 0) return [];
  if (a.length === 0 || b.length === 0) {
    return [{ start: prefix, end: before.length - suffix, text: after.slice(prefix, after.length - suffix) }];
  }
  if (a.length * b.length > limit) throw new Error(strings['ai.editTooLarge'] ?? 'too large');

  // Longest common subsequence, walked backward from a table of lengths.
  const width = b.length + 1;
  const table = new Uint32Array((a.length + 1) * width);
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      table[i * width + j] = a[i] === b[j] ? table[(i + 1) * width + j + 1] + 1 : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }
  const hunks = [];
  let i = 0;
  let j = 0;
  let offset = prefix;
  let current = null;
  const close = () => {
    if (current) hunks.push(current);
    current = null;
  };
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      close();
      offset += a[i].length;
      i++;
      j++;
    } else if (j < b.length && (i === a.length || table[i * width + j + 1] >= table[(i + 1) * width + j])) {
      current ??= { start: offset, end: offset, text: '' };
      current.text += b[j];
      j++;
    } else {
      current ??= { start: offset, end: offset, text: '' };
      offset += a[i].length;
      current.end = offset;
      i++;
    }
  }
  close();
  return hunks;
}

/// Refuses anything text cannot do, before anything has changed.
function aiCheckHunks(hunks, map) {
  const conflict = () => new Error(strings['ai.attachmentConflict'] ?? 'conflict');
  for (const hunk of hunks) {
    const removed = map.text.slice(hunk.start, hunk.end);
    if (removed.includes('￼') || hunk.text.includes('￼')) throw conflict();
    const from = aiPartAt(map, hunk.start);
    const to = aiPartAt(map, hunk.end);
    if (from.fixed || to.fixed) {
      // A table keeps its shape. Text inside one cell can change, and nothing else.
      if (from !== to || /[\n\t]/.test(hunk.text) || /[\n\t]/.test(removed)) throw conflict();
    }
  }
}

function aiApplyHunk(hunk) {
  const map = aiTextMap();
  const from = aiPosition(map, hunk.start);
  const to = aiPosition(map, hunk.end);
  const range = document.createRange();
  range.setStart(from.node, from.offset);
  range.setEnd(to.node, to.offset);
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  const lines = hunk.text.split('\n');
  if (!range.collapsed && hunk.text === '') {
    exec('delete');
    return;
  }
  lines.forEach((line, index) => {
    if (index > 0) insertNewLine({ ctrlKey: false });
    if (line) exec('insertText', line);
    else if (!getSelection().isCollapsed) exec('delete');
  });
}

/// `snapshot.text` must still be the document. Everything is checked first, and a result that does
/// not come out exactly as the answer said is taken back.
function aiApplyRevision(snapshot, revised) {
  const map = aiTextMap();
  if (map.text !== snapshot.text) throw new Error(strings['ai.editConflict'] ?? 'conflict');
  const whole = snapshot.text.slice(0, snapshot.start) + revised + snapshot.text.slice(snapshot.end);
  const hunks = aiDiff(snapshot.text, whole);
  if (hunks.length === 0) return false;
  aiCheckHunks(hunks, map);

  root.focus();
  let steps = 0;
  findReplacing = true;
  try {
    // From the end, so earlier offsets stay right.
    for (const hunk of [...hunks].reverse()) {
      aiApplyHunk(hunk);
      steps += 1 + hunk.text.split('\n').length * 2;
    }
    if (aiTextMap().text !== whole) {
      for (let index = 0; index < steps && aiTextMap().text !== snapshot.text; index++) exec('undo');
      throw new Error(strings['ai.editConflict'] ?? 'conflict');
    }
  } finally {
    findReplacing = false;
  }
  root.dispatchEvent(new InputEvent('input', { bubbles: true }));
  return true;
}

// MARK: - Selection

function aiSelectionOffsets(map) {
  if (!aiSelection || !root.contains(aiSelection.startContainer) || aiSelection.collapsed) return null;
  const offsetOf = (node, offset) => {
    let block = node;
    while (block && block.parentNode !== root) block = block.parentNode;
    if (!block) return 0;
    let inside = node;
    let part = map.parts.find(item => item.element === block);
    if (!part) {
      while (inside && inside.nodeName !== 'TH' && inside.nodeName !== 'TD') inside = inside.parentNode;
      part = map.parts.find(item => item.element === inside) ?? map.parts.find(item => block.contains(item.element));
    }
    if (!part) return 0;
    const range = document.createRange();
    range.setStart(part.element, 0);
    range.setEnd(node, offset);
    const fragment = range.cloneContents();
    const holder = document.createElement('div');
    holder.append(fragment);
    return part.start + aiPartMap(holder).text.length;
  };
  const start = offsetOf(aiSelection.startContainer, aiSelection.startOffset);
  const end = offsetOf(aiSelection.endContainer, aiSelection.endOffset);
  return end > start ? { start, end } : null;
}

function aiUpdateSelection() {
  if (!aiActive) return;
  CSS.highlights.delete('ai-selection');
  const map = aiSelection ? aiTextMap() : null;
  const offsets = map ? aiSelectionOffsets(map) : null;
  aiSelectionLabel.hidden = offsets === null;
  if (offsets) {
    const excerpt = map.text.slice(offsets.start, offsets.end).replace(/\n/g, ' ');
    aiSelectionLabel.textContent = `${strings['ai.selection'] ?? ''} ${offsets.end - offsets.start} · ${excerpt.slice(0, 60)}`;
    // Focus in the composer hides the native selection. This keeps showing what will be sent.
    CSS.highlights.set('ai-selection', new Highlight(aiSelection));
  }
  const whole = strings[aiConversation?.mode === 'edit' ? 'ai.wholeEdit' : 'ai.wholeContext'] ?? '';
  document.getElementById('ai-mode').title = offsets ? aiSelectionLabel.textContent : whole;
}

// MARK: - Messages

const aiSafeLink = address => /^(https?|mailto):/i.test(address ?? '');

/// Reuses the document's rendering. A generated answer must not load files or run odd links.
function aiRenderMarkdown(blocks) {
  const holder = document.createElement('div');
  holder.className = 'ai-markdown';
  for (const block of blocks) holder.append(renderBlock(block));
  for (const image of holder.querySelectorAll('img')) {
    const label = document.createElement('span');
    label.className = 'ai-image-label';
    label.textContent = image.alt || image.dataset.path || '';
    image.replaceWith(label);
  }
  for (const link of holder.querySelectorAll('a')) {
    if (!aiSafeLink(link.getAttribute('href'))) link.replaceWith(...link.childNodes);
  }
  for (const element of holder.querySelectorAll('[contenteditable]')) element.removeAttribute('contenteditable');
  return holder;
}

function aiMessageElement(message) {
  const row = document.createElement('div');
  row.className = `ai-message ai-${message.role}`;
  if (message.role === 'assistant' && message.blocks) row.append(aiRenderMarkdown(message.blocks));
  else row.textContent = message.text;
  return row;
}

function aiRenderMessages() {
  const messages = aiConversation?.messages ?? [];
  aiMessagesView.replaceChildren(...messages.map(message => (message.element ??= aiMessageElement(message))));
  aiLoading.hidden = !aiBusy;
  aiTranscript.scrollTop = aiTranscript.scrollHeight;
}

function aiAdd(role, text, blocks) {
  aiConversation?.messages.push({ role, text, blocks });
}

function aiUpdateControls() {
  aiSendButton.textContent = aiBusy ? '■' : '↑';
  aiSendButton.title = strings[aiBusy ? 'ai.stop' : 'ai.send'] ?? '';
  aiSendButton.disabled = !aiConversation;
  aiModelPicker.disabled = aiBusy;
  for (const button of document.querySelectorAll('#ai-mode button')) {
    button.disabled = aiBusy;
    button.classList.toggle('on', button.dataset.mode === (aiConversation?.mode ?? 'guide'));
  }
  const tokens = aiConversation?.tokens[aiProvider];
  document.getElementById('ai-session').textContent = `${strings['ai.conversationTokens'] ?? ''}: ${tokens ?? '—'}`;
}

// MARK: - Sending

function aiSnapshot() {
  const map = aiTextMap();
  const offsets = aiSelectionOffsets(map);
  return {
    text: map.text,
    start: offsets ? offsets.start : 0,
    end: offsets ? offsets.end : map.text.length,
    selectedText: offsets ? map.text.slice(offsets.start, offsets.end) : '',
  };
}

function aiSend() {
  if (aiBusy || !aiConversation) return;
  const question = aiInput.value.trim();
  if (!question) return;
  const conversation = aiConversation;
  const snapshot = aiSnapshot();
  const id = ++aiRequestId;
  post({
    type: 'aiSend',
    id,
    document: snapshot.text,
    selectedText: snapshot.selectedText,
    history: conversation.messages.map(message => ({ role: message.role, text: message.text })),
    request: question,
    mode: conversation.mode,
  });
  aiPending = { id, snapshot, question, conversation, mode: conversation.mode };
  aiAdd('user', question);
  aiInput.value = '';
  conversation.draft = '';
  aiBusy = true;
  aiRenderMessages();
  aiUpdateControls();
}

function aiStop(announce = true) {
  if (!aiPending) return;
  post({ type: 'aiCancel', id: aiPending.id });
  document.getElementById('ai-waiting').textContent = strings['ai.waiting'] ?? '';
  const { conversation } = aiPending;
  aiPending = null;
  aiBusy = false;
  if (announce) conversation.messages.push({ role: 'status', text: strings['ai.cancelled'] ?? '' });
  aiRenderMessages();
  aiUpdateControls();
}

function aiResult(message) {
  if (!aiPending || aiPending.id !== message.id) return;
  const { snapshot, question, conversation, mode } = aiPending;
  aiPending = null;
  aiBusy = false;
  const giveBack = () => {
    // A failed request must not lose what the author wrote.
    if (conversation === aiConversation && !aiInput.value) aiInput.value = question;
    if (!conversation.draft) conversation.draft = question;
  };

  if (message.consulted?.length > 0 && !message.promptFailed) {
    // What was actually read, so nobody mistakes this for a check of the whole work.
    conversation.messages.push({ role: 'status', text: `${strings['ai.index.sources'] ?? ''}\n${message.consulted.join('\n')}` });
  }
  if (message.tokens != null && message.provider) {
    conversation.tokens[message.provider] = (conversation.tokens[message.provider] ?? 0) + message.tokens;
  }
  document.getElementById('ai-waiting').textContent = strings['ai.waiting'] ?? '';
  if (message.promptFailed) {
    // Nothing was sent, so the question was never part of this conversation.
    const question_ = conversation.messages.findLastIndex(item => item.role === 'user' && item.text === question);
    if (question_ >= 0) conversation.messages.splice(question_, 1);
    conversation.messages.push({ role: 'status', text: message.error });
    giveBack();
  } else if (message.error !== undefined) {
    conversation.messages.push({ role: 'status', text: message.error });
    giveBack();
  } else {
    conversation.messages.push({ role: 'assistant', text: message.text, blocks: message.blocks });
    if (mode === 'edit' && message.replacement != null) {
      try {
        if (conversation !== aiConversation || aiComposing) throw new Error(strings['ai.editConflict'] ?? 'conflict');
        aiApplyRevision(snapshot, message.replacement);
        conversation.messages.push({ role: 'status', text: strings['doc.aiApplied'] ?? '' });
      } catch (error) {
        conversation.messages.push({ role: 'status', text: `${error.message}\n\n${message.raw ?? ''}` });
      }
    }
  }
  aiRenderMessages();
  aiUpdateControls();
  aiRefreshMetadata();
}

// MARK: - Models and usage

function aiFillModels() {
  const ids = aiMetadataState.models.map(model => model.id);
  if (aiModel && !ids.includes(aiModel)) ids.push(aiModel);
  aiModelPicker.replaceChildren();
  const add = (value, label) => {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = label;
    aiModelPicker.append(option);
  };
  add('', strings['ai.defaultModel'] ?? '');
  for (const id of ids) add(id, id);
  add(AI_CUSTOM_MODEL, strings['ai.composer.customModel'] ?? '');
  aiModelPicker.value = aiModel;
  aiModelPicker.title = strings['ai.modelHint'] ?? '';
}

function aiCountdown(resetsAt) {
  if (resetsAt == null) return '—';
  const minutes = Math.ceil(Math.max(0, resetsAt - Date.now() / 1000) / 60);
  if (minutes >= 1440) return `${Math.floor(minutes / 1440)}d ${Math.floor((minutes % 1440) / 60)}h`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

function aiUpdateUsage() {
  const state = aiMetadataState;
  const details = document.getElementById('ai-usage-details');
  if (state.refreshing) {
    aiUsageStatus.textContent = strings['ai.loadingUsage'] ?? '';
    details.textContent = aiUsageStatus.textContent;
  } else if (state.usageAvailable) {
    // Unknown stays unknown, never a made-up 0%.
    aiUsageStatus.textContent = state.quotas.map(quota => `${Math.round(quota.percent)}% ${quota.modelName ?? aiCountdown(quota.resetsAt)}`).join(' · ');
    details.textContent = `${strings['ai.accountUsage'] ?? ''}: ${state.quotas.map(quota => quota.summary).join(' · ')}`;
  } else {
    aiUsageStatus.textContent = strings[state.failed ? 'ai.metadataUnavailable' : 'ai.quotaUnavailable'] ?? '';
    details.textContent = aiUsageStatus.textContent;
  }
  aiUsageStatus.title = aiProvider === 'gemini' ? strings['ai.geminiQuotaHint'] ?? '' : strings['ai.quotaHint'] ?? '';
}

function aiRefreshMetadata() {
  if (!aiActive) return;
  aiMetadataState = { ...aiMetadataState, refreshing: true, failed: false };
  aiUpdateUsage();
  post({ type: 'aiMetadata', id: ++aiMetadataId });
}

function aiMetadataResult(message) {
  if (message.id !== aiMetadataId) return;
  const failed = message.failed === true;
  const loaded = message.metadata ?? {};
  aiMetadataState = {
    models: loaded.models ?? [],
    quotas: loaded.quotas ?? [],
    usageAvailable: loaded.usageAvailable === true,
    refreshing: false,
    failed,
  };
  aiFillModels();
  aiUpdateUsage();
}

// MARK: - Panel

function aiDocumentName() {
  if (!readingPath) return strings['doc.untitled'] ?? '';
  return readingPath.split(/[\\/]/).pop();
}

/// Each document has its own conversation for as long as the app runs, as on macOS.
function aiDocumentChanged() {
  if (aiConversation) aiConversation.draft = aiInput.value;
  aiStop();
  aiKey = readingPath ?? `untitled:${++aiUntitledCount}`;
  aiEnterConversation();
}

/// Saving an untitled document under a name keeps its conversation.
function aiPathChanged(previous) {
  if (previous === readingPath) return;
  const key = readingPath ?? aiKey;
  if (aiConversation && !aiConversations.has(key)) {
    aiConversations.delete(aiKey);
    aiConversations.set(key, aiConversation);
  }
  aiKey = key;
  aiEnterConversation();
}

function aiUpdateWorkRow(status) {
  const dot = document.getElementById('ai-work-dot');
  const row = document.getElementById('ai-work');
  const off = strings['ai.work.row.off'] ?? '';
  const settings = strings['ai.work.row.settingsButton'] ?? '';
  const views = {
    unsaved: [off, settings, '', false],
    notInWork: [off, settings, '', true],
    noSources: [off, settings, '', true],
    disabled: [strings['ai.work.row.disabled'] ?? '', strings['ai.work.row.enableButton'] ?? '', '', true],
    corrupt: [strings['ai.work.row.corrupt'] ?? '', strings['ai.work.row.resetButton'] ?? '', 'bad', true],
    indexed: [status.text ?? '', settings, status.failed ? 'bad' : status.running ? 'busy' : 'ok', true],
  };
  const [text, button, tone, enabled] = views[status.kind] ?? views.notInWork;
  document.getElementById('ai-work-text').textContent = text;
  document.getElementById('ai-work-button').textContent = button;
  dot.className = tone;
  row.disabled = !enabled;
  row.title = status.kind === 'unsaved' ? strings['ai.work.row.saveFirst'] ?? '' : text;
}

function aiEnterConversation() {
  if (!aiConversations.has(aiKey)) aiConversations.set(aiKey, { messages: [], tokens: {}, draft: '', mode: 'guide' });
  aiConversation = aiConversations.get(aiKey);
  aiInput.value = aiConversation.draft;
  aiSelection = null;
  document.getElementById('ai-document').textContent = aiDocumentName();
  if (!aiActive) return;
  aiRenderMessages();
  aiUpdateControls();
  aiUpdateSelection();
  post({ type: 'aiWorkRefresh' });
}

function aiSetWidth(width) {
  aiPanel.style.width = `${Math.min(AI_MAX_WIDTH, Math.max(AI_MIN_WIDTH, width))}px`;
}

function aiToggle() {
  captureAnchorNow();
  // The panel works on the document, not on its source.
  if (sourceActive && !aiActive) post({ type: 'command', name: 'toggleSource' });
  aiActive = !aiActive;
  aiPanel.hidden = !aiActive;
  aiSplitter.hidden = !aiActive;
  if (!aiActive) {
    aiStop(false);
    CSS.highlights.delete('ai-selection');
    clearInterval(aiCountdownTimer);
    aiUsagePopover.hidden = true;
  }
  layoutReading();
  updateReadingToolbar();
  updateSourceToolbar();
  if (aiActive) {
    if (!aiConversation) aiDocumentChanged();
    aiFillStrings();
    aiEnterConversation();
    if (aiMetadataProvider !== aiProvider) {
      aiMetadataProvider = aiProvider;
      aiMetadataState = { models: [], quotas: [], usageAvailable: false, refreshing: false, failed: false };
      aiRefreshMetadata();
    }
    aiFillModels();
    aiUpdateUsage();
    aiCountdownTimer = setInterval(aiUpdateUsage, 60000);
    aiInput.focus();
  } else {
    root.focus();
  }
}

function aiFillStrings() {
  document.getElementById('ai-settings').title = strings['ai.settings'] ?? '';
  document.getElementById('ai-usage').title = strings['ai.accountUsage'] ?? '';
  document.getElementById('ai-usage-refresh').textContent = strings['ai.refreshUsage'] ?? '';
  document.getElementById('ai-waiting').textContent = strings['ai.waiting'] ?? '';
  document.getElementById('ai-session').title = strings['ai.conversationTokensHint'] ?? '';
  for (const button of document.querySelectorAll('#ai-mode button')) button.textContent = strings[`ai.${button.dataset.mode}`] ?? '';
  aiInput.placeholder = strings['ai.composer.placeholder'] ?? '';
  aiInput.title = strings['ai.composer.keyboard'] ?? '';
  document.getElementById('ai-model-label').textContent = strings['ai.model'] ?? '';
  document.getElementById('ai-model-ok').textContent = strings['ai.composer.apply'] ?? '';
  document.getElementById('ai-model-cancel').textContent = strings['ai.work.cancel'] ?? '';
}

function aiApplyHostSettings(ai) {
  const changed = ai.provider !== aiProvider;
  aiProvider = ai.provider;
  aiModel = ai.model ?? '';
  if (!aiActive) return;
  aiFillStrings();
  if (changed) {
    aiMetadataProvider = aiProvider;
    aiMetadataState = { models: [], quotas: [], usageAvailable: false, refreshing: false, failed: false };
    aiRefreshMetadata();
  }
  aiFillModels();
  aiUpdateUsage();
  aiUpdateControls();
}

// MARK: - Events

let aiComposing = false;
root.addEventListener('compositionstart', () => { aiComposing = true; });
root.addEventListener('compositionend', () => { aiComposing = false; });

document.addEventListener('selectionchange', () => {
  if (document.activeElement !== root) return;
  const selection = getSelection();
  aiSelection = selection?.rangeCount && !selection.isCollapsed && root.contains(selection.anchorNode) ? selection.getRangeAt(0).cloneRange() : null;
  aiUpdateSelection();
});

aiInput.addEventListener('keydown', event => {
  if (event.key !== 'Enter' || event.isComposing || event.keyCode === 229) return;
  if (event.shiftKey || event.ctrlKey || event.altKey) return;
  event.preventDefault();
  aiSend();
});
aiInput.addEventListener('input', () => {
  if (aiConversation) aiConversation.draft = aiInput.value;
});

aiSendButton.addEventListener('click', () => (aiBusy ? aiStop() : aiSend()));
document.getElementById('ai-settings').addEventListener('click', () => post({ type: 'command', name: 'aiSettings' }));
document.getElementById('ai-work').addEventListener('click', () => post({ type: 'command', name: 'aiWorkAction' }));
for (const button of document.querySelectorAll('#ai-mode button')) {
  button.addEventListener('click', () => {
    if (!aiConversation) return;
    aiConversation.mode = button.dataset.mode;
    aiUpdateControls();
    aiUpdateSelection();
  });
}

aiModelPicker.addEventListener('change', () => {
  if (aiModelPicker.value === AI_CUSTOM_MODEL) {
    aiFillModels();
    document.getElementById('ai-model-input').value = aiModel;
    document.getElementById('ai-model-dialog').showModal();
    return;
  }
  aiModel = aiModelPicker.value;
  aiFillModels();
  post({ type: 'readingChange', values: { aiModel } });
});
document.getElementById('ai-model-dialog').addEventListener('close', event => {
  if (event.target.returnValue !== 'ok') return;
  aiModel = document.getElementById('ai-model-input').value.trim();
  aiFillModels();
  post({ type: 'readingChange', values: { aiModel } });
});

document.getElementById('ai-usage').addEventListener('click', () => {
  aiUsagePopover.hidden = !aiUsagePopover.hidden;
  if (!aiUsagePopover.hidden) placePopover(aiUsagePopover, document.getElementById('ai-usage'));
});
document.getElementById('ai-usage-refresh').addEventListener('click', aiRefreshMetadata);
document.getElementById('ai-usage-reload').addEventListener('click', aiRefreshMetadata);
document.addEventListener('mousedown', event => {
  if (!aiUsagePopover.contains(event.target) && event.target.id !== 'ai-usage') aiUsagePopover.hidden = true;
});

aiMessagesView.addEventListener('click', event => {
  const link = event.target.closest?.('a');
  if (!link) return;
  event.preventDefault();
  if (aiSafeLink(link.getAttribute('href'))) post({ type: 'openLink', url: link.getAttribute('href') });
});

aiSplitter.addEventListener('pointerdown', event => {
  event.preventDefault();
  aiSplitter.setPointerCapture(event.pointerId);
  const startX = event.clientX;
  const startWidth = aiPanel.getBoundingClientRect().width;
  const move = moved => aiSetWidth(startWidth + startX - moved.clientX);
  const up = () => {
    aiSplitter.removeEventListener('pointermove', move);
    aiSplitter.removeEventListener('pointerup', up);
  };
  aiSplitter.addEventListener('pointermove', move);
  aiSplitter.addEventListener('pointerup', up);
});

window.chrome.webview.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  switch (message.type) {
    case 'aiResult':
      aiResult(message);
      break;
    case 'aiMetadataResult':
      aiMetadataResult(message);
      break;
    case 'aiToggle':
      aiToggle();
      break;
    case 'aiWork':
      aiUpdateWorkRow(message);
      break;
    case 'aiProgress':
      if (aiPending?.id === message.id) document.getElementById('ai-waiting').textContent = message.text;
      break;
    case 'settings':
      aiApplyHostSettings(message.ai);
      break;
  }
});
