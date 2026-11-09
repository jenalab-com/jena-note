'use strict';

// The editor's one-row toolbar, laid out like the macOS app's: view controls, then formatting with
// the paragraph style, lists and inserts in menus, then the marks, and reading tools at the right.
// Every icon button has a tooltip with its name and shortcut.

const toolbarMenu = document.createElement('div');
toolbarMenu.id = 'toolbar-menu';
toolbarMenu.className = 'popover';
toolbarMenu.setAttribute('role', 'menu');
toolbarMenu.hidden = true;
document.body.append(toolbarMenu);
let toolbarMenuOwner = null;
let toolbarColor = null;

function tip(key, shortcut) {
  const name = strings[key] ?? key;
  return shortcut ? `${name} (${shortcut})` : name;
}

/// An icon button. With `label`, the text shows beside the icon.
function iconButton(id, iconName, title, onClick, label) {
  const button = toolbarButton('', onClick, id);
  button.classList.add('tool');
  button.title = title;
  button.setAttribute('aria-label', title);
  if (iconName) button.append(icon(iconName));
  if (label) {
    const text = document.createElement('span');
    text.textContent = label;
    button.append(text);
    button.classList.add('labeled');
  }
  return button;
}

function toolGroup(...children) {
  const group = document.createElement('div');
  group.className = 'tool-group';
  group.append(...children);
  return group;
}

function segmented(...buttons) {
  const group = document.createElement('div');
  group.className = 'segmented';
  group.setAttribute('role', 'group');
  group.append(...buttons);
  return group;
}

function toolSeparator() {
  const line = document.createElement('span');
  line.className = 'separator';
  return line;
}

/// A button that opens a short menu of commands under it.
function menuButton(id, iconName, title, entries, label) {
  const button = iconButton(id, iconName, title, () => toggleToolbarMenu(button, entries), label);
  button.menuEntries = entries;
  button.classList.add('menu-button');
  button.setAttribute('aria-haspopup', 'menu');
  button.append(icon('chevron-down'));
  return button;
}

function toggleToolbarMenu(owner, entries) {
  if (!toolbarMenu.hidden && toolbarMenuOwner === owner) {
    closeToolbarMenu();
    return;
  }
  closePopovers();
  toolbarMenu.replaceChildren();
  for (const entry of entries) {
    const item = document.createElement('button');
    item.type = 'button';
    item.tabIndex = -1;
    item.setAttribute('role', 'menuitem');
    if (entry.separator) {
      const line = document.createElement('div');
      line.className = 'menu-separator';
      toolbarMenu.append(line);
      continue;
    }
    if (entry.icon) item.append(icon(entry.icon));
    else if (entry.iconNode) item.append(entry.iconNode);
    const text = document.createElement('span');
    text.textContent = strings[entry.label] ?? entry.label;
    item.append(text);
    if (entry.shortcut) {
      const key = document.createElement('kbd');
      key.textContent = entry.shortcut;
      item.append(key);
    }
    if (entry.current?.()) item.classList.add('on');
    item.addEventListener('mousedown', event => event.preventDefault());
    item.addEventListener('click', () => {
      closeToolbarMenu();
      entry.run();
    });
    toolbarMenu.append(item);
  }
  toolbarMenuOwner = owner;
  owner.classList.add('open');
  placePopover(toolbarMenu, owner);
}

function closeToolbarMenu() {
  toolbarMenu.hidden = true;
  toolbarMenuOwner?.classList.remove('open');
  toolbarMenuOwner = null;
}

const HEADING_ENTRIES = [
  { label: 'menu.format.body', tag: 'P', command: 'body' },
  { label: 'menu.format.h1', tag: 'H1', command: 'h1' },
  { label: 'menu.format.h2', tag: 'H2', command: 'h2' },
  { label: 'menu.format.h3', tag: 'H3', command: 'h3' },
];

