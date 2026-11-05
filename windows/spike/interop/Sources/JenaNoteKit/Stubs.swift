import Foundation

// Stand-ins for types whose real files are not portable yet.
// AIError lives in AIProcess.swift (imports Darwin). L10n lives in Localization.swift,
// which reads SettingsManager (imports AppKit).
struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum L10n {
    static func tr(_ key: String) -> String { key }
}
