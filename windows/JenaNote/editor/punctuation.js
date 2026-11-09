'use strict';

// Dialogue, quotation and thought marks, as on macOS. Turning a mark on inserts only its opening
// mark and turning it off only its closing mark, so nothing runs ahead of the writer. Marks go in
// through the same editing commands as typing, so formatting, layout and undo behave the same.

const PUNCTUATION_KINDS = ['dialogue', 'quotation', 'thought'];
const PUNCTUATION_DEFAULTS = {
  dialogue: { opening: '"', closing: '"', leadingSpaces: 0, trigger: ';;;' },
  quotation: { opening: "'", closing: "'", leadingSpaces: 0, trigger: "'''" },
  thought: { opening: "'", closing: "'", leadingSpaces: 0, trigger: '///' },
};
/// One character cannot be told apart from ordinary typing.
const PUNCTUATION_MINIMUM_TRIGGER = 2;
const DOUBLE_SHIFT_HOLD = 300;
const DOUBLE_SHIFT_GAP = 350;

let punctuationSettings = { styles: PUNCTUATION_DEFAULTS, triggers: false, closesOnReturn: false, shiftTarget: null };
/// In the order they were turned on. A quotation can sit inside dialogue, and closing all of them
/// at once closes the inner one first.
let punctuationActive = [];
let punctuationInserting = false;
let punctuationComposing = false;
/// Where the author was in the document, for a toggle that comes while focus is elsewhere.
let punctuationRange = null;
const punctuationShift = { pressedAt: null, releasedAt: null };

function punctuationStyle(kind) {
  return punctuationSettings.styles?.[kind] ?? PUNCTUATION_DEFAULTS[kind];
}

function punctuationOpeningText(style) {
  return ' '.repeat(style.leadingSpaces ?? 0) + style.opening;
}

function punctuationSetActive(next) {
  const changed = next.length !== punctuationActive.length || next.some((kind, index) => kind !== punctuationActive[index]);
  punctuationActive = next;
  if (!changed) return;
  punctuationUpdateToolbar();
  post({ type: 'punctuationState', active: punctuationActive });
}

/// A new document or the source view leaves nothing to continue, so this turns off without closing.
function punctuationReset() {
  punctuationShiftInterrupt();
  punctuationSetActive([]);
}

// MARK: - Toggle

/// `origin` is "key" for a shortcut typed in the page, "toolbar" for a button, and "menu" for the
/// window's menu or a shortcut it caught. `force` says the window had the focus, not the page.
function punctuationToggle(kind, origin, force = false) {
  if (sourceActive || !PUNCTUATION_KINDS.includes(kind)) return;
  const focused = document.activeElement;
  if (focused !== root) {
    // A menu shortcut belongs to where the author is typing. It never takes the question box or
    // the find field's input into the document.
    if (origin === 'menu' && !force && focused && (focused.tagName === 'INPUT' || focused.tagName === 'TEXTAREA')) return;
    root.focus();
    if (punctuationRange && root.contains(punctuationRange.startContainer)) punctuationSelect(punctuationRange);
  }
  punctuationCommitComposition();
  const selection = getSelection();
  if (!selection.rangeCount || !root.contains(selection.anchorNode)) placeCaret(root.firstElementChild, 0);
  const range = getSelection().getRangeAt(0);
  if (range.collapsed) punctuationFlip(kind, null);
  else punctuationWrap(range.cloneRange(), punctuationStyle(kind));
}

function punctuationFlip(kind, replacing) {
  const style = punctuationStyle(kind);
  if (punctuationActive.includes(kind)) {
    punctuationInsert(style.closing, replacing);
    punctuationSetActive(punctuationActive.filter(item => item !== kind));
  } else {
    punctuationInsert(punctuationOpeningText(style), replacing);
    punctuationSetActive([...punctuationActive, kind]);
  }
}

