import XCTest
@testable import JenaNoteKit

final class AISkillsTests: XCTestCase {
    private var home: URL!
    private let policy = URL(fileURLWithPath: "/tmp/policy.toml")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AISkillsTests-\(UUID().uuidString)")
        try makeSkill("writing", root: ".claude/skills", description: "\"Korean prose style\"")
        try makeSkill("editing", root: ".claude/skills", description: "Book editor review")
        try makeSkill("shared", root: ".agents/skills", description: "Shared skill")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/skills/not-a-skill"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func makeSkill(_ name: String, root: String, description: String) throws {
        let dir = home.appendingPathComponent(root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\n# \(name)\n"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func testOffKeepsTheFullyIsolatedArguments() {
        for provider in AIProvider.allCases {
            XCTAssertEqual(AIClient.arguments(for: provider, policy: policy, access: AIToolAccess()),
                           AIClient.arguments(for: provider, policy: policy),
                           "Internal requests (proofreading, retrieval) must stay isolated")
        }
        let claude = AIClient.arguments(for: .claude, policy: policy)
        XCTAssertTrue(claude.contains("--safe-mode") && claude.contains("--disable-slash-commands"))
    }

    func testClaudeSkillsLoadOnlyThePluginWithoutPersonalSettings() {
        let plugin = URL(fileURLWithPath: "/tmp/skills-plugin")
        let args = AIClient.arguments(for: .claude, policy: policy, access: AIToolAccess(skills: .auto), skillPlugin: plugin)
        XCTAssertFalse(args.contains("--safe-mode"), "safe-mode also blocks the user's skills")
        XCTAssertFalse(args.contains("--disable-slash-commands"))
        let sources = try? XCTUnwrap(args.firstIndex(of: "--setting-sources"))
        XCTAssertEqual(sources.map { args[$0 + 1] }, "", "Personal settings, hooks and CLAUDE.md stay off")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertFalse(args.contains("--no-session-persistence"), "Approval needs the session to resume")
        XCTAssertEqual(args.firstIndex(of: "--plugin-dir").map { args[$0 + 1] }, plugin.path)
        XCTAssertEqual(args.firstIndex(of: "--tools").map { args[$0 + 1] }, "Skill,Read,Glob,Grep,Bash,Edit,Write")
        XCTAssertEqual(Array(AIClient.arguments(for: .claude, policy: policy, model: "haiku", access: AIToolAccess(skills: .auto),
                                                skillPlugin: plugin).suffix(2)), ["--model", "haiku"])
    }

    func testCodexSkillsUnderApprovalStayReadOnlyWithoutScripts() {
        // 승인 요청(기본값)은 실행도 요청 대상인데 Codex 는 승인을 못 받으므로 셸을 끈 채 읽기만 한다.
        let args = AIClient.arguments(for: .codex, policy: policy, access: AIToolAccess(skills: .use("writing")))
        XCTAssertTrue(args.contains("shell_tool"))
        XCTAssertEqual(args.firstIndex(of: "--sandbox").map { args[$0 + 1] }, "read-only")
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertEqual(args.last, "-")
        XCTAssertTrue(AIClient.arguments(for: .codex, policy: policy).contains("shell_tool"))
    }

    func testGeminiPolicyAllowsOnlySkillTools() {
        XCTAssertFalse(AIClient.geminiPolicy(access: AIToolAccess()).contains("allow"))
        let policy = AIClient.geminiPolicy(access: AIToolAccess(skills: .auto))
        XCTAssertFalse(policy.contains("run_shell_command"), "Approval modes stay read-only on Gemini")
        for tool in ["activate_skill", "read_file"] {
            XCTAssertTrue(policy.contains("toolName = \"\(tool)\"\ndecision = \"allow\""), tool)
        }
        XCTAssertTrue(policy.contains("toolName = \"*\"\ndecision = \"deny\""))
        XCTAssertTrue(AIClient.geminiSettings(access: AIToolAccess()).contains("\"core\":[]"))
    }

