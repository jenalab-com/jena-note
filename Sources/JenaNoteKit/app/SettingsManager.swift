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
        static let readingFont = "jn_readingFont"
        static let readingWeight = "jn_readingWeight"
        static let readingLineSpacing = "jn_readingLineSpacing"
        static let sidebarSortKey = "jn_sidebarSortKey"
        static let sidebarSortOrder = "jn_sidebarSortOrder"
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

    /// 읽기 모드 본문 글꼴.
    ///
    /// `serif`/`sans` 는 서체를 특정하지 않는 "자동" — 설치 상황에 따라 후보 체인에서
    /// 고른다. 구버전 설정값("serif"/"sans")이 그대로 살아 있으므로 케이스를 지우지 않는다.
    /// 나머지는 사용자가 툴바에서 직접 고른 서체다.
    ///
    /// 실제 서체 해석(패밀리 후보·설치 여부)은 `ReaderMetrics` 가 맡는다 — 설정은
    /// 무엇을 골랐는지만 알고, 그것이 어떤 폰트인지는 모른다.
    enum ReadingFont: String, CaseIterable {
        case serif = "serif"   // 자동: 명조 계열
        case sans  = "sans"    // 자동: 고딕 계열 (시스템)

        case kopubBatang        = "kopubBatang"
        case nanumMyeongjo      = "nanumMyeongjo"
        case kimjungchulMyungjo = "kimjungchulMyungjo"
        case appleMyungjo       = "appleMyungjo"

        case appleGothicNeo = "appleGothicNeo"
        case nanumGothic    = "nanumGothic"
        case notoSansKR     = "notoSansKR"
        case pretendard     = "pretendard"

        var locKey: String { "reader.font.\(rawValue)" }
    }

    /// 읽기 모드 본문 굵기.
    ///
    /// `bold` 는 조판 전용 굵기일 뿐 마크다운 `**볼드**` 가 아니다 — 이 둘을 섞지 않는 처리가
    /// `ReaderMetrics` 에 있다(`.mdReaderBold`). 없으면 읽기 모드에서 새로 친 글자가
    /// 저장 시 통째로 볼드 마크업이 되어 문서가 오염된다.
    enum ReadingWeight: String, CaseIterable {
        case light   = "light"
        case regular = "regular"
        case bold    = "bold"

        /// `NSFontManager` 굵기 척도(0~15). 서체에 없는 굵기는 가장 가까운 것으로 대체된다.
        var fontManagerWeight: Int {
            switch self {
            case .light:   return 3
            case .regular: return 5
            case .bold:    return 9
            }
        }

        var locKey: String { "reader.weight.\(rawValue)" }
    }

    // MARK: - Sidebar Sort

    /// 사이드바 파일·폴더 정렬 기준.
    enum SidebarSortKey: String, CaseIterable {
        case name = "name"   // 이름순
        case date = "date"   // 수정일순
    }

    /// 정렬 방향.
    enum SidebarSortOrder: String, CaseIterable {
        case ascending  = "asc"   // 오름차순 (이름 A→Z / 날짜 과거→최근)
        case descending = "desc"  // 내림차순 (이름 Z→A / 날짜 최근→과거)
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

    var readingFont: ReadingFont {
        get {
            guard let raw = defaults.string(forKey: Key.readingFont),
                  let f = ReadingFont(rawValue: raw) else { return .serif }
            return f
        }
        set { defaults.set(newValue.rawValue, forKey: Key.readingFont) }
    }

    var readingWeight: ReadingWeight {
        get {
            guard let raw = defaults.string(forKey: Key.readingWeight),
                  let w = ReadingWeight(rawValue: raw) else { return .regular }
            return w
        }
        set { defaults.set(newValue.rawValue, forKey: Key.readingWeight) }
    }

    /// 본문 줄 높이 배수. 기본 1.5(넉넉하게), 범위 1.0~2.5.
    var readingLineSpacing: CGFloat {
        get {
            let v = defaults.object(forKey: Key.readingLineSpacing) as? Double
            return CGFloat(v ?? 1.5)
        }
        set {
            let clamped = min(max(newValue, 1.0), 2.5)
            defaults.set(Double(clamped), forKey: Key.readingLineSpacing)
        }
    }

    var sidebarSortKey: SidebarSortKey {
        get {
            guard let raw = defaults.string(forKey: Key.sidebarSortKey),
                  let key = SidebarSortKey(rawValue: raw) else { return .name }
            return key
        }
        set { defaults.set(newValue.rawValue, forKey: Key.sidebarSortKey) }
    }

    var sidebarSortOrder: SidebarSortOrder {
        get {
            guard let raw = defaults.string(forKey: Key.sidebarSortOrder),
                  let order = SidebarSortOrder(rawValue: raw) else { return .ascending }
            return order
        }
        set { defaults.set(newValue.rawValue, forKey: Key.sidebarSortOrder) }
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
