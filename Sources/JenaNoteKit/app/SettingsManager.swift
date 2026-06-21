import AppKit

// MARK: - Settings Manager

final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let language = "jn_language"
        static let appearance = "jn_appearance"
        static let readingPageMode = "jn_readingPageMode"
        static let readingFontScale = "jn_readingFontScale"
        static let readingLineLength = "jn_readingLineLength"
    }

    // MARK: - Language

    enum Language: String, CaseIterable {
        case ko = "ko"
        case en = "en"
        case zh = "zh"
        case ja = "ja"
        case es = "es"
        case de = "de"
        case fr = "fr"

        var displayName: String {
            switch self {
            case .ko: return "한국어"
            case .en: return "English"
            case .zh: return "中文"
            case .ja: return "日本語"
            case .es: return "Español"
            case .de: return "Deutsch"
            case .fr: return "Français"
            }
        }
    }

    // MARK: - Reading Mode

    enum ReadingPageMode: String, CaseIterable {
        case scroll = "scroll"
        case paged  = "paged"
    }

    // MARK: - Appearance

    enum AppearanceMode: String, CaseIterable {
        case system = "system"
        case light  = "light"
        case dark   = "dark"

        var displayName: String {
            return L10n.tr(self.locKey)
        }

        var locKey: String {
            switch self {
            case .system: return "appearance.system"
            case .light:  return "appearance.light"
            case .dark:   return "appearance.dark"
            }
        }
    }

    var language: Language {
        get {
            guard let raw = defaults.string(forKey: Key.language),
                  let lang = Language(rawValue: raw) else { return .ko }
            return lang
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.language)
            NotificationCenter.default.post(name: .settingsLanguageChanged, object: nil)
        }
    }

    var appearanceMode: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: Key.appearance),
                  let mode = AppearanceMode(rawValue: raw) else { return .system }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    var readingPageMode: ReadingPageMode {
        get {
            guard let raw = defaults.string(forKey: Key.readingPageMode),
                  let mode = ReadingPageMode(rawValue: raw) else { return .scroll }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.readingPageMode) }
    }

    var readingFontScale: CGFloat {
        get {
            let v = defaults.object(forKey: Key.readingFontScale) as? Double
            return CGFloat(v ?? 1.0)
        }
        set {
            let clamped = min(max(newValue, 0.8), 2.0)
            defaults.set(Double(clamped), forKey: Key.readingFontScale)
        }
    }

    var readingLineLength: Int {
        get {
            let v = defaults.object(forKey: Key.readingLineLength) as? Int
            return v ?? 35
        }
        set { defaults.set(newValue, forKey: Key.readingLineLength) }
    }

    // MARK: - Apply

    func applyAppearance() {
        switch appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let settingsLanguageChanged = Notification.Name("jn_settingsLanguageChanged")
}
