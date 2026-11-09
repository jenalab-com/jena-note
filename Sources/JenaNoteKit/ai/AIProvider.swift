import Foundation

extension AIProvider {
    var environmentOverrides: [String: String] {
        self == .grok ? ["GROK_HOME": AISettings.grokProfile.path] : [:]
    }

    var installCommand: String {
        switch self {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .grok: return "curl -fsSL https://x.ai/cli/install.sh | bash"
        case .codex: return "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        case .gemini:
            let package = "@google/gemini-cli"
            let brew = "brew install gemini-cli"
            return "if command -v npm >/dev/null 2>&1; then npm install -g \(package); elif command -v brew >/dev/null 2>&1; then \(brew); else echo 'Install Node.js (https://nodejs.org) or Homebrew (https://brew.sh), then retry.'; exit 1; fi"
        }
    }
}

/// Credentials stay with the CLI. Store only UI choices and executable paths.
enum AISettings {
    /// Grok has no invocation-only native hook switch. Keep its writing profile separate,
    /// with explicit CLI login; never copy credentials or modify the user's ~/.grok files.
    static var grokProfile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("JenaNote/GrokCLI", isDirectory: true)
    }

    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ai.provider") }
    }
    static func customPath(for provider: AIProvider) -> String {
        UserDefaults.standard.string(forKey: "ai.path.\(provider.rawValue)") ?? ""
    }
    static func setPath(_ path: String, for provider: AIProvider) {
        UserDefaults.standard.set(path.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.path.\(provider.rawValue)")
    }

    static func model(for provider: AIProvider) -> String {
        UserDefaults.standard.string(forKey: "ai.model.\(provider.rawValue)") ?? ""
    }
    static func setModel(_ model: String, for provider: AIProvider) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.model.\(provider.rawValue)")
    }

    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        paths += ["\(home)/.local/bin", "\(home)/.grok/bin", "\(home)/.cargo/bin", "\(home)/.npm-global/bin",
                  "\(home)/.volta/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        return paths.filter { !$0.isEmpty }
    }

    static func executable(for provider: AIProvider) -> URL? {
        let custom = customPath(for: provider)
        let candidates = custom.isEmpty ? searchDirectories.map { "\($0)/\(provider.rawValue)" }
            : [(custom as NSString).expandingTildeInPath]
        return candidates.first(where: { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }).map { URL(fileURLWithPath: $0) }
    }
}
