import AppKit

// MARK: - Settings Manager

final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let language = "jn_language"
        static let appearance = "jn_appearance"
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