    func testProvidersWithoutSkillsNeverOpenTools() {
        for provider in [AIProvider.grok, .local] {
            XCTAssertFalse(AISkillCatalog.supportsSkills(provider))
            XCTAssertEqual(AIClient.arguments(for: provider, policy: policy, access: AIToolAccess(skills: .auto)),
                           AIClient.arguments(for: provider, policy: policy))
            XCTAssertNil(AISkillCatalog.instruction(for: "writing", provider: provider))
        }
    }

    func testCatalogReadsSkillFoldersAndDescriptions() {
        let claude = AISkillCatalog.skills(for: .claude, home: home)
        XCTAssertEqual(claude.map(\.name), ["editing", "writing"], "Folders without SKILL.md are ignored")
        XCTAssertEqual(claude.last?.summary, "Korean prose style", "Quotes are stripped")
        XCTAssertEqual(AISkillCatalog.skills(for: .gemini, home: home).map(\.name), ["shared"])
        XCTAssertTrue(AISkillCatalog.skills(for: .grok, home: home).isEmpty)
    }

    func testClaudePluginLinksEachUserSkill() throws {
        let work = home.appendingPathComponent("request")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let plugin = try AISkillCatalog.makeClaudePlugin(in: work, home: home)
        let manifest = try String(contentsOf: plugin.appendingPathComponent(".claude-plugin/plugin.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(AISkillCatalog.claudePluginName))
        let linked = try FileManager.default.contentsOfDirectory(atPath: plugin.appendingPathComponent("skills").path).sorted()
        XCTAssertEqual(linked, ["editing", "writing"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.appendingPathComponent("skills/writing/SKILL.md").path))
    }

    func testChosenSkillInstructionNamesTheSkillTheWayEachCLIExpects() {
        XCTAssertTrue(AISkillCatalog.instruction(for: "writing", provider: .claude)!
            .contains("`\(AISkillCatalog.claudePluginName):writing`"))
        XCTAssertTrue(AISkillCatalog.instruction(for: "writing", provider: .codex)!.contains("$writing"))
        XCTAssertTrue(AISkillCatalog.instruction(for: "writing", provider: .gemini)!.contains("activate_skill"))
    }

    func testChatAlwaysOpensSkillsWhereTheCLISupportsThem() {
        XCTAssertEqual(AISettings.skillMode(for: .claude), .auto)
        XCTAssertEqual(AISettings.skillMode(for: .codex), .auto)
        XCTAssertEqual(AISettings.skillMode(for: .grok), .off)
        XCTAssertEqual(AISettings.skillMode(for: .local), .off)
    }

    // MARK: - `/` 스킬

    func testSlashQueryStartsAtAWordBoundary() {
        XCTAssertEqual(AISlashCommand.activeQuery(in: "/wri", cursor: 4)?.query, "wri")
        XCTAssertEqual(AISlashCommand.activeQuery(in: "다듬어줘 /", cursor: 6)?.query, "")
        XCTAssertEqual(AISlashCommand.activeQuery(in: "다듬어줘 /", cursor: 6)?.range, NSRange(location: 5, length: 1))
        XCTAssertNil(AISlashCommand.activeQuery(in: "1/2", cursor: 3), "A slash inside a word is not a command")
        XCTAssertNil(AISlashCommand.activeQuery(in: "/writing 이걸", cursor: 11), "The command ends at a space")
        XCTAssertNil(AISlashCommand.activeQuery(in: "/한글", cursor: 3), "Skill names are ASCII folder names")
        XCTAssertNil(AISlashCommand.activeQuery(in: "", cursor: 0))
    }

    func testFilterPutsPrefixMatchesFirst() {
        let skills = ["humanize-korean", "writing", "writing-comic", "editing"].map {
            AISkill(name: $0, summary: "", directory: URL(fileURLWithPath: "/"))
        }
        XCTAssertEqual(AISlashCommand.filter(skills, query: "").count, 4)
        XCTAssertEqual(AISlashCommand.filter(skills, query: "wri").map(\.name), ["writing", "writing-comic"])
        XCTAssertEqual(AISlashCommand.filter(skills, query: "IT").map(\.name), ["writing", "writing-comic", "editing"])
        XCTAssertEqual(AISlashCommand.filter(skills, query: "kor").map(\.name), ["humanize-korean"])
        XCTAssertTrue(AISlashCommand.filter(skills, query: "zzz").isEmpty)
    }

    func testOnlyExistingSkillsInTheMessageAreUsed() {
        let available = ["writing", "editing"]
        XCTAssertEqual(AISlashCommand.referencedSkills(in: "/writing 이 문단 다듬어줘", available: available), ["writing"])
        XCTAssertEqual(AISlashCommand.referencedSkills(in: "먼저 /editing 그다음 /writing /editing", available: available),
                       ["editing", "writing"], "In order, each once")
        XCTAssertTrue(AISlashCommand.referencedSkills(in: "/nothing 그냥 질문", available: available).isEmpty,
                      "Unknown names are ignored")
        XCTAssertTrue(AISlashCommand.referencedSkills(in: "and/or 1/2", available: ["or", "2"]).isEmpty)
    }

    func testCodexAnswerIsTheFinalMessageNotTheProgressNotes() throws {
        let lines = [
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"I'll read the skill first.\"}}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"command\":\"cat SKILL.md\"}}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Final answer\"}}",
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
        ]
        let answer = try AIClient.answer(from: .init(status: 0, stdout: lines.joined(separator: "\n"), stderr: ""), provider: .codex)
        XCTAssertEqual(answer, "Final answer")
    }

    // MARK: - 권한 모드

    func testPermissionDecidesHowTheDocumentIsChanged() {
        XCTAssertEqual(AIPermission.approval.chatMode, .guide)
        XCTAssertEqual(AIPermission.edit.chatMode, .edit)
        XCTAssertEqual(AIPermission.full.chatMode, .edit)
        let conversation = AIConversation()
        conversation.permission = .edit
        XCTAssertEqual(conversation.mode, .edit)
        conversation.permission = .approval
        XCTAssertEqual(conversation.mode, .guide)
    }

    func testClaudeApprovalAllowsOnlyReadsUntilApprovedAndResumesTheSession() {
        let folder = URL(fileURLWithPath: "/Users/me/novel")
        var access = AIToolAccess(skills: .auto, permission: .approval, workFolder: folder)
        var args = AIClient.arguments(for: .claude, policy: policy, access: access)
        XCTAssertEqual(args.firstIndex(of: "--allowed-tools").map { args[$0 + 1] }, "Skill Read Glob Grep")
        XCTAssertFalse(args.contains("--permission-mode"))
        XCTAssertTrue(args.contains(folder.path), "The document folder is opened with --add-dir")
        access.resume = "session-1"
        access.approvedTools = ["Write"]
        args = AIClient.arguments(for: .claude, policy: policy, access: access)
        XCTAssertEqual(args.firstIndex(of: "--allowed-tools").map { args[$0 + 1] }, "Skill Read Glob Grep Write")
        XCTAssertEqual(args.firstIndex(of: "--resume").map { args[$0 + 1] }, "session-1")
    }

    func testClaudeFullAccessRunsWithoutAsking() {
        let args = AIClient.arguments(for: .claude, policy: policy,
                                      access: AIToolAccess(skills: .auto, permission: .full))
        XCTAssertEqual(args.firstIndex(of: "--permission-mode").map { args[$0 + 1] }, "bypassPermissions")
        XCTAssertFalse(args.contains("--allowed-tools"))
        XCTAssertTrue(args.contains("--setting-sources"), "Personal settings stay off even with full access")
    }

    func testEditsAreAllowedWithoutAskingButScriptsOnlyWithFullAccess() {
        let folder = URL(fileURLWithPath: "/Users/me/novel")
        func access(_ permission: AIPermission) -> AIToolAccess {
            AIToolAccess(skills: .auto, permission: permission, workFolder: folder)
        }
        // Claude: 승인 요청은 읽기만 허용(나머지는 승인), 편집 허용은 Edit·Write 까지, 전체는 모두.
        let claudeApproval = AIClient.arguments(for: .claude, policy: policy, access: access(.approval))
        XCTAssertEqual(claudeApproval.firstIndex(of: "--allowed-tools").map { claudeApproval[$0 + 1] }, "Skill Read Glob Grep")
        let claudeEdit = AIClient.arguments(for: .claude, policy: policy, access: access(.edit))
        XCTAssertEqual(claudeEdit.firstIndex(of: "--allowed-tools").map { claudeEdit[$0 + 1] }, "Skill Read Glob Grep Edit Write")
        XCTAssertFalse(claudeEdit.firstIndex(of: "--allowed-tools").map { claudeEdit[$0 + 1] }?.contains("Bash") ?? true,
                       "Scripts still need approval")

        // Codex: 수정은 쓰기 샌드박스, 실행은 셸 도구로 가른다.
        func codex(_ permission: AIPermission) -> (sandbox: String?, shellOff: Bool, folder: String?) {
            let args = AIClient.arguments(for: .codex, policy: policy, access: access(permission))
            return (args.firstIndex(of: "--sandbox").map { args[$0 + 1] },
                    zip(args, args.dropFirst()).contains { $0 == "--disable" && $1 == "shell_tool" },
                    args.firstIndex(of: "-C").map { args[$0 + 1] })
        }
        XCTAssertEqual(codex(.approval).sandbox, "read-only")
        XCTAssertTrue(codex(.approval).shellOff)
        XCTAssertEqual(codex(.edit).sandbox, "workspace-write")
        XCTAssertTrue(codex(.edit).shellOff, "Codex cannot ask, so scripts stay off")
        XCTAssertEqual(codex(.full).sandbox, "workspace-write")
        XCTAssertFalse(codex(.full).shellOff)
        XCTAssertEqual(codex(.edit).folder, folder.path)
        XCTAssertEqual(AIClient.arguments(for: .codex, policy: policy, access: access(.full)).last, "-")

        // Gemini: 모드만큼 도구를 열고 승인 방식도 맞춘다.
        XCTAssertFalse(AIClient.geminiTools(access: access(.approval)).contains("write_file"))
        XCTAssertTrue(AIClient.geminiTools(access: access(.edit)).contains("write_file"))
        XCTAssertFalse(AIClient.geminiTools(access: access(.edit)).contains("run_shell_command"))
        XCTAssertTrue(AIClient.geminiTools(access: access(.full)).contains("run_shell_command"))
        for (permission, mode) in [(AIPermission.approval, "default"), (.edit, "auto_edit"), (.full, "yolo")] {
            let gemini = AIClient.arguments(for: .gemini, policy: policy, access: access(permission))
            XCTAssertEqual(gemini.firstIndex(of: "--approval-mode").map { gemini[$0 + 1] }, mode)
            XCTAssertEqual(gemini.firstIndex(of: "--include-directories").map { gemini[$0 + 1] }, folder.path)
        }
    }

    // MARK: - 컨텍스트

    func testClaudeContextUsesTheFullestCallAndTheModelWindow() {
        let json = """
        {"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,
          "iterations":[{"input_tokens":2,"cache_read_input_tokens":1000,"cache_creation_input_tokens":3000},
                        {"input_tokens":5,"cache_read_input_tokens":4000,"cache_creation_input_tokens":1000}]},
         "modelUsage":{"claude-x":{"inputTokens":7,"cacheReadInputTokens":5000,"contextWindow":200000}}}
        """
        XCTAssertEqual(AIClient.contextUsage(from: json, provider: .claude, model: nil),
                       AIContextUsage(used: 5005, window: 200_000))
    }

    func testCodexContextReadsTheWindowFromTheModelCache() throws {
        let cache = home.appendingPathComponent("models_cache.json")
        try """
        {"models":[{"slug":"big","priority":2,"context_window":500000},{"slug":"default","priority":1,"context_window":272000}]}
        """.write(to: cache, atomically: true, encoding: .utf8)
        let events = "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":27200,\"output_tokens\":5}}"
        XCTAssertEqual(AIClient.contextUsage(from: events, provider: .codex, model: nil, codexModels: cache),
                       AIContextUsage(used: 27_200, window: 272_000), "No model chosen → highest-priority model")
        XCTAssertEqual(AIClient.contextUsage(from: events, provider: .codex, model: "big", codexModels: cache)?.window, 500_000)
        XCTAssertNil(AIClient.contextUsage(from: events, provider: .codex, model: "unknown", codexModels: cache))
    }

    func testGeminiContextUsesThePromptTokens() {
        let json = "{\"response\":\"ok\",\"stats\":{\"models\":{\"g\":{\"tokens\":{\"prompt\":104857,\"total\":110000}}}}}"
        XCTAssertEqual(AIClient.contextUsage(from: json, provider: .gemini, model: nil),
                       AIContextUsage(used: 104_857, window: AIClient.geminiContextWindow))
        XCTAssertNil(AIClient.contextUsage(from: json, provider: .grok, model: nil))
    }

    func testContextFormattingAndPie() {
        XCTAssertEqual(AIContextUsage.compact(74_321), "74K")
        XCTAssertEqual(AIContextUsage.compact(1_000_000), "1M")
        XCTAssertEqual(AIContextUsage.compact(1_048_576), "1.0M")
        XCTAssertEqual(AIContextUsage(used: 300, window: 200).fraction, 1, "Clamped")
        let pie = AIContextPieView()
        pie.usage = AIContextUsage(used: 50_000, window: 200_000)
        XCTAssertEqual(pie.accessibilityValue() as? String, "25%")
        XCTAssertTrue(pie.toolTip?.contains("50K / 200K") == true)
    }

    func testDeniedToolsAndSessionAreReadFromClaudeResult() {
        let json = """
        {"result":"done","session_id":"abc","permission_denials":[
          {"tool_name":"Write","tool_input":{"file_path":"/n/out.md","content":"x"}},
          {"tool_name":"Bash","tool_input":{"command":"python fix.py"}},
          {"tool_name":"Bash","tool_input":{"command":"python fix.py"}}]}
        """
        let (session, denied) = AIClient.permissionState(from: json, provider: .claude)
        XCTAssertEqual(session, "abc")
        XCTAssertEqual(denied, [AIToolRequest(tool: "Write", detail: "/n/out.md"),
                                AIToolRequest(tool: "Bash", detail: "python fix.py")], "Repeats are asked once")
        XCTAssertTrue(AIClient.permissionState(from: json, provider: .codex).1.isEmpty)
    }

    func testQuotaBarClampsAndReportsItsValue() {
        let bar = AIQuotaBarView()
        bar.label = "세션"
        bar.fraction = 0.42
        XCTAssertEqual(bar.accessibilityValue() as? String, "42%")
        XCTAssertGreaterThan(bar.intrinsicContentSize.width, bar.trackWidth, "The label sits before the track")
    }

    func testFoldedYAMLDescriptionsAreJoined() {
        let text = "---\nname: writing-comic\ndescription: >\n  코믹 서사를 쓸 때\n  핑퐁 대사로.\nallowed: x\n---\n# body"
        XCTAssertEqual(AISkillCatalog.frontMatterValue("description", in: text), "코믹 서사를 쓸 때 핑퐁 대사로.")
        XCTAssertEqual(AISkillCatalog.frontMatterValue("name", in: text), "writing-comic")
    }
}
