import AppKit

/// Portrait dimensions in millimeters; automatic preserves the existing reading layout.
enum DocumentPaperSize: String, CaseIterable {
    case automatic, a3, a4, a5, a6, b3, b4, b5, b6, jisB4, jisB5, letter, legal
    static let changed = Notification.Name("JenaNoteDocumentPaperSizeChanged")
    static var selected: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: "jn_documentPaperSize") ?? "") ?? .automatic }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "jn_documentPaperSize")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    var millimeters: NSSize? {
        switch self {
        case .automatic: return nil
        case .a3: return NSSize(width: 297, height: 420)
        case .a4: return NSSize(width: 210, height: 297)
        case .a5: return NSSize(width: 148, height: 210)
        case .a6: return NSSize(width: 105, height: 148)
        case .b3: return NSSize(width: 353, height: 500)
        case .b4: return NSSize(width: 250, height: 353)
        case .b5: return NSSize(width: 176, height: 250)
        case .b6: return NSSize(width: 125, height: 176)
        case .jisB4: return NSSize(width: 257, height: 364)
        case .jisB5: return NSSize(width: 182, height: 257)
        case .letter: return NSSize(width: 215.9, height: 279.4)
        case .legal: return NSSize(width: 215.9, height: 355.6)
        }
    }
    var points: NSSize? {
        millimeters.map { NSSize(width: $0.width * 72 / 25.4, height: $0.height * 72 / 25.4) }
    }
    var title: String {
        guard let size = millimeters else { return L10n.tr("paperSize.automatic") }
        let name: String
        switch self {
        case .jisB4: name = "B4 (JIS)"
        case .jisB5: name = "B5 (JIS)"
        case .b3, .b4, .b5, .b6: name = rawValue.uppercased() + " (ISO)"
        case .letter: name = "Letter"
        case .legal: name = "Legal"
        default: name = rawValue.uppercased()
        }
        return name + String(format: " · %g × %g mm", Double(size.width), Double(size.height))
    }
}
