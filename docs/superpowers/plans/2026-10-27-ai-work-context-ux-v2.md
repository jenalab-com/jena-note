# AI 작품 문맥 UX v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 1차 구현의 보이는 층(텍스트 한 줄·팝오버·시트)을 설계서 v2(§5, §7)대로 "눌리는 줄 + 별도 3탭 창"으로 바꾼다. 뼈대(선별·요약·캐시·프롬프트·보안)는 그대로 쓴다.

**Architecture:** 순수 로직(행 모델·토글·용량 계산·Draft)을 `AIWorkContextModel.swift`로 모아 테스트 가능하게 두고, 그 위에 얇은 AppKit 뷰 셋(참고 자료·지난 화·작품 폴더)을 `AIWorkContextWindowController`가 사이드바로 묶는다. 창은 작품 루트마다 하나(레지스트리). 변경은 즉시 `context.json`에 저장되고 `onChange`로 채팅 패널이 줄을 갱신한다. 요약 생성 소유권은 1차와 같이 `AIChatViewController`가 가진다.

**Tech Stack:** Swift 5.7 / AppKit (NSWindowController, NSSplitView 또는 NSStackView 사이드바, NSTableView, NSSegmentedControl, NSOpenPanel) / XCTest.

**Spec:** `docs/superpowers/specs/2026-10-27-ai-work-context-design.md` (§5, §7 v2, §13 UX 개정)

## Global Constraints

- 앱은 사실만 보여주고 해결안을 제시하지 않는다. "N개를 요약으로" 류의 제안 UI 금지.
- 작품 문맥 줄은 §7.1 표의 11가지 상태를 **점 색 · 문구 · 오른쪽 버튼 · 바탕**으로 그린다. 글자만 있는 텍스트 버튼 금지.
- 창은 작품 루트마다 하나. 변경 즉시 `context.json` 저장(저장 버튼 없음). 열려 있는 동안 AI 패널 줄이 즉시 반영.
- 참고 자료 출처는 폴더·파일 혼합 다중. 작품 루트 밖은 거부(빨간 안내). 출처가 0개면 `enabled=false`.
- 파일 목록 기본 정렬 크기순(내림차순), 이름순 전환 가능. 체크·원문/요약 변경 시 용량 막대·사실 한 줄 즉시 갱신.
- "열기"는 새 창. "다시 만들기"는 직접 고친 요약이면 확인 대화.
- 요약 생성 트리거는 send 직전과 명시적 버튼("요약 전부 새로 만들기", "다시 만들기", "지금 만들기")뿐.
- 새 L10n 키는 ko/en 모두, 중복 금지. 1차 전용 키(`ai.work.active`, `ai.work.setup`, `ai.work.sheetTitle`, `ai.work.save`, `ai.work.changeSettings`, `ai.work.include`, `ai.work.budget`)는 마지막 작업에서 제거.
- 삭제 대상: `AIWorkContextPopover.swift`, `AIWorkContextSheet.swift`, `AIWorkContextPopoverTests.swift`, `AIWorkContextSheetTests.swift`(순수 로직 테스트는 `AIWorkContextModelTests.swift`로 이전).
- 테스트는 컨트롤러 세션에서만 실행(서브에이전트는 `swift build`만).

## Review Focus

1. 출처를 처음 넣는 순간(이전 `enabled=false`, 소스 0개 → 1개): `enabled`가 true로 바뀌고 줄이 "사용 중"으로 바뀐다. → Task 2 `testAddingFirstSourceEnablesContext`.
2. 마지막 출처를 ×로 지웠을 때: `enabled=false`, 파일 목록 비움, 줄 "사용 안 함". `excludedSettings`/`summarizedSettings`는 보존. → Task 2 `testRemovingLastSourceDisablesButKeepsChoices`.
3. 폴더 출처와 그 안의 파일을 동시에 넣었을 때: 파일 목록에 중복 없음, 출처 목록엔 둘 다 보임. → Task 2 `testOverlappingSourcesDedupeFilesOnly`.
4. 창이 열린 채 다른 창에서 같은 작품의 `context.json`이 바뀌었을 때: 창은 자기 변경을 저장하기 전에 디스크를 다시 읽어 합친다(마지막 쓰기 승리 금지). → Task 3 `testWindowReloadsConfigBeforeMutating`.
5. 미저장 문서에서 줄의 "설정…"은 비활성이고, 저장 뒤 `switchDocument`/`refreshWorkContext`로 활성화된다. → Task 1 `testUnsavedDocumentDisablesSetupButton`.

