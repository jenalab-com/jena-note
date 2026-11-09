'use strict';

// Reading layout: column width, paper sizes, scroll and paged views, the ruler, the reading
// position and bookmarks. All of it is presentation. Nothing here changes what readBlocks() sees,
// so a font, weight or page setting can never end up in the saved document.
//
// One screen point on macOS is one CSS pixel here, so the same settings give the same line breaks.
// The numbers below are the ones in ReaderMetrics.swift and PageRulerView.swift.

const POINTS_PER_CM = 72 / 2.54;
const MARGIN_SNAP_CM = 0.25;
const MIN_TEXT_WIDTH = 120;
const SPREAD_GUTTER = 56;
const SPREAD_SIDE_MARGIN = 24;
const SPREAD_HYSTERESIS = 40;
const MOBILE_WIDTH = 360;
const PAGE_V_MARGIN = 40;
const SCROLL_SIDE_INSET = 60;
const RULER_HEIGHT = 18;
const RULER_HIT_SLOP = 12;
// The ruler floats over the top of the scroll view. Positions are read and restored below it.
const SCROLL_READ_OFFSET = 34;
const SNIPPET_LENGTH = 32;
const SEARCH_RADIUS = 2048;
const MAX_BOOKMARKS = 100;

const scroller = document.getElementById('scroller');
const pageClip = document.getElementById('page-clip');
const rulerLayer = document.getElementById('ruler-layer');
const pageIndicator = document.getElementById('page-indicator');
const appearancePopover = document.getElementById('appearance-popover');
const bookmarkPopover = document.getElementById('bookmark-popover');

let reading = {
  mode: 'scroll', fontScale: 1.3, bodySize: 15, font: 'serif', weight: 'regular', lineSpacing: 1.5,
  letterSpacing: 0, lineLength: 35, pageWidth: 0, marginLeft: 0, marginRight: 0, paper: 'automatic',
};
let readingFonts = [];
let paperSizes = [];
let widthMode = 'book';
let isSpread = false;
let currentPage = 0;
let pageCount = 1;
let pageZoom = 1;
let pageStep = 1;
let rulers = [];
let rulerDrag = null;
let shiftHeld = false;
let aiActive = false;

let readingPath = null;
let anchorOffset = 0;
let restorePending = false;
let positionTimer = 0;
let bookmarks = [];
let trackedText = null;
let idleTimer = 0;
let lastHostSize = '';

// MARK: - Measures

function snappedMargin(points) {
  const grid = MARGIN_SNAP_CM * POINTS_PER_CM;
  return Math.max(0, Math.round(points / grid) * grid);
}

/// The left margin wins when both no longer fit, so the text never disappears.
function clampedMargins(left, right, pageWidth) {
  const room = Math.max(0, pageWidth - MIN_TEXT_WIDTH);
  const clampedLeft = Math.min(Math.max(0, left), room);
  return { left: clampedLeft, right: Math.min(Math.max(0, right), room - clampedLeft) };
}

function textWidth(pageWidth, left, right) {
  const margins = clampedMargins(left, right, pageWidth);
  return Math.max(Math.min(pageWidth, MIN_TEXT_WIDTH), pageWidth - margins.left - margins.right);
}

/// Already showing two pages, the window may narrow a little before it falls back to one.
function fitsSpread(hostWidth, columnWidth, currentlySpread) {
  if (columnWidth <= 0) return false;
  const enter = 2 * columnWidth + SPREAD_GUTTER + 2 * SPREAD_SIDE_MARGIN;
  return hostWidth >= (currentlySpread ? enter - SPREAD_HYSTERESIS : enter);
}

const spreadStart = page => (page > 0 ? page - (page % 2) : 0);

function maxPageWidth(hostWidth, spread) {
  const single = hostWidth - 2 * SPREAD_SIDE_MARGIN;
  const paired = (hostWidth - SPREAD_GUTTER - 2 * SPREAD_SIDE_MARGIN) / 2;
  return Math.max(MIN_TEXT_WIDTH, spread ? paired : single);
}

const paperWidth = () => paperSizes.find(size => size.id === reading.paper)?.width ?? 0;
const displaySize = () => reading.bodySize * reading.fontScale;
// The AI panel works on a scrolling document, and the page view returns when it closes.
const isPaged = () => reading.mode === 'paged' && !plainMode && !aiActive;
const WEIGHTS = { light: 300, regular: 400, bold: 700 };

function currentFontCss() {
  return (readingFonts.find(font => font.id === reading.font) ?? readingFonts[0])?.css ?? 'serif';
}

let measureContext = null;
function glyphAdvance() {
  measureContext ??= document.createElement('canvas').getContext('2d');
  const size = displaySize();
  measureContext.font = `${WEIGHTS[reading.weight] ?? 400} ${size}px ${currentFontCss()}`;
  return measureContext.measureText('한').width + size * reading.letterSpacing / 100;
}

function columnWidth() {
  if (widthMode === 'mobile') return MOBILE_WIDTH;
  const paper = paperWidth();
  if (paper > 0) return paper;
  if (reading.pageWidth > 0) return reading.pageWidth;
  return reading.lineLength * glyphAdvance();
}

// MARK: - Layout

function applyReadingStyle() {
  const style = document.documentElement.style;
  style.setProperty('--body-size', `${displaySize()}px`);
  style.setProperty('--letter-spacing', `${reading.letterSpacing / 100}em`);
  style.setProperty('--line-spacing', reading.lineSpacing);
  style.setProperty('--reader-weight', WEIGHTS[reading.weight] ?? 400);
  style.setProperty('--reader-font', currentFontCss());
}

function clearLayoutStyles() {
  for (const property of ['width', 'height', 'margin-left', 'margin-right', 'padding-left', 'padding-right', 'column-width', 'column-gap', 'zoom']) {
    root.style.removeProperty(property);
  }
  for (const property of ['left', 'top', 'width', 'height']) pageClip.style.removeProperty(property);
}

