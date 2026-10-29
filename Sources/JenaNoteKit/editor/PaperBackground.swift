import AppKit

/// View-only colors: never add these to a document's attributed text.
enum PaperBackground: String, CaseIterable {
    case standard, sepia, green, gray
    static let changed = Notification.Name("JenaNotePaperBackgroundChanged")
    static var selected: PaperBackground {
        get { PaperBackground(rawValue: UserDefaults.standard.string(forKey: "jn_paperBackground") ?? "") ?? .standard }
        set {
            UserDefaults.standard.removeObject(forKey: "jn_paperBackgroundColor")
            UserDefaults.standard.set(newValue.rawValue, forKey: "jn_paperBackground")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    /// Custom sRGB colors take precedence; legacy presets remain readable.
    static var currentColor: NSColor {
        get {
            guard let values = UserDefaults.standard.array(forKey: "jn_paperBackgroundColor") as? [Double],
                  values.count == 3, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return selected.color }
            return NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: 1)
        }
        set {
            guard let color = newValue.usingColorSpace(.sRGB) else { return }
            UserDefaults.standard.set([Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)], forKey: "jn_paperBackgroundColor")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    var title: String { L10n.tr("paper." + rawValue) }
    var color: NSColor {
        guard self != .standard else { return .textBackgroundColor }
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            switch self {
            case .sepia: return MarkdownColor.fromHex(dark ? "#302B24" : "#F5EFDF")!
            case .green: return MarkdownColor.fromHex(dark ? "#243029" : "#E8F1E7")!
            case .gray: return MarkdownColor.fromHex(dark ? "#292B2E" : "#EAECEE")!
            case .standard: return .textBackgroundColor
            }
        }
    }
}