function buildToolbarItems(toolbar) {
  const runner = name => () => run(name);
  const headingButton = menuButton('toolbar-heading', null, strings['menu.format.body'] ?? '',
    HEADING_ENTRIES.map(entry => ({
      label: entry.label,
      current: () => currentBlock()?.tagName === entry.tag,
      // Choosing the style a line already has would turn a heading back into body text.
      run: () => { if (currentBlock()?.tagName !== entry.tag) run(entry.command); },
    })), strings['menu.format.body'] ?? '');
  headingButton.classList.add('heading-button');

  const colorButton = iconButton('toolbar-color', 'baseline', tip('toolbar.textColor'), runner('color'));
  const swatch = document.createElement('span');
  swatch.className = 'color-bar';
  colorButton.append(swatch);

  const punctuation = PUNCTUATION_KINDS.map((kind, index) => {
    const button = toolbarButton(strings[`punctuation.short.${kind}`] ?? kind, () => punctuationToggle(kind, 'toolbar'), `toolbar-punctuation-${kind}`);
    button.title = `${strings[`menu.format.punctuation.${kind}`] ?? kind} (Ctrl+${index + 1})`;
    return button;
  });

  const spacer = document.createElement('span');
  spacer.className = 'spacer';
  const size = document.createElement('span');
  size.id = 'toolbar-size';
  size.title = strings['reader.fontSize'] ?? '';

  const sourceButton = iconButton('toolbar-source', 'file-code', strings['source.hint'] || tip('source.title'), () => post({ type: 'command', name: 'toggleSource' }));

  const sizeButton = (id, text, key, shortcut, change) => {
    const button = toolbarButton(text, () => changeReading({ bodySize: Math.min(30, Math.max(8, reading.bodySize + change)) }), id);
    button.classList.add('tool', 'step');
    button.title = tip(key, shortcut);
    button.setAttribute('aria-label', button.title);
    return button;
  };

  if (!findField.querySelector('.icon')) findField.prepend(icon('search'));
  const replaceToggle = iconButton('toolbar-replace', 'replace', tip('find.replace', 'Ctrl+H'), findToggleReplace);
  replaceToggle.classList.toggle('on', !replaceRow.hidden);

  // The same order as the macOS toolbar (ReaderToolbar.toolbarDefaultItemIdentifiers).
  toolbar.replaceChildren(
    toolGroup(findField, replaceToggle),
    toolGroup(
      segmented(
        iconButton('toolbar-scroll', 'scroll-text', tip('reader.scroll'), () => runReadingCommand('scroll')),
        iconButton('toolbar-paged', 'book-open', tip('reader.paged'), () => runReadingCommand('paged'))),
      iconButton('toolbar-appearance', 'sliders-horizontal', tip('toolbar.appearance'), () => runReadingCommand('appearance')),
      sourceButton),
    toolSeparator(),
    toolGroup(
      headingButton,
      toolGroup(
        sizeButton('toolbar-size-down', '−', 'reader.fontDown', 'Ctrl+-', -1),
        size,
        sizeButton('toolbar-size-up', '+', 'reader.fontUp', 'Ctrl+=', 1)),
      iconButton('toolbar-bold', 'bold', tip('toolbar.bold', 'Ctrl+B'), runner('bold')),
      iconButton('toolbar-italic', 'italic', tip('toolbar.italic', 'Ctrl+I'), runner('italic')),
      iconButton('toolbar-code', 'code', tip('menu.format.code'), runner('code')),
      menuButton('toolbar-lists', 'list', tip('toolbar.lists'), [
        { icon: 'list', label: 'menu.format.ul', run: runner('ul'), current: () => currentBlock()?.tagName === 'DT' },
        { icon: 'list-ordered', label: 'menu.format.ol', run: runner('ol'), current: () => currentBlock()?.tagName === 'DD' },
        { icon: 'text-quote', label: 'menu.format.quote', run: runner('quote'), current: () => currentBlock()?.tagName === 'BLOCKQUOTE' },
        { icon: 'square-code', label: 'doc.codeBlock', run: runner('codeblock'), current: () => currentBlock()?.tagName === 'PRE' },
      ]),
      menuButton('toolbar-insert', 'plus', tip('toolbar.insert'), [
        { icon: 'link', label: 'toolbar.link', run: runner('link') },
        { icon: 'separator-horizontal', label: 'toolbar.hr', run: runner('hr') },
      ])),
    segmented(...punctuation),
    colorButton,
    spacer,
    toolGroup(
      iconButton('toolbar-bookmark', 'bookmark', tip('reader.bookmark.toggle', 'Ctrl+D'), () => runReadingCommand('bookmarkToggle')),
      iconButton('toolbar-bookmark-list', 'book-marked', tip('reader.bookmark.list'), () => runReadingCommand('bookmarkList')),
      iconButton('toolbar-proof', 'spell-check', tip('proof.button'), runner('proofSelection')),
      iconButton('toolbar-ai', 'sparkles', tip('ai.title'), aiToggle, 'AI')),
    iconButton('toolbar-more', 'chevrons-right', tip('toolbar.more'), () => toggleToolbarMenu(document.getElementById('toolbar-more'), toolbarOverflowEntries())),
  );
  fitToolbar();
  updateToolbarState();
  updateReadingToolbar();
  punctuationUpdateToolbar();
}

