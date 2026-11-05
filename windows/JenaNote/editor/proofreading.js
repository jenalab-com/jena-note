'use strict';

// Live proofreading. Like macOS it never touches the document: underlines are a highlight over
// the text, so typing, undo and Korean composition see no change in the DOM. It checks what is on
// screen two seconds after the last edit or scroll, and pauses during composition.

const PROOF_DELAY_MS = 2000;
const PROOF_SHOW_MS = 300;
const PROOF_HIDE_MS = 350;
const PROOF_MAX_TEXT = 6000;
const proofPopover = document.getElementById('proof-popover');

let proofTimer = null;
let proofRequest = 0;
let proofComposing = false;
let proofSent = new Map();
let proofCandidates = [];
let proofShown = null;
let proofShowTimer = null;
let proofHideTimer = null;
let proofSelectionRequest = 0;
let proofSelectionPending = null;

/// Maps an element's text to DOM positions. Images and note marks count as one placeholder
/// character, which keeps sentences containing them out of the check, as on macOS.
function proofTextMap(element) {
  const segments = [];
  let text = '';
  const walk = node => {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        segments.push({ node: child, start: text.length });
        text += child.data;
      } else if (child.nodeType !== Node.ELEMENT_NODE || child.classList.contains('note-label') || child.tagName === 'BR') {
        continue;
      } else if (child.tagName === 'IMG' || child.classList.contains('note-ref')) {
        text += '￼';
      } else {
        walk(child);
      }
    }
  };
  walk(element);
  return { text, segments };
}

function proofPosition(map, offset, isEnd) {
  for (const { node, start } of map.segments) {
    const end = start + node.length;
    if (isEnd ? offset > start && offset <= end : offset >= start && offset < end) {
      return { node, offset: offset - start };
    }
  }
  const last = map.segments.at(-1);
  return last ? { node: last.node, offset: last.node.length } : null;
}

function proofRange(map, start, end) {
  const from = proofPosition(map, start, false);
  const to = start === end ? from : proofPosition(map, end, true);
  if (!from || !to) return null;
  const range = document.createRange();
  range.setStart(from.node, from.offset);
  range.setEnd(to.node, to.offset);
  return range;
}

function proofOffset(map, node, offset) {
  for (const segment of map.segments) {
    if (segment.node === node) return segment.start + offset;
  }
  return null;
}

// MARK: - Choosing what to check

function proofTargets() {
  const scroller = document.getElementById('scroller').getBoundingClientRect();
  const blocks = root.children;
  let low = 0;
  let high = blocks.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (blocks[middle].getBoundingClientRect().bottom <= scroller.top) low = middle + 1;
    else high = middle;
  }
  const targets = [];
  for (let index = low; index < blocks.length; index++) {
    const block = blocks[index];
    if (block.getBoundingClientRect().top >= scroller.bottom) break;
    if (block.tagName === 'TABLE') targets.push(...block.querySelectorAll('th, td'));
    else if (block.tagName !== 'PRE' && block.tagName !== 'HR') targets.push(block);
  }
  return targets;
}

/// Keeps context around the visible part when one paragraph holds a very long text.
function proofWindow(element, map) {
  if (map.text.length <= PROOF_MAX_TEXT) return { offset: 0, text: map.text };
  const scroller = document.getElementById('scroller').getBoundingClientRect();
  const box = element.getBoundingClientRect();
  const caret = document.caretRangeFromPoint(box.left + 8, Math.max(box.top, scroller.top) + 8);
  const visible = caret ? proofOffset(map, caret.startContainer, caret.startOffset) ?? 0 : 0;
  let offset = Math.max(0, visible - 500);
  // Never start inside a surrogate pair.
  const code = map.text.charCodeAt(offset);
  if (code >= 0xDC00 && code <= 0xDFFF) offset += 1;
  return { offset, text: map.text.slice(offset, offset + PROOF_MAX_TEXT) };
}

function proofRefresh() {
  proofTimer = null;
  if (proofComposing) return;
  const request = ++proofRequest;
  proofClear();
  proofSent = new Map();
  const items = [];
  proofTargets().forEach((element, id) => {
    const map = proofTextMap(element);
    if (!map.text.trim()) return;
    const part = proofWindow(element, map);
    proofSent.set(id, { element, full: map.text, offset: part.offset });
    items.push({ id, text: part.text });
  });
  if (items.length > 0) post({ type: 'proofread', requestId: request, items });
}