/// Everything that decides where text sits goes through here. The reading place comes from the
/// anchor, so whoever changes what the screen shows reads the anchor first, while it still can.
function layoutReading() {
  const hostWidth = scroller.clientWidth;
  const hostHeight = scroller.clientHeight;
  if (hostWidth <= 0 || hostHeight <= 0) return;
  document.body.classList.toggle('paged', isPaged());
  clearLayoutStyles();
  if (plainMode) {
    setRulerCount(0);
    updateIndicator();
    return;
  }
  const page = columnWidth();
  const margins = clampedMargins(reading.marginLeft, reading.marginRight, page);
  const column = textWidth(page, margins.left, margins.right);
  if (isPaged()) layoutPaged(hostWidth, hostHeight, page);
  else layoutScroll(hostWidth, page, margins, column);
  applyAnchor();
  updateIndicator();
}

function layoutScroll(hostWidth, page, margins, column) {
  pageZoom = 1;
  const fixed = widthMode === 'book' && paperWidth() > 0;
  let side;
  let rulerX;
  let rulerWidth = page;
  if (fixed) {
    // A sheet wider than the window scrolls sideways, and its line breaks stay as they are.
    const pageX = Math.max(SCROLL_SIDE_INSET, (hostWidth - page) / 2);
    side = pageX + margins.left;
    root.style.width = `${column}px`;
    root.style.marginRight = `${margins.right + SCROLL_SIDE_INSET}px`;
    rulerX = pageX;
  } else {
    side = Math.max(SCROLL_SIDE_INSET, (hostWidth - column) / 2);
    const shown = Math.max(MIN_TEXT_WIDTH, hostWidth - 2 * side);
    root.style.width = `${shown}px`;
    rulerX = side - margins.left;
    // When the window is narrower than the page, the ruler matches the text, so its handles stay in reach.
    rulerWidth = Math.min(page, shown + margins.left + margins.right);
  }
  root.style.marginLeft = `${side}px`;
  setRulerCount(1);
  placeRuler(rulers[0], rulerX - scroller.scrollLeft, 8, rulerWidth, margins, {
    canGrow: widthMode === 'book' && !fixed,
    maxWidth: Math.max(MIN_TEXT_WIDTH, hostWidth - 2 * SCROLL_SIDE_INSET),
    paperOrigin: fixed,
    baseX: rulerX,
  });
}

function layoutPaged(hostWidth, hostHeight, exactPage) {
  // Pages are reached by scrolling, and scrolling lands on whole pixels.
  const page = Math.round(exactPage);
  const margins = clampedMargins(reading.marginLeft, reading.marginRight, page);
  const column = textWidth(page, margins.left, margins.right);
  // Only the width comes from the paper. Printing goes through export, so the height fits the window.
  const paper = widthMode === 'book' ? paperWidth() : 0;
  pageZoom = paper > 0 ? Math.min(1, hostWidth / (paper + 48)) : 1;
  const logicalWidth = hostWidth / pageZoom;
  const logicalHeight = hostHeight / pageZoom;
  isSpread = fitsSpread(logicalWidth, page, isSpread);
  const pageHeight = Math.max(40, logicalHeight - 2 * PAGE_V_MARGIN);
  const gap = SPREAD_GUTTER + margins.left + margins.right;
  const count = isSpread ? 2 : 1;
  const total = count * page + (count - 1) * SPREAD_GUTTER;
  const startX = Math.max(0, (logicalWidth - total) / 2);

  pageClip.style.left = `${startX * pageZoom}px`;
  pageClip.style.top = `${PAGE_V_MARGIN * pageZoom}px`;
  pageClip.style.width = `${total * pageZoom}px`;
  pageClip.style.height = `${pageHeight * pageZoom}px`;

  root.style.zoom = pageZoom;
  root.style.width = `${count * column + (count - 1) * gap}px`;
  root.style.height = `${pageHeight}px`;
  root.style.paddingLeft = `${margins.left}px`;
  root.style.paddingRight = `${margins.right}px`;
  root.style.columnWidth = `${column}px`;
  root.style.columnGap = `${gap}px`;
  document.documentElement.style.setProperty('--page-height', `${pageHeight}px`);
  pageStep = (page + SPREAD_GUTTER) * pageZoom;

  setRulerCount(count);
  rulers.forEach((ruler, index) => placeRuler(ruler, (startX + index * (page + SPREAD_GUTTER)) * pageZoom, 12 * pageZoom, page, margins, {
    canGrow: widthMode === 'book' && paper === 0,
    maxWidth: maxPageWidth(logicalWidth, count === 2),
    paperOrigin: paper > 0,
  }));
  updatePageCount();
}

/// The caret can only be scrolled to a page that exists as scrollable space. This keeps the last
/// spread in place when it has only a left page.
function updatePageCount() {
  if (!isPaged()) return;
  const last = root.lastElementChild;
  const rects = last?.getClientRects();
  const rect = rects?.[rects.length - 1];
  const left = pageClip.getBoundingClientRect().left;
  pageCount = rect ? Math.max(1, Math.floor((rect.left - left + pageClip.scrollLeft + 1) / pageStep) + 1) : 1;
  document.documentElement.style.setProperty('--page-end', `${(pageCount + 2) * pageStep}px`);
  updateIndicator();
}

function updateIndicator() {
  const paged = isPaged();
  pageIndicator.hidden = !paged;
  if (!paged) return;
  const first = currentPage + 1;
  const last = Math.min(currentPage + (isSpread ? 2 : 1), pageCount);
  document.getElementById('page-number').textContent = `${last > first ? `${first}–${last}` : first} / ${pageCount}`;
}

function showPage(page) {
  const limit = Math.max(0, pageCount - 1);
  let next = Math.min(Math.max(0, page), limit);
  if (isSpread) next = spreadStart(next);
  currentPage = next;
  pageClip.scrollLeft = next * pageStep;
  updateIndicator();
  schedulePositionCapture();
}

function turnPage(forward) {
  showPage(currentPage + (forward ? 1 : -1) * (isSpread ? 2 : 1));
  if (document.activeElement === root) placeCaretAtPageStart();
}

function placeCaretAtPageStart() {
  const box = pageClip.getBoundingClientRect();
  const left = box.left + clampedMargins(reading.marginLeft, reading.marginRight, columnWidth()).left * pageZoom + 2;
  const caret = document.caretRangeFromPoint(left, box.top + 2);
  if (!caret || !root.contains(caret.startContainer)) return;
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(caret);
}

