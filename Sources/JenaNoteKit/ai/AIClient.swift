import Foundation

final class AIClient {
    private let process = AIProcess()
    static let defaultTimeout: TimeInterval = 120
    static let summaryTimeout: TimeInterval = 240
    /// A 12B model on an M1 produces about 10 tokens/s, and it reasons before it answers.
    static let localTimeout: TimeInterval = 600
    private(set) var tokenUsage: Int?
    /// Claude 가 돌려준 세션 — 승인 후 같은 세션을 이어갈 때 쓴다.
    private(set) var sessionID: String?
    /// 권한이 없어 막힌 도구들 (Claude). 채팅에서 승인받을 목록.
    private(set) var deniedTools: [AIToolRequest] = []
    /// 이번 요청이 모델 컨텍스트를 얼마나 채웠는지 — 다음 요청도 대화 전체를 다시 보내므로 그 크기의 지표다.
    private(set) var contextUsage: AIContextUsage?
    private var localTask: URLSessionDataTask?
    func cancel() { process.cancel(); localTask?.cancel() }

    /// 스킬은 도구를 거쳐 여러 차례 오가므로 한 번에 끝나는 요청보다 넉넉히 기다린다.
    static let skillTimeout: TimeInterval = 300

    /// Claude 를 도구와 함께 돌릴 고정 작업 폴더 — 세션을 이어가려면(--resume) 같은 폴더여야 한다.
    /// 늘 비어 있는 폴더이고, 원고 폴더는 --add-dir 로만 연다.
    static var claudeWorkDirectory: URL {
        AISettings.applicationSupport.appendingPathComponent("AIWork", isDirectory: true)
    }

