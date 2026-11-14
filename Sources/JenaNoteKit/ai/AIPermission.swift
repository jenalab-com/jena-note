import Foundation

/// 채팅 권한 모드 — 문서에 어떻게 반영할지와 AI 가 도구(파일 수정·스크립트)를 어디까지 쓸지를 함께 정한다.
///
/// | 모드 | 문서·파일 수정 | 스크립트 실행 |
/// |---|---|---|
/// | 승인 요청 | 요청 (문서는 제안만) | 요청 |
/// | 편집 허용 | 묻지 않고 (문서 폴더 안) | 요청 |
/// | 전체 액세스 | 묻지 않고 | 묻지 않고 |
///
/// "요청"은 Claude 만 채팅에서 승인받을 수 있다. Codex·Gemini 는 일회성 실행이라 승인할 길이 없어 거절된 채 끝난다.
enum AIPermission: Int, CaseIterable {
    case approval, edit, full

    /// 문서 반영 방식 — 승인 요청은 제안만, 나머지는 문서를 직접 고친다.
    var chatMode: AIChatMode { self == .approval ? .guide : .edit }

    var title: String {
        switch self {
        case .approval: return L10n.tr("ai.permission.approval")
        case .edit: return L10n.tr("ai.permission.edit")
        case .full: return L10n.tr("ai.permission.full")
        }
    }

    var symbol: String {
        switch self {
        case .approval: return "hand.raised"
        case .edit: return "pencil"
        case .full: return "bolt"
        }
    }

    /// Claude 만 막힌 작업을 채팅에서 승인받을 수 있다.
    static func canAskApproval(_ provider: AIProvider) -> Bool { provider == .claude }

    func hint(for provider: AIProvider) -> String {
        let asks = Self.canAskApproval(provider)
        switch self {
        case .approval: return L10n.tr(asks ? "ai.permission.approvalHint" : "ai.permission.approvalNoAskHint")
        case .edit: return L10n.tr(asks ? "ai.permission.editHint" : "ai.permission.editNoAskHint")
        case .full: return L10n.tr("ai.permission.fullHint")
        }
    }
}

/// Claude 가 막힌 도구로 멈춘 작업 하나 — 채팅에서 승인받을 내용.
struct AIToolRequest: Equatable {
    let tool: String
    let detail: String

    /// 승인하면 다음 이어가기에서 이 이름으로 도구를 허용한다.
    var allowRule: String { tool }

    /// Claude `permission_denials` 항목 → 사람이 읽을 요약.
    static func from(denial: [String: Any]) -> AIToolRequest? {
        guard let tool = denial["tool_name"] as? String else { return nil }
        let input = denial["tool_input"] as? [String: Any] ?? [:]
        let detail = (input["command"] as? String)
            ?? (input["file_path"] as? String)
            ?? (input["path"] as? String)
            ?? (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) }
            ?? ""
        return AIToolRequest(tool: tool, detail: String(detail.prefix(300)))
    }
}

/// 요청 하나에 여는 도구 범위. 기본값은 완전히 격리(스킬·도구 없음) — 내부 요청은 늘 이 값이다.
struct AIToolAccess: Equatable {
    var skills: AISkillMode = .off
    var permission: AIPermission = .approval
    /// 열린 문서의 폴더 — AI 가 읽고(전체 액세스면 쓰는) 범위
    var workFolder: URL?
    /// 승인 후 이어갈 Claude 세션
    var resume: String?
    /// 승인받아 이번 이어가기에서 허용할 도구
    var approvedTools: [String] = []
}
