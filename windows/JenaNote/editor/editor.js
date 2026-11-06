'use strict';

// The document is a flat list of block elements, one per line, like the macOS attributed string.
// Document text only ever enters the page through textContent and DOM properties, never as markup.

const root = document.getElementById('editor');
const IMAGE_URL = 'https://doc.jenanote.local/image?p=';
const BLOCK_TAGS = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BLOCKQUOTE', 'DT', 'DD', 'PRE', 'TABLE', 'HR', 'DIV', 'UL', 'OL', 'LI']);

let plainMode = false;
let revision = 0;
let strings = {};

function post(message) {
  window.chrome.webview.postMessage(JSON.stringify(message));
}

function exec(command, value) {
  return document.execCommand(command, false, value);
}

// MARK: - Model to DOM

function wrap(tag, child) {
  const element = document.createElement(tag);
  element.append(child);
  return element;
}

function renderRun(run) {
  let node;
  if (run.image) {
    node = document.createElement('img');
    node.src = IMAGE_URL + encodeURIComponent(run.image.path);
    node.alt = run.image.alt ?? '';
    node.dataset.path = run.image.path;
    node.dataset.alt = run.image.alt ?? '';
    if (run.raw) node.dataset.raw = run.raw;
    if (run.image.width != null) {
      node.dataset.width = String(run.image.width);
      if (run.image.width > 0) node.width = run.image.width;
    }
  } else if (run.note !== undefined) {
    node = document.createElement('span');
    node.className = 'note-ref';
    node.dataset.note = run.note;
    node.contentEditable = 'false';
    node.textContent = `[${run.note}]`;
  } else {
    node = document.createTextNode(run.text);
    if (run.code) node = wrap('code', node);
    if (run.italic) node = wrap('i', node);
    if (run.bold) node = wrap('b', node);
    if (run.link != null) {
      const anchor = wrap('a', node);
      anchor.setAttribute('href', run.link);
      node = anchor;
    }
  }
  if (run.color) {
    const span = wrap('span', node);
    span.dataset.color = run.color;
    span.style.color = run.color;
    node = span;
  }
  return node;
}

function fill(element, runs) {
  for (const run of runs ?? []) element.append(renderRun(run));
  if (element.childNodes.length === 0) element.append(document.createElement('br'));
  return element;
}

function renderTable(block) {
  const table = document.createElement('table');
  if (block.separators) table.dataset.separators = JSON.stringify(block.separators);
  const body = document.createElement('tbody');
  block.rows.forEach((row, rowIndex) => {
    const line = document.createElement('tr');
    for (const cell of row) line.append(fill(document.createElement(rowIndex === block.headerRow ? 'th' : 'td'), cell));
    body.append(line);
  });
  table.append(body);
  return table;
}

function renderBlock(block) {
  switch (block.type) {
    case 'blank': return fill(document.createElement('p'));
    case 'paragraph': return fill(document.createElement('p'), block.runs);
    case 'heading': return fill(document.createElement(`h${block.level}`), block.runs);
    case 'blockquote': return fill(document.createElement('blockquote'), block.runs);
    case 'horizontalRule': return document.createElement('hr');
    case 'table': return renderTable(block);
    case 'listItem': {
      const item = fill(document.createElement(block.ordered ? 'dd' : 'dt'), block.runs);
      if (block.ordered) item.dataset.index = String(block.index);
      return item;
    }
    case 'codeBlock': {
      // One final newline keeps an empty last line visible; reading removes it again.
      const pre = document.createElement('pre');
      pre.textContent = block.lines.length > 0 ? block.lines.join('\n') + '\n' : '';
      pre.dataset.block = 'true';
      if (block.language) pre.dataset.language = block.language;
      return pre;
    }
    case 'noteDefinition': {
      const paragraph = document.createElement('p');
      const label = document.createElement('span');
      label.className = 'note-label';
      label.dataset.id = block.id;
      label.contentEditable = 'false';
      label.textContent = `[${block.id}] `;
      paragraph.append(label);
      for (const run of block.runs ?? []) paragraph.append(renderRun(run));
      return paragraph;
    }
    default:
      throw new Error(`unknown block: ${block.type}`);
  }
}