    func send(provider: AIProvider, prompt: String, model: String? = nil, timeout: TimeInterval = AIClient.defaultTimeout,
              access: AIToolAccess = AIToolAccess(),
              completion: @escaping (Result<String, Error>) -> Void) {
        var access = access
        if !AISkillCatalog.supportsSkills(provider) { access.skills = .off }
        let skills = access.skills
        if provider == .local {
            sendToLocalServer(prompt: prompt, model: model, timeout: max(timeout, Self.localTimeout), completion: completion)
            return
        }
        guard let executable = AISettings.executable(for: provider) else {
            completion(.failure(AIError(message: L10n.tr("ai.notInstalled"))))
            return
        }
        do {
            if provider == .grok {
                try FileManager.default.createDirectory(at: AISettings.grokProfile, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JenaNote-AI-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let policy = directory.appendingPathComponent("deny-tools.toml")
            try Self.geminiPolicy(access: access).write(to: policy, atomically: true, encoding: .utf8)
            let geminiDirectory = directory.appendingPathComponent(".gemini", isDirectory: true)
            try FileManager.default.createDirectory(at: geminiDirectory, withIntermediateDirectories: true)
            try Self.geminiSettings(access: access).write(
                to: geminiDirectory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            let plugin = (provider == .claude && skills.isEnabled) ? try AISkillCatalog.makeClaudePlugin(in: directory) : nil
            var workingDirectory = directory
            if provider == .claude && skills.isEnabled {
                workingDirectory = Self.claudeWorkDirectory
                try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            process.run(executable: executable,
                        arguments: Self.arguments(for: provider, policy: policy, model: model,
                                                  access: access, skillPlugin: plugin),
                        input: prompt, directory: workingDirectory,
                        timeout: skills.isEnabled ? max(timeout, Self.skillTimeout) : timeout,
                        environmentOverrides: provider.environmentOverrides) { result in
                // This folder is created solely for this request, never the user's note folder.
                try? FileManager.default.removeItem(at: directory)
                completion(result.flatMap { output in
                    Result {
                        self.tokenUsage = Self.tokens(from: output.stdout, provider: provider)
                        (self.sessionID, self.deniedTools) = Self.permissionState(from: output.stdout, provider: provider)
                        self.contextUsage = Self.contextUsage(from: output.stdout, provider: provider, model: model)
                        return try Self.answer(from: output, provider: provider)
                    }
                })
            }
        } catch { completion(.failure(error)) }
    }

    private func sendToLocalServer(prompt: String, model: String?, timeout: TimeInterval,
                                   completion: @escaping (Result<String, Error>) -> Void) {
        guard let server = AISettings.localServerURL else {
            completion(.failure(AIError(message: L10n.tr("ai.local.invalidAddress")))); return
        }
        do {
            let request = try Self.localRequest(server: server, prompt: prompt, model: model, timeout: timeout)
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    completion(Result {
                        if let error { throw Self.localFailure(error) }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let reply = try Self.localReply(from: data ?? Data(), status: status)
                        self.tokenUsage = reply.tokens
                        return reply.text
                    })
                }
            }
            localTask = task
            task.resume()
        } catch { completion(.failure(error)) }
    }

    static func localRequest(server: URL, prompt: String, model: String?, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent("v1/chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["messages": [["role": "user", "content": prompt]], "stream": false]
        if let model, !model.isEmpty { body["model"] = model }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func localFailure(_ error: Error) -> AIError {
        switch (error as? URLError)?.code {
        case .cancelled: return AIError(message: L10n.tr("ai.cancelled"))
        case .timedOut: return AIError(message: L10n.tr("ai.local.timeout"))
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return AIError(message: L10n.tr("ai.local.notRunning"))
        default: return AIError(message: error.localizedDescription)
        }
    }

    static func localReply(from data: Data, status: Int) throws -> (text: String, tokens: Int?) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let detail = (root?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(1800), as: UTF8.self)
            throw AIError(message: L10n.tr("ai.local.requestFailed") + "\n" + detail)
        }
        let choice = (root?["choices"] as? [[String: Any]])?.first
        // Reasoning arrives in `reasoning_content`; only the final answer belongs in the chat.
        guard let text = (choice?["message"] as? [String: Any])?["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError(message: L10n.tr("ai.invalidResponse"))
        }
        return (text, (root?["usage"] as? [String: Any])?["total_tokens"] as? Int)
    }

    /// Gemini 는 일회성 실행에서 승인을 받을 수 없다 — 모드가 허용한 도구만 열고 나머지는 거부한다.
    static let geminiReadTools = ["activate_skill", "read_file", "read_many_files", "glob", "search_file_content", "list_directory"]
    /// 편집 허용부터 여는 도구 — 파일 쓰기·고치기
    static let geminiEditTools = ["write_file", "replace"]
    /// 전체 액세스에서만 여는 도구 — 셸(스크립트 실행)
    static let geminiRunTools = ["run_shell_command"]

    static func geminiTools(access: AIToolAccess) -> [String] {
        guard access.skills.isEnabled else { return [] }
        switch access.permission {
        case .approval: return geminiReadTools
        case .edit: return geminiReadTools + geminiEditTools
        case .full: return geminiReadTools + geminiEditTools + geminiRunTools
        }
    }

    static func geminiPolicy(access: AIToolAccess) -> String {
        let deny = "[[rule]]\ntoolName = \"*\"\ndecision = \"deny\"\npriority = 999\n"
        let allow = geminiTools(access: access).map { "[[rule]]\ntoolName = \"\($0)\"\ndecision = \"allow\"\npriority = 1000\n" }
        return (allow + [deny]).joined(separator: "\n")
    }

    static func geminiSettings(access: AIToolAccess) -> String {
        let core = geminiTools(access: access).map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"hooksConfig\":{\"enabled\":false},\"mcp\":{\"allowed\":[]},\"tools\":{\"core\":[\(core)]}}"
    }

    /// Claude JSON 결과에서 세션 ID 와 막힌 도구를 꺼낸다. 다른 CLI 는 승인 흐름이 없다.
    static func permissionState(from text: String, provider: AIProvider) -> (String?, [AIToolRequest]) {
        guard provider == .claude,
              let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return (nil, []) }
        let denials = (root["permission_denials"] as? [[String: Any]] ?? []).compactMap(AIToolRequest.from(denial:))
        // 같은 도구·대상이 여러 번 막혔어도 한 번만 묻는다.
        var seen = Set<String>()
        return (root["session_id"] as? String, denials.filter { seen.insert($0.tool + "\u{0}" + $0.detail).inserted })
    }

    static func arguments(for provider: AIProvider, policy: URL, model: String? = nil,
                          access: AIToolAccess = AIToolAccess(), skillPlugin: URL? = nil) -> [String] {
        let base = access.skills.isEnabled
            ? skillArguments(for: provider, policy: policy, plugin: skillPlugin, access: access)
            : baseArguments(for: provider, policy: policy)
        guard let model = model, !model.isEmpty else { return base }
        // Insert before stdin's positional '-' and pass as one argv value, never shell code.
        if provider == .codex { return Array(base.dropLast()) + ["--model", model, "-"] }
        return base + ["--model", model]
    }

    private static func baseArguments(for provider: AIProvider, policy: URL) -> [String] {
        switch provider {
        case .claude:
            return ["-p", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                    "--disable-slash-commands", "--no-session-persistence", "--safe-mode"]
        case .codex:
            return ["-a", "never", "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
                    "--sandbox", "read-only", "--skip-git-repo-check", "--disable", "shell_tool", "--disable", "hooks", "--disable", "multi_agent", "--disable", "apps",
                    "-c", "web_search=\"disabled\"", "--json", "-"]
        case .gemini:
            return ["--prompt", "Follow the request on stdin.", "--output-format", "json",
                    "--approval-mode", "plan", "--policy", policy.path, "--extensions", "none", "--skip-trust"]
        case .grok:
            return ["--prompt-file", "/dev/stdin", "--output-format", "json", "--max-turns", "1", "--tools", "",
                    "--disable-web-search", "--no-subagents", "--permission-mode", "dontAsk",
                    "--deny", "MCPTool", "--sandbox", "read-only"]
        case .local:
            return []
        }
    }

    /// 채팅에서 스킬·도구를 쓸 때. MCP 차단과 개인 설정 차단은 그대로 두고, 권한 모드만큼만 연다.
    private static func skillArguments(for provider: AIProvider, policy: URL, plugin: URL?, access: AIToolAccess) -> [String] {
        let folder = access.workFolder?.path
        switch provider {
        case .claude:
            // --safe-mode 는 사용자 스킬까지 막는다. 대신 --setting-sources "" 로 개인 설정·훅·CLAUDE.md 를
            // 끄고, 사용자 스킬은 임시 플러그인(--plugin-dir)으로만 넘긴다.
            var arguments = ["-p", "--output-format", "json",
                             "--tools", "Skill,Read,Glob,Grep,Bash,Edit,Write",
                             "--strict-mcp-config", "--setting-sources", ""]
            if access.permission == .full {
                // 전체 액세스: 묻지 않고 모두 실행한다. 파일 도구는 작업 폴더·--add-dir 안으로 한정된다.
                arguments += ["--permission-mode", "bypassPermissions", "--no-session-persistence"]
            } else {
                // 허용 목록 밖(승인 요청: 수정·스크립트 / 편집 허용: 스크립트)은 막혀 permission_denials 로
                // 돌아온다 → 채팅에서 승인. 승인 후 같은 세션을 이어가야 하므로 세션은 남긴다(--resume).
                let edits = access.permission == .edit ? ["Edit", "Write"] : []
                let allowed = ["Skill", "Read", "Glob", "Grep"] + edits + access.approvedTools
                var seen = Set<String>()
                arguments += ["--allowed-tools", allowed.filter { seen.insert($0).inserted }.joined(separator: " ")]
                if let resume = access.resume { arguments += ["--resume", resume] }
            }
            if let plugin { arguments += ["--plugin-dir", plugin.path] }
            let directories = [AISkillCatalog.roots(for: .claude).first?.path, folder].compactMap { $0 }
            if !directories.isEmpty { arguments += ["--add-dir"] + directories }
            return arguments
        case .codex:
            // 승인할 길이 없어 "요청"은 막아 둔다. 수정은 쓰기 샌드박스(문서 폴더 안), 실행은 셸 도구로 가른다.
            // 셸이 꺼져도 파일 읽기와 패치(apply_patch)는 내장 도구로 된다.
            let sandbox = access.permission == .approval ? "read-only" : "workspace-write"
            let shell = access.permission == .full ? [] : ["--disable", "shell_tool"]
            return ["-a", "never", "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
                    "--sandbox", sandbox, "--skip-git-repo-check"] + shell
                + ["--disable", "hooks", "--disable", "multi_agent", "--disable", "apps",
                   "-c", "web_search=\"disabled\""]
                + (folder.map { ["-C", $0] } ?? [])
                + ["--json", "-"]
        case .gemini:
            return ["--prompt", "Follow the request on stdin.", "--output-format", "json",
                    "--approval-mode", ["default", "auto_edit", "yolo"][access.permission.rawValue],
                    "--policy", policy.path, "--extensions", "none", "--skip-trust"]
                + (folder.map { ["--include-directories", $0] } ?? [])
        case .grok, .local:
            return baseArguments(for: provider, policy: policy)
        }
    }

    // MARK: - 컨텍스트 사용량

    /// Gemini 출력에는 컨텍스트 크기가 없다. 현재 Gemini 모델(2.5·3 계열)은 모두 1M 토큰이다.
    static let geminiContextWindow = 1_048_576

    static func contextUsage(from text: String, provider: AIProvider, model: String?,
                             codexModels: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".codex/models_cache.json")) -> AIContextUsage? {
        func object(_ text: String) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        switch provider {
        case .claude:
            // 도구를 쓰면 모델을 여러 번 부른다. 컨텍스트가 가장 찼던 호출(=마지막 쪽)을 쓴다.
            guard let root = object(text), let usage = root["usage"] as? [String: Any] else { return nil }
            func filled(_ row: [String: Any]) -> Int {
                int(row["input_tokens"]) + int(row["cache_read_input_tokens"]) + int(row["cache_creation_input_tokens"])
            }
            let iterations = usage["iterations"] as? [[String: Any]] ?? []
            let used = iterations.map(filled).max() ?? filled(usage)
            let models = (root["modelUsage"] as? [String: [String: Any]] ?? [:]).values
            let main = models.max { int($0["inputTokens"]) + int($0["cacheReadInputTokens"]) < int($1["inputTokens"]) + int($1["cacheReadInputTokens"]) }
            let window = int(main?["contextWindow"])
            return used > 0 && window > 0 ? AIContextUsage(used: used, window: window) : nil
        case .codex:
            // turn.completed 의 input_tokens 는 한 턴의 합계라, 도구를 여러 번 쓰면 실제보다 크게 잡힌다(보수적 추정).
            let event = text.split(separator: "\n").compactMap { object(String($0)) }.last { $0["type"] as? String == "turn.completed" }
            let used = int((event?["usage"] as? [String: Any])?["input_tokens"])
            guard used > 0, let window = codexContextWindow(model: model, cache: codexModels) else { return nil }
            return AIContextUsage(used: used, window: window)
        case .gemini:
            guard let models = (object(text)?["stats"] as? [String: Any])?["models"] as? [String: [String: Any]] else { return nil }
            let used = models.values.map { int(($0["tokens"] as? [String: Any])?["prompt"]) }.max() ?? 0
            return used > 0 ? AIContextUsage(used: used, window: geminiContextWindow) : nil
        case .grok, .local:
            return nil
        }
    }