function pageOfRect(rect) {
  const left = pageClip.getBoundingClientRect().left;
  return Math.max(0, Math.floor((rect.left - left + pageClip.scrollLeft + 1) / pageStep));
}

function firstRect(range) {
  // A position where a line wraps belongs to the character after it. On its own it reports the end
  // of the line before, which can be on the page before.
  const start = range.startContainer;
  if (range.collapsed && start.nodeType === Node.TEXT_NODE && range.startOffset < start.length) {
    const next = document.createRange();
    next.setStart(start, range.startOffset);
    next.setEnd(start, range.startOffset + 1);
    const nextRects = next.getClientRects();
    if (nextRects.length > 0) return nextRects[nextRects.length - 1];
  }
  const rects = range.getClientRects();
  if (rects.length > 0) return rects[0];
  // An empty line has no text rectangle, only its block.
  let node = range.startContainer;
  if (node.nodeType !== Node.ELEMENT_NODE) node = node.parentElement;
  return node?.getClientRects()[0] ?? null;
}

function caretRect() {
  const selection = getSelection();
  if (!selection?.rangeCount || !root.contains(selection.focusNode)) return null;
  const range = document.createRange();
  range.setStart(selection.focusNode, selection.focusOffset);
  range.collapse(true);
  return firstRect(range);
}

/// Native caret following scrolls just far enough to show the caret. Pages move whole.
function syncPageToCaret() {
  if (!isPaged()) return;
  const rect = caretRect();
  const page = rect ? pageOfRect(rect) : currentPage;
  const target = isSpread ? spreadStart(page) : page;
  if (target !== currentPage || Math.abs(pageClip.scrollLeft - target * pageStep) > 1) {
    if (target >= pageCount) updatePageCount();
    showPage(target);
  }
}

/// Used by find: brings a range into view without touching the selection.
function revealRange(range) {
  const rect = firstRect(range);
  if (!rect) return;
  if (sourceActive) {
    const view = sourceText.getBoundingClientRect();
    if (rect.top < view.top || rect.bottom > view.bottom) sourceText.scrollTop += rect.top - view.top - view.height / 3;
    return;
  }
  if (isPaged()) {
    showPage(pageOfRect(rect));
    return;
  }
  const box = scroller.getBoundingClientRect();
  if (rect.top < box.top + SCROLL_READ_OFFSET || rect.bottom > box.bottom) {
    scroller.scrollTop += rect.top - box.top - box.height / 3;
  }
}

/// The blocks that can be on screen, for proofreading to check.
function blocksInView() {
  const blocks = root.children;
  const box = (isPaged() ? pageClip : scroller).getBoundingClientRect();
  const before = block => {
    const rects = block.getClientRects();
    const rect = rects[rects.length - 1];
    if (!rect) return false;
    return isPaged() ? rect.right <= box.left : rect.bottom <= box.top;
  };
  const after = block => {
    const rect = block.getClientRects()[0];
    if (!rect) return false;
    return isPaged() ? rect.left >= box.right : rect.top >= box.bottom;
  };
  let low = 0;
  let high = blocks.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (before(blocks[middle])) low = middle + 1;
    else high = middle;
  }
  const visible = [];
  for (let index = low; index < blocks.length && !after(blocks[index]); index++) visible.push(blocks[index]);
  return visible;
}

// MARK: - Reading position

function displayText() {
  const parts = [];
  for (const block of root.children) parts.push(block.textContent);
  return parts.join('\n');
}

function offsetOfPosition(node, offset) {
  let block = node;
  while (block && block.parentNode !== root) block = block.parentNode;
  if (!block) return 0;
  let start = 0;
  for (let item = root.firstElementChild; item && item !== block; item = item.nextElementSibling) {
    start += item.textContent.length + 1;
  }
  const range = document.createRange();
  range.setStart(block, 0);
  range.setEnd(node, offset);
  return start + range.toString().length;
}

/// The position at a character offset. Offsets count like the macOS document string: one line
/// break between blocks, and UTF-16 units.
function positionAtOffset(offset) {
  let start = 0;
  let block = root.firstElementChild;
  while (block?.nextElementSibling && start + block.textContent.length < offset) {
    start += block.textContent.length + 1;
    block = block.nextElementSibling;
  }
  if (!block) return { node: root, offset: 0 };
  let remaining = Math.max(0, offset - start);
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
  let last = null;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (remaining <= node.length) return { node, offset: remaining };
    remaining -= node.length;
    last = node;
  }
  return last ? { node: last, offset: last.length } : { node: block, offset: 0 };
}

function rangeAtOffset(offset) {
  const position = positionAtOffset(offset);
  const range = document.createRange();
  range.setStart(position.node, position.offset);
  range.collapse(true);
  return range;
}

function pointOffset(x, y) {
  const caret = document.caretRangeFromPoint(x, y);
  if (!caret || !root.contains(caret.startContainer)) return null;
  return offsetOfPosition(caret.startContainer, caret.startOffset);
}

function visibleOffset() {
  const blocks = blocksInView();
  if (isPaged()) {
    const box = pageClip.getBoundingClientRect();
    const margins = clampedMargins(reading.marginLeft, reading.marginRight, columnWidth());
    const start = pointOffset(box.left + margins.left * pageZoom + 2, box.top + 2);
    if (start !== null) return start;
    return blocks[0] ? offsetOfPosition(blocks[0], 0) : 0;
  }
  if (scroller.scrollTop <= 0) return 0;
  const box = scroller.getBoundingClientRect();
  const lineTop = box.top + SCROLL_READ_OFFSET;
  const block = blocks.find(item => {
    const rects = item.getClientRects();
    return rects[rects.length - 1]?.bottom > lineTop;
  });
  if (!block) return 0;
  const rect = block.getClientRects()[0];
  const found = pointOffset(rect.left + 2, Math.max(rect.top + 2, lineTop + 2));
  return found ?? offsetOfPosition(block, 0);
}