function proofSchedule(delay = PROOF_DELAY_MS) {
  clearTimeout(proofTimer);
  proofRequest += 1; // A result still on its way is now out of date.
  proofTimer = setTimeout(proofRefresh, delay);
}

// MARK: - Marks

function proofClear() {
  proofDismiss();
  proofCandidates = [];
  CSS.highlights.delete('proof');
}

function proofReceive(message) {
  if (message.requestId !== proofRequest || proofComposing) return;
  const ranges = [];
  for (const result of message.results) {
    const sent = proofSent.get(result.id);
    if (!sent || !sent.element.isConnected) continue;
    const map = proofTextMap(sent.element);
    if (map.text !== sent.full) continue;
    for (const item of result.suggestions) {
      const marks = item.marks
        .map(mark => proofRange(map, sent.offset + mark.location, sent.offset + mark.location + mark.length))
        .filter(Boolean);
      if (marks.length === 0) continue;
      ranges.push(...marks);
      proofCandidates.push({
        element: sent.element,
        full: sent.full,
        start: sent.offset + item.range.location,
        end: sent.offset + item.range.location + item.range.length,
        original: item.original,
        replacement: item.replacement,
        marks,
      });
    }
  }
  if (ranges.length > 0) CSS.highlights.set('proof', new Highlight(...ranges));
  proofSelectionChanged();
}

// MARK: - Applying

/// Replaces only the characters that differ, so formatting around the change stays.
function proofApply(candidate) {
  const map = proofTextMap(candidate.element);
  proofDismiss();
  if (map.text !== candidate.full) return false;
  const before = Array.from(candidate.original);
  const after = Array.from(candidate.replacement);
  let prefix = 0;
  while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix += 1;
  let suffix = 0;
  while (suffix < before.length - prefix && suffix < after.length - prefix
         && before[before.length - suffix - 1] === after[after.length - suffix - 1]) suffix += 1;
  const start = candidate.start + before.slice(0, prefix).join('').length;
  const end = candidate.end - before.slice(before.length - suffix).join('').length;
  const inserted = after.slice(prefix, after.length - suffix).join('');
  const range = proofRange(map, start, end);
  if (!range) return false;
  root.focus();
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  return inserted ? exec('insertText', inserted) : exec('delete');
}

// MARK: - Popover

function proofDismiss() {
  clearTimeout(proofShowTimer);
  clearTimeout(proofHideTimer);
  proofShown = null;
  proofPopover.hidden = true;
}

function proofShow(candidate) {
  const rect = candidate.marks[0].getClientRects()[0];
  if (!rect) return;
  proofShown = candidate;
  document.getElementById('proof-original').textContent = candidate.original;
  document.getElementById('proof-suggestion').textContent = candidate.replacement;
  document.getElementById('proof-add').hidden = candidate.isSelection === true;
  proofPopover.hidden = false;
  const box = proofPopover.getBoundingClientRect();
  const left = Math.min(rect.left, window.innerWidth - box.width - 8);
  const below = rect.bottom + 6;
  const top = below + box.height > window.innerHeight ? rect.top - box.height - 6 : below;
  proofPopover.style.left = `${Math.max(8, left)}px`;
  proofPopover.style.top = `${Math.max(8, top)}px`;
}

function proofPresent(candidate) {
  clearTimeout(proofHideTimer);
  if (proofShown === candidate) return;
  clearTimeout(proofShowTimer);
  proofShowTimer = setTimeout(() => proofShow(candidate), PROOF_SHOW_MS);
}

function proofHideSoon() {
  clearTimeout(proofShowTimer);
  clearTimeout(proofHideTimer);
  proofHideTimer = setTimeout(proofDismiss, PROOF_HIDE_MS);
}

function proofRangesMeet(a, b) {
  return a.compareBoundaryPoints(Range.END_TO_START, b) < 0 && a.compareBoundaryPoints(Range.START_TO_END, b) > 0;
}

function proofSelectionChanged() {
  if (proofComposing || proofCandidates.length === 0) return;
  const selection = getSelection();
  if (!selection?.rangeCount || !root.contains(selection.anchorNode)) return;
  const range = selection.getRangeAt(0);
  const found = proofCandidates.find(candidate => {
    if (!candidate.element.contains(selection.anchorNode)) return false;
    if (!selection.isCollapsed) return candidate.marks.some(mark => proofRangesMeet(mark, range));
    const offset = proofOffset(proofTextMap(candidate.element), selection.anchorNode, selection.anchorOffset);
    return offset !== null && offset >= candidate.start && offset <= candidate.end;
  });
  if (found) proofPresent(found);
  else if (proofShown && !proofShown.isSelection) proofDismiss();
}