    /// Codex 모델 캐시에서 컨텍스트 크기를 찾는다. 모델을 고르지 않았으면 우선순위가 가장 높은(기본) 모델.
    static func codexContextWindow(model: String?, cache: URL) -> Int? {
        guard let data = try? Data(contentsOf: cache),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return nil }
        let entry: [String: Any]?
        if let model, !model.isEmpty {
            entry = models.first { $0["slug"] as? String == model }
        } else {
            entry = models.min { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
        }
        return (entry?["context_window"] as? NSNumber)?.intValue
    }

    static func tokens(from text: String, provider: AIProvider) -> Int? {
        func object(_ text: String) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        if provider == .codex {
            let event = text.split(separator: "\n").compactMap { object(String($0)) }.last { $0["type"] as? String == "turn.completed" }
            guard let usage = event?["usage"] as? [String: Any], let input = usage["input_tokens"] as? Int,
                  let output = usage["output_tokens"] as? Int else { return nil }
            return max(0, input) + max(0, output) // cached_input_tokens is already part of input_tokens.
        }
        guard let root = object(text) else { return nil }
        if provider == .gemini {
            guard let stats = root["stats"] as? [String: Any], let models = stats["models"] as? [String: [String: Any]] else { return nil }
            let totals = models.values.compactMap { ($0["tokens"] as? [String: Any])?["total"] as? Int }
            return totals.isEmpty ? nil : totals.reduce(0) { $0 + max(0, $1) }
        }
        guard let usage = root["usage"] as? [String: Any] else { return nil }
        if let total = usage["total_tokens"] as? Int { return max(0, total) }
        let keys = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        let values = keys.compactMap { usage[$0] as? Int }
        return values.isEmpty ? nil : values.reduce(0) { $0 + max(0, $1) }
    }

