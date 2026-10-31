import AppKit

/// Shows the bundled third-party license notices (`Resources/ThirdParty`) inside the app.
final class AcknowledgementsWindowController: NSWindowController {

    static let shared = AcknowledgementsWindowController()

    private var textView: NSTextView!
    private var languageObserver: NSObjectProtocol?

    /// `Contents/Resources/ThirdParty` in the app bundle, or the SwiftPM resource during development.
    static func noticesURL() -> URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        return Bundle.module.url(forResource: "ThirdParty", withExtension: nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("about.licenses")
        window.center()
        window.minSize = NSSize(width: 480, height: 400)

        super.init(window: window)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        window.contentView = scrollView

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
        window?.title = L10n.tr("about.licenses")
        textView.textStorage?.setAttributedString(Self.buildNotices(from: Self.noticesURL()))
        textView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - Content

    /// One section per component folder; inside it the summary (README), NOTICE and LICENSE come
    /// first, then the remaining dependency licenses alphabetically. Texts are shown verbatim.
    static func buildNotices(from root: URL?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: L10n.tr("about.licenses") + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.labelColor
        ]))
        result.append(NSAttributedString(string: L10n.tr("about.licenses.intro") + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        guard let root else { return result }
        let fm = FileManager.default
        let components = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let leading = ["README.txt", "NOTICE", "LICENSE"]
        for component in components {
            result.append(NSAttributedString(string: "\n" + component.lastPathComponent + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.labelColor
            ]))
            let files = ((try? fm.contentsOfDirectory(at: component, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted {
                    let (a, b) = (leading.firstIndex(of: $0.lastPathComponent) ?? leading.count,
                                  leading.firstIndex(of: $1.lastPathComponent) ?? leading.count)
                    return a != b ? a < b : $0.lastPathComponent < $1.lastPathComponent
                }
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                result.append(NSAttributedString(string: "\n" + file.lastPathComponent + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor
                ]))
                result.append(NSAttributedString(string: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.labelColor
                ]))
            }
        }
        return result
    }
}
