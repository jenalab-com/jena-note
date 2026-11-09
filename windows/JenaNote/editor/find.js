'use strict';

// Find and replace in the document. Like macOS, matches are highlights over the text, so finding
// never touches the document, saving or undo. Only replacing edits, one undoable change at a time.
// Also as on macOS, the query is a field in the toolbar and replacing opens a panel under it.

const findField = document.getElementById('find-field');
const findInput = document.getElementById('find-input');
const findCount = document.getElementById('find-count');
const replaceRow = document.getElementById('replace-panel');
const replaceInput = document.getElementById('replace-input');
/// A search is open from Ctrl+F or typing in the field until Esc or the clear button ends it.
let findActive = false;
let findMatches = [];
let findCurrent = -1;
// Where the caret was when the bar opened. Focusing the field moves the page selection away.
let findAnchor = null;
let findRefreshTimer = 0;
let findReplacing = false;

function findIsOpen() {
  return findActive;
}

/// The search's own fields, whose keys belong to them and not to the document.
function findOwns(node) {
  return findField.contains(node) || replaceRow.contains(node);
}

function findShowReplace() {
  // The source view is read only, so there is nothing to replace in it.
  if (sourceActive) return;
  replaceRow.hidden = false;
  findPlaceReplace();
  document.getElementById('toolbar-replace')?.classList.add('on');
}

function findHideReplace() {
  replaceRow.hidden = true;
  document.getElementById('toolbar-replace')?.classList.remove('on');
}

/// Hangs from the field, at its width, like the macOS panel.
function findPlaceReplace() {
  if (replaceRow.hidden) return;
  const box = findField.getBoundingClientRect();
  replaceRow.style.left = `${Math.max(8, Math.min(box.left, innerWidth - replaceRow.offsetWidth - 8))}px`;
  replaceRow.style.top = `${box.bottom + 4}px`;
  replaceInput.style.width = `${Math.max(140, box.width - 16)}px`;
}

/// The toolbar button: opens the panel, or closes it and goes back to the query.
function findToggleReplace() {
  if (!replaceRow.hidden) {
    findHideReplace();
    findInput.focus();
    return;
  }
  findOpen(true);
}

function findTargets() {
  if (sourceActive) return [sourceText];
  const targets = [];
  for (const block of root.children) {
    if (block.tagName === 'TABLE') targets.push(...block.querySelectorAll('th, td'));
    else if (block.tagName !== 'HR') targets.push(block);
  }
  return targets;
}

function findPattern(query) {
  return new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu');
}

/// Every occurrence as a live range, in document order.
function findCollect(query) {
  const matches = [];
  if (!query) return matches;
  const pattern = findPattern(query);
  for (const element of findTargets()) {
    const map = proofTextMap(element);
    for (const match of map.text.matchAll(pattern)) {
      const range = proofRange(map, match.index, match.index + match[0].length);
      if (range) matches.push({ element, range, start: match.index, end: match.index + match[0].length });
    }
  }
  return matches;
}

function findPaint() {
  CSS.highlights.delete('find');
  CSS.highlights.delete('find-current');
  const all = new Highlight();
  findMatches.forEach(match => all.add(match.range));
  if (findMatches.length > 0) CSS.highlights.set('find', all);
  const current = findMatches[findCurrent];
  if (current) CSS.highlights.set('find-current', new Highlight(current.range));
  findCount.textContent = findInput.value ? `${findCurrent + 1}/${findMatches.length}` : '';
  findField.classList.toggle('has-text', findInput.value !== '');
  const hasMatches = findMatches.length > 0;
  document.getElementById('replace-one').disabled = !hasMatches;
  document.getElementById('replace-all').disabled = !hasMatches;
}

function findReveal() {
  const range = findMatches[findCurrent]?.range;
  if (range) revealRange(range);
}

/// Starts from the caret when a search begins, so the first match is near where the author is.
function findSearch() {
  const anchor = findMatches[findCurrent]?.range ?? findAnchor;
  findMatches = findCollect(findInput.value);
  findCurrent = -1;
  if (findMatches.length > 0) {
    const next = anchor ? findMatches.findIndex(match => match.range.compareBoundaryPoints(Range.START_TO_START, anchor) >= 0) : 0;
    findCurrent = next < 0 ? 0 : next;
  }
  findPaint();
  findReveal();
}

function findMove(forward) {
  if (findMatches.length === 0) return;
  findCurrent = (findCurrent + (forward ? 1 : -1) + findMatches.length) % findMatches.length;
  findPaint();
  findReveal();
}

/// Follows edits without moving the view.
function findRefresh() {
  if (!findActive || !findInput.value) return;
  const position = findCurrent;
  findMatches = findCollect(findInput.value);
  findCurrent = findMatches.length === 0 ? -1 : Math.min(Math.max(position, 0), findMatches.length - 1);
  findPaint();
}

function findOpen(withReplace) {
  findActive = true;
  if (withReplace) findShowReplace();
  else findHideReplace();
  const selection = getSelection();
  const inDocument = selection?.rangeCount && (sourceActive ? sourceText : root).contains(selection.anchorNode);
  if (inDocument) findAnchor = selection.getRangeAt(0).cloneRange();
  const selected = inDocument && !selection.isCollapsed ? selection.toString() : '';
  if (selected && !selected.includes('\n')) findInput.value = selected;
  // With a query already there, replacing starts where the replacement is typed.
  if (withReplace && !replaceRow.hidden && findInput.value) {
    replaceInput.focus();
    replaceInput.select();
  } else {
    findInput.focus();
    findInput.select();
  }
  findSearch();
}