function ensureEditableLine() {
  if (root.childNodes.length === 0) root.append(fill(document.createElement('p')));
}

function render(blocks) {
  const fragment = document.createDocumentFragment();
  for (const block of blocks) fragment.append(renderBlock(block));
  root.replaceChildren(fragment);
  ensureEditableLine();
}

function renderPlain(text) {
  const lines = text.split('\n');
  if (lines.at(-1) === '') lines.pop();
  const fragment = document.createDocumentFragment();
  for (const line of lines) {
    const paragraph = document.createElement('p');
    if (line) paragraph.textContent = line;
    else paragraph.append(document.createElement('br'));
    fragment.append(paragraph);
  }
  root.replaceChildren(fragment);
  ensureEditableLine();
}

// MARK: - DOM to model

function colorToHex(value) {
  if (!value) return null;
  if (value.startsWith('#')) return value.toUpperCase();
  const match = value.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)/);
  if (!match) return null;
  return '#' + match.slice(1, 4).map(part => Number(part).toString(16).padStart(2, '0')).join('').toUpperCase();
}

function styleOf(element, style) {
  const next = { ...style };
  switch (element.tagName) {
    case 'B': case 'STRONG': next.bold = true; break;
    case 'I': case 'EM': next.italic = true; break;
    case 'CODE': next.code = true; break;
    case 'A': next.link = element.getAttribute('href') ?? ''; break;
    case 'FONT': if (element.getAttribute('color')) next.color = colorToHex(element.getAttribute('color')); break;
  }
  const inline = element.style;
  if (inline) {
    if (inline.fontWeight === 'normal') next.bold = false;
    else if (inline.fontWeight === 'bold' || Number(inline.fontWeight) >= 600) next.bold = true;
    if (inline.fontStyle === 'italic') next.italic = true;
    else if (inline.fontStyle === 'normal') next.italic = false;
    const color = element.dataset?.color ?? colorToHex(inline.color);
    if (color) next.color = color;
  }
  return next;
}

function appendRun(line, run, style) {
  if (style.color) run.color = style.color;
  if (run.text === undefined) {
    line.push(run);
    return;
  }
  if (style.bold) run.bold = true;
  if (style.italic) run.italic = true;
  if (style.code) run.code = true;
  if (style.link != null) run.link = style.link;
  const last = line.at(-1);
  if (last && last.text !== undefined && last.bold === run.bold && last.italic === run.italic
      && last.code === run.code && last.link === run.link && last.color === run.color) {
    last.text += run.text;
  } else {
    line.push(run);
  }
}

/// Walks inline content into lines. A `<br>` or a nested block starts a new line, and a
/// nested `<hr>` becomes its own entry.
function readLines(node, style, lines) {
  for (const child of node.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) {
      child.data.split('\n').forEach((part, index) => {
        if (index > 0) lines.push([]);
        if (part) appendRun(lines.at(-1), { text: part }, style);
      });
    } else if (child.nodeType !== Node.ELEMENT_NODE) {
      continue;
    } else if (child.tagName === 'BR') {
      lines.push([]);
    } else if (child.tagName === 'HR') {
      lines.push({ rule: true }, []);
    } else if (child.tagName === 'IMG') {
      const image = { path: child.dataset.path ?? '', alt: child.dataset.alt ?? '' };
      if (child.dataset.width !== undefined) image.width = Number(child.dataset.width);
      const run = { image };
      if (child.dataset.raw) run.raw = child.dataset.raw;
      appendRun(lines.at(-1), run, style);
    } else if (child.classList.contains('note-ref')) {
      appendRun(lines.at(-1), { note: child.dataset.note }, style);
    } else if (child.classList.contains('note-label')) {
      continue;
    } else if (BLOCK_TAGS.has(child.tagName)) {
      if (lines.at(-1).length > 0) lines.push([]);
      readLines(child, style, lines);
      lines.push([]);
    } else {
      readLines(child, styleOf(child, style), lines);
    }
  }
}