/// The characters on screen, which decide whether a bookmark toggle adds or removes.
function visibleRange() {
  const start = visibleOffset();
  let end;
  if (isPaged()) {
    const box = pageClip.getBoundingClientRect();
    end = pointOffset(box.right - 2, box.bottom - 2);
  } else {
    const box = scroller.getBoundingClientRect();
    const blocks = blocksInView();
    const last = blocks[blocks.length - 1];
    const rect = last?.getClientRects()[0];
    end = rect ? pointOffset(rect.right - 2, box.bottom - 2) : null;
  }
  return { start, end: Math.max(start, end ?? start) };
}

function captureAnchorNow() {
  if (restorePending || !root.firstElementChild) return;
  anchorOffset = visibleOffset();
}

function applyAnchor() {
  if (scroller.clientHeight <= 0) {
    restorePending = true;
    return;
  }
  restorePending = false;
  const range = rangeAtOffset(anchorOffset);
  const rect = firstRect(range);
  if (isPaged()) {
    updatePageCount();
    const focused = document.activeElement === root ? caretRect() : null;
    const target = focused ?? rect;
    showPageSilently(target ? pageOfRect(target) : 0);
    return;
  }
  pageClip.scrollLeft = 0;
  if (anchorOffset <= 0) {
    scroller.scrollTop = 0;
    return;
  }
  if (rect) scroller.scrollTop += rect.top - scroller.getBoundingClientRect().top - SCROLL_READ_OFFSET;
}

function showPageSilently(page) {
  const limit = Math.max(0, pageCount - 1);
  let next = Math.min(Math.max(0, page), limit);
  if (isSpread) next = spreadStart(next);
  currentPage = next;
  pageClip.scrollLeft = next * pageStep;
  updateIndicator();
}

function makeAnchor(offset, text) {
  const clamped = Math.min(Math.max(0, offset), text.length);
  return { characterOffset: clamped, contextSnippet: text.slice(clamped, clamped + SNIPPET_LENGTH), contentLength: text.length, updatedAt: Date.now() / 1000 };
}

function nearestOccurrence(needle, text, target, lower, upper) {
  if (!needle || upper <= lower) return null;
  let backward = null;
  const backStart = Math.min(Math.min(target, text.length - needle.length), upper - needle.length);
  if (backStart >= lower) {
    const found = text.lastIndexOf(needle, backStart);
    if (found >= lower) backward = found;
  }
  let forward = null;
  const forwardStart = Math.max(lower, Math.min(target, upper));
  const found = text.indexOf(needle, forwardStart);
  if (found >= 0 && found + needle.length <= upper) forward = found;
  if (backward === null) return forward;
  if (forward === null) return backward;
  return target - backward <= forward - target ? backward : forward;
}

/// Same three steps as ReadingAnchor.resolve: in place, nearby, then the whole document.
function resolveAnchor(anchor, text) {
  if (text.length === 0) return 0;
  const { characterOffset: offset, contextSnippet: snippet } = anchor;
  if (!snippet) return Math.min(offset, text.length);
  if (offset >= 0 && text.startsWith(snippet, offset)) return offset;
  const near = nearestOccurrence(snippet, text, offset, Math.max(0, offset - SEARCH_RADIUS),
    Math.min(text.length, offset + SEARCH_RADIUS + snippet.length));
  if (near !== null) return near;
  const far = nearestOccurrence(snippet, text, offset, 0, text.length);
  if (far !== null) return far;
  return Math.min(Math.max(0, offset), text.length);
}

function offsetAfterEdit(offset, location, removed, inserted) {
  if (offset < location) return offset;
  if (offset >= location + removed) return offset + inserted - removed;
  return location + Math.min(offset - location, inserted);
}

function previewText(offset, text, maxLength = 60) {
  const start = Math.min(Math.max(0, offset), text.length);
  const flattened = text.slice(start, start + maxLength * 2).trim().split(/\s+/).join(' ');
  return flattened.length <= maxLength ? flattened : `${flattened.slice(0, maxLength)}…`;
}

function schedulePositionCapture() {
  clearTimeout(positionTimer);
  positionTimer = setTimeout(flushPosition, 500);
  updateBookmarkButton();
}

function flushPosition() {
  clearTimeout(positionTimer);
  positionTimer = 0;
  if (!readingPath || restorePending) return;
  const offset = visibleOffset();
  anchorOffset = offset;
  // The start of a document needs no entry, as on macOS.
  post({ type: 'progress', path: readingPath, anchor: offset > 0 ? makeAnchor(offset, displayText()) : null });
}

// MARK: - Bookmarks

function saveBookmarks() {
  if (readingPath) post({ type: 'bookmarks', path: readingPath, list: bookmarks });
  updateBookmarkButton();
}

function bookmarkHere() {
  if (!readingPath) return false;
  const range = visibleRange();
  const inside = item => item.characterOffset >= range.start && item.characterOffset <= range.end;
  if (bookmarks.some(inside)) {
    bookmarks = bookmarks.filter(item => !inside(item));
  } else {
    const anchor = makeAnchor(range.start, displayText());
    if (bookmarks.some(item => item.characterOffset === anchor.characterOffset)) return false;
    bookmarks.push(anchor);
    bookmarks.sort((a, b) => a.characterOffset - b.characterOffset);
    if (bookmarks.length > MAX_BOOKMARKS) {
      // The oldest go first. What stays keeps document order.
      bookmarks = [...bookmarks].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, MAX_BOOKMARKS)
        .sort((a, b) => a.characterOffset - b.characterOffset);
    }
  }
  saveBookmarks();
  return true;
}

function updateBookmarkButton() {
  const button = document.getElementById('toolbar-bookmark');
  if (!button) return;
  const range = readingPath && bookmarks.length > 0 ? visibleRange() : null;
  button.classList.toggle('on', range !== null && bookmarks.some(item => item.characterOffset >= range.start && item.characterOffset <= range.end));
}

function goToOffset(offset) {
  anchorOffset = offset;
  restorePending = false;
  const position = positionAtOffset(offset);
  // Under the source view keys must never reach the editor.
  if (!sourceActive) root.focus();
  const selection = getSelection();
  selection.removeAllRanges();
  const range = document.createRange();
  range.setStart(position.node, position.offset);
  range.collapse(true);
  selection.addRange(range);
  applyAnchor();
  schedulePositionCapture();
}

function closePopovers() {
  appearancePopover.hidden = true;
  bookmarkPopover.hidden = true;
}

