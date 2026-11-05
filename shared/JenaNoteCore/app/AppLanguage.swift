import Foundation

public enum AppLanguage: String, CaseIterable {
    case ko = "ko"
    case en = "en"
    case zh = "zh"
    case ja = "ja"
    case es = "es"
    case de = "de"
    case fr = "fr"

    public var displayName: String {
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

    private static let defaultsKey = "jn_language"

    /// The saved UI language. L10n reads it on every lookup, so a change applies immediately.
    public static var current: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let language = AppLanguage(rawValue: raw) else { return .ko }
            return language
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