function proofHover(event) {
  if (proofComposing || proofCandidates.length === 0) return;
  const inside = rect => event.clientX >= rect.left - 2 && event.clientX <= rect.right + 2
    && event.clientY >= rect.top - 6 && event.clientY <= rect.bottom + 6;
  const found = proofCandidates.find(candidate =>
    candidate.marks.some(mark => [...mark.getClientRects()].some(inside)));
  if (found) proofPresent(found);
  else if (proofShown) proofHideSoon();
}

// MARK: - Checking a selection on request

function proofCheckSelection() {
  const selection = getSelection();
  const fail = key => post({ type: 'alert', text: strings[key] ?? key });
  if (!selection?.rangeCount || selection.isCollapsed) return fail('proof.select');
  const range = selection.getRangeAt(0);
  let element = currentBlock();
  if (element?.tagName === 'TABLE') {
    element = range.startContainer.parentElement?.closest('th, td');
  }
  if (!element || element.tagName === 'PRE' || !element.contains(range.endContainer)) return fail('proof.select');
  const map = proofTextMap(element);
  const start = proofOffset(map, range.startContainer, range.startOffset);
  const end = proofOffset(map, range.endContainer, range.endOffset);
  if (start === null || end === null || start === end) return fail('proof.select');
  const text = map.text.slice(start, end);
  const id = ++proofSelectionRequest;
  proofSelectionPending = { id, element, full: map.text, start, end, text, range: range.cloneRange() };
  post({ type: 'proofreadSelection', id, text });
}

function proofReceiveSelection(message) {
  const pending = proofSelectionPending;
  if (!pending || pending.id !== message.id) return;
  proofSelectionPending = null;
  if (message.error) return post({ type: 'alert', text: message.error });
  if (message.corrected === pending.text) return post({ type: 'alert', text: strings['proof.unchanged'] ?? '' });
  proofShow({
    element: pending.element,
    full: pending.full,
    start: pending.start,
    end: pending.end,
    original: pending.text,
    replacement: message.corrected,
    marks: [pending.range],
    isSelection: true,
  });
}

// MARK: - Events

root.addEventListener('input', () => {
  proofClear();
  if (!proofComposing) proofSchedule();
});
root.addEventListener('compositionstart', () => {
  proofComposing = true;
  clearTimeout(proofTimer);
  proofRequest += 1;
  proofClear();
});
root.addEventListener('compositionend', () => {
  proofComposing = false;
  proofSchedule();
});
root.addEventListener('mousemove', proofHover);
root.addEventListener('mouseleave', () => { if (proofShown) proofHideSoon(); });
document.getElementById('scroller').addEventListener('scroll', () => {
  proofDismiss();
  proofSchedule();
});
window.addEventListener('resize', () => proofSchedule());
document.addEventListener('selectionchange', proofSelectionChanged);
document.addEventListener('keydown', event => { if (event.key === 'Escape') proofDismiss(); });

proofPopover.addEventListener('mouseenter', () => clearTimeout(proofHideTimer));
proofPopover.addEventListener('mouseleave', () => { if (proofShown && !proofShown.isSelection) proofHideSoon(); });
// Keeps the caret in the document while the mouse presses a button.
proofPopover.addEventListener('mousedown', event => {
  if (event.target.tagName === 'BUTTON') event.preventDefault();
});
document.getElementById('proof-apply').addEventListener('click', () => {
  if (proofShown) proofApply(proofShown);
});
document.getElementById('proof-add').addEventListener('click', () => {
  if (!proofShown) return;
  const term = proofShown.original.replace(/^[\s\p{P}]+|[\s\p{P}]+$/gu, '');
  proofDismiss();
  post({ type: 'addToDictionary', term });
});

window.chrome.webview.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  switch (message.type) {
    case 'load':
      proofClear();
      proofSchedule();
      break;
    case 'proofreadResult':
      proofReceive(message);
      break;
    case 'proofreadSelectionResult':
      proofReceiveSelection(message);
      break;
    case 'dictionaryChanged':
      proofClear();
      proofSchedule();
      break;
    case 'strings':
      document.getElementById('proof-original-label').textContent = message.strings['proof.original'] ?? '';
      document.getElementById('proof-suggestion-label').textContent = message.strings['proof.suggestion'] ?? '';
      document.getElementById('proof-apply').textContent = message.strings['proof.apply'] ?? '';
      document.getElementById('proof-add').textContent = message.strings['dictionary.add'] ?? '';
      break;
  }
});