function placePopover(popover, anchor) {
  popover.hidden = false;
  const box = anchor?.getBoundingClientRect();
  const left = Math.max(8, Math.min((box?.left ?? 80), innerWidth - popover.offsetWidth - 8));
  popover.style.left = `${left}px`;
  popover.style.top = `${box ? box.bottom + 4 : 8}px`;
}

function showBookmarkList() {
  closePopovers();
  bookmarkPopover.replaceChildren();
  const text = displayText();
  if (bookmarks.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'popover-empty';
    empty.textContent = strings['reader.bookmark.empty'] ?? '';
    bookmarkPopover.append(empty);
  }
  for (const item of bookmarks) {
    const row = document.createElement('div');
    row.className = 'bookmark-row';
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'bookmark-open';
    open.textContent = previewText(item.characterOffset, text) || (strings['reader.bookmark.untitled'] ?? '');
    open.addEventListener('click', () => {
      closePopovers();
      goToOffset(item.characterOffset);
    });
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'bookmark-remove';
    remove.textContent = '×';
    remove.addEventListener('click', () => {
      bookmarks = bookmarks.filter(other => other !== item);
      saveBookmarks();
      showBookmarkList();
    });
    row.append(open, remove);
    bookmarkPopover.append(row);
  }
  placePopover(bookmarkPopover, document.getElementById('toolbar-bookmark-list'));
}

// MARK: - After edits

/// Finds what changed by comparing the text before and after, which gives the exact range macOS
/// gets from its text storage. Bookmarks then move with the text around them.
function adjustBookmarksForEdit() {
  const next = displayText();
  const previous = trackedText;
  trackedText = next;
  if (previous === null || previous === next) return;
  let start = 0;
  const shorter = Math.min(previous.length, next.length);
  while (start < shorter && previous.charCodeAt(start) === next.charCodeAt(start)) start++;
  let end = 0;
  while (end < shorter - start && previous.charCodeAt(previous.length - 1 - end) === next.charCodeAt(next.length - 1 - end)) end++;
  const removed = previous.length - start - end;
  const inserted = next.length - start - end;
  anchorOffset = offsetAfterEdit(anchorOffset, start, removed, inserted);
  if (bookmarks.length === 0) return;
  bookmarks = bookmarks.map(item => makeAnchor(offsetAfterEdit(item.characterOffset, start, removed, inserted), next))
    .sort((a, b) => a.characterOffset - b.characterOffset);
  saveBookmarks();
}

function textCounts(text) {
  let noSpaces = 0;
  let withSpaces = 0;
  const count = character => {
    if (character === '\n' || character === '\r' || character === '\r\n' || character === '￼') return;
    withSpaces++;
    if (!/^\s+$/u.test(character)) noSpaces++;
  };
  // Grapheme segmentation is slow on a long manuscript, and these characters each stand alone.
  if (/^[\u0000-˿　-〩〰-゘゛-힣＀-￯]*$/.test(text)) {
    for (let index = 0; index < text.length; index++) count(text[index]);
  } else {
    for (const part of new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)) count(part.segment);
  }
  return { noSpaces, withSpaces };
}

function reportCounts(text) {
  post({ type: 'counts', ...textCounts(text) });
}

function afterEditIdle() {
  idleTimer = 0;
  adjustBookmarksForEdit();
  reportCounts(trackedText ?? displayText());
  updateBookmarkButton();
}

// MARK: - Document load

function readingBeforeLoad() {
  if (positionTimer) flushPosition();
  sourceReturnRange = null;
  clearTimeout(idleTimer);
  idleTimer = 0;
  readingPath = null;
  bookmarks = [];
  anchorOffset = 0;
  restorePending = false;
  trackedText = null;
  currentPage = 0;
  closePopovers();
}

function readingAfterLoad() {
  pageClip.scrollLeft = 0;
  layoutReading();
  trackedText = displayText();
  reportCounts(trackedText);
}

function applyReadingState(message) {
  readingPath = message.path ?? null;
  const text = trackedText ?? displayText();
  bookmarks = (message.bookmarks ?? []).map(item => makeAnchor(resolveAnchor(item, text), text))
    .sort((a, b) => a.characterOffset - b.characterOffset);
  if (message.progress) {
    anchorOffset = resolveAnchor(message.progress, text);
    goToOffset(anchorOffset);
  }
  updateBookmarkButton();
  aiDocumentChanged();
}

// MARK: - Ruler

function setRulerCount(count) {
  while (rulers.length > count) rulers.pop().canvas.remove();
  while (rulers.length < count) {
    const canvas = document.createElement('canvas');
    const ruler = { canvas, x: 0, width: 0, left: 0, right: 0, options: {} };
    canvas.addEventListener('pointerdown', event => rulerPointerDown(ruler, event));
    canvas.addEventListener('pointermove', event => rulerPointerMove(ruler, event));
    canvas.addEventListener('pointerup', event => rulerPointerUp(ruler, event));
    canvas.addEventListener('pointercancel', event => rulerPointerUp(ruler, event));
    rulerLayer.append(canvas);
    rulers.push(ruler);
  }
}

function placeRuler(ruler, x, y, width, margins, options) {
  ruler.x = x;
  ruler.y = y;
  ruler.width = width;
  ruler.left = margins.left;
  ruler.right = margins.right;
  ruler.options = options;
  drawRuler(ruler);
}