function linesOf(element) {
  const lines = [[]];
  readLines(element, {}, lines);
  // The line after a final `<br>` is only the browser's placeholder.
  if (lines.length > 1 && !lines.at(-1).rule && lines.at(-1).length === 0) lines.pop();
  return lines;
}

function cellRuns(cell) {
  // A cell holds one line, so anything that split it joins back with a space.
  const line = [];
  linesOf(cell).forEach((runs, index) => {
    if (runs.rule) return;
    if (index > 0 && line.length > 0) appendRun(line, { text: ' ' }, {});
    for (const run of runs) {
      if (run.text === undefined) {
        line.push(run);
      } else {
        const { text, ...rest } = run;
        appendRun(line, { text }, rest);
      }
    }
  });
  return line;
}

function readTable(table) {
  const rows = [];
  let headerRow = 0;
  for (const row of table.querySelectorAll('tr')) {
    const cells = [...row.children].filter(cell => cell.tagName === 'TH' || cell.tagName === 'TD');
    if (cells[0]?.tagName === 'TH') headerRow = rows.length;
    rows.push(cells.map(cell => cell));
  }
  const block = {
    type: 'table',
    headerRow,
    rows: rows.map(cells => cells.map(cellRuns)),
  };
  if (table.dataset.separators) block.separators = JSON.parse(table.dataset.separators);
  return block;
}

function codeLines(pre) {
  let text = '';
  const walk = node => {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) text += child.data;
      else if (child.tagName === 'BR') text += '\n';
      else walk(child);
    }
  };
  walk(pre);
  if (text === '') return [];
  if (text.endsWith('\n')) text = text.slice(0, -1);
  return text.split('\n');
}

function readBlocks() {
  const blocks = [];
  const pushLines = (element, make) => {
    linesOf(element).forEach((runs, index) => blocks.push(runs.rule ? { type: 'horizontalRule' } : make(runs, index)));
  };
  const paragraph = runs => (runs.length ? { type: 'paragraph', runs } : { type: 'blank' });
  let loose = null;

  const flushLoose = () => {
    if (!loose) return;
    pushLines(loose, paragraph);
    loose = null;
  };

  for (const node of root.childNodes) {
    if (node.nodeType !== Node.ELEMENT_NODE || !BLOCK_TAGS.has(node.tagName)) {
      // Inline content directly under the root belongs to one implicit paragraph.
      if (node.nodeType === Node.TEXT_NODE && !node.data) continue;
      loose ??= document.createElement('div');
      loose.append(node.cloneNode(true));
      continue;
    }
    flushLoose();
    switch (node.tagName) {
      case 'H1': case 'H2': case 'H3':
        pushLines(node, runs => ({ type: 'heading', level: Number(node.tagName[1]), runs }));
        break;
      case 'BLOCKQUOTE':
        pushLines(node, runs => ({ type: 'blockquote', runs }));
        break;
      case 'DT':
        pushLines(node, runs => ({ type: 'listItem', ordered: false, index: 0, runs }));
        break;
      case 'DD': {
        const previous = blocks.at(-1);
        const start = Number(node.dataset.index) || (previous?.type === 'listItem' && previous.ordered ? previous.index + 1 : 1);
        pushLines(node, (runs, line) => ({ type: 'listItem', ordered: true, index: start + line, runs }));
        break;
      }
      case 'PRE': {
        // Turning several lines into code makes one element each. Those are one block; a block
        // that came from the file keeps its own fences.
        const lines = codeLines(node);
        const previous = blocks.at(-1);
        if (previous?.type === 'codeBlock' && !node.dataset.block) {
          previous.lines.push(...lines);
        } else {
          const block = { type: 'codeBlock', lines };
          if (node.dataset.language) block.language = node.dataset.language;
          blocks.push(block);
        }
        break;
      }
      case 'TABLE':
        blocks.push(readTable(node));
        break;
      case 'HR':
        blocks.push({ type: 'horizontalRule' });
        break;
      default: {
        const label = node.querySelector(':scope > .note-label');
        pushLines(node, (runs, line) => (label && line === 0
          ? { type: 'noteDefinition', id: label.dataset.id, runs }
          : paragraph(runs)));
      }
    }
  }
  flushLoose();
  // An untouched empty document saves as empty, not as one blank line.
  return blocks.length === 1 && blocks[0].type === 'blank' ? [] : blocks;
}

