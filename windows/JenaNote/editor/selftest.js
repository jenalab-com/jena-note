'use strict';

// Loaded only by `JenaNote.exe --selftest`. Drives the real editor with the same commands the
// keyboard and toolbar use. Korean composition cannot be simulated here; test that by hand.

(() => {
  const emptyDoc = () => {
    render([]);
    placeCaret(root.firstElementChild, 0);
    root.focus();
  };
  const type = text => exec('insertText', text);
  const press = (key, options = {}) => {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...options });
    root.dispatchEvent(event);
  };
  const enter = options => press('Enter', options);

  /// Selects characters of a block by offset across its text nodes.
  const select = (block, start, end) => {
    const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    let position = 0;
    let startSet = false;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const next = position + node.length;
      if (!startSet && start <= next) { range.setStart(node, start - position); startSet = true; }
      if (end <= next) { range.setEnd(node, end - position); break; }
      position = next;
    }
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  };
  const caretAtEnd = block => {
    const selection = getSelection();
    selection.selectAllChildren(block);
    selection.collapseToEnd();
  };

  const text = value => ({ text: value });
  const scenarios = [
    ['typing', '가나다\n', () => { type('가나다'); }],
    ['enter splits a line', 'a\nb\n', () => { type('a'); enter(); type('b'); }],
    ['shift enter is also a new line', 'a\nb\n', () => { type('a'); enter({ shiftKey: true }); type('b'); }],
    ['two enters leave a blank line', 'a\n\nb\n', () => { type('a'); enter(); enter(); type('b'); }],
    ['spaces stay ordinary spaces', '  a  b  \n', () => { type('  a  b  '); }],
    ['bold selection', 'a**b**c\n', () => { type('abc'); select(root.firstElementChild, 1, 2); run('bold'); }],
    ['bold toggles off', 'abc\n', () => { type('abc'); select(root.firstElementChild, 1, 2); run('bold'); run('bold'); }],
    ['italic selection', 'a*b*c\n', () => { type('abc'); select(root.firstElementChild, 1, 2); run('italic'); }],
    ['inline code', 'a`b`c\n', () => { type('abc'); select(root.firstElementChild, 1, 2); run('code'); }],
    ['inline code escapes markup', '`<b>`\n', () => { type('<b>'); select(root.firstElementChild, 0, 3); run('code'); }],
    ['color', 'a<span style="color: #FF0000">b</span>c\n', () => {
      type('abc'); select(root.firstElementChild, 1, 2); exec('foreColor', '#ff0000');
    }],
    ['link', 'a[b](https://x.y)c\n', () => { type('abc'); select(root.firstElementChild, 1, 2); applyLink('https://x.y'); }],
    ['heading command', '# t\n', () => { type('t'); run('h1'); }],
    ['heading toggles back', 't\n', () => { type('t'); run('h2'); run('h2'); }],
    ['body command clears heading', 't\n', () => { type('t'); run('h3'); run('body'); }],
    ['enter after a heading starts body text', '# t\nx\n', () => { type('t'); run('h1'); enter(); type('x'); }],
    ['bullet list', '- a\n- b\n', () => { run('ul'); type('a'); enter(); type('b'); }],
    ['empty bullet exits the list', '- a\nc\n', () => { run('ul'); type('a'); enter(); enter(); type('c'); }],
    ['numbered list counts', '1. a\n2. b\n3. c\n', () => { run('ol'); type('a'); enter(); type('b'); enter(); type('c'); }],
    ['empty number exits the list', '1. a\nc\n', () => { run('ol'); type('a'); enter(); enter(); type('c'); }],
    ['backspace at the start clears a list line', 'a\n', () => { run('ul'); type('a'); placeCaret(root.firstElementChild, 0); press('Backspace'); }],
    ['quote', '> a\n> b\n', () => { run('quote'); type('a'); enter(); type('b'); }],
    ['empty quote line exits', '> a\nc\n', () => { run('quote'); type('a'); enter(); enter(); type('c'); }],
    ['code block lines', '```\nx\ny\n```\n', () => { run('codeblock'); type('x'); enter(); type('y'); }],
    ['ctrl enter leaves a code block', '```\nx\n```\nz\n', () => { run('codeblock'); type('x'); enter({ ctrlKey: true }); type('z'); }],
    ['tab in text', 'a\tb\n', () => { type('a'); press('Tab'); type('b'); }],
    ['horizontal rule', 'a\n---\nb\n', () => { type('a'); enter(); run('hr'); type('b'); }],
    ['undo restores formatting', 'abc\n', () => { type('abc'); select(root.firstElementChild, 1, 2); run('bold'); exec('undo'); }],
    ['pasted text stays plain', 'l1\n<b>l2</b>\n', () => {
      const data = new DataTransfer();
      data.setData('text/plain', 'l1\r\n<b>l2</b>');
      data.setData('text/html', '<h1>ignored</h1>');
      root.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    }],
    ['edit keeps other formatting', '**a** bc\n', () => {
      render([{ type: 'paragraph', runs: [{ text: 'a', bold: true }, text(' b')] }]);
      caretAtEnd(root.firstElementChild); type('c');
    }],
    ['enter in a table cell adds no line', '| **Ax** |\n| --- |\n| 1 |\n', () => {
      render([{ type: 'table', headerRow: 0, rows: [[[{ text: 'A', bold: true }]], [[text('1')]]] }]);
      caretAtEnd(root.querySelector('th')); enter(); type('x');
    }],
    ['tab moves between cells', '| **A** |\n| --- |\n| x1 |\n', () => {
      render([{ type: 'table', headerRow: 0, rows: [[[{ text: 'A', bold: true }]], [[text('1')]]] }]);
      caretAtEnd(root.querySelector('th')); press('Tab'); type('x');
    }],
    ['typing in a note definition keeps it', '[^1]: 설명x\n', () => {
      render([{ type: 'noteDefinition', id: '1', runs: [text('설명')] }]);
      caretAtEnd(root.firstElementChild); type('x');
    }],
    ['markup in document text stays text', '<img src=x onerror=alert(1)>\n', () => {
      render([{ type: 'paragraph', runs: [text('<img src=x onerror=alert(1)>')] }]);
      if (root.querySelector('img')) throw new Error('markup became an element');
    }],
  ];

  // MARK: - Proofreading, through the real engine and dictionary

  const proofText = '오랫만에 친구를 만났다.';
  const waitFor = async (condition, timeout = 30000) => {
    const started = performance.now();
    while (!condition()) {
      if (performance.now() - started > timeout) return false;
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    return true;
  };
  const saved = () => JSON.stringify(readBlocks());
  const proofDocument = runs => {
    render([{ type: 'paragraph', runs }]);
    placeCaret(root.firstElementChild, 0);
  };
  const checkNow = async () => {
    const before = proofRequest;
    proofRefresh();
    await waitFor(() => proofCandidates.length > 0, 25000);
    return before !== proofRequest;
  };

  const steps = {
    async typeAtStart() {
      placeCaret(root.firstElementChild, 0);
      root.focus();
      type('쓴글');
    },
    async marks(check) {
      proofDocument([text(proofText)]);
      const markup = root.innerHTML;
      await checkNow();
      check('finds the misspelling', proofCandidates.length === 1, proofCandidates.length);
      const item = proofCandidates[0];
      check('suggests the correction', item?.replacement === '오랜만에', item?.replacement);
      check('underlines without touching the document', CSS.highlights.has('proof') && root.innerHTML === markup);
      if (item) proofShow(item);
      check('shows original and suggestion', !proofPopover.hidden
        && document.getElementById('proof-original').textContent === '오랫만에'
        && document.getElementById('proof-suggestion').textContent === '오랜만에');
      proofApply(item);
      check('applies the correction', root.textContent === '오랜만에 친구를 만났다.', root.textContent);
      check('applying clears the marks', proofCandidates.length === 0 && !CSS.highlights.has('proof') && proofPopover.hidden);
      exec('undo');
      check('undo restores the original', root.textContent === proofText, root.textContent);

      proofDocument([{ text: '오랫만', bold: true }, text('에 친구를 만났다.')]);
      await checkNow();
      proofApply(proofCandidates[0]);
      const runs = readBlocks()[0].runs;
      check('keeps formatting around the change', runs.length === 2 && runs[0].text === '오랜만' && runs[0].bold === true, JSON.stringify(runs));

      proofDocument([text('😀 ' + proofText)]);
      await checkNow();
      const emoji = proofCandidates[0];
      check('offsets survive emoji', emoji?.marks[0].toString().includes('랫') === true, emoji?.marks[0].toString());

      proofDocument([text(proofText)]);
      await checkNow();
      root.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      check('composition clears marks', proofCandidates.length === 0 && !CSS.highlights.has('proof'));
      proofRefresh();
      check('composition holds off checking', proofComposing && proofCandidates.length === 0);
      root.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
      check('composition end reschedules', !proofComposing && proofTimer !== null);
      clearTimeout(proofTimer);

      render([{ type: 'codeBlock', lines: [proofText] }]);
      proofRefresh();
      await new Promise(resolve => setTimeout(resolve, 200));
      check('code blocks are not checked', proofCandidates.length === 0);

      render([{ type: 'table', headerRow: 0, rows: [[[{ text: 'A', bold: true }]], [[text(proofText)]]] }]);
      await checkNow();
      check('table cells are checked', proofCandidates.length === 1 && proofCandidates[0].element.tagName === 'TD', proofCandidates.length);

      proofDocument([text(proofText)]);
      await checkNow();
      const stale = proofCandidates[0];
      root.firstElementChild.firstChild.data = '다른 글';
      check('a stale suggestion does not apply', proofApply(stale) === false && root.textContent === '다른 글', root.textContent);

      proofDocument([text(proofText)]);
    },
    async afterDictionary(check) {
      await new Promise(resolve => setTimeout(resolve, 50));
      proofRefresh();
      await new Promise(resolve => setTimeout(resolve, 400));
      check('a dictionary word is not marked', proofCandidates.length === 0, proofCandidates.length);
    },
    async afterRemoval(check) {
      await new Promise(resolve => setTimeout(resolve, 50));
      await checkNow();
      check('a removed word is marked again', proofCandidates.length === 1, proofCandidates.length);
    },
    async selection(check) {
      proofClear();
      clearTimeout(proofTimer);
      proofDocument([text('앞말 ' + proofText)]);
      select(root.firstElementChild, 3, 3 + proofText.length);
      run('proofSelection');
      check('selection check shows a suggestion', await waitFor(() => !proofPopover.hidden, 15000));
      check('selection suggestion is corrected', document.getElementById('proof-suggestion').textContent === '오랜만에 친구를 만났다.');
      check('selection offers no dictionary button', document.getElementById('proof-add').hidden);
      proofApply(proofShown);
      check('selection applies inside the line', root.textContent === '앞말 오랜만에 친구를 만났다.', root.textContent);
      render([]);
      clearTimeout(proofTimer);
    },
  };

  window.chrome.webview.addEventListener('message', async event => {
    const message = JSON.parse(event.data);
    if (message.type !== 'selftestStep') return;
    const checks = [];
    const check = (name, ok, detail) => checks.push({ name, ok: ok === true, detail: detail === undefined ? '' : String(detail) });
    try {
      await steps[message.step](check);
    } catch (error) {
      checks.push({ name: `${message.step} stopped`, ok: false, detail: String(error.stack ?? error) });
    }
    post({ type: 'selftest', checks });
  });

  window.jenaRunSelfTest = cases => {
    const roundTrips = cases.map(item => {
      render(item.blocks);
      return { name: item.name, blocks: readBlocks() };
    });
    const interactions = scenarios.map(([name, expected, action]) => {
      try {
        emptyDoc();
        action();
        return { name, expected, blocks: readBlocks() };
      } catch (error) {
        return { name, expected, error: String(error) };
      }
    });

    // A long manuscript: about a million characters in 3,300 paragraphs.
    const sentence = '그제야 리에느가 빵을 받아 들고 조용히 고개를 끄덕였다. **창밖으로** 내리는 비는 멈출 기미가 보이지 않았다. '.repeat(5);
    const long = Array.from({ length: 3300 }, () => ({ type: 'paragraph', runs: [{ text: sentence }] }));
    let started = performance.now();
    render(long);
    root.getBoundingClientRect();
    const renderMs = Math.round(performance.now() - started);
    started = performance.now();
    const readBack = readBlocks();
    const readMs = Math.round(performance.now() - started);
    const longOk = readBack.length === long.length;
    render([]);

    post({ type: 'selftest', roundTrips, interactions, longDocument: { renderMs, readMs, ok: longOk } });
  };
})();
