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
    ['several lines become one code block', '```\na\nb\n```\n', () => {
      render([{ type: 'paragraph', runs: [text('a')] }, { type: 'paragraph', runs: [text('b')] }]);
      const selection = getSelection();
      const range = document.createRange();
      range.setStart(root.firstElementChild.firstChild, 0);
      range.setEnd(root.lastElementChild.firstChild, 1);
      selection.removeAllRanges();
      selection.addRange(range);
      run('codeblock');
    }],
    ['typing in a code block keeps its language', '```swift\nxy\n```\n', () => {
      render([{ type: 'codeBlock', lines: ['x'], language: 'swift' }]);
      placeCaret(root.firstElementChild.firstChild, 1);
      type('y');
    }],
    ['neighboring code blocks stay apart while editing', '```\nax\n```\n```\nb\n```\n', () => {
      render([{ type: 'codeBlock', lines: ['a'], language: null }, { type: 'codeBlock', lines: ['b'], language: null }]);
      placeCaret(root.firstElementChild.firstChild, 1);
      type('x');
    }],
    ['a pipe typed in a cell stays in the cell', '| A |\n| --- |\n| a\\|b |\n', () => {
      render([{ type: 'table', headerRow: 0, rows: [[[text('A')]], [[]]] }]);
      placeCaret(root.querySelector('td'), 0);
      type('a|b');
    }],
    ['formatting in a cell survives editing', '| A |\n| --- |\n| *b*c |\n', () => {
      render([{ type: 'table', headerRow: 0, rows: [[[text('A')]], [[{ text: 'b', italic: true }]]] }]);
      caretAtEnd(root.querySelector('td'));
      exec('italic');
      type('c');
    }],
    ['column alignment survives editing', '| A |\n| :-: |\n| 1x |\n', () => {
      render([{ type: 'table', headerRow: 0, separators: [':-:'], rows: [[[text('A')]], [[text('1')]]] }]);
      caretAtEnd(root.querySelector('td'));
      type('x');
    }],
    ['enter in a table cell adds no line', '| Ax |\n| --- |\n| 1 |\n', () => {
      render([{ type: 'table', headerRow: 0, rows: [[[{ text: 'A', bold: true }]], [[text('1')]]] }]);
      caretAtEnd(root.querySelector('th')); enter(); type('x');
    }],
    ['tab moves between cells', '| A |\n| --- |\n| x1 |\n', () => {
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
    async find(check) {
      const lines = ['가나다 ABC 가나다', '**x** abc', 'abc'];
      render([
        { type: 'heading', level: 1, runs: [text(lines[0])] },
        { type: 'paragraph', runs: [{ text: 'x', bold: true }, text(' abc')] },
        { type: 'codeBlock', lines: ['abc'], language: null },
        { type: 'table', headerRow: 0, rows: [[[text('abc')]], [[text('z')]]] },
      ]);
      placeCaret(root.firstElementChild, 0);
      const markup = root.innerHTML;
      const before = saved();
      findOpen(false);
      findInput.value = 'abc';
      findInput.dispatchEvent(new Event('input'));
      check('finds in every kind of block, ignoring case', findMatches.length === 4, findMatches.length);
      check('finding leaves the document alone', root.innerHTML === markup && saved() === before);
      check('shows the count', findCount.textContent === '1/4', findCount.textContent);
      check('highlights matches', CSS.highlights.has('find') && CSS.highlights.has('find-current'));
      findMove(true);
      check('moves forward', findCount.textContent === '2/4', findCount.textContent);
      findMove(false);
      findMove(false);
      check('wraps around backward', findCount.textContent === '4/4', findCount.textContent);
      findMove(true);
      check('wraps around forward', findCount.textContent === '1/4', findCount.textContent);

      findClose();
      placeCaret(root.children[2], 0);
      findOpen(false);
      check('a search starts from the caret', findCount.textContent === '3/4', findCount.textContent);

      findInput.value = 'a.c(';
      findInput.dispatchEvent(new Event('input'));
      check('search text is not a pattern', findMatches.length === 0 && document.getElementById('replace-all').disabled, findMatches.length);

      findClose();
      placeCaret(root.firstElementChild, 0);
      findOpen(false);
      findInput.value = 'abc';
      findInput.dispatchEvent(new Event('input'));
      replaceRow.hidden = false;
      replaceInput.value = 'abcd';
      findReplaceCurrent();
      check('replace changes one match', saved().includes('가나다 abcd 가나다') && root.textContent.match(/abc/gi).length === 4, root.textContent);
      check('replace moves past its own text', findMatches[findCurrent]?.element === root.children[1], findMatches[findCurrent]?.element?.tagName);
      exec('undo');
      check('replace can be undone', root.firstElementChild.textContent === lines[0], root.firstElementChild.textContent);

      findInput.value = 'abc';
      findInput.dispatchEvent(new Event('input'));
      replaceInput.value = '';
      const count = findReplaceAll();
      check('replace all reports its count', count === 4, count);
      check('replace all empties every match', !/abc/i.test(root.textContent) && root.firstElementChild.textContent === '가나다  가나다', root.textContent);
      const bold = readBlocks()[1].runs[0];
      check('replace keeps formatting around it', bold.text === 'x' && bold.bold === true, JSON.stringify(bold));

      render([{ type: 'paragraph', runs: [text('한글 abc')] }]);
      findInput.value = '한글';
      findInput.dispatchEvent(new Event('input'));
      const current = findMatches[findCurrent].range.toString();
      findClose();
      check('closing selects the match', getSelection().toString() === current && findBar.hidden, getSelection().toString());
      check('closing clears the highlights', !CSS.highlights.has('find') && !CSS.highlights.has('find-current'));
      render([]);
    },
    async jumpSecond(check) {
      const selected = getSelection().toString();
      const line = getSelection().anchorNode?.parentElement?.closest('p')?.textContent;
      check('a search result jumps to its occurrence', selected === '오랫만' && line === '둘째 오랫만에', `${selected} / ${line}`);
    },
    async workAsk(check) {
      if (!aiActive) aiToggle();
      await new Promise(resolve => setTimeout(resolve, 200));
      check('the row names the work status', document.getElementById('ai-work-dot').className === 'ok' && document.getElementById('ai-work-text').textContent !== '', document.getElementById('ai-work-text').textContent);
      aiConversation.messages = [];
      aiConversation.mode = 'guide';
      aiInput.value = '리에느는 무엇을 좋아하나요?';
      aiSend();
      check('sent', aiBusy);
    },
    async workSee(check) {
      check('the answer arrived', !aiBusy, aiBusy);
      const messages = aiConversation.messages;
      const answer = messages[messages.length - 1];
      const sources = messages[messages.length - 2];
      check('the settings reached the request', answer.text.includes('빵을 좋아한다'), answer.text.slice(0, 300));
      check('an earlier episode reached the request', answer.text.includes('첫째 화 내용'), answer.text.slice(0, 300));
      check('the document itself reached the request', answer.text.includes('둘째 화 지금 내용'), '');
      check('a later episode never does', !answer.text.includes('미래비밀'), '');
      check('it tells the CLI this is not exhaustive', answer.text.includes('do not claim an exhaustive review'), '');
      check('what was read is listed', sources.role === 'status' && sources.text.includes('설정/인물.md') && sources.text.includes('1화.md') && !sources.text.includes('10화'), sources.text);
    },
    async workAskLarge(check) {
      aiConversation.messages = [];
      aiConversation.tokens = {};
      aiInput.value = '큰 작품 질문';
      aiSend();
      check('sent', aiBusy);
    },
    async workSeeLarge(check) {
      check('the answer arrived', !aiBusy, aiBusy);
      const messages = aiConversation.messages;
      check('the search round counts too', aiConversation.tokens[aiProvider] === 14, JSON.stringify(aiConversation.tokens));
      const sources = messages.find(item => item.role === 'status');
      check('only part of the work is read', sources && !sources.text.includes('10화'), sources?.text.slice(0, 200));
      check('the answer follows', messages[messages.length - 1].role === 'assistant', messages[messages.length - 1].role);
    },
    async workAskBad(check) {
      aiConversation.messages = [];
      aiInput.value = '잘못된 탐색 질문';
      aiSend();
      check('sent', aiBusy);
    },
    async workSeeBad(check) {
      check('it stops', !aiBusy, aiBusy);
      const last = aiConversation.messages[aiConversation.messages.length - 1];
      check('it says why', last.role === 'status', last.role);
      check('the question comes back', aiInput.value === '잘못된 탐색 질문' && !aiConversation.messages.some(item => item.role === 'user'), aiInput.value);
      aiInput.value = '';
    },
    async workRowOff(check) {
      await new Promise(resolve => setTimeout(resolve, 150));
      check('outside a work the row is off', document.getElementById('ai-work-text').textContent === strings['ai.work.row.off'], document.getElementById('ai-work-text').textContent);
      check('and has a button', document.getElementById('ai-work-button').textContent === strings['ai.work.row.settingsButton'], document.getElementById('ai-work-button').textContent);
    },
    async workClose(check) {
      aiToggle();
      check('closed', !aiActive);
      render([]);
    },
    async aiRevisions(check) {
      const load = blocks => {
        render(blocks);
        placeCaret(root.firstElementChild, 0);
        root.focus();
      };
      const revise = (blocks, revised, selection) => {
        load(blocks);
        const original = aiTextMap().text;
        const start = selection ? original.indexOf(selection) : 0;
        const end = selection ? start + selection.length : original.length;
        try {
          aiApplyRevision({ text: original, start, end }, revised);
        } catch (error) {
          return `refused: ${error.message.slice(0, 20)} / now ${aiTextMap().text} / hunks ${JSON.stringify(aiDiff(original, original.slice(0, start) + revised + original.slice(end)))}`;
        }
        return aiTextMap().text;
      };
      const paragraph = (...runs) => ({ type: 'paragraph', runs: runs.map(run => (typeof run === 'string' ? text(run) : run)) });

      // The text sent to the CLI
      load([paragraph('첫 줄'), { type: 'heading', level: 2, runs: [text('제목')] }, paragraph('끝')]);
      check('blocks are lines', aiTextMap().text === '첫 줄\n제목\n끝', aiTextMap().text);
      load([{ type: 'table', headerRow: 0, rows: [[[text('a')], [text('b')]], [[text('1')], [text('2')]]] }, paragraph('뒤')]);
      check('table cells keep their order', aiTextMap().text === 'a\tb\n1\t2\n뒤', JSON.stringify(aiTextMap().text));
      load([paragraph({ image: true, path: 'x.png', alt: 'x' }, ' 글')]);
      check('an image is one mark', aiTextMap().text === '\uFFFC 글' || aiTextMap().text === ' 글', JSON.stringify(aiTextMap().text));

      // Formatting stays on the words that did not change.
      let result = revise([paragraph({ text: '굵은', bold: true }, ' 말을 고칩니다')], '굵은 글을 고칩니다');
      check('a revision changes the word', result === '굵은 글을 고칩니다', result);
      const runs = readBlocks()[0].runs;
      check('bold stays where it was', runs[0].text === '굵은' && runs[0].bold === true && runs[1].bold !== true, JSON.stringify(runs));
      result = revise([paragraph('가나다라마바사')], '가나X라마Y사');
      check('two changes apply separately', result === '가나X라마Y사', result);
      result = revise([paragraph('앞'), paragraph('뒤')], '앞\n가운데\n뒤');
      check('a new line makes a block', result === '앞\n가운데\n뒤' && root.children.length === 3, `${result} ${root.children.length}`);
      result = revise([paragraph('앞'), paragraph('가운데'), paragraph('뒤')], '앞\n뒤');
      check('a removed line removes its block', result === '앞\n뒤' && root.children.length === 2, `${result} ${root.children.length}`);
      result = revise([paragraph('앞 글'), paragraph('뒤 글')], '앞 글 바꾼 뒤 글', '앞 글\n뒤 글');
      check('two blocks can become one', result === '앞 글 바꾼 뒤 글' && root.children.length === 1, result);
      result = revise([paragraph('😀 웃음')], '😀 미소');
      check('emoji survive', result === '😀 미소', result);
      result = revise([{ type: 'listItem', ordered: false, index: 0, runs: [text('하나')] }, { type: 'listItem', ordered: false, index: 0, runs: [text('둘')] }], '하나\n셋');
      check('a list item changes in place', result === '하나\n셋' && readBlocks()[1].type === 'listItem', JSON.stringify(readBlocks()[1]));
      result = revise([{ type: 'codeBlock', lines: ['a', 'b'], language: null }], 'a\nc\nb');
      check('code keeps its lines', result === 'a\nc\nb' && readBlocks()[0].lines.length === 3, `${JSON.stringify(result)} ${root.innerHTML} ${JSON.stringify(readBlocks()[0])}`);

      // Only the selection is revised.
      load([paragraph('앞 문장'), paragraph('가운데 문장'), paragraph('뒤 문장')]);
      const doc = aiTextMap().text;
      const from = doc.indexOf('가운데');
      aiApplyRevision({ text: doc, start: from, end: from + 6 }, '고친 문장');
      check('a selection revision stays inside it', aiTextMap().text === '앞 문장\n고친 문장\n뒤 문장', aiTextMap().text);

      // Refusals change nothing.
      const refused = (blocks, revised, name) => {
        load(blocks);
        const before = root.innerHTML;
        const original = aiTextMap().text;
        let failed = false;
        try {
          aiApplyRevision({ text: original, start: 0, end: original.length }, revised);
        } catch {
          failed = true;
        }
        check(name, failed && root.innerHTML === before, failed);
      };
      const table = { type: 'table', headerRow: 0, rows: [[[text('a')], [text('b')]], [[text('1')], [text('2')]]] };
      refused([table], 'a\tb\n1', 'removing a table cell is refused');
      refused([table], 'a\tb\tc\n1\t2', 'adding a table cell is refused');
      load([table]);
      aiApplyRevision({ text: aiTextMap().text, start: 0, end: aiTextMap().text.length }, 'a\tb\n1\t고침');
      check('a cell can change', readBlocks()[0].rows[1][1][0].text === '고침', JSON.stringify(readBlocks()[0].rows[1]));
      load([paragraph('글')]);
      let conflict = false;
      try {
        aiApplyRevision({ text: '다른 글', start: 0, end: 4 }, '새 글');
      } catch {
        conflict = true;
      }
      check('a changed document is refused', conflict && aiTextMap().text === '글');
      let tooLarge = false;
      try {
        aiDiff('가'.repeat(3000) + '끝', '나'.repeat(3000) + '끝!');
      } catch {
        tooLarge = true;
      }
      check('a huge rewrite is refused', tooLarge);
      check('same text means no change', aiDiff('같음', '같음').length === 0);

      // Undo takes it back.
      load([paragraph('되돌릴 글')]);
      const backText = aiTextMap().text;
      aiApplyRevision({ text: backText, start: 0, end: backText.length }, '바뀐 글');
      for (let index = 0; index < 6 && aiTextMap().text !== backText; index++) exec('undo');
      check('a revision can be undone', aiTextMap().text === backText, aiTextMap().text);
      render([]);
    },
    async aiPanelOpen(check) {
      render([{ type: 'paragraph', runs: [text('패널 문서입니다')] }]);
      readingPath = null;
      aiDocumentChanged();
      if (!aiActive) aiToggle();
      await new Promise(resolve => setTimeout(resolve, 100));
      check('the panel opens', aiActive && !aiPanel.hidden && !aiSplitter.hidden);
      check('keys go to the question box', document.activeElement === aiInput, document.activeElement?.id);
      check('every string exists', Object.entries(strings).every(([key, value]) => key !== value), Object.entries(strings).filter(([key, value]) => key === value).map(([key]) => key).join(','));
      check('the paged button rests', document.getElementById('toolbar-paged').disabled);
      const before = reading.mode;
      reading.mode = 'paged';
      layoutReading();
      check('the document scrolls while it is open', !isPaged() && !document.body.classList.contains('paged'));
      reading.mode = before;
      layoutReading();
      const rulerBox = rulers[0].canvas.getBoundingClientRect();
      check('the ruler stays in reach beside the panel', rulerBox.right <= aiPanel.getBoundingClientRect().left + 1, `${rulerBox.right} ${aiPanel.getBoundingClientRect().left}`);
      const wide = root.getBoundingClientRect().right;
      check('the panel takes room from the document', wide <= aiPanel.getBoundingClientRect().left, wide);

      // Korean composition must not send.
      aiInput.value = '조합 중';
      aiInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 229, bubbles: true, cancelable: true }));
      check('confirming a composition does not send', !aiBusy && aiInput.value === '조합 중');
      aiInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, bubbles: true, cancelable: true }));
      check('shift enter does not send', !aiBusy);
      aiInput.value = '   ';
      aiSend();
      check('an empty question does not send', !aiBusy);
    },
    async aiAskGuide(check) {
      aiInput.value = '이 글 어떤가요?';
      aiInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
      check('enter sends', aiBusy && aiInput.value === '', aiInput.value);
      check('the question shows at once', aiMessagesView.querySelector('.ai-user')?.textContent === '이 글 어떤가요?');
      check('waiting shows', !aiLoading.hidden);
      check('the button stops', aiSendButton.title === strings['ai.stop'], aiSendButton.title);
    },
    async aiSeeAnswer(check) {
      check('the answer arrived', !aiBusy && aiLoading.hidden, aiBusy);
      const last = aiConversation.messages[aiConversation.messages.length - 1];
      check('the prompt reached the CLI whole', last.text.includes('이 글 어떤가요?') && last.text.includes('패널 문서입니다') && last.text.includes('You are JenaNote'), last.text.slice(0, 200));
      check('tokens are counted', aiConversation.tokens[aiProvider] === 7, JSON.stringify(aiConversation.tokens));
      check('the document is untouched', aiTextMap().text === '패널 문서입니다');
    },
    async aiAskFail(check) {
      aiInput.value = '실패할 질문';
      aiSend();
      check('sent', aiBusy);
    },
    async aiSeeFailure(check) {
      const last = aiConversation.messages[aiConversation.messages.length - 1];
      check('a failure says so', last.role === 'status' && last.text.includes('bad login'), last.text);
      check('the question comes back', aiInput.value === '실패할 질문', aiInput.value);
      aiInput.value = '';
    },
    async aiAskEdit(check) {
      render([{ type: 'paragraph', runs: [{ text: '굵은', bold: true }, text(' 말')] }]);
      aiConversation.mode = 'edit';
      aiInput.value = '고쳐 주세요';
      aiSend();
      check('sent', aiBusy);
    },
    async aiSeeEdit(check) {
      check('the revision applied', aiTextMap().text === '굵은 글', aiTextMap().text);
      check('its formatting stayed', readBlocks()[0].runs[0].bold === true, JSON.stringify(readBlocks()[0].runs));
      const messages = aiConversation.messages;
      check('it explains and reports', messages[messages.length - 2].text === '설명입니다' && messages[messages.length - 1].text === strings['doc.aiApplied'], messages[messages.length - 1].text);
      check('a revision marks the document changed', revision > 0, revision);
    },
    async aiAskConflict(check) {
      aiInput.value = '또 고쳐 주세요';
      aiSend();
      // The author keeps writing while the answer is on its way.
      placeCaret(root.firstElementChild, 0);
      root.focus();
      exec('insertText', '끼어듦');
      check('sent', aiBusy);
    },
    async aiSeeConflict(check) {
      const messages = aiConversation.messages;
      check('a stale answer is not applied', aiTextMap().text.startsWith('끼어듦'), aiTextMap().text);
      check('it says why', messages[messages.length - 1].text.startsWith(strings['ai.editConflict']), messages[messages.length - 1].text);
    },
    async aiAskHang(check) {
      aiConversation.mode = 'guide';
      aiInput.value = '오래 걸릴 질문';
      aiSend();
      check('sent', aiBusy);
    },
    async aiStopHang(check) {
      aiStop();
      const last = aiConversation.messages[aiConversation.messages.length - 1];
      check('stopping says so', !aiBusy && last.text === strings['ai.cancelled'], last.text);
    },
    async aiSafety(check) {
      const rendered = aiRenderMarkdown([
        { type: 'paragraph', runs: [{ text: 'x', image: true, path: 'C:/secret.png', alt: '설명' }] },
        { type: 'paragraph', runs: [{ text: '나쁜', link: 'javascript:alert(1)' }, { text: '좋은', link: 'https://example.com' }] },
      ]);
      check('an answer cannot load a file', rendered.querySelector('img') === null && !rendered.innerHTML.includes('secret'), rendered.innerHTML);
      const links = [...rendered.querySelectorAll('a')];
      check('an answer keeps only safe links', links.length === 1 && links[0].getAttribute('href') === 'https://example.com', rendered.innerHTML);
      aiAdd('assistant', '<img src=x onerror=alert(1)>');
      const row = aiMessageElement(aiConversation.messages[aiConversation.messages.length - 1]);
      check('raw text stays text', row.querySelector('img') === null);
      aiConversation.messages.pop();
    },
    async aiPanelClose(check) {
      const name = aiConversation;
      aiInput.value = '남길 초안';
      aiInput.dispatchEvent(new Event('input'));
      aiDocumentChanged();
      check('another document has its own conversation', aiConversation !== name && aiConversation.messages.length === 0 && aiInput.value === '');
      aiConversation = name;
      aiToggle();
      check('the panel closes', !aiActive && aiPanel.hidden);
      check('the page view can return', !document.getElementById('toolbar-paged').disabled);
      render([]);
    },
    async sourceShown(check) {
      check('the source view covers the editor', sourceActive && !sourceView.hidden, sourceActive);
      check('it shows the saved form', sourceText.textContent.includes('**굵게** <b>꺾쇠</b>'), sourceText.textContent);
      check('markup in the text stays text', sourceText.querySelector('b') === null);
      check('keys go to the source', document.activeElement === sourceText, document.activeElement?.id);

      // What would change the document does nothing here.
      const blocks = JSON.stringify(readBlocks());
      const shown = sourceText.textContent;
      run('bold');
      run('h1');
      runSourceNative('undo');
      runSourceNative('paste');
      runSourceNative('cut');
      runReadingCommand('bookmarkToggle');
      runReadingCommand('paged');
      check('commands leave the document alone', JSON.stringify(readBlocks()) === blocks && reading.mode === 'scroll' && bookmarks.length === 0);
      check('commands leave the source alone', sourceText.textContent === shown);
      check('only its own button works', document.getElementById('toolbar-bold')?.disabled !== false
        && [...document.querySelectorAll('#toolbar button')].every(button => button.disabled === !['toolbar-source', 'toolbar-ai'].includes(button.id)));

      // Select All takes the source and nothing behind it.
      sourceText.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', ctrlKey: true, bubbles: true, cancelable: true }));
      check('select all stays in the source', getSelection().toString().trimEnd() === shown.trimEnd(), getSelection().toString().length);
      runSourceNative('selectAll');
      check('the menu command does the same', getSelection().toString().trimEnd() === shown.trimEnd());

      // Find works, replace does not.
      findOpen(true);
      check('replace stays closed', replaceRow.hidden && !findBar.hidden);
      findInput.value = '**';
      findInput.dispatchEvent(new Event('input'));
      check('find sees the markup', findMatches.length === 2, findMatches.length);
      replaceInput.value = 'x';
      findReplaceCurrent();
      check('replacing does nothing', findReplaceAll() === 0 && sourceText.textContent === shown);
      findClose();
      check('closing find selects in the source', getSelection().toString() === '**' && document.activeElement === sourceText, getSelection().toString());
      findOpen(false);
      findInput.value = '굵게';
      findInput.dispatchEvent(new Event('input'));
      check('an open search stays with the source', findMatches.length === 1 && findMatches[0].element === sourceText, findMatches.length);
    },
    async sourceHidden(check) {
      check('the source view is gone', !sourceActive && sourceView.hidden);
      check('keys go back to the editor', document.activeElement === root, document.activeElement?.id);
      check('an open search follows back', !findBar.hidden && findMatches.length === 1 && root.contains(findMatches[0].range.startContainer), findMatches.length);
      findClose();
      check('every button works again', [...document.querySelectorAll('#toolbar button')].every(button => !button.disabled));
    },
    async readingFonts(check) {
      await document.fonts.load('400 20px "KoPub Batang App"');
      await document.fonts.load('700 20px "KoPub Batang App"');
      const faces = [...document.fonts].filter(face => face.family.includes('KoPub'));
      check('both bundled faces load', faces.length === 2 && faces.every(face => face.status === 'loaded'), faces.map(face => `${face.weight} ${face.status}`).join(', '));
      // The two faces have the same widths, so only the ink tells them apart.
      const ink = weight => {
        const canvas = document.createElement('canvas');
        canvas.width = 500;
        canvas.height = 80;
        const context = canvas.getContext('2d', { willReadFrequently: true });
        context.font = `${weight} 40px "KoPub Batang App"`;
        context.fillText('Reading 한글 test', 4, 50);
        return context.getImageData(0, 0, 500, 80).data.reduce((sum, value, index) => (index % 4 === 3 ? sum + value : sum), 0);
      };
      check('bold text uses the bold face', ink(700) > ink(400) * 1.1, `${ink(400)} ${ink(700)}`);
      render([{ type: 'heading', level: 1, runs: [text('제목')] }]);
      const heading = getComputedStyle(root.firstElementChild);
      check('a heading is bold', heading.fontWeight === '700', heading.fontWeight);
      render([]);
    },
    async readingMeasures(check) {
      const near = (a, b) => Math.abs(a - b) < 0.01;
      // The same answers as ReaderMetrics on macOS.
      const grid = 0.25 * 72 / 2.54;
      check('margins snap to a quarter centimeter', near(snappedMargin(grid * 1.4), grid) && snappedMargin(-5) === 0);
      let margins = clampedMargins(500, 500, 400);
      check('the left margin wins when they do not fit', margins.left === 280 && margins.right === 0, JSON.stringify(margins));
      check('text keeps its minimum width', textWidth(400, 500, 500) === 120 && textWidth(100, 50, 50) === 100);
      check('two pages need room', fitsSpread(2 * 600 + 56 + 48, 600, false) && !fitsSpread(2 * 600 + 56 + 47, 600, false));
      check('two pages hold on a little', fitsSpread(2 * 600 + 56 + 48 - 40, 600, true) && !fitsSpread(2 * 600 + 56 + 48 - 41, 600, true));
      check('a spread starts on an even page', spreadStart(0) === 0 && spreadStart(3) === 2 && spreadStart(4) === 4);

      // Anchors: the cases in the shared ReadingAnchor tests.
      const text = '가나다라마바사 첫째 문단입니다.\n둘째 문단입니다. 끝까지 이어집니다.\n셋째.';
      const anchor = makeAnchor(10, text);
      check('an anchor holds its place', resolveAnchor(anchor, text) === 10, resolveAnchor(anchor, text));
      check('an anchor finds text that moved', resolveAnchor(anchor, `앞에 넣음 ${text}`) === 16, resolveAnchor(anchor, `앞에 넣음 ${text}`));
      check('an anchor without its text stays in range', resolveAnchor({ characterOffset: 999, contextSnippet: '없는 글', contentLength: 0 }, text) === text.length);
      check('an anchor at the end stays in range', resolveAnchor({ characterOffset: 999, contextSnippet: '', contentLength: 0 }, text) === text.length);
      const twice = 'abc xyz abc xyz abc';
      check('the nearest match wins', resolveAnchor({ characterOffset: 9, contextSnippet: 'abc', contentLength: 0 }, twice) === 8, resolveAnchor({ characterOffset: 9, contextSnippet: 'abc', contentLength: 0 }, twice));
      check('an edit before moves the offset', offsetAfterEdit(10, 2, 3, 5) === 12);
      check('an edit after leaves the offset', offsetAfterEdit(1, 2, 3, 5) === 1);
      check('an edit around lands inside', offsetAfterEdit(4, 2, 5, 1) === 3);
      check('a preview flattens lines', previewText(0, 'a\n\n  b') === 'a b');
      check('a long preview is cut', previewText(0, 'x'.repeat(100)).length === 61);

      // Counting is the same as TextMetrics: a line break counts nowhere, a space only in one.
      const counts = textCounts('가 나\n다\t라');
      check('counts follow macOS', counts.noSpaces === 4 && counts.withSpaces === 6, JSON.stringify(counts));
      const emoji = textCounts('\u{1F468}\u200D\u{1F469} e\u0301');
      check('joined characters count once', emoji.noSpaces === 2 && emoji.withSpaces === 3, JSON.stringify(emoji));
    },
    async readingLayout(check) {
      const saved = { ...reading };
      const near = (a, b, tolerance = 1) => Math.abs(a - b) <= tolerance;
      const sample = Array.from({ length: 200 }, (_, index) => ({ type: 'paragraph', runs: [text(`문단 ${index}. 그제야 리에느가 빵을 받아 들고 조용히 고개를 끄덕였다. 창밖으로는 비가 내리고 있었고 아무도 말을 꺼내지 않았다.`)] }));
      const set = values => {
        Object.assign(reading, values);
        applyReadingStyle();
        layoutReading();
      };
      render(sample);
      set({ mode: 'scroll', paper: 'automatic', pageWidth: 0, marginLeft: 0, marginRight: 0, bodySize: 15, fontScale: 1.3, letterSpacing: 0, weight: 'regular', lineSpacing: 1.5 });
      const before = JSON.stringify(readBlocks());

      // Scroll view
      const expected = 35 * glyphAdvance();
      check('the book width is a count of characters', near(root.getBoundingClientRect().width, Math.min(expected, scroller.clientWidth - 120)), root.getBoundingClientRect().width);
      check('there is one ruler', rulers.length === 1 && rulers[0].canvas.isConnected);
      widthMode = 'mobile';
      layoutReading();
      check('the mobile width is fixed', near(root.getBoundingClientRect().width, 360), root.getBoundingClientRect().width);
      widthMode = 'book';
      set({ marginLeft: 40, marginRight: 60, pageWidth: 500 });
      check('margins take from the page', near(root.getBoundingClientRect().width, 400), root.getBoundingClientRect().width);
      const textLeft = root.getBoundingClientRect().left;
      check('the ruler starts a margin before the text', near(rulers[0].canvas.getBoundingClientRect().left, textLeft - 40), rulers[0].canvas.getBoundingClientRect().left);
      set({ marginLeft: 0, marginRight: 0, pageWidth: 0, paper: 'a4' });
      check('a paper size sets the width', near(root.getBoundingClientRect().width, 595.28), root.getBoundingClientRect().width);
      set({ paper: 'a3' });
      check('a sheet wider than the window scrolls sideways', paperWidth() > scroller.clientWidth ? scroller.scrollWidth > scroller.clientWidth : true, `${scroller.scrollWidth}`);
      set({ paper: 'automatic' });

      // The ruler
      set({ pageWidth: 400 });
      const ruler = rulers[0];
      beginRulerDrag(ruler, 'left', 0);
      applyRulerDrag(50);
      const grid = 0.25 * 72 / 2.54;
      check('dragging a handle snaps', near(ruler.left, Math.round(50 / grid) * grid, 0.01), ruler.left);
      applyRulerDrag(9999);
      check('a margin leaves room for text', near(ruler.left, 280, 0.01), ruler.left);
      applyRulerDrag(-30);
      check('dragging past the edge widens the page', ruler.left === 0 && ruler.width > 400, `${ruler.left} ${ruler.width}`);
      rulerDrag = null;
      set({ pageWidth: 0 });

      // Paged view
      set({ mode: 'paged' });
      check('the page is marked as paged', document.body.classList.contains('paged'));
      check('text flows into pages', pageCount > 1, pageCount);
      check('the document is one element still', root.children.length === 200);
      const firstPage = root.children[0].getClientRects()[0];
      const clip = pageClip.getBoundingClientRect();
      check('the first page shows at the left', firstPage.left >= clip.left - 1 && firstPage.right <= clip.right + 1, `${firstPage.left} ${clip.left}`);
      const last = pageCount;
      showPage(1);
      check('pages turn whole', isSpread ? currentPage === 0 || currentPage === 2 : Math.abs(pageClip.scrollLeft - pageStep) <= 1, `${pageClip.scrollLeft} ${pageStep}`);
      showPage(9999);
      check('pages stop at the last', currentPage <= last - 1, `${currentPage} ${last}`);
      const lastBlock = root.lastElementChild.getClientRects();
      const lastRect = lastBlock[lastBlock.length - 1];
      check('the last page can be reached', lastRect.left < clip.right && lastRect.right > clip.left, `${lastRect.left} ${clip.left} ${clip.right}`);
      showPage(0);

      const pagesBefore = pageCount;
      set({ marginLeft: 150 });
      check('narrower text makes more pages', pageCount > pagesBefore, `${pagesBefore} ${pageCount}`);
      set({ marginLeft: 0 });
      check('wider text makes fewer pages again', pageCount === pagesBefore, `${pagesBefore} ${pageCount}`);

      // Page Down from a page start must not fall back to the page before.
      const settle = () => new Promise(resolve => setTimeout(resolve, 60));
      showPage(0);
      placeCaret(root.children[0], 0);
      root.focus();
      await settle();
      const turn = isSpread ? 2 : 1;
      press('PageDown');
      await settle();
      check('page down turns a page', currentPage === turn, currentPage);
      press('PageDown');
      await settle();
      check('page down turns again from a page start', currentPage === 2 * turn, currentPage);
      const pageStart = visibleOffset();
      const pageStartCaret = caretRect();
      check('the caret stands on the new page', pageStartCaret && pageStartCaret.left >= clip.left - 1 && pageStartCaret.left < clip.right, `${pageStartCaret?.left} ${clip.left}`);
      showPage(0);
      anchorOffset = pageStart;
      getSelection().removeAllRanges();
      root.blur();
      applyAnchor();
      check('a stored place at a page start reopens on that page', currentPage === 2 * turn, currentPage);
      press('PageUp');
      root.focus();
      showPage(0);

      // The caret takes the page with it.
      placeCaret(root.children[150], 0);
      root.focus();
      syncPageToCaret();
      const caret = caretRect();
      check('the page follows the caret', caret && caret.left >= clip.left - 1 && caret.left < clip.right, `${caret?.left} ${clip.left} ${clip.right}`);
      check('whole pages only', Math.abs(pageClip.scrollLeft - currentPage * pageStep) < 1, `${pageClip.scrollLeft} ${currentPage * pageStep}`);
      const beforeTyping = saved;
      exec('insertText', '쓴글');
      check('typing on a later page reaches the document', root.children[150].textContent.startsWith('쓴글'));
      exec('undo');
      check('undo works on a later page', !root.children[150].textContent.startsWith('쓴글'));

      // Two pages side by side, when the window has room for them.
      widthMode = 'mobile';
      layoutReading();
      check('a narrow page opens as a spread', isSpread && rulers.length === 2, `${isSpread} ${rulers.length} ${scroller.clientWidth}`);
      const spreadClip = pageClip.getBoundingClientRect();
      check('a spread is two pages and a gutter', near(spreadClip.width, 2 * 360 + 56), spreadClip.width);
      showPage(0);
      const spreadColumns = new Set();
      for (const block of root.children) {
        for (const rect of block.getClientRects()) {
          if (rect.right > spreadClip.left && rect.left < spreadClip.right) spreadColumns.add(Math.round(rect.left));
        }
      }
      check('both pages show text', spreadColumns.size === 2, [...spreadColumns].join(','));
      showPage(3);
      check('a spread starts on an even page', currentPage === 2, currentPage);
      check('the indicator names both pages', document.getElementById('page-number').textContent.startsWith('3–4'), document.getElementById('page-number').textContent);
      // An odd last page sits alone on the left, and the view can still reach it.
      showPage(pageCount - 1);
      const spreadEnd = root.lastElementChild.getClientRects();
      const endRect = spreadEnd[spreadEnd.length - 1];
      check('the last spread can be reached', endRect.left < spreadClip.right && endRect.right > spreadClip.left, `${endRect.left} ${spreadClip.left} ${spreadClip.right} ${pageCount}`);
      check('whole spreads only', Math.abs(pageClip.scrollLeft - currentPage * pageStep) <= 1, `${pageClip.scrollLeft} ${currentPage * pageStep}`);
      widthMode = 'book';
      layoutReading();
      showPage(0);

      // A sheet wider than the window shrinks to fit, and keeps its line breaks.
      set({ paper: 'a3' });
      check('a wide sheet zooms out', pageZoom < 1 && near(pageZoom, Math.min(1, scroller.clientWidth / (841.89 + 48)), 0.01), pageZoom);
      const sheet = pageClip.getBoundingClientRect();
      const host = scroller.getBoundingClientRect();
      check('the sheet fits the window', sheet.left >= host.left - 1 && sheet.right <= host.right + 1, `${sheet.left} ${sheet.right} ${host.left} ${host.right}`);
      check('the ruler matches the sheet', near(rulers[0].canvas.getBoundingClientRect().width, sheet.width, 2), `${rulers[0].canvas.getBoundingClientRect().width} ${sheet.width}`);
      const zoomedPages = pageCount;
      showPage(1);
      const moved = [...root.children].some(block => [...block.getClientRects()].some(rect => rect.left >= sheet.left - 1 && rect.left < sheet.right));
      check('a zoomed page turns to text', zoomedPages >= 1 && moved, zoomedPages);
      placeCaret(root.children[150], 0);
      root.focus();
      syncPageToCaret();
      const zoomedCaret = caretRect();
      check('the page follows the caret when zoomed', zoomedCaret && zoomedCaret.left >= sheet.left - 1 && zoomedCaret.left < sheet.right, `${zoomedCaret?.left} ${sheet.left} ${sheet.right}`);
      set({ paper: 'automatic' });
      showPage(0);

      // Find across pages
      findOpen(false);
      findInput.value = '문단 180.';
      findInput.dispatchEvent(new Event('input'));
      const found = findMatches[findCurrent]?.range.getClientRects()[0];
      check('find turns to the page of the match', found && found.left >= clip.left - 1 && found.left < clip.right, `${found?.left} ${clip.left}`);
      findClose();

      // Position survives a change of view.
      goToOffset(offsetOfPosition(root.children[120].firstChild, 0));
      const offset = anchorOffset;
      set({ mode: 'scroll' });
      const top = root.children[120].getBoundingClientRect().top - scroller.getBoundingClientRect().top;
      check('going to scroll view keeps the place', near(top, SCROLL_READ_OFFSET, 40), top);
      check('the offset reads back', Math.abs(visibleOffset() - offset) < 60, `${visibleOffset()} ${offset}`);
      set({ mode: 'paged' });
      const rect = root.children[120].getClientRects()[0];
      const visible = pageClip.getBoundingClientRect();
      check('going to paged view keeps the place', rect.left >= visible.left - 1 && rect.left < visible.right, `${rect.left} ${visible.left}`);

      // Blocks in view
      const inView = blocksInView();
      check('proofreading sees this page only', inView.includes(root.children[120]) && inView.length < 40, inView.length);

      // Presentation never reaches the file.
      for (const change of [{ weight: 'bold' }, { weight: 'light' }, { font: 'sans' }, { lineSpacing: 2 }, { fontScale: 2 }, { paper: 'a5' }, { marginLeft: 50 }]) {
        set(change);
        check(`${Object.keys(change)[0]} ${Object.values(change)[0]} leaves the document alone`, JSON.stringify(readBlocks()) === before);
      }
      set({ mode: 'scroll', weight: 'bold', paper: 'automatic', marginLeft: 0, font: saved.font, lineSpacing: 1.5, fontScale: 1.3 });
      render([{ type: 'paragraph', runs: [text('글자')] }]);
      layoutReading();
      const paragraph = root.firstElementChild;
      const selection = getSelection();
      selection.removeAllRanges();
      const range = document.createRange();
      range.selectNodeContents(paragraph);
      selection.addRange(range);
      run('bold');
      const blocks = readBlocks();
      check('bold works while reading in bold', blocks[0].runs[0].bold === true, JSON.stringify(blocks[0]));
      set({ weight: 'regular' });

      // Long manuscript: what typing costs on a page.
      const sentence = '그제야 리에느가 빵을 받아 들고 조용히 고개를 끄덕였다. 창밖으로 내리는 비를 한참 바라보다가 천천히 입을 열었다. '.repeat(3);
      render(Array.from({ length: 3300 }, () => ({ type: 'paragraph', runs: [text(sentence)] })));
      set({ mode: 'paged' });
      let started = performance.now();
      updatePageCount();
      const layoutMs = Math.round(performance.now() - started);
      const pages = pageCount;
      placeCaret(root.children[1650], 0);
      root.focus();
      syncPageToCaret();
      started = performance.now();
      for (let index = 0; index < 10; index++) {
        exec('insertText', '가');
        root.getBoundingClientRect();
      }
      const keyMs = Math.round((performance.now() - started) / 10);
      for (let index = 0; index < 10; index++) exec('undo');
      check(`long manuscript in pages: ${pages} pages, layout ${layoutMs} ms, typing ${keyMs} ms per key`, keyMs < 150, keyMs);

      Object.assign(reading, saved);
      widthMode = 'book';
      render([]);
      applyReadingStyle();
      layoutReading();
    },
    async readingBookmarks(check) {
      const saved = readingPath;
      const sample = Array.from({ length: 120 }, (_, index) => ({ type: 'paragraph', runs: [text(`문단 ${index} 내용이 여기에 있습니다.`)] }));
      render(sample);
      readingBeforeLoad();
      readingPath = 'test-path';
      trackedText = displayText();
      layoutReading();
      scroller.scrollTop = 0;
      check('no path means no bookmark', (() => { readingPath = null; const done = bookmarkHere(); readingPath = 'test-path'; return done === false && bookmarks.length === 0; })());
      goToOffset(offsetOfPosition(root.children[50].firstChild, 0));
      bookmarkHere();
      check('a bookmark marks this screen', bookmarks.length === 1, bookmarks.length);
      const mark = bookmarks[0].characterOffset;
      check('the toolbar shows it', document.getElementById('toolbar-bookmark')?.classList.contains('on') !== false);
      bookmarkHere();
      check('a second press removes it', bookmarks.length === 0, bookmarks.length);
      goToOffset(mark);
      bookmarkHere();

      // Edits before it move it, by exactly what was typed.
      placeCaret(root.children[2], 0);
      exec('insertText', '앞에 넣은 글');
      adjustBookmarksForEdit();
      const typed = '앞에 넣은 글'.length;
      check('an edit before a bookmark moves it', bookmarks[0].characterOffset === mark + typed, `${bookmarks[0].characterOffset} ${mark}`);
      placeCaret(root.children[100], 0);
      exec('insertText', '뒤에 넣은 글');
      adjustBookmarksForEdit();
      check('an edit after a bookmark leaves it', bookmarks[0].characterOffset === mark + typed, bookmarks[0].characterOffset);

      showBookmarkList();
      const rows = bookmarkPopover.querySelectorAll('.bookmark-open');
      check('the list shows the text there', rows.length === 1 && rows[0].textContent.includes('문단'), rows[0]?.textContent);
      rows[0].click();
      check('choosing one closes the list', bookmarkPopover.hidden);
      const here = root.children[50].getBoundingClientRect().top - scroller.getBoundingClientRect().top;
      check('choosing one goes there', Math.abs(here - SCROLL_READ_OFFSET) < 60, here);
      showBookmarkList();
      bookmarkPopover.querySelector('.bookmark-remove').click();
      check('a bookmark can be removed from the list', bookmarks.length === 0 && bookmarkPopover.querySelectorAll('.bookmark-open').length === 0);
      closePopovers();

      // Stored state from the host.
      const content = displayText();
      applyReadingState({ path: 'other', progress: makeAnchor(content.indexOf('문단 80 '), content), bookmarks: [makeAnchor(content.indexOf('문단 30 '), content)] });
      check('stored bookmarks come back', bookmarks.length === 1 && bookmarks[0].characterOffset === content.indexOf('문단 30 '));
      const restored = root.children[80].getBoundingClientRect().top - scroller.getBoundingClientRect().top;
      check('the reading place comes back', Math.abs(restored - SCROLL_READ_OFFSET) < 60, restored);
      showAppearance();
      check('the appearance panel fills', appearancePopover.querySelectorAll('.appearance-row').length === 7 && !appearancePopover.hidden, appearancePopover.children.length);
      closePopovers();
      readingPath = saved;
      bookmarks = [];
      render([]);
      scroller.scrollTop = 0;
    },
    async styleApplied(check) {
      render([
        { type: 'heading', level: 1, runs: [text('제목')] },
        { type: 'paragraph', runs: [text('본문 '), { text: 'c', code: true }] },
      ]);
      const near = (actual, expected) => Math.abs(parseFloat(actual) - expected) < 0.05;
      const body = getComputedStyle(root);
      const size = 11 * 1.3;
      check('body size follows the size and the zoom', near(body.fontSize, size), body.fontSize);
      check('letter spacing is a percent of the size', near(body.letterSpacing, size * 0.1), body.letterSpacing);
      const heading = getComputedStyle(root.querySelector('h1'));
      check('headings keep their proportion', near(heading.fontSize, size * 28 / 15), heading.fontSize);
      const code = getComputedStyle(root.querySelector('code'));
      check('code has no letter spacing', code.letterSpacing === 'normal' || parseFloat(code.letterSpacing) === 0, code.letterSpacing);
      const paper = getComputedStyle(document.getElementById('scroller')).backgroundColor;
      check('paper color reaches the page', paper === 'rgb(16, 32, 48)', paper);
    },
    async toolbarEnglish(check) {
      const first = document.querySelector('#toolbar button')?.textContent;
      check('toolbar follows the language', first === 'Bold', first);
      check('popover follows the language', document.getElementById('proof-apply').textContent !== '적용', document.getElementById('proof-apply').textContent);
    },
    async dark(check) {
      check('dark mode reaches the page', matchMedia('(prefers-color-scheme: dark)').matches);
    },
    async light(check) {
      check('light mode reaches the page', !matchMedia('(prefers-color-scheme: dark)').matches);
    },
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
    findBar.hidden = false;
    findInput.value = '그';
    started = performance.now();
    findSearch();
    root.getBoundingClientRect();
    const findMs = Math.round(performance.now() - started);
    const findTotal = findMatches.length;
    // A name changed throughout a manuscript, about once in every paragraph or so.
    render(long.map((block, index) => (index % 3 === 0 ? { type: 'paragraph', runs: [{ text: `표식 ${sentence}` }] } : block)));
    findInput.value = '표식';
    findSearch();
    const replaceTotal = findMatches.length;
    replaceInput.value = '이름';
    started = performance.now();
    findReplaceAll();
    const replaceMs = Math.round(performance.now() - started);
    findClose();
    render([]);

    post({ type: 'selftest', roundTrips, interactions, longDocument: { renderMs, readMs, findMs, findTotal, replaceMs, replaceTotal, ok: longOk } });
  };
})();