function drawRuler(ruler) {
  const { canvas } = ruler;
  const zoom = pageZoom;
  const scale = devicePixelRatio;
  canvas.width = Math.ceil(ruler.width * zoom * scale);
  canvas.height = Math.ceil(RULER_HEIGHT * zoom * scale);
  canvas.style.width = `${ruler.width * zoom}px`;
  canvas.style.height = `${RULER_HEIGHT * zoom}px`;
  canvas.style.left = `${ruler.x}px`;
  canvas.style.top = `${ruler.y}px`;
  const context = canvas.getContext('2d');
  context.setTransform(scale * zoom, 0, 0, scale * zoom, 0, 0);
  const css = getComputedStyle(document.documentElement);
  const color = name => css.getPropertyValue(name).trim();
  const width = ruler.width;
  const textStart = ruler.left;
  const textEnd = width - ruler.right;

  context.clearRect(0, 0, width, RULER_HEIGHT);
  context.fillStyle = color('--bar');
  context.fillRect(0, 0, width, RULER_HEIGHT);
  context.fillStyle = color('--paper') || color('--surface');
  context.fillRect(textStart, 0, Math.max(0, textEnd - textStart), RULER_HEIGHT);
  context.strokeStyle = color('--line');
  context.strokeRect(0.5, 0.5, width - 1, RULER_HEIGHT - 1);

  // Zero sits where the text starts, unless a paper size makes the sheet's edge the natural start.
  const origin = ruler.options.paperOrigin ? 0 : textStart;
  const quarter = POINTS_PER_CM / 4;
  const middle = RULER_HEIGHT / 2;
  context.fillStyle = color('--muted');
  context.font = '8px "Segoe UI", sans-serif';
  context.textAlign = 'center';
  context.textBaseline = 'middle';
  const last = Math.ceil((width - origin) / quarter);
  for (let index = Math.floor(-origin / quarter); index <= last; index++) {
    const x = origin + index * quarter;
    if (x < 0 || x > width) continue;
    if (index % 4 === 0) {
      const number = Math.abs(index / 4);
      if (number === 0) context.fillRect(x - 0.5, middle - 4, 1, 8);
      else context.fillText(String(number), x, middle);
    } else if (index % 2 === 0) {
      context.fillRect(x - 0.5, middle - 3, 1, 6);
    } else {
      context.fillRect(x - 0.5, middle - 1.5, 1, 3);
    }
  }
  drawRulerHandle(context, ruler, textStart, 'left', color);
  drawRulerHandle(context, ruler, textEnd, 'right', color);
}

function drawRulerHandle(context, ruler, x, side, color) {
  const active = rulerDrag?.ruler === ruler && rulerDrag.handle === side;
  context.fillStyle = active ? color('--link') : color('--text');
  context.beginPath();
  context.moveTo(x - 6, 0);
  context.lineTo(x + 6, 0);
  context.lineTo(x, 8);
  context.closePath();
  context.fill();
  if (!active) return;
  const value = side === 'left' ? ruler.left : ruler.right;
  const label = `${(value / POINTS_PER_CM).toFixed(2)} cm · ${(ruler.width / POINTS_PER_CM).toFixed(1)} cm`;
  context.font = '500 9px "Segoe UI", sans-serif';
  context.textAlign = 'left';
  context.textBaseline = 'alphabetic';
  const size = context.measureText(label).width;
  const start = side === 'left' ? x + 8 : x - 8 - size;
  context.fillStyle = color('--link');
  context.fillText(label, Math.min(Math.max(0, start), ruler.width - size), RULER_HEIGHT - 2);
}

function rulerHandleAt(ruler, x) {
  const toLeft = Math.abs(x - ruler.left);
  const toRight = Math.abs(x - (ruler.width - ruler.right));
  if (Math.min(toLeft, toRight) > RULER_HIT_SLOP) return null;
  return toLeft <= toRight ? 'left' : 'right';
}

function beginRulerDrag(ruler, handle, clientX) {
  rulerDrag = { ruler, handle, clientX, left: ruler.left, right: ruler.right, x: ruler.x, width: ruler.width, moved: false };
  drawRuler(ruler);
}

/// One margin at a time, on a grid, and never so far that the text has no room. Dragging past the
/// page edge widens the page instead, when the page is not a fixed size.
function applyRulerDrag(dx) {
  const drag = rulerDrag;
  const { ruler, handle } = drag;
  const { canGrow, maxWidth } = ruler.options;
  let left = drag.left;
  let right = drag.right;
  let growth = 0;
  const maxGrowth = canGrow ? Math.max(0, maxWidth - drag.width) : 0;
  const raw = handle === 'left' ? drag.left + dx : drag.right - dx;
  const opposite = handle === 'left' ? drag.right : drag.left;
  if (raw >= 0) {
    const value = Math.min(snappedMargin(raw), Math.max(0, drag.width - MIN_TEXT_WIDTH - opposite));
    if (handle === 'left') left = value;
    else right = value;
  } else {
    if (handle === 'left') left = 0;
    else right = 0;
    growth = Math.min(snappedMargin(-raw), maxGrowth);
  }
  ruler.left = left;
  ruler.right = right;
  ruler.width = drag.width + growth;
  ruler.x = handle === 'left' ? drag.x - growth * pageZoom : drag.x;
  drag.moved = true;
  // Two pages are one book, so the other ruler shows the same margins while this one moves.
  for (const other of rulers) {
    if (other !== ruler) {
      other.left = left;
      other.right = right;
      drawRuler(other);
    }
  }
  drawRuler(ruler);
}

function endRulerDrag() {
  const drag = rulerDrag;
  rulerDrag = null;
  if (!drag) return;
  const { ruler } = drag;
  drawRuler(ruler);
  const changed = Math.abs(ruler.left - drag.left) > 0.01 || Math.abs(ruler.right - drag.right) > 0.01 || Math.abs(ruler.width - drag.width) > 0.01;
  if (!changed) return;
  const values = { marginLeft: ruler.left, marginRight: ruler.right };
  // Only the automatic book width can be set this way. Mobile and paper sizes are fixed.
  if (widthMode === 'book' && paperWidth() === 0 && Math.abs(ruler.width - drag.width) > 0.5) values.pageWidth = ruler.width;
  changeReading(values);
}

function rulerPointerDown(ruler, event) {
  // Keeps the caret and selection in the document.
  event.preventDefault();
  if (event.detail === 2) {
    resetPageLayout();
    return;
  }
  const handle = rulerHandleAt(ruler, event.offsetX / pageZoom);
  if (!handle) return;
  ruler.canvas.setPointerCapture(event.pointerId);
  beginRulerDrag(ruler, handle, event.clientX);
}

function rulerPointerMove(ruler, event) {
  if (rulerDrag?.ruler === ruler) {
    applyRulerDrag((event.clientX - rulerDrag.clientX) / pageZoom);
    return;
  }
  ruler.canvas.style.cursor = rulerHandleAt(ruler, event.offsetX / pageZoom) ? 'ew-resize' : 'default';
}

function rulerPointerUp(ruler) {
  if (rulerDrag?.ruler === ruler) endRulerDrag();
}