// MARK: - Overflow

/// What gives way first when the window is narrow, as NSToolbar does on macOS: the tools at the
/// right, then formatting from the end. Find and AI stay, and the marks go last of all, as they
/// have high priority there.
const TOOLBAR_OVERFLOW_ORDER = [
  'toolbar-proof', 'toolbar-bookmark-list', 'toolbar-bookmark', 'toolbar-color', 'toolbar-insert', 'toolbar-lists',
  'toolbar-code', 'toolbar-source', 'toolbar-appearance', 'toolbar-italic', 'toolbar-bold',
  'toolbar-punctuation-thought', 'toolbar-punctuation-quotation', 'toolbar-punctuation-dialogue',
];

/// Keeps the toolbar to one row. What does not fit moves into the » menu at the end.
function fitToolbar() {
  const toolbar = document.getElementById('toolbar');
  const more = document.getElementById('toolbar-more');
  if (!toolbar || !more) return;
  for (const id of TOOLBAR_OVERFLOW_ORDER) document.getElementById(id)?.classList.remove('overflowed');
  more.hidden = true;
  if (toolbar.scrollWidth <= toolbar.clientWidth) return;
  more.hidden = false;
  for (const id of TOOLBAR_OVERFLOW_ORDER) {
    document.getElementById(id)?.classList.add('overflowed');
    if (toolbar.scrollWidth <= toolbar.clientWidth) break;
  }
  if (toolbarMenuOwner === more) closeToolbarMenu();
}

/// The hidden tools in toolbar order. A menu button brings its own entries.
function toolbarOverflowEntries() {
  const entries = [];
  for (const button of document.querySelectorAll('#toolbar button.overflowed')) {
    if (button.menuEntries) {
      if (entries.length > 0) entries.push({ separator: true });
      entries.push(...button.menuEntries);
      entries.push({ separator: true });
    } else {
      entries.push({ label: button.title, iconNode: button.querySelector('svg.icon')?.cloneNode(true), run: () => button.click(), disabled: button.disabled });
    }
  }
  while (entries.at(-1)?.separator) entries.pop();
  return entries.filter(entry => !entry.disabled);
}

new ResizeObserver(() => fitToolbar()).observe(document.getElementById('toolbar'));

/// The paragraph style and the bold and italic buttons follow the caret, as on macOS.
function updateToolbarState() {
  const heading = document.getElementById('toolbar-heading');
  if (!heading) return;
  const tag = currentBlock()?.tagName;
  const entry = HEADING_ENTRIES.find(item => item.tag === tag) ?? HEADING_ENTRIES[0];
  const label = heading.querySelector('span');
  if (label) label.textContent = strings[entry.label] ?? entry.label;
  // Headings are bold by their style, so only marked text counts, as it does when saved.
  const style = document.activeElement === root ? inlineStyleAtCaret() : {};
  document.getElementById('toolbar-bold')?.classList.toggle('on', style.bold === true);
  document.getElementById('toolbar-italic')?.classList.toggle('on', style.italic === true);
  const swatch = document.querySelector('#toolbar-color .color-bar');
  if (swatch) swatch.style.background = toolbarColor ?? 'currentColor';
}

function inlineStyleAtCaret() {
  const selection = getSelection();
  let node = selection?.anchorNode;
  if (!node || !root.contains(node)) return {};
  const chain = [];
  for (let current = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement; current && current !== root; current = current.parentElement) chain.unshift(current);
  return chain.reduce((style, element) => styleOf(element, style), {});
}

document.addEventListener('selectionchange', () => {
  if (document.activeElement === root) updateToolbarState();
});
root.addEventListener('input', updateToolbarState);
document.getElementById('color-input').addEventListener('change', event => {
  toolbarColor = event.target.value;
  updateToolbarState();
});

document.addEventListener('mousedown', event => {
  if (toolbarMenu.hidden) return;
  if (!toolbarMenu.contains(event.target) && !toolbarMenuOwner?.contains(event.target)) closeToolbarMenu();
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') closeToolbarMenu();
});
window.addEventListener('resize', closeToolbarMenu);