/// Ending a search selects the current match, so it can be fixed at once.
function findClose() {
  const current = findMatches[findCurrent];
  findActive = false;
  findHideReplace();
  findInput.value = '';
  findCount.textContent = '';
  findField.classList.remove('has-text');
  findMatches = [];
  findCurrent = -1;
  findAnchor = null;
  clearTimeout(findRefreshTimer);
  CSS.highlights.delete('find');
  CSS.highlights.delete('find-current');
  (sourceActive ? sourceText : root).focus();
  if (current) {
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(current.range);
  }
}

function findReplaceMatch(match, text) {
  if (document.activeElement !== root) root.focus();
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(match.range);
  return text ? exec('insertText', text) : exec('delete');
}

/// Replaces the current match and moves past the new text, even if it contains the query.
function findReplaceCurrent() {
  const match = findMatches[findCurrent];
  if (!match || sourceActive) return;
  const { element, start } = match;
  const text = replaceInput.value;
  findReplaceMatch(match, text);
  findMatches = findCollect(findInput.value);
  const after = start + text.length;
  const elements = findTargets();
  const position = elements.indexOf(element);
  const next = findMatches.findIndex(item => {
    const other = elements.indexOf(item.element);
    return other > position || (other === position && item.start >= after);
  });
  findCurrent = findMatches.length === 0 ? -1 : (next < 0 ? 0 : next);
  findPaint();
  findReveal();
  replaceInput.focus();
}

function findReplaceAll() {
  if (sourceActive) return 0;
  const matches = findCollect(findInput.value);
  const text = replaceInput.value;
  // Proofreading and change tracking only need to hear about this once, at the end.
  findReplacing = true;
  try {
    // From the end, so earlier ranges stay where they are.
    for (const match of matches.reverse()) findReplaceMatch(match, text);
  } finally {
    findReplacing = false;
  }
  if (matches.length > 0) root.dispatchEvent(new InputEvent('input', { bubbles: true }));
  findMatches = findCollect(findInput.value);
  findCurrent = findMatches.length > 0 ? 0 : -1;
  findPaint();
  replaceInput.focus();
  return matches.length;
}

/// An open search follows when the source view takes over or gives back the screen.
function findModeChanged() {
  if (!findActive) return;
  if (sourceActive) findHideReplace();
  findAnchor = null;
  findMatches = [];
  findCurrent = -1;
  findSearch();
}

/// From a search result: the file's nth occurrence, or the first if editing has moved things.
function findJump(query, ordinal) {
  const matches = findCollect(query);
  const match = matches[ordinal] ?? matches[0];
  if (!match) return;
  root.focus();
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(match.range);
  revealRange(match.range);
}

findInput.addEventListener('input', () => {
  findActive = true;
  findSearch();
});
findInput.addEventListener('focus', () => {
  if (findActive) return;
  // Clicking into the field starts a search from where the author was.
  const selection = getSelection();
  if (selection?.rangeCount && (sourceActive ? sourceText : root).contains(selection.anchorNode)) findAnchor = selection.getRangeAt(0).cloneRange();
});
findInput.addEventListener('keydown', event => {
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Enter') {
    event.preventDefault();
    findMove(!event.shiftKey);
  } else if (event.key === 'Escape') {
    event.preventDefault();
    findClose();
  }
});
replaceInput.addEventListener('keydown', event => {
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Enter') {
    event.preventDefault();
    findReplaceCurrent();
  } else if (event.key === 'Escape') {
    // As on macOS, this closes only the panel and goes back to the query.
    event.preventDefault();
    findHideReplace();
    findInput.focus();
  }
});
document.getElementById('find-close').addEventListener('mousedown', event => event.preventDefault());
document.getElementById('find-close').addEventListener('click', findClose);
window.addEventListener('resize', findPlaceReplace);
document.getElementById('replace-one').addEventListener('click', findReplaceCurrent);
document.getElementById('replace-all').addEventListener('click', findReplaceAll);
root.addEventListener('input', event => {
  if (findReplacing) event.stopImmediatePropagation();
}, true);
root.addEventListener('input', () => {
  clearTimeout(findRefreshTimer);
  findRefreshTimer = setTimeout(findRefresh, 150);
});

window.chrome.webview.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  switch (message.type) {
    case 'load':
      findRefresh();
      break;
    case 'jump':
      findJump(message.query, message.ordinal);
      break;
    case 'find':
      if (message.action === 'open') findOpen(false);
      else if (message.action === 'replace') findOpen(true);
      else if (!findActive) findOpen(false);
      else findMove(message.action === 'next');
      break;
    case 'strings':
      findInput.placeholder = message.strings['toolbar.find'] ?? '';
      findInput.title = `${message.strings['toolbar.find'] ?? ''} (Ctrl+F)`;
      document.getElementById('find-close').title = message.strings['ai.work.cancel'] ?? '';
      replaceInput.placeholder = message.strings['find.replacePlaceholder'] ?? '';
      document.getElementById('replace-one').textContent = message.strings['find.replace'] ?? '';
      document.getElementById('replace-all').textContent = message.strings['find.replaceAll'] ?? '';
      break;
  }
});