function resetPageLayout() {
  const values = { marginLeft: 0, marginRight: 0 };
  if (paperWidth() === 0) values.pageWidth = 0;
  changeReading(values);
}

// MARK: - Settings

/// Applies at once in this page, and the host saves it and tells other windows.
function changeReading(values) {
  captureAnchorNow();
  Object.assign(reading, values);
  applyReadingStyle();
  layoutReading();
  post({ type: 'readingChange', values });
  fillAppearance();
  updateReadingToolbar();
}

function applyHostSettings(message) {
  captureAnchorNow();
  reading = { ...reading, ...message.reading };
  readingFonts = message.fonts ?? readingFonts;
  paperSizes = message.paperSizes ?? paperSizes;
  reading.bodySize = message.bodySize;
  reading.letterSpacing = message.letterSpacing;
  if (message.paper) document.documentElement.style.setProperty('--paper', message.paper);
  else document.documentElement.style.removeProperty('--paper');
  applyReadingStyle();
  layoutReading();
  fillAppearance();
  updateReadingToolbar();
}

/// Reader bold is only how the text looks. The bold command judges by computed weight, so with
/// it on, the command would see every word as already bold and take bold away.
function withPlainWeight(action) {
  if (reading.weight !== 'bold') return action();
  root.style.fontWeight = '400';
  try {
    return action();
  } finally {
    root.style.removeProperty('font-weight');
  }
}

const stepped = (value, step, low, high) => Math.min(high, Math.max(low, Math.round((value + step) * 10) / 10));

function runReadingCommand(name) {
  // The source view shows the saved form, which has no layout and no place to bookmark.
  if (sourceActive) return;
  switch (name) {
    case 'scroll': changeReading({ mode: 'scroll' }); break;
    case 'paged':
      if (!aiActive) changeReading({ mode: 'paged' });
      break;
    case 'fontUp': changeReading({ fontScale: stepped(reading.fontScale, 0.1, 0.8, 2) }); break;
    case 'fontDown': changeReading({ fontScale: stepped(reading.fontScale, -0.1, 0.8, 2) }); break;
    case 'appearance': showAppearance(); break;
    case 'bookmarkToggle': bookmarkHere(); break;
    case 'bookmarkList': showBookmarkList(); break;
  }
}

// MARK: - Toolbar

function toolbarButton(label, onClick, id) {
  const button = document.createElement('button');
  button.type = 'button';
  button.tabIndex = -1;
  button.textContent = label;
  if (id) button.id = id;
  button.addEventListener('mousedown', event => event.preventDefault());
  button.addEventListener('click', onClick);
  return button;
}

function appendReadingToolbar(toolbar) {
  const separator = () => {
    const element = document.createElement('span');
    element.className = 'separator';
    return element;
  };
  toolbar.append(separator());
  toolbar.append(toolbarButton(strings['reader.scroll'] ?? '', () => runReadingCommand('scroll'), 'toolbar-scroll'));
  toolbar.append(toolbarButton(strings['reader.paged'] ?? '', () => runReadingCommand('paged'), 'toolbar-paged'));
  toolbar.append(toolbarButton(strings['toolbar.appearance'] ?? '', () => runReadingCommand('appearance'), 'toolbar-appearance'));
  const source = toolbarButton(strings['source.title'] ?? '', () => post({ type: 'command', name: 'toggleSource' }), 'toolbar-source');
  source.title = strings['source.hint'] ?? '';
  toolbar.append(source);
  toolbar.append(separator());
  toolbar.append(toolbarButton('−', () => changeReading({ bodySize: Math.max(8, reading.bodySize - 1) }), 'toolbar-size-down'));
  const size = document.createElement('span');
  size.id = 'toolbar-size';
  size.title = strings['reader.fontSize'] ?? '';
  toolbar.append(size);
  toolbar.append(toolbarButton('+', () => changeReading({ bodySize: Math.min(30, reading.bodySize + 1) }), 'toolbar-size-up'));
  toolbar.append(separator());
  toolbar.append(toolbarButton(strings['reader.bookmark.toggle'] ?? '', () => runReadingCommand('bookmarkToggle'), 'toolbar-bookmark'));
  toolbar.append(toolbarButton(strings['reader.bookmark.list'] ?? '', () => runReadingCommand('bookmarkList'), 'toolbar-bookmark-list'));
  toolbar.append(separator());
  const ai = toolbarButton('AI', aiToggle, 'toolbar-ai');
  ai.title = strings['ai.title'] ?? '';
  toolbar.append(ai);
  updateReadingToolbar();
}

function updateReadingToolbar() {
  document.getElementById('toolbar-scroll')?.classList.toggle('on', !isPaged());
  document.getElementById('toolbar-paged')?.classList.toggle('on', isPaged());
  document.getElementById('toolbar-ai')?.classList.toggle('on', aiActive);
  const size = document.getElementById('toolbar-size');
  if (size) size.textContent = `${reading.bodySize}pt`;
  updateBookmarkButton();
}

// MARK: - Appearance panel

function appearanceRow(label, control) {
  const row = document.createElement('div');
  row.className = 'appearance-row';
  const name = document.createElement('span');
  name.textContent = label;
  row.append(name, control);
  return row;
}

function appearanceSelect(options, selected, onChange) {
  const select = document.createElement('select');
  for (const option of options) {
    const element = document.createElement('option');
    element.value = option.id;
    element.textContent = option.label;
    select.append(element);
  }
  select.value = selected;
  select.addEventListener('change', () => onChange(select.value));
  return select;
}

function appearanceSegments(options, selected, onChange) {
  const group = document.createElement('div');
  group.className = 'segments';
  for (const option of options) {
    const button = toolbarButton(option.label, () => onChange(option.id));
    button.classList.toggle('on', option.id === selected);
    group.append(button);
  }
  return group;
}

function appearanceStepper(text, down, up) {
  const group = document.createElement('div');
  group.className = 'stepper';
  const value = document.createElement('span');
  value.textContent = text;
  group.append(toolbarButton('−', down), value, toolbarButton('+', up));
  return group;
}

