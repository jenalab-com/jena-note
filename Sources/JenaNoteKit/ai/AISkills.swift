import Foundation

/// 채팅에서 쓸 수 있는 CLI 스킬 하나 — 스킬 폴더(SKILL.md 가 든 곳) 기준.
struct AISkill: Equatable {
    /// 폴더 이름 = CLI 가 부르는 이름
    let name: String
    /// SKILL.md 머리말의 description (메뉴 툴팁용)
    let summary: String
    let directory: URL
}

/// 요청 하나에 스킬을 어떻게 열지.
/// 채팅만 `.auto`/`.use` 를 쓰고, 내부 요청(문장 검사·자료 검색·연결 확인)은 늘 `.off` 로 격리한다.
enum AISkillMode: Equatable {
    case off
    /// 스킬을 켜두고 고르는 건 AI 에게 맡긴다
    case auto
    /// 이 스킬을 먼저 불러 따르게 한다
    case use(String)

    var isEnabled: Bool { self != .off }
}

/// CLI 별 스킬 위치와 부르는 방법.
enum AISkillCatalog {
    /// Claude Code 에는 사용자 스킬을 이 이름의 임시 플러그인으로 넘긴다(--plugin-dir).
    static let claudePluginName = "jenanote-user-skills"

    static func supportsSkills(_ provider: AIProvider) -> Bool {
        [.claude, .codex, .gemini].contains(provider)
    }

    static func roots(for provider: AIProvider,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        func dir(_ path: String) -> URL { home.appendingPathComponent(path, isDirectory: true) }
        switch provider {
        case .claude: return [dir(".claude/skills")]
        case .codex: return [dir(".codex/skills"), dir(".agents/skills")]
        case .gemini: return [dir(".gemini/skills"), dir(".agents/skills")]
        case .grok, .local: return []
        }
    }

    /// 각 위치의 하위 폴더 중 SKILL.md 가 있는 것. 이름이 겹치면 앞선 위치가 이긴다.
    static func skills(for provider: AIProvider,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AISkill] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [AISkill] = []
        for root in roots(for: provider, home: home) {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                let directory = entry.resolvingSymlinksInPath()
                let manifest = directory.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: manifest.path), seen.insert(entry.lastPathComponent).inserted else { continue }
                let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
                result.append(AISkill(name: entry.lastPathComponent,
                                      summary: frontMatterValue("description", in: text) ?? "",
                                      directory: directory))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `---` 로 둘러싼 머리말에서 한 줄짜리 값을 꺼낸다.
    static func frontMatterValue(_ key: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        let body = Array(lines.dropFirst())
        for (index, line) in body.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard trimmed.hasPrefix(key + ":") else { continue }
            var value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            // YAML 여러 줄 값(`>` 접기, `|` 그대로) — 이어지는 들여쓴 줄을 한 줄로 모은다.
            if [">", ">-", ">+", "|", "|-", "|+"].contains(value) {
                var parts: [String] = []
                for next in body[(index + 1)...] {
                    guard next.first == " " || next.first == "\t" || next.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                    if next.trimmingCharacters(in: .whitespaces) == "---" { break }
                    let piece = next.trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { parts.append(piece) }
                }
                value = parts.joined(separator: " ")
            }
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 목록에서 고른 스킬을 쓰게 하는 지시 — 요청 맨 앞에 붙인다. CLI 마다 부르는 방식이 다르다.
    static func instruction(for skill: String, provider: AIProvider) -> String? {
        switch provider {
        case .claude:
            return "Before answering, use the Skill tool to load the `\(claudePluginName):\(skill)` skill and follow its instructions for this request."
        case .codex:
            return "Before answering, use the $\(skill) skill: read its SKILL.md and follow its instructions for this request."
        case .gemini:
            return "Before answering, call activate_skill for the `\(skill)` skill and follow its instructions for this request."
        case .grok, .local:
            return nil
        }
    }

    /// Claude Code 용 임시 플러그인 — 사용자 스킬 폴더를 심볼릭 링크로 모은다.
    /// --safe-mode 는 사용자 스킬까지 막으므로, 대신 --setting-sources "" 로 개인 설정·훅·CLAUDE.md 를
    /// 끄고 스킬만 이 플러그인으로 명시해 넘긴다.
    static func makeClaudePlugin(in directory: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let fm = FileManager.default
        let plugin = directory.appendingPathComponent("skills-plugin", isDirectory: true)
        let manifestDirectory = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
        let skillsDirectory = plugin.appendingPathComponent("skills", isDirectory: true)
        try fm.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        try "{\"name\":\"\(claudePluginName)\",\"version\":\"1.0.0\"}"
            .write(to: manifestDirectory.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        for skill in skills(for: .claude, home: home) {
            try fm.createSymbolicLink(at: skillsDirectory.appendingPathComponent(skill.name),
                                      withDestinationURL: skill.directory)
        }
        return plugin
    }
}
