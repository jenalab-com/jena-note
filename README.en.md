<div align="center">

<img src="icon-1024.png" width="128" alt="JenaNote icon" />

# JenaNote

**A WYSIWYG Markdown note app for macOS — no Markdown syntax required**

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.7](https://img.shields.io/badge/Swift-5.7-orange?logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/jenalab-com/jena-note)](https://github.com/jenalab-com/jena-note/releases/latest)

[Download](#installation) · [Features](#features) · [Build from source](#build-from-source) · [Shortcuts](#keyboard-shortcuts) · [한국어](README.md)

</div>

---

## Why JenaNote

The built-in macOS editors (TextEdit, Notes) cannot save formatting as `.md`, while dedicated Markdown editors (Typora, Obsidian) are either more than you need or show symbols such as `**` and `#` on screen.

**JenaNote fills that gap.** You edit text as it looks once formatted (WYSIWYG), without Markdown symbols on screen, and the file is saved as standard CommonMark `.md` that opens anywhere. People who don't know Markdown can write formatted documents and share them as `.md` without reading a manual.

## Features

- **WYSIWYG Markdown editing** — Formatting is shown applied, without `**`, `#` or `>` symbols. Saving produces standard `.md`.
- **Formatting toolbar** — Bold, italic, headings (H1–H3), bulleted and numbered lists, code, blockquote, link.
- **Sidebar folder browser** — Register a folder to see its `.md` files as a recursive tree. Clicking a file swaps the document in place in the current window. FSEvents keeps the tree live (external additions, deletions and renames appear automatically), and registered folders are restored after relaunch.
- **Unified editing view** — Edit directly without switching between reading and editing modes. The top toolbar provides formatting, insert, find, bookmarks and AI; the view settings adjust typeface, display weight, zoom, line spacing and mobile/book text width. You can edit while keeping page and two-page layouts; later pages are laid out incrementally. Arrow keys move the cursor; Page Up/Down and scroll gestures turn pages. A `…` in the total page count means pagination is still in progress.
- **CLI-based AI chat** — The AI button opens a per-document chat. It recognizes selected text and can give guidance or edit directly; edits are undoable with ⌘Z. The editor switches to scroll layout while AI is in use. Install and sign in to Claude Code, Codex, Gemini CLI or Grok CLI from Settings and use **Recheck** to test the connection. Recheck sends a short AI request and may use quota. Conversations are kept per file while the app is running. Grok requires a first sign-in in a JenaNote-specific profile so it does not conflict with your existing setup.
- **Automatic error highlighting** — When you pause typing for about 0.5 seconds, the sentences on screen are checked with Kiwi and suggested corrections get an orange wavy dotted underline. Newly visible text is checked as you scroll or turn pages. Checking waits while Hangul is being composed, and never changes the text, saved formatting or undo history. A missing space is marked on the two characters around it. Hovering over or placing the cursor on a suggestion shows the correction with Apply and Add to dictionary buttons. Apply changes only that suggestion and can be undone with ⌘Z.
- **My Dictionary** — In Edit > My Dictionary…, search, add and edit words to exclude from checking. Adding defaults to the current work, and can be shared with all works or selected works. Documents outside a work show that the default is all works. Adding, editing and deleting apply immediately to on-screen and selection checks, and several words can be selected and deleted at once. The dictionary is stored on this Mac and the previous file is kept before every change.
- **Check Selected Text** — Select text and run Proofread from the toolbar or Edit > Check Selected Text. Kiwi suggests spacing and common typo corrections on device; you compare them with the original before applying, and ⌘Z restores the original. It checks up to 500 characters at a time without Apple Intelligence and does not wait for work summaries. The model needs a moment to load the first time. Words analyzed as proper nouns, line breaks and tabs are preserved, but not every error is detected.
- **Rules from Korean orthography** — Corrections follow the Korean orthography rules of the National Institute of Korean Language: auxiliary verbs written together are allowed (`꺼져간다`); `-어 지다` and adjective + `-어 하다` are joined; `뿐·대로·만큼` after a noun are joined; `하` contraction (`넉넉지`, `생각건대`); plain consonants in `-ㄹ게·-ㄹ지·-ㄹ수록·-ㄹ걸`; `-이/-히` adverbs; `됬 → 됐`. Spacing that the rules accept either way is left as written. Spellings that depend on meaning (`맞추다/맞히다`, `-던지/-든지`) and standard-vocabulary replacement are not covered yet.
- **Open source licenses** — Jena Note's About window lists the bundled open source components and their license notices.
- **Paper size** — Choose A4, A5, ISO/JIS B series, Letter, Legal and more in the view settings, and adjust the left and right text margins with the horizontal ruler. Standard paper sizes keep their full dimensions.
- **Page background** — Pick any background color with the macOS color picker in the UI tab of Settings. It affects only the display, not the manuscript or exports.
- **Settings tabs and autosave** — Settings are split into General, UI and AI tabs. General sets the language, autosave on/off and the save interval (30 seconds, 1, 3, 5 or 10 minutes; default 1 minute).
- **Version history and restore** — Keeps named versions and automatic history, with a side-by-side comparison and a change map to find differences. The current text is kept before restoring, and a restore can be undone. Automatic history keeps the latest 100 entries; named versions are kept indefinitely. Separate image files are not included.
- **Endnotes** — Add, edit and delete numbered references and notes from Format > Endnotes…. They are saved in Markdown footnote syntax and kept as plain numbered text in docx and hwpx exports.
- **Automatic work context** — Register your reference material and manuscript folders and the original text becomes searchable right away, while detailed summaries continue in the background. You can chat without waiting for all summaries; recent questions and the open document are processed first. AI looks up the settings and earlier chapters a request needs, and only changed parts are updated afterwards. There is no need to summarize files by hand to fit 500 KB. You can keep editing during preparation; status, retry and the number of on-device summaries/excerpts are shown in the work context window. Initial preparation runs on device with Foundation Models and does not use external AI quota (macOS 26 or later with Apple Intelligence). If the model is unavailable or a summary fails, search continues with excerpts, and text after the current chapter is never included in requests.
- **Compact AI composer** — Guidance/direct edit, model selection and send/stop live inside the input field. Enter sends, Shift+Enter inserts a line break, and confirming Hangul composition does not send. Usage is shown from the info button.
- **Markdown source view** — Switch the text area to read-only Markdown source to check and copy it. Switching back returns to the editor, including unsaved changes. **Inline Code** is a separate button that applies code formatting to the selection.
- **Ruler and side margins** — A Word-style centimeter ruler sits above the text. Drag the handles at either end to set the page's left and right margins; in two-page layout each page has its own ruler and both move together. Dragging a handle past the page edge widens the page (in book width), and double-clicking resets it. Width and margins are remembered like other view settings.
- **Documents on cloud drives** — While a document on iCloud Drive, Google Drive or another synced folder is downloading, opening several other files in a row shows only the last one you opened. Files that cannot be opened are reported, and files that cannot be read as UTF-8 are not opened as empty documents, so the original is never overwritten. The window may pause briefly while a file downloads.
- **Character count in the status bar** — Live character count at the bottom of the window.
- **docx and hwpx export** — Export notes to Word (`.docx`) and Hangul (`.hwpx`). No external tools or libraries: zip and XML are generated directly in pure Swift. (One-way export; the original `.md` is untouched.)
- **Line spacing and text color**, standard macOS shortcuts, and unsaved-change warnings.

## Installation

Download `JenaNote.dmg` from the [latest release](https://github.com/jenalab-com/jena-note/releases/latest) and drag the app into the **Applications** folder in the window that opens. (macOS 13 Ventura or later)

### ⚠️ First launch — "unidentified developer" / "is damaged and can't be opened"

JenaNote is a free app that is not signed or notarized through the Apple Developer program, so macOS Gatekeeper blocks it the first time. **The app is not damaged.** Open it with one of the methods below.

**Method 1 — Terminal (most reliable, all macOS versions)**

```bash
xattr -dr com.apple.quarantine /Applications/JenaNote.app
```

Then double-click the app as usual.

**Method 2 — System Settings (macOS 15 Sequoia or later)**

Double-click the app once → when it is blocked, go to **System Settings > Privacy & Security** → click **Open Anyway** next to "JenaNote was blocked" at the bottom → open it again.

**Method 3 — Right-click Open (macOS 13–14)**

In Finder, **right-click (or Control-click) the app → Open → Open**.

> After allowing it once, it opens normally with a double-click.

## Build from source

Requires Swift 5.7+ and Xcode. The Kiwi source is in `Vendor/Kiwi/source/`, where you can read and modify it; the app links a locally built XCFramework. For the first setup, install CMake and run `make bootstrap-kiwi` (it downloads the model with a pinned version and checksum only when it is missing). After that, `make build` and `make test` check readiness offline and use the local library. Run `make rebuild-kiwi` after changing the source. The model (about 104 MB) is bundled in the app; nothing is downloaded at runtime. See the [Kiwi development guide](Vendor/Kiwi/README.md) (Korean) for tool setup, offline copies and a source tour. Run `make prepare-kiwi` before calling `swift build` or `swift test` directly.

```bash
git clone https://github.com/jenalab-com/jena-note.git
cd jena-note

make build     # build .build/JenaNote.app
make run       # build and launch
make install   # install to ~/Applications
make dmg       # create a distributable .dmg
make test      # run tests
make clean     # remove build products
```

Apps you build yourself have no quarantine attribute, so the Gatekeeper steps above are not needed.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Save | ⌘S |
| Save As | ⇧⌘S |
| Bold | ⌘B |
| Italic | ⌘I |
| Link | ⌘K |
| Add Folder | ⇧⌘O |
| Toggle Sidebar | ⌥⌘S |
| Undo / Redo | ⌘Z / ⇧⌘Z |

## File format

- **Storage format**: UTF-8, CommonMark-compatible `.md` — renders the same in other viewers such as VS Code and GitHub.
- **Internal representation**: `NSAttributedString` ↔ Markdown serialization (on save) and parsing (on open).
- **Export**: `.docx` (OOXML) and `.hwpx` (OWPML) are one-way. The original `.md` is not changed.

## Project structure

```
Resources/
  Info.plist        bundle metadata
  Fonts/            serif body font (KoPub Batang, bundled with the app)
Sources/
  JenaNote/         executable entry point (main.swift)
  JenaNoteKit/
    app/            AppDelegate, settings, help, license window, localization
    ai/             CLI AI chat, work context index and search, on-device summaries
    document/       Markdown serialization/parsing, version history, endnotes
    editor/         editor views and window controller, format commands, page layout, ruler
    proofreading/   Kiwi proofreading engine, orthography rules, error highlighting, My Dictionary
    sidebar/        folder bookmarks, FSEvents watching, outline view
    statusbar/      bottom status bar (character count)
    toolbar/        unified toolbar and format buttons
    export/         docx and hwpx writers, document IR, direct zip/XML generation
  Resources/        Kiwi model (prepared at build time), third-party license notices
Vendor/Kiwi/        Kiwi 0.24.1 C++ source snapshot and local build guide
Tests/              JenaNoteKit unit tests
docs/               spec, architecture, development logs (devlog)
```

Planning and design are in [`docs/spec.md`](docs/spec.md) and [`docs/architecture.md`](docs/architecture.md); per-version changes are in [`docs/devlog/`](docs/devlog/) (Korean).

## License

[MIT](LICENSE) © 2026 JenaLab

### Kiwi Korean morphological analyzer

Text checking uses [Kiwi](https://github.com/bab2min/Kiwi) 0.24.1 and its base model (Apache-2.0). The unmodified source is included in `Vendor/Kiwi/source/`. Its notices, together with those of the libraries Kiwi links statically — Eigen (MPL-2.0), mimalloc, streamvbyte, cpp-btree and nlohmann/json — are available in the app under About Jena Note → Open Source Licenses.

### Bundled font

The serif body text of the unified editing view uses **KoPub Batang** (Medium, Bold), bundled with the app.
KoPub fonts are free fonts produced and distributed by the Korean Publishers Society, which holds the copyright.
See the full terms of use at [kopus.org](https://www.kopus.org/biz/electronic/font/).