---

### Task 1: 작품 문맥 줄 v2 (`AIWorkContextBar`) + 채팅 패널 진입점 정리

**Files:**
- Modify: `Sources/JenaNoteKit/ai/AIWorkContextBar.swift` (전면 재작성)
- Modify: `Sources/JenaNoteKit/ai/AIChatViewController.swift` (`workBarClicked`, `presentSetup`/`presentPopover` 제거, `openWorkWindow()` 자리)
- Modify: `Sources/JenaNoteKit/app/Localization.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkContextBarTests.swift` (재작성), `Tests/JenaNoteKitTests/AIChatLayoutTests.swift` (기존 줄 위치 테스트 유지)

**Interfaces:**
- Produces:

```swift
enum AIWorkContextStatus: Equatable {
    case unavailable(reason: UnavailableReason)   // .notInWork, .unsavedDocument
    case disabled
    case corrupt
    case active(settingsCount: Int, summariesReady: Int, summariesTotal: Int,
                outsideWriting: Bool, contextBytes: Int, budget: AIPromptBudget)
    case generating(done: Int, total: Int)
    enum UnavailableReason: Equatable { case notInWork, unsavedDocument }
}
struct AIWorkContextBarAppearance: Equatable {
    let dotColor: NSColor; let text: String; let detail: String?   // detail = 보조색 숫자
    let buttonTitle: String; let buttonEnabled: Bool; let background: NSColor?; let tooltip: String?
}
final class AIWorkContextBar: NSView {
    var onPrimaryAction: (() -> Void)?        // 줄 클릭 = 버튼 클릭
    func update(_ status: AIWorkContextStatus)
    static func appearance(for status: AIWorkContextStatus) -> AIWorkContextBarAppearance   // §7.1 표 그대로
    static func formatBytes(_ bytes: Int) -> String                                         // 기존 유지
}
```

L10n(ko/en): `ai.work.row.off`("작품 문맥 사용 안 함"), `ai.work.row.disabled`("작품 문맥 꺼짐"), `ai.work.row.on`("작품 문맥 사용 중"), `ai.work.row.settings`("설정 %d개"), `ai.work.row.episodes`("지난 화 %d화"), `ai.work.row.episodesPartial`("지난 화 %d/%d화 준비"), `ai.work.row.noEpisodes`("지난 화 없음"), `ai.work.row.nearLimit`("%@ / %@에 가까워요"), `ai.work.row.overLimit`("설정이 한도를 넘었어요"), `ai.work.row.corrupt`("작품 문맥 설정을 읽을 수 없어요"), `ai.work.row.generating`("지난 화 요약 만드는 중 %d/%d"), `ai.work.row.settingsButton`("설정…"), `ai.work.row.enableButton`("켜기"), `ai.work.row.resetButton`("다시 설정…"), `ai.work.row.cancelButton`("취소"), `ai.work.row.saveFirst`("먼저 저장하세요").

- [ ] **Step 1: Write the failing tests**

```swift
func testAppearanceForEachStatusMatchesTable()   // 표 전 행(작성 당시 10행; 최종 리뷰 후 "요약이 빠짐" 행 추가로 11행): 점 색·문구·버튼 제목·바탕(nil/연노랑)·버튼 활성
func testUnsavedDocumentDisablesSetupButton()    // Review Focus 5: .unavailable(.unsavedDocument) → buttonEnabled false, tooltip "먼저 저장하세요"
func testDetailCarriesNumbersNotSentence()       // .active(settings 6, 12/12) → text "작품 문맥 사용 중", detail "설정 6개 · 지난 화 12화"
func testRowClickAndButtonClickFireSameAction()  // onPrimaryAction 호출 1회씩
```

