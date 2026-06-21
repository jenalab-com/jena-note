import AppKit

class HelpWindowController: NSWindowController {

    static let shared = HelpWindowController()

    private var textView: NSTextView!
    private var languageObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("help.title")
        window.center()
        window.minSize = NSSize(width: 480, height: 400)

        super.init(window: window)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        window.contentView = scrollView

        textView.textStorage?.setAttributedString(buildHelp())

        languageObserver = NotificationCenter.default.addObserver(
            forName: .settingsLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshContent()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let obs = languageObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func show() {
        refreshContent()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func refreshContent() {
        window?.title = L10n.tr("help.title")
        textView.textStorage?.setAttributedString(buildHelp())
    }

    // MARK: - Content

    private func buildHelp() -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(h1(L10n.tr("help.title")))
        result.append(body(L10n.tr("help.intro")))
        result.append(spacer())

        result.append(h2(L10n.tr("help.file")))
        result.append(item(L10n.tr("help.file.new"), detail: L10n.tr("help.file.new.d")))
        result.append(item(L10n.tr("help.file.open"), detail: L10n.tr("help.file.open.d")))
        result.append(item(L10n.tr("help.file.save"), detail: L10n.tr("help.file.save.d")))
        result.append(item(L10n.tr("help.file.saveAs"), detail: L10n.tr("help.file.saveAs.d")))
        result.append(item(L10n.tr("help.file.recent"), detail: L10n.tr("help.file.recent.d")))
        result.append(spacer())

        result.append(h2(L10n.tr("help.format")))
        result.append(body(L10n.tr("help.format.intro")))
        result.append(spacer(height: 6))

        result.append(h3(L10n.tr("help.format.inline")))
        result.append(shortcut(L10n.tr("help.format.bold"), key: "⌘B"))
        result.append(shortcut(L10n.tr("help.format.italic"), key: "⌘I"))
        result.append(shortcut(L10n.tr("help.format.code"), key: L10n.tr("help.format.code.d")))
        result.append(shortcut(L10n.tr("help.format.link"), key: L10n.tr("help.format.link.d")))
        result.append(spacer(height: 6))

        result.append(h3(L10n.tr("help.format.para")))
        result.append(shortcut(L10n.tr("help.format.body"), key: L10n.tr("help.format.body.d")))
        result.append(shortcut(L10n.tr("help.format.h1"), key: L10n.tr("help.format.h1.d")))
        result.append(shortcut(L10n.tr("help.format.h2"), key: L10n.tr("help.format.h2.d")))
        result.append(shortcut(L10n.tr("help.format.h3"), key: L10n.tr("help.format.h3.d")))
        result.append(shortcut(L10n.tr("help.format.ul"), key: L10n.tr("help.format.ul.d")))
        result.append(shortcut(L10n.tr("help.format.ol"), key: L10n.tr("help.format.ol.d")))
        result.append(shortcut(L10n.tr("help.format.quote"), key: L10n.tr("help.format.quote.d")))
        result.append(shortcut(L10n.tr("help.format.hr"), key: L10n.tr("help.format.hr.d")))
        result.append(spacer())

        result.append(h2(L10n.tr("help.spacing")))
        result.append(body(L10n.tr("help.spacing.d")))
        result.append(spacer())

        result.append(h2(L10n.tr("help.edit")))
        result.append(shortcut(L10n.tr("help.edit.undo"), key: "⌘Z"))
        result.append(shortcut(L10n.tr("help.edit.redo"), key: "⇧⌘Z"))
        result.append(shortcut(L10n.tr("help.edit.cut"), key: "⌘X"))
        result.append(shortcut(L10n.tr("help.edit.copy"), key: "⌘C"))
        result.append(shortcut(L10n.tr("help.edit.paste"), key: "⌘V"))
        result.append(shortcut(L10n.tr("help.edit.pastePlain"), key: "⇧⌘V"))
        result.append(shortcut(L10n.tr("help.edit.selectAll"), key: "⌘A"))
        result.append(shortcut(L10n.tr("help.edit.find"), key: "⌘F"))
        result.append(spacer())

        result.append(h2(L10n.tr("help.fileFormat")))
        result.append(body(L10n.tr("help.fileFormat.d")))
        result.append(spacer())

        return result
    }

    // MARK: - Style Helpers

    private func h1(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
    }

    private func h2(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 8
        para.paragraphSpacing = 4
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
    }

    private func h3(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 4
        para.paragraphSpacing = 2
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ])
    }

    private func body(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 2
        para.lineSpacing = 3
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
    }

    private func item(_ title: String, detail: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.headIndent = 16
        para.firstLineHeadIndent = 0
        para.paragraphSpacing = 3
        para.lineSpacing = 2
        result.append(NSAttributedString(string: "• ", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]))
        result.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]))
        result.append(NSAttributedString(string: " — " + detail + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]))
        return result
    }

    private func shortcut(_ label: String, key: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.headIndent = 120
        para.firstLineHeadIndent = 16
        para.tabStops = [NSTextTab(type: .leftTabStopType, location: 120)]
        para.paragraphSpacing = 3

        result.append(NSAttributedString(string: "  " + label + "\t", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]))
        result.append(NSAttributedString(string: key + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]))
        return result
    }

    private func spacer(height: CGFloat = 12) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = height
        para.maximumLineHeight = height
        return NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .paragraphStyle: para
        ])
    }
}