/// Puts marks around the selection without turning anything on, and leaves the caret after them.
/// Within a line this is one undo step, as on macOS.
function punctuationWrap(range, style) {
  const opening = punctuationOpeningText(style);
  if (range.startContainer === range.endContainer && range.startContainer.nodeType === Node.TEXT_NODE) {
    punctuationInsert(opening + range.toString() + style.closing, range);
    return;
  }
  const startCell = range.startContainer.parentElement?.closest('td, th') ?? null;
  const endCell = range.endContainer.parentElement?.closest('td, th') ?? null;
  if (punctuationBlockOf(range.startContainer) === punctuationBlockOf(range.endContainer) && startCell === endCell) {
    // Formatting inside stays, because the selected nodes go back in as they were.
    const holder = document.createElement('div');
    holder.append(document.createTextNode(opening), range.cloneContents(), document.createTextNode(style.closing));
    punctuationInserting = true;
    try {
      punctuationSelect(range);
      exec('insertHTML', holder.innerHTML);
      punctuationSelect(getSelection().getRangeAt(0));
    } finally {
      punctuationInserting = false;
    }
    return;
  }
  const startBlock = punctuationBlockOf(range.startContainer);
  const endBlock = punctuationBlockOf(range.endContainer);
  const endOffset = punctuationTextOffset(endBlock, range.endContainer, range.endOffset);
  const end = range.cloneRange();
  end.collapse(false);
  const start = range.cloneRange();
  start.collapse(true);
  // The closing mark goes in first, so the start of the selection stays where it was.
  punctuationInsert(style.closing, end);
  punctuationInsert(opening, start);
  const point = punctuationPointAt(endBlock, endOffset + style.closing.length + (startBlock === endBlock ? opening.length : 0));
  if (point) placeCaret(point.node, point.offset);
}

function punctuationBlockOf(node) {
  while (node && node.parentNode !== root) node = node.parentNode;
  return node;
}

function punctuationTextOffset(block, node, offset) {
  const range = document.createRange();
  range.setStart(block, 0);
  range.setEnd(node, offset);
  return range.toString().length;
}

function punctuationPointAt(block, offset) {
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
  let position = 0;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (offset <= position + node.length) return { node, offset: offset - position };
    position += node.length;
  }
  return null;
}

/// Replaces `range`, or the caret when it is null, as its own undo step.
function punctuationInsert(text, range) {
  if (!text && (!range || range.collapsed)) return;
  punctuationInserting = true;
  try {
    // Setting the selection ends the typing step, so undo takes the mark back on its own.
    punctuationSelect(range ?? getSelection().getRangeAt(0));
    exec(text ? 'insertText' : 'delete', text || undefined);
    punctuationSelect(getSelection().getRangeAt(0));
  } finally {
    punctuationInserting = false;
  }
}

function punctuationSelect(range) {
  const selection = getSelection();
  const copy = range.cloneRange();
  selection.removeAllRanges();
  selection.addRange(copy);
}

/// A mark must follow a syllable being composed, not split it. Leaving the editor finishes it.
function punctuationCommitComposition() {
  if (!punctuationComposing) return;
  root.blur();
  root.focus();
  punctuationComposing = false;
  const selection = getSelection();
  if (!selection.rangeCount || !root.contains(selection.anchorNode)) {
    if (punctuationRange) punctuationSelect(punctuationRange);
  }
}

function punctuationIsCode(node) {
  if (plainMode) return false;
  for (let current = node; current && current !== root; current = current.parentNode) {
    if (current.nodeName === 'CODE' || current.nodeName === 'PRE') return true;
  }
  return false;
}

// MARK: - Typed sequences

/// When the last character of a sequence is typed, the sequence becomes the mark. True if it did.
function punctuationHandleTyped(data) {
  if (punctuationInserting || !punctuationSettings.triggers || sourceActive) return false;
  // Keys arrive one character at a time. Anything longer is pasted.
  if (typeof data !== 'string' || [...data].length !== 1) return false;
  const selection = getSelection();
  if (!selection.isCollapsed || !selection.rangeCount || !root.contains(selection.anchorNode)) return false;
  if (punctuationIsCode(selection.anchorNode)) return false;
  const caret = selection.getRangeAt(0);
  const block = currentBlock();
  if (!block) return false;
  const before = document.createRange();
  before.setStart(caret.startContainer.parentElement?.closest('td, th') ?? block, 0);
  before.setEnd(caret.startContainer, caret.startOffset);
  const typedBefore = before.toString();
  for (const kind of PUNCTUATION_KINDS) {
    const trigger = punctuationStyle(kind).trigger ?? '';
    if ([...trigger].length < PUNCTUATION_MINIMUM_TRIGGER || !trigger.endsWith(data)) continue;
    const head = trigger.slice(0, trigger.length - data.length);
    if (!typedBefore.endsWith(head)) continue;
    const replacing = punctuationRangeBefore(caret, head.length);
    if (!replacing || replacing.toString() !== head) continue;
    punctuationFlip(kind, replacing);
    return true;
  }
  return false;
}