- [ ] **Step 2: Run → 컴파일 실패 확인** (`swift test --filter AIWorkContextBarTests`, 컨트롤러가 실행)
- [ ] **Step 3: Implement** — `NSView` 안에 둥근 테두리 배경(`wantsLayer`, cornerRadius 8, 1pt 테두리), 8pt 원(`NSView` layer), 12pt 라벨, 11pt 보조 라벨, 오른쪽 `NSButton`(bezel `.rounded`, controlSize `.small`). 전체 클릭은 `NSClickGestureRecognizer`. `AIChatViewController`에서 `presentSetup`/`presentPopover`/`workPopover`/`workSheet` 관련 멤버를 제거하고 `workBar.onPrimaryAction = { [weak self] in self?.openWorkWindow() }`; `openWorkWindow()`는 Task 6까지 `// TODO(Task 6)` 빈 함수. `refreshWorkContext()`의 상태 매핑을 새 enum으로 옮긴다(`fileURL == nil` → `.unavailable(.unsavedDocument)`, 작품 아님 → `.unavailable(.notInWork)`). 기존 `presentWorkPopover`/`presentWorkSetupSheet`/`syncWorkPopover`는 **일단 남겨두되 호출하지 않는다**(Task 6에서 삭제; 컴파일 유지 목적).
- [ ] **Step 4: Controller runs tests → PASS**
- [ ] **Step 5: Commit** `feat(ai): work context row v2 with status dot and action button`

---

### Task 2: 순수 모델 계층 `AIWorkContextModel` (팝오버·시트의 statics 이전 + 출처 모델)

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContextModel.swift`
- Modify: `Sources/JenaNoteKit/ai/AIWorkContextPopover.swift`, `AIWorkContextSheet.swift` (statics를 모델로 위임만; 삭제는 Task 6)
- Test: `Tests/JenaNoteKitTests/AIWorkContextModelTests.swift` (Popover/Sheet 테스트의 순수 로직 케이스 이전 + 신규)

**Interfaces:**
- Consumes: `AIResolvedWorkContext`, `AIEpisodeSummaryStore`, `AIWorkPayload`, `AIWorkContextConfig`, `AIWorkContext.validate/relativePath`.
- Produces:

```swift
enum AIWorkContextModel {
    // 이전(동일 시그니처): settingRows, episodeRows, stateText, toggleIncluded, toggleSummarized,
    // budgetSegments, largeFileThreshold, isLarge, invalidPathsText
    struct SourceRow: Equatable { let relativePath: String; let url: URL; let isDirectory: Bool; let fileCount: Int?; let byteCount: Int? }
    static func sourceRows(_ resolved: AIResolvedWorkContext) -> [SourceRow]
    enum FileSort { case sizeDescending, name }
    static func sortedSettingRows(_ rows: [SettingRow], by: FileSort) -> [SettingRow]
    /// 사실 한 줄: 여유 "설정 180KB + 요약 40KB = 220KB / 500KB" / 초과 "… = 640KB. 한도는 500KB예요. 140KB를 줄여야 보낼 수 있어요"
    static func budgetFactLine(_ payload: AIWorkPayload) -> String
    /// 출처 추가/제거. 루트 밖이면 throws AIWorkContextValidationError.settingsOutsideRoot; 루트 자체면 .settingsIsRoot.
    static func addingSource(_ url: URL, to config: inout AIWorkContextConfig, root: URL) throws
    static func removingSource(_ relativePath: String, from config: inout AIWorkContextConfig)
    /// enabled 규칙: settingsSources.isEmpty → false. 비어 있지 않고 이전이 "소스 0개로 인한 false"였으면 true.
    static func normalizeEnabled(_ config: inout AIWorkContextConfig, previouslyHadSources: Bool)
    struct FoldersDraft: Equatable { var rootURL: URL; var writingFolder: URL; var title: String
        var errors: [AIWorkContextValidationError]; var canApply: Bool }
    static func foldersDraft(from context: AIWorkContext) -> FoldersDraft
    static func foldersDraft(suggestionFor fileURL: URL) -> FoldersDraft    // 첫 설정용
    static func applying(_ draft: FoldersDraft, to config: AIWorkContextConfig) -> AIWorkContextConfig
    static func folderPreview(_ url: URL, limit: Int = 5) -> [String]        // 작품 폴더 탭 미리보기(이름만, 숨김 제외)
}
```

- [ ] **Step 1: Write the failing tests** — 이전 케이스(Popover 6 + Sheet 5) 전부 + 신규:

```swift
func testSourceRowsCountFilesAndBytes()                // 폴더 → fileCount, 파일 → byteCount
func testSortedBySizeThenName()
func testBudgetFactLineUnderAndOverLimit()             // 두 문구 정확히
func testAddingSourceRejectsOutsideRootAndRoot()
func testAddingFirstSourceEnablesContext()             // Review Focus 1
func testRemovingLastSourceDisablesButKeepsChoices()   // Review Focus 2
func testOverlappingSourcesDedupeFilesOnly()           // Review Focus 3
func testFoldersDraftFromSuggestionAndApply()
func testFolderPreviewSkipsHiddenAndLimits()
```

- [ ] **Step 2: Run → 컴파일 실패 확인**
- [ ] **Step 3: Implement** — statics를 모델로 옮기고 Popover/Sheet는 `AIWorkContextModel.x`로 위임(호출부 변경 최소). `normalizeEnabled`는 `config.enabled`가 명시적으로 꺼진 경우(`!previouslyHadSources == false && enabled == false`)를 보존한다 — 즉 "사용자가 껐다"와 "소스가 없어서 꺼짐"을 구분: 구분 저장이 필요하면 `AIWorkContextConfig`에 `var disabledByUser: Bool = false`를 추가(Codable, 기본 false, 기존 파일 호환).
- [ ] **Step 4: Controller runs tests → PASS** (Popover/Sheet 기존 테스트도 계속 PASS)
- [ ] **Step 5: Commit** `refactor(ai): extract work context model layer with source management`

---

### Task 3: 작품 문맥 창 뼈대 + ③ 작품 폴더 탭

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContextWindowController.swift`
- Create: `Sources/JenaNoteKit/ai/AIWorkContextFoldersView.swift`
- Modify: `Sources/JenaNoteKit/app/Localization.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkContextWindowTests.swift`

