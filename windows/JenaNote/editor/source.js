'use strict';

// The document as it would be saved, unsaved changes included. It is read only and covers the
// editor instead of replacing it, so the document, its undo history and the reading place stay
// exactly where they were.

const sourceView = document.getElementById('source-view');
const sourceText = document.getElementById('source-text');
let sourceActive = false;
let sourceReturnRange = null;

function updateSourceToolbar() {
  for (const button of document.querySelectorAll('#toolbar button')) {
    // As on macOS, finding still works in the source. Nothing that changes the document does.
    button.disabled = (sourceActive && !['toolbar-source', 'toolbar-ai', 'toolbar-more', 'find-close'].includes(button.id)) || (aiActive && button.id === 'toolbar-paged');
  }
  document.getElementById('toolbar-source')?.classList.toggle('on', sourceActive);
}

function fillSourceStrings() {
  document.getElementById('source-description').textContent = strings['source.description'] ?? '';
  document.getElementById('source-copy').textContent = strings['source.copyAll'] ?? '';
}

function showSource(text) {
  if (!sourceActive) {
    const selection = getSelection();
    sourceReturnRange = selection?.rangeCount && root.contains(selection.anchorNode) ? selection.getRangeAt(0).cloneRange() : null;
    sourceActive = true;
    punctuationReset();
    sourceView.hidden = false;
    proofDismiss();
    closePopovers();
    updateSourceToolbar();
  }
  if (sourceText.textContent !== text) {
    const top = sourceText.scrollTop;
    sourceText.textContent = text;
    sourceText.scrollTop = top;
  }
  sourceText.focus();
  findModeChanged();
}

function hideSource() {
  if (!sourceActive) return;
  sourceActive = false;
  sourceView.hidden = true;
  updateSourceToolbar();
  root.focus();
  if (sourceReturnRange) {
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(sourceReturnRange);
    sourceReturnRange = null;
  }
  findModeChanged();
}

function selectAllSource() {
  const selection = getSelection();
  selection.removeAllRanges();
  const range = document.createRange();
  range.selectNodeContents(sourceText);
  selection.addRange(range);
}

/// Menu commands that would change the document do nothing here.
function runSourceNative(name) {
  sourceText.focus();
  if (name === 'selectAll') selectAllSource();
  else if (name === 'copy') exec('copy');
}

sourceText.addEventListener('keydown', event => {
  // The browser's Select All would take in the hidden editor as well.
  if (event.ctrlKey && !event.altKey && event.key.toLowerCase() === 'a') {
    event.preventDefault();
    selectAllSource();
  }
});
document.getElementById('source-copy').addEventListener('click', () => post({ type: 'command', name: 'copySource' }));