function readPlainText() {
  const lines = [];
  for (const node of root.childNodes) {
    const text = node.innerText ?? node.textContent ?? '';
    lines.push(text.replace(/\n$/, ''));
  }
  const text = lines.join('\n');
  return text === '' ? '' : text + '\n';
}

// MARK: - Selection helpers

function currentBlock() {
  const selection = getSelection();
  let node = selection?.anchorNode;
  if (!node || !root.contains(node)) return root.firstElementChild;
  if (node === root) return root.children[selection.anchorOffset] ?? root.lastElementChild;
  while (node.parentNode !== root) node = node.parentNode;
  return node.nodeType === Node.ELEMENT_NODE ? node : null;
}

function isInsideTable() {
  return currentBlock()?.tagName === 'TABLE';
}

function isEmptyBlock(block) {
  return block.textContent === '' && !block.querySelector('img');
}

function caretIsAtStart(block) {
  const selection = getSelection();
  if (!selection?.isCollapsed || selection.rangeCount === 0) return false;
  const range = selection.getRangeAt(0).cloneRange();
  range.setStart(block, 0);
  return range.toString() === '' && !range.cloneContents().querySelector('img');
}

function placeCaret(node, offset = 0) {
  const range = document.createRange();
  range.setStart(node, offset);
  range.collapse(true);
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

function assignListNumbers() {
  let previous = 0;
  for (const block of root.children) {
    if (block.tagName !== 'DD') {
      previous = 0;
    } else {
      if (!block.dataset.index) block.dataset.index = String(previous + 1);
      previous = Number(block.dataset.index);
    }
  }
}

// MARK: - Commands

const BLOCK_COMMANDS = { h1: 'h1', h2: 'h2', h3: 'h3', body: 'p', ul: 'dt', ol: 'dd', quote: 'blockquote', codeblock: 'pre' };

function setBlock(tag) {
  if (isInsideTable()) return;
  const current = currentBlock()?.tagName.toLowerCase();
  exec('formatBlock', current === tag ? 'p' : tag);
  assignListNumbers();
}

function toggleInlineCode() {
  const selection = getSelection();
  if (!selection || selection.isCollapsed) return;
  let code = selection.anchorNode;
  while (code && code !== root && code.nodeName !== 'CODE') code = code.parentNode;
  if (code && code !== root) {
    const range = document.createRange();
    range.selectNode(code);
    selection.removeAllRanges();
    selection.addRange(range);
    exec('insertText', code.textContent);
  } else {
    const escape = document.createElement('div');
    escape.textContent = selection.toString();
    exec('insertHTML', `<code>${escape.innerHTML}</code>`);
  }
}

function insertRule() {
  if (isInsideTable()) return;
  exec('insertHorizontalRule');
}

let savedRange = null;

function saveRange() {
  const selection = getSelection();
  savedRange = selection?.rangeCount ? selection.getRangeAt(0).cloneRange() : null;
}

function restoreRange() {
  root.focus();
  if (!savedRange) return;
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(savedRange);
}

function applyLink(url) {
  if (!url) return;
  const selection = getSelection();
  if (selection.isCollapsed) {
    const anchor = document.createElement('a');
    anchor.setAttribute('href', url);
    anchor.textContent = url;
    const holder = document.createElement('div');
    holder.append(anchor);
    exec('insertHTML', holder.innerHTML);
  } else {
    exec('createLink', url);
  }
}

function promptLink() {
  saveRange();
  const dialog = document.getElementById('link-dialog');
  const input = document.getElementById('link-url');
  input.value = '';
  dialog.returnValue = '';
  dialog.showModal();
}

function run(name) {
  if (plainMode && name !== 'proofSelection') return;
  root.focus();
  if (BLOCK_COMMANDS[name]) return setBlock(BLOCK_COMMANDS[name]);
  switch (name) {
    case 'bold': exec('bold'); break;
    case 'italic': exec('italic'); break;
    case 'code': toggleInlineCode(); break;
    case 'hr': insertRule(); break;
    case 'link': promptLink(); break;
    case 'proofSelection': proofCheckSelection(); break;
    case 'color':
      saveRange();
      document.getElementById('color-input').click();
      break;
  }
}

// MARK: - Keys

function insertNewLine(event) {
  const block = currentBlock();
  const tag = block?.tagName;
  if (tag === 'TABLE') return;
  if (tag === 'PRE') {
    if (event.ctrlKey) {
      const next = fill(document.createElement('p'));
      block.after(next);
      placeCaret(next);
    } else {
      exec('insertLineBreak');
    }
    return;
  }
  if ((tag === 'DT' || tag === 'DD' || tag === 'BLOCKQUOTE') && isEmptyBlock(block)) {
    exec('formatBlock', 'p');
    return;
  }
  exec('insertParagraph');
  if (tag === 'DD') {
    const next = currentBlock();
    if (next?.tagName === 'DD' && next !== block) next.dataset.index = String(Number(block.dataset.index || 0) + 1);
  }
}

function moveToCell(forward) {
  const selection = getSelection();
  let cell = selection.anchorNode;
  while (cell && cell.nodeName !== 'TD' && cell.nodeName !== 'TH') cell = cell.parentNode;
  if (!cell) return;
  const cells = [...cell.closest('table').querySelectorAll('th, td')];
  const next = cells[cells.indexOf(cell) + (forward ? 1 : -1)];
  if (next) placeCaret(next, 0);
}

const SHORTCUTS = {
  b: () => run('bold'),
  i: () => run('italic'),
  u: () => {},
  s: event => post({ type: 'command', name: event.shiftKey ? 'saveAs' : 'save' }),
  o: () => post({ type: 'command', name: 'open' }),
  n: () => post({ type: 'command', name: 'new' }),
  ',': () => post({ type: 'command', name: 'settings' }),
};

document.addEventListener('keydown', event => {
  if (event.ctrlKey && !event.altKey) {
    const action = SHORTCUTS[event.key.toLowerCase()];
    if (action) {
      event.preventDefault();
      action(event);
      return;
    }
  }
  if (event.target !== root) return;
  // During Korean composition these keys belong to the input method.
  if (event.isComposing || event.keyCode === 229) return;

  if (event.key === 'Enter') {
    event.preventDefault();
    insertNewLine(event);
  } else if (event.key === 'Tab') {
    event.preventDefault();
    if (isInsideTable()) moveToCell(!event.shiftKey);
    else if (!event.shiftKey) exec('insertText', '\t');
  } else if (event.key === 'Backspace') {
    const block = currentBlock();
    if (block && ['DT', 'DD', 'BLOCKQUOTE', 'H1', 'H2', 'H3'].includes(block.tagName) && caretIsAtStart(block)) {
      event.preventDefault();
      exec('formatBlock', 'p');
    }
  }
});

// Only plain text comes in, so pasted markup can never reach the document.
root.addEventListener('paste', event => {
  event.preventDefault();
  const text = event.clipboardData?.getData('text/plain') ?? '';
  if (!text) return;
  const normalized = text.replace(/\r\n?/g, '\n');
  exec('insertText', isInsideTable() ? normalized.replace(/\n+/g, ' ') : normalized);
});
root.addEventListener('drop', event => event.preventDefault());

// A link is text being edited. Ctrl+click opens it outside the app.
root.addEventListener('click', event => {
  const anchor = event.target.closest?.('a');
  if (!anchor) return;
  event.preventDefault();
  if (event.ctrlKey) post({ type: 'openLink', url: anchor.getAttribute('href') });
});

root.addEventListener('input', () => {
  ensureEditableLine();
  revision += 1;
  post({ type: 'changed', revision });
});

// MARK: - Toolbar

function buildToolbar() {
  const toolbar = document.getElementById('toolbar');
  const items = [
    ['bold', 'toolbar.bold'], ['italic', 'toolbar.italic'], ['code', 'toolbar.code'], null,
    ['body', 'toolbar.body'], ['h1', 'toolbar.h1'], ['h2', 'toolbar.h2'], ['h3', 'toolbar.h3'], null,
    ['ul', 'toolbar.ul'], ['ol', 'toolbar.ol'], ['quote', 'toolbar.quote'], ['codeblock', 'doc.codeBlock'], ['hr', 'toolbar.hr'], null,
    ['link', 'toolbar.link'], ['color', 'menu.format.textColor'], null,
    ['proofSelection', 'proof.button'],
  ];
  toolbar.replaceChildren();
  for (const item of items) {
    if (!item) {
      const separator = document.createElement('span');
      separator.className = 'separator';
      toolbar.append(separator);
      continue;
    }
    const button = document.createElement('button');
    button.type = 'button';
    button.tabIndex = -1;
    button.textContent = strings[item[1]] ?? item[1];
    // Keeps the selection in the editor while the mouse presses a button.
    button.addEventListener('mousedown', event => event.preventDefault());
    button.addEventListener('click', () => run(item[0]));
    toolbar.append(button);
  }
  document.getElementById('link-label').textContent = strings['doc.linkPrompt'] ?? '';
  document.getElementById('link-ok').textContent = strings['doc.ok'] ?? 'OK';
  document.getElementById('link-cancel').textContent = strings['ai.work.cancel'] ?? 'Cancel';
}

document.getElementById('link-dialog').addEventListener('close', event => {
  restoreRange();
  if (event.target.returnValue === 'ok') applyLink(document.getElementById('link-url').value.trim());
});
document.getElementById('color-input').addEventListener('change', event => {
  restoreRange();
  exec('foreColor', event.target.value);
});

// MARK: - Host messages

function loadDocument(message) {
  plainMode = message.plain === true;
  document.body.classList.toggle('plain', plainMode);
  if (plainMode) renderPlain(message.text);
  else render(message.blocks);
  revision = 0;
  document.getElementById('scroller').scrollTop = 0;
  placeCaret(root.firstElementChild, 0);
  root.focus();
}

window.chrome.webview.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  switch (message.type) {
    case 'strings':
      strings = message.strings;
      buildToolbar();
      break;
    case 'settings': {
      const style = document.documentElement.style;
      style.setProperty('--body-size', `${message.bodySize}pt`);
      style.setProperty('--letter-spacing', `${message.letterSpacing / 100}em`);
      if (message.paper) style.setProperty('--paper', message.paper);
      else style.removeProperty('--paper');
      break;
    }
    case 'load':
      loadDocument(message);
      post({ type: 'loaded' });
      break;
    case 'getContent':
      // Export always needs blocks. Saving a plain text document needs its characters.
      post(message.format === 'text' || (plainMode && message.format !== 'export')
        ? { type: 'content', id: message.id, revision, text: readPlainText() }
        : { type: 'content', id: message.id, revision, blocks: readBlocks() });
      break;
    case 'run':
      run(message.name);
      break;
    case 'native':
      root.focus();
      exec(message.name);
      break;
    case 'selftest': {
      const script = document.createElement('script');
      script.src = 'selftest.js';
      // Without cases this only prepares the page for later self test steps.
      script.addEventListener('load', () => (message.cases ? window.jenaRunSelfTest(message.cases) : post({ type: 'selftest' })));
      document.head.append(script);
      break;
    }
  }
});

document.execCommand('defaultParagraphSeparator', false, 'p');
ensureEditableLine();
post({ type: 'ready' });