**Interfaces:**
- Consumes: Task 2 모델, `AIWorkContext.save/load`, `AIWorkContextResolver.resolve`, `AIEpisodeSummaryStore`.
- Produces:

```swift
final class AIWorkContextWindowController: NSWindowController {
    enum Tab: Int { case sources, episodes, folders }
    /// 루트별 하나. 이미 있으면 그 창을 돌려준다(호출자가 showWindow).
    static func shared(for rootURL: URL, store: AIEpisodeSummaryStore) -> AIWorkContextWindowController
    /// 아직 context.json이 없는 첫 설정: 제안으로 만든 임시 컨텍스트로 연다(디스크에는 첫 유효 변경 때 저장).
    static func forFirstSetup(fileURL: URL, store: AIEpisodeSummaryStore) -> AIWorkContextWindowController
    var currentFile: URL?                         // resolve 기준; 채팅 패널이 문서 전환 때 갱신
    var onChange: (() -> Void)?                   // context.json 저장 후
    var onRegenerate: ((AIWorkFile, Bool) -> Void)?, onRefreshAll: (() -> Void)?, onCancelRefresh: (() -> Void)?
    var maintenanceProgress: (done: Int, total: Int)? { didSet }   // 채팅 패널이 밀어 넣음
    func select(_ tab: Tab)
    func reload()                                 // 디스크에서 context 재로드 → resolve → 각 탭 갱신
    /// 모든 변경의 단일 경로: 디스크 재로드 → mutate → save → reload → onChange  (Review Focus 4)
    func mutate(_ change: (inout AIWorkContextConfig) throws -> Void) rethrows
}
final class AIWorkContextFoldersView: NSView {
    init(controller: AIWorkContextWindowController)
    func render(_ draft: AIWorkContextModel.FoldersDraft, enabled: Bool)
}
```

창: `NSWindow(contentRect: 680×440, style [.titled,.closable,.resizable])`, 제목 "<title> — 작품 문맥". 왼쪽 150pt 사이드바(`NSStackView`에 3개 선택 가능한 행, 선택 행 강조) + 오른쪽 `NSView` 컨테이너에 탭 뷰 교체. 하단 바에 "닫기"만. 창을 닫아도 인스턴스는 레지스트리에 남고 다음에 재사용(상태 유지).

L10n(ko/en): `ai.work.window.title`("%@ — 작품 문맥"), `ai.work.tab.sources`("참고 자료"), `ai.work.tab.episodes`("지난 화"), `ai.work.tab.folders`("작품 폴더"), `ai.work.folders.root`("작품 루트"), `ai.work.folders.writing`("집필 폴더"), `ai.work.folders.title`("제목"), `ai.work.folders.change`("바꾸기…"), `ai.work.folders.enable`("이 작품에서 작품 문맥 사용"), `ai.work.folders.preview`("안에: %@"), `ai.work.close`("닫기").