/// The `count` characters just before a caret, across text nodes inside the same line.
function punctuationRangeBefore(caret, count) {
  const block = currentBlock();
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
  const nodes = [];
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const position = caret.comparePoint(node, 0);
    if (position > 0) break;
    nodes.push(node);
  }
  const range = document.createRange();
  range.setEnd(caret.startContainer, caret.startOffset);
  let remaining = count;
  for (let index = nodes.length - 1; index >= 0; index -= 1) {
    const node = nodes[index];
    const end = node === caret.startContainer ? caret.startOffset : caret.comparePoint(node, node.length) <= 0 ? node.length : 0;
    if (end >= remaining) {
      range.setStart(node, end - remaining);
      return range;
    }
    remaining -= end;
  }
  return null;
}

// MARK: - Return

/// Only for authors who turned it on: Return closes every open mark, the inner one first.
function punctuationBeforeNewLine() {
  if (!punctuationSettings.closesOnReturn || punctuationActive.length === 0) return;
  punctuationCommitComposition();
  for (const kind of [...punctuationActive].reverse()) punctuationFlip(kind, null);
}

// MARK: - Double Shift

/// Returns true at the second of two short Shift presses. Any other key in between starts over.
function punctuationShiftChanged(down, time) {
  if (down) {
    if (punctuationShift.releasedAt != null && time - punctuationShift.releasedAt <= DOUBLE_SHIFT_GAP) {
      punctuationShiftInterrupt();
      return true;
    }
    punctuationShift.releasedAt = null;
    punctuationShift.pressedAt = time;
  } else {
    const pressed = punctuationShift.pressedAt;
    punctuationShift.releasedAt = pressed != null && time - pressed <= DOUBLE_SHIFT_HOLD ? time : null;
    punctuationShift.pressedAt = null;
  }
  return false;
}

function punctuationShiftInterrupt() {
  punctuationShift.pressedAt = null;
  punctuationShift.releasedAt = null;
}

/// While a syllable is composed the key reads "Process", so the physical key decides.
function punctuationIsShift(event) {
  return event.code === 'ShiftLeft' || event.code === 'ShiftRight' || event.key === 'Shift';
}

// MARK: - Toolbar

function punctuationUpdateToolbar() {
  for (const kind of PUNCTUATION_KINDS) {
    const button = document.getElementById(`toolbar-punctuation-${kind}`);
    if (!button) continue;
    const on = punctuationActive.includes(kind);
    button.classList.toggle('on', on);
    button.setAttribute('aria-pressed', String(on));
  }
}

// MARK: - Events

root.addEventListener('compositionstart', () => {
  punctuationComposing = true;
  punctuationShiftInterrupt();
});
root.addEventListener('compositionend', () => { punctuationComposing = false; });

root.addEventListener('beforeinput', event => {
  if (event.inputType !== 'insertText' || event.isComposing) return;
  if (punctuationHandleTyped(event.data)) event.preventDefault();
});

root.addEventListener('keydown', event => {
  if (punctuationIsShift(event)) {
    if (event.repeat) return;
    if (event.ctrlKey || event.altKey || event.metaKey) punctuationShiftInterrupt();
    else if (punctuationSettings.shiftTarget && punctuationShiftChanged(true, event.timeStamp)) punctuationToggle(punctuationSettings.shiftTarget, 'key');
  } else {
    punctuationShiftInterrupt();
  }
});
root.addEventListener('keyup', event => {
  if (punctuationIsShift(event)) punctuationShiftChanged(false, event.timeStamp);
});
root.addEventListener('mousedown', punctuationShiftInterrupt);

function punctuationRemember() {
  const selection = getSelection();
  if (selection.rangeCount && root.contains(selection.anchorNode)) punctuationRange = selection.getRangeAt(0).cloneRange();
}

document.addEventListener('selectionchange', () => {
  if (document.activeElement === root) punctuationRemember();
});
// Selection changes are reported later, so the place is also taken as focus leaves.
root.addEventListener('blur', punctuationRemember);

window.chrome.webview.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  switch (message.type) {
    case 'punctuationSettings':
      punctuationSettings = message;
      break;
    case 'punctuation':
      punctuationToggle(message.kind, 'menu', message.force === true);
      break;
  }
});