function fillAppearance() {
  if (appearancePopover.hidden) return;
  const fontAvailable = readingFonts.some(font => font.id === reading.font);
  const lineSpacingChoice = reading.lineSpacing <= 1.35 ? 1.2 : reading.lineSpacing >= 1.75 ? 2 : 1.5;
  appearancePopover.replaceChildren(
    appearanceRow(strings['paperSize.title'] ?? '', appearanceSelect(paperSizes, reading.paper, id => {
      // A paper size is a book width, so it leaves the mobile preset.
      widthMode = 'book';
      changeReading({ paper: id });
    })),
    appearanceRow(strings['reader.width'] ?? '', appearanceSegments(
      [{ id: 'mobile', label: strings['reader.widthMobile'] ?? '' }, { id: 'book', label: strings['reader.widthBook'] ?? '' }],
      widthMode, id => {
        captureAnchorNow();
        widthMode = id;
        layoutReading();
        fillAppearance();
      })),
    appearanceRow(strings['reader.font'] ?? '', appearanceSelect(readingFonts, fontAvailable ? reading.font : readingFonts[0]?.id, id => changeReading({ font: id }))),
    appearanceRow(strings['reader.weight'] ?? '', appearanceSegments(
      ['light', 'regular', 'bold'].map(id => ({ id, label: strings[`reader.weight.${id}`] ?? '' })),
      reading.weight, id => changeReading({ weight: id }))),
    appearanceRow(strings['reader.lineSpacing'] ?? '', appearanceSegments(
      [{ id: 1.2, label: strings['reader.lineTight'] ?? '' }, { id: 1.5, label: strings['reader.lineNormal'] ?? '' }, { id: 2, label: strings['reader.lineWide'] ?? '' }],
      lineSpacingChoice, id => changeReading({ lineSpacing: id }))),
    appearanceRow(strings['reader.letterSpacing'] ?? '', appearanceStepper(`${reading.letterSpacing}%`,
      () => changeReading({ letterSpacing: Math.max(-10, reading.letterSpacing - 1) }),
      () => changeReading({ letterSpacing: Math.min(20, reading.letterSpacing + 1) }))),
    appearanceRow(strings['toolbar.zoom'] ?? '', appearanceStepper(`${Math.round(reading.fontScale * 100)}%`,
      () => runReadingCommand('fontDown'), () => runReadingCommand('fontUp'))),
  );
}

function showAppearance() {
  const wasOpen = !appearancePopover.hidden;
  closePopovers();
  if (wasOpen) return;
  appearancePopover.hidden = false;
  fillAppearance();
  placePopover(appearancePopover, document.getElementById('toolbar-appearance'));
}

// MARK: - Events

document.addEventListener('selectionchange', () => {
  if (document.activeElement !== root) return;
  const selection = getSelection();
  // Select All must not throw the reader to the last page. Extending with the keyboard follows.
  if (selection && !selection.isCollapsed && !shiftHeld) return;
  syncPageToCaret();
});

document.addEventListener('keydown', event => {
  shiftHeld = event.shiftKey;
  if (event.key === 'Escape') closePopovers();
  if (event.target !== root || !isPaged() || event.isComposing || event.keyCode === 229) return;
  if (event.key === 'PageDown' || event.key === 'PageUp') {
    event.preventDefault();
    turnPage(event.key === 'PageDown');
  }
});
document.addEventListener('keyup', event => {
  shiftHeld = event.shiftKey;
});

document.addEventListener('mousedown', event => {
  const inside = appearancePopover.contains(event.target) || bookmarkPopover.contains(event.target);
  const toggles = ['toolbar-appearance', 'toolbar-bookmark-list'].includes(event.target.id);
  if (!inside && !toggles) closePopovers();
});

root.addEventListener('input', () => {
  if (isPaged()) {
    updatePageCount();
    syncPageToCaret();
  }
  clearTimeout(idleTimer);
  idleTimer = setTimeout(afterEditIdle, 400);
});

pageClip.addEventListener('scroll', () => {
  if (!isPaged() || rulerDrag) return;
  // Native caret following moved the view. Put it on a whole page again.
  if (Math.abs(pageClip.scrollLeft - currentPage * pageStep) > 1) {
    if (document.activeElement === root) syncPageToCaret();
    else pageClip.scrollLeft = currentPage * pageStep;
  }
});

scroller.addEventListener('scroll', () => {
  if (isPaged()) return;
  // Sideways, on a sheet wider than the window, the ruler goes along with the page.
  const ruler = rulers[0];
  if (ruler && ruler.options.baseX !== undefined && !rulerDrag) {
    ruler.x = ruler.options.baseX - scroller.scrollLeft;
    ruler.canvas.style.left = `${ruler.x}px`;
  }
  schedulePositionCapture();
});

let wheelTotal = 0;
let wheelCooldown = 0;
scroller.addEventListener('wheel', event => {
  if (!isPaged()) return;
  event.preventDefault();
  const now = performance.now();
  if (now < wheelCooldown) return;
  wheelTotal += event.deltaY;
  if (Math.abs(wheelTotal) < 40) return;
  const forward = wheelTotal > 0;
  wheelTotal = 0;
  wheelCooldown = now + 180;
  showPage(currentPage + (forward ? 1 : -1) * (isSpread ? 2 : 1));
}, { passive: false });

document.getElementById('page-previous').addEventListener('click', () => turnPage(false));
document.getElementById('page-next').addEventListener('click', () => turnPage(true));
for (const button of [document.getElementById('page-previous'), document.getElementById('page-next')]) {
  button.addEventListener('mousedown', event => event.preventDefault());
}

new ResizeObserver(() => {
  const size = `${scroller.clientWidth}x${scroller.clientHeight}`;
  if (size === lastHostSize) return;
  lastHostSize = size;
  layoutReading();
}).observe(scroller);

// A bundled font arrives after the first layout, and glyph widths decide the column.
document.fonts.addEventListener('loadingdone', layoutReading);

window.chrome.webview.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  switch (message.type) {
    case 'settings':
      applyHostSettings(message);
      break;
    case 'readingState':
      applyReadingState(message);
      break;
    case 'readingPath': {
      const previous = readingPath;
      readingPath = message.path ?? null;
      aiPathChanged(previous);
      break;
    }
    case 'readingCommand':
      runReadingCommand(message.name);
      break;
  }
});