- [ ] **Step 1: Write the failing tests** (창은 만들되 `showWindow`는 하지 않음; `_ = NSApplication.shared`)

```swift
func testSharedReturnsSameControllerPerRoot()
func testMutateSavesImmediatelyAndNotifies()           // onChange 1회, context.json 내용 반영
func testWindowReloadsConfigBeforeMutating()           // Review Focus 4: 외부에서 excludedSettings 수정 후 mutate(title 변경) → 둘 다 보존
func testFirstSetupDoesNotWriteUntilValidChange()      // forFirstSetup 직후 .jenanote 없음; mutate로 소스 추가 → 생김
func testFoldersTabRejectsWritingFolderOutsideRoot()   // errors 표시, 저장 안 됨
```

- [ ] **Step 2: Run → 컴파일 실패 확인**
- [ ] **Step 3: Implement** 창·사이드바·③탭. 경로 변경은 `NSOpenPanel`(디렉터리). 루트 변경 시 기존 상대 경로는 새 루트 기준으로 재계산하고 밖으로 나가는 항목은 `invalidPaths`로 표시. `enabled` 스위치는 `mutate { $0.enabled = on; $0.disabledByUser = !on }`.
- [ ] **Step 4: Controller runs tests → PASS**
- [ ] **Step 5: Commit** `feat(ai): work context window shell with folders tab`

---

### Task 4: ① 참고 자료 탭

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContextSourcesView.swift`
- Modify: `Sources/JenaNoteKit/ai/AIWorkContextWindowController.swift` (탭 연결)
- Modify: `Sources/JenaNoteKit/app/Localization.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkContextSourcesViewTests.swift`

**Interfaces:**
```swift
final class AIWorkContextSourcesView: NSView {
    init(controller: AIWorkContextWindowController)
    var sort: AIWorkContextModel.FileSort = .sizeDescending
    func render(_ resolved: AIResolvedWorkContext, payload: AIWorkPayload, store: AIEpisodeSummaryStore, enabled: Bool)
    // 테스트 가시성
    private(set) var sourceRowViews: [NSView]; private(set) var fileRowViews: [NSView]
    private(set) var factLabel: NSTextField; private(set) var budgetBar: AIWorkContextBudgetBar
}
final class AIWorkContextBudgetBar: NSView { func update(settings: Int, summaries: Int, previous: Int, limit: Int) }
```
구성(§7.2 ①): 머리 "어디서 가져오나" + 출처 목록(아이콘·경로·"폴더 · N개 파일"/"파일 · KB"·× 버튼) + "+ 폴더 추가…"/"+ 파일 추가…" → 용량 막대 + 사실 한 줄 → "AI가 매번 함께 읽는 파일 · N개" + 정렬 세그먼트 → `NSTableView`(체크 · 경로 · 크기 · 원문/요약 `NSSegmentedControl`; unreadable 회색+⚠, large ⚠) → `invalidPaths` 노란 줄. 모든 변경은 `controller.mutate`.

L10n(ko/en): `ai.work.sources.header`("어디서 가져오나"), `ai.work.sources.hint`("폴더를 넣으면 그 안의 글 파일을 전부, 파일을 넣으면 그 파일만. 섞어도 돼요."), `ai.work.sources.folderCount`("폴더 · %d개 파일"), `ai.work.sources.fileSize`("파일 · %@"), `ai.work.sources.addFolder`("+ 폴더 추가…"), `ai.work.sources.addFile`("+ 파일 추가…"), `ai.work.sources.filesHeader`("AI가 매번 함께 읽는 파일 · %d개"), `ai.work.sources.sortSize`("크기순"), `ai.work.sources.sortName`("이름순"), `ai.work.sources.full`("원문"), `ai.work.sources.summary`("요약"), `ai.work.sources.empty`("아직 출처가 없어요. 폴더나 파일을 추가하면 AI가 매번 함께 읽어요."), `ai.work.budget.under`("설정 %@ + 지난 화 요약 %@ = %@ / %@"), `ai.work.budget.over`("설정 %@ + 지난 화 요약 %@ = %@. 한도는 %@예요. %@를 줄여야 보낼 수 있어요.").

- [ ] **Step 1: Write the failing tests**
```swift
func testRenderListsSourcesAndFilesSortedBySize()
func testToggleIncludeUpdatesBarAndFactImmediately()   // 체크 끄기 → factLabel 바이트 감소, config.excludedSettings 반영
func testSummarySegmentUpdatesSummarizedSettings()
func testAddFolderOutsideRootShowsErrorAndDoesNotSave()
func testEmptySourcesShowsPlaceholderAndDisablesList()
```
- [ ] **Step 2: Run → 컴파일 실패 확인**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Controller runs tests → PASS**
- [ ] **Step 5: Commit** `feat(ai): work context sources tab with mixed folder/file sources and live budget`

---

### Task 5: ② 지난 화 탭

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContextEpisodesView.swift`
- Modify: `Sources/JenaNoteKit/ai/AIWorkContextWindowController.swift`
- Modify: `Sources/JenaNoteKit/app/Localization.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkContextEpisodesViewTests.swift`