    static func answer(from output: AIProcessOutput, provider: AIProvider) throws -> String {
        guard output.status == 0 else {
            // Keep diagnostic output bounded; never display environment or authentication files.
            let diagnostic = output.stderr.isEmpty ? output.stdout : output.stderr
            throw AIError(message: L10n.tr("ai.cliFailed") + "\n" + String(diagnostic.suffix(1800)))
        }
        let text: String
        if provider == .grok {
            guard let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
                  object["stopReason"] as? String == "end_turn", (object["num_turns"] as? Int ?? 1) <= 1, let message = object["text"] as? String else {
                throw AIError(message: L10n.tr("ai.grokIncomplete"))
            }
            text = message
        } else if provider == .codex {
            var messages: [String] = []
            var complete = false
            for line in output.stdout.split(separator: "\n") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let type = event["type"] as? String
                if type == "turn.failed" || type == "error" { throw AIError(message: L10n.tr("ai.cliFailed")) }
                if type == "turn.completed" { complete = true }
                if type == "item.completed", let item = event["item"] as? [String: Any],
                   item["type"] as? String == "agent_message", let message = item["text"] as? String {
                    messages.append(message)
                }
            }
            guard complete else { throw AIError(message: L10n.tr("ai.incomplete")) }
            // 스킬·도구를 쓰면 중간 진행 멘트("스킬을 읽어볼게요")가 따로 온다. 최종 답은 마지막 메시지다.
            text = messages.last ?? ""
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
                  object["is_error"] as? Bool != true, object["error"] == nil,
                  let message = object[provider == .claude ? "result" : "response"] as? String else {
                throw AIError(message: L10n.tr("ai.invalidResponse"))
            }
            text = message
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError(message: L10n.tr("ai.invalidResponse"))
        }
        return text
    }
}

/// 요청 하나가 채운 컨텍스트 — 입력(캐시 포함) 토큰 / 모델 컨텍스트 크기.
struct AIContextUsage: Equatable {
    let used: Int
    let window: Int
    var fraction: Double { window > 0 ? min(1, Double(used) / Double(window)) : 0 }

    /// "74K / 200K" — 1,000 단위 반올림, 1M 이상은 M.
    static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let value = Double(tokens) / 1_000_000
            return (value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)) + "M"
        }
        if tokens >= 1_000 { return "\(Int((Double(tokens) / 1_000).rounded()))K" }
        return "\(tokens)"
    }
}
