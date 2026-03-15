# Jena Note

A native macOS WYSIWYG Markdown editor. Write without seeing Markdown symbols — formatting is applied directly as you type and saved as standard `.md` files.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-blue)

---

## Features

- **WYSIWYG editing** — Bold, italic, headings, lists, blockquotes, code, and links render inline without Markdown symbols
- **CommonMark compatible** — Saves as standard `.md` files readable by any Markdown tool
- **Plain text support** — Opens and saves `.txt` files as plain text
- **Recent documents** — Quick access to recently opened files; last document restores on relaunch
- **Line spacing** — Adjustable 1×, 1.5×, 2× via toolbar
- **Native macOS** — Built with AppKit, NSDocument architecture, full Undo/Redo, autosave, and Retina support

### Supported Formatting

| Format | Toolbar | Shortcut |
|--------|---------|----------|
| Bold | ✓ | ⌘B |
| Italic | ✓ | ⌘I |
| Inline Code | ✓ | — |
| Heading 1 | ✓ | — |
| Heading 2 | ✓ | — |
| Heading 3 | ✓ | — |
| Unordered List | ✓ | — |
| Ordered List | ✓ | — |
| Blockquote | ✓ | — |
| Link | ✓ | ⌘K |
| Horizontal Rule | ✓ | — |
| Code Block | — | — |
| Table | — | — |

---

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`)

---

## Build

```bash
# Build .app bundle
make build

# Build and run
make run

# Install to ~/Applications
make install

# Create .pkg installer
make pkg

# Clean build artifacts
make clean
```

The app bundle is output to `.build/JenaNote.app`.

---

## Project Structure

```
Sources/
  app/
    main.swift                  — Entry point
    AppDelegate.swift           — App lifecycle, menu setup
    HelpWindowController.swift  — Help window
  document/
    MarkdownDocument.swift      — NSDocument subclass
    MarkdownSerializer.swift    — NSAttributedString ↔ CommonMark
    SyntaxHighlighter.swift     — Syntax highlighting
  editor/
    EditorWindowController.swift
    EditorViewController.swift
    EditorTextView.swift
    FormatCommands.swift
  toolbar/
    FormatToolbar.swift
Resources/
  Info.plist
  JenaNote.icns
```

---

## Architecture

Jena Note follows the standard macOS **NSDocument architecture**:

- `MarkdownDocument` (NSDocument) is the single source of truth for document content
- `MarkdownSerializer` handles bidirectional conversion between `NSAttributedString` and CommonMark `.md`
- UI layer communicates only through `MarkdownDocument` — no direct file I/O in views
- Undo/Redo, autosave, window restoration, and unsaved-changes warnings are handled automatically by AppKit

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

Made by [@jenalab](https://www.jenalab.com)