**Interfaces:**
```swift
final class AIWorkContextEpisodesView: NSView {
    init(controller: AIWorkContextWindowController)
    func render(_ resolved: AIResolvedWorkContext, store: AIEpisodeSummaryStore, progress: (Int, Int)?, otherGenerating: Bool, lastRefresh: Date?)
    func openSummary(_ file: AIWorkFile, store: AIEpisodeSummaryStore)   // 새 창(기존 Popover.openSummary 로직 이전) + isSafeInsideRoot 가드
}
```
구성(§7.2 ②): 머리 + 설명("%d화를 쓰는 중이라 1~%d화 요약과 %d화 전문을 함께 보내요…") → 도구 줄("요약 전부 새로 만들기" ↔ 생성 중 "갱신 취소" + "N/M", 오른쪽 "마지막 갱신 …") → 목록(파일명 · 상태 문구+점/🔒 · "열기" · "다시 만들기"/"지금 만들기") → ☑ 앞 화 전문. 직접 고친 요약의 "다시 만들기"는 `NSAlert.beginSheetModal(for: window)`.

L10n(ko/en): `ai.work.episodes.header`("AI가 기억하는 지금까지의 이야기"), `ai.work.episodes.hint`("%d화를 쓰는 중이라 1~%d화 요약과 %d화 전문을 함께 보내요. 요약은 한 번 만들면 다시 안 만들어요."), `ai.work.episodes.hintNone`("아직 지난 화가 없어요. 다음 화부터 요약이 쌓여요."), `ai.work.episodes.refreshAll`("요약 전부 새로 만들기"), `ai.work.episodes.lastRefresh`("마지막 갱신 %@"), `ai.work.episodes.ready`("준비됨"), `ai.work.episodes.manual`("직접 고침"), `ai.work.episodes.manualChanged`("직접 고침 · 원문이 바뀌었어요"), `ai.work.episodes.stale`("원문이 바뀌어 다시 만들 예정"), `ai.work.episodes.missing`("아직 없음 · 다음 요청 때 만들어요"), `ai.work.episodes.previousTag`("앞 화 · 전문"), `ai.work.episodes.makeNow`("지금 만들기"), `ai.work.episodes.remake`("다시 만들기"), `ai.work.episodes.includePrevious`("바로 앞 화는 요약 대신 전문으로 보내기"), `ai.work.episodes.otherGenerating`("다른 요청이 요약을 만드는 중이에요").

- [ ] **Step 1: Write the failing tests**
```swift
func testRowsShowStateTextAndTags()            // ready/manual/manualChanged/stale/missing + 앞 화 태그
func testOpenDisabledWhenSummaryMissing()
func testRefreshButtonTogglesToCancelWhileGenerating()
func testOpenSummaryRefusesSymlinkedLeaf()     // 1차 보류 항목 해소
```
- [ ] **Step 2: Run → 컴파일 실패 확인**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Controller runs tests → PASS**
- [ ] **Step 5: Commit** `feat(ai): work context episodes tab`

---

### Task 6: 채팅 패널 연결, 1차 UI 제거, L10n 정리

**Files:**
- Modify: `Sources/JenaNoteKit/ai/AIChatViewController.swift`
- Delete: `Sources/JenaNoteKit/ai/AIWorkContextPopover.swift`, `AIWorkContextSheet.swift`, `Tests/JenaNoteKitTests/AIWorkContextPopoverTests.swift`, `AIWorkContextSheetTests.swift`
- Modify: `Sources/JenaNoteKit/app/Localization.swift` (1차 전용 키 제거)
- Test: `Tests/JenaNoteKitTests/AIChatLayoutTests.swift` (줄 위치 유지), `AIWorkContextBarTests.swift`

**Interfaces:** `AIChatViewController.openWorkWindow()`:
- `.unavailable(.unsavedDocument)` → 아무 것도 안 함(버튼 비활성).
- `.unavailable(.notInWork)` → `AIWorkContextWindowController.forFirstSetup(fileURL:store:)`, `select(.folders)`, `showWindow`.
- `.corrupt` → 같은 첫 설정 경로(기존 파일은 덮어쓰기 전에 `context.json.bak`으로 이름 변경).
- `.disabled` → 창 열지 않고 `mutate { $0.enabled = true; $0.disabledByUser = false }` 후 `refreshWorkContext()` ("켜기" 버튼). 소스가 0개면 창을 ① 탭으로 연다.
- `.active`/`.generating` → `shared(for:store:)`, `select(.sources)`, `showWindow`.
- 창 훅: `onChange → refreshWorkContext()`, `onRegenerate/onRefreshAll/onCancelRefresh → 기존 regenerateSummary/refreshAllSummaries/cancelMaintenance`, 진행은 `window.maintenanceProgress = …`, 문서 전환 시 `window.currentFile = url; window.reload()`.
- 삭제 뒤 `presentWorkPopover`/`presentWorkSetupSheet`/`syncWorkPopover`/`workPopover`/`workSheet` 제거.

- [ ] **Step 1: Write/adjust tests** — `AIChatLayoutTests`에 "작품 문맥 줄이 문서 이름 바로 아래" 유지; `testOpenWorkWindowRoutesByStatus`(상태별로 어떤 창/탭이 선택되는지, `showWindow`는 스텁으로 가로채기 가능하게 `windowPresenter: (NSWindowController) -> Void` 훅 추가).
- [ ] **Step 2: Run → 실패 확인**
- [ ] **Step 3: Implement + 파일 삭제 + L10n 키 제거**(남는 참조 없는지 grep: `ai.work.active|ai.work.setup|sheetTitle|ai.work.save"|changeSettings|ai.work.include"|ai.work.budget"`).
- [ ] **Step 4: Controller runs full suite → PASS, `make build` OK**
- [ ] **Step 5: Commit** `feat(ai): route work context row to the window; remove popover and sheet`

---

### Task 7: 문서 갱신 (spec.md, ADR-0014 보완)

- [ ] `docs/spec.md` 작품 문맥 소절을 §5/§7 v2로 교체(줄 상태표 — 작성 당시 10행, 최종 리뷰 후 11행 —, 창 3탭, AC 4·4-1).
- [ ] `docs/architecture.md` ADR-0014에 "UX v2(2026-10-27): 텍스트 줄·팝오버·시트 → 눌리는 줄 + 별도 3탭 창; 앱은 해결안을 제시하지 않음; 창은 루트별 1개, 변경 즉시 저장" 보완 항목 추가, 파일 표 갱신.
- [ ] Commit `docs: work context UX v2 in spec and ADR-0014`

---

## Self-Review 기록

- **Spec coverage:** §5.1(T3·T4·T6) · §5.2 줄 문구(T1) · §5.3(T5) · §5.4(T4, 해결안 없음) · §5.5(T1·T6) · §7.1 표(작성 당시 10행, 최종 리뷰 후 11행)(T1) · §7.2 ①(T4) ②(T5) ③(T3) 창 규칙(T3) · §7.3 제거(T6) · §13 UX 개정 5항(T1·T3·T4·T6) · AC 4/4-1(T1·T4).
- **Type consistency:** `AIWorkContextStatus` 새 정의(T1)를 T6 라우팅이 사용; `AIWorkContextModel` 시그니처(T2)를 T4·T5가 사용; `mutate` 단일 경로(T3)를 T4·T5가 사용.
- **Proportion:** 시그니처·테스트명·L10n 키만; 본문 없음.
