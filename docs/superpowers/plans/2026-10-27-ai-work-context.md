# AI 작품 문맥(Work Context) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AI 요청마다 작품의 설정집 원문과 지난 화 요약을 앱이 골라 묶어 함께 보내고, 그 구성을 AI 패널에서 보고 조절할 수 있게 한다.

**Architecture:** `ai/` 레이어에 순수 로직 세 덩어리(설정 파일 `AIWorkContext`, 파일 선별 `AIWorkContextResolver`, 요약 캐시·생성 큐 `AIEpisodeSummaryStore`)를 먼저 세우고, 기존 `AIPrompt.make`에 `work` 페이로드와 예산 축소를 붙인 뒤, 마지막에 `AIChatViewController`와 UI(줄·팝오버·시트)를 연결한다. AI(CLI)는 계속 도구 차단 상태이고 파일은 앱만 읽는다.

**Tech Stack:** Swift 5.7 / AppKit / SwiftPM / XCTest / CryptoKit(SHA-256). 외부 의존성 없음.

**Spec:** `docs/superpowers/specs/2026-10-27-ai-work-context-design.md`

## Global Constraints

- macOS 11+, SwiftPM 타깃 `JenaNoteKit`, 테스트는 `Tests/JenaNoteKitTests/` (`swift test`).
- 새 UI 문자열은 전부 `L10n.tr("ai.work.*")` 키. `Localization.swift`의 `ko`·`en` 표에 추가(다른 언어는 `en` 폴백).
- `AIPrompt.maximumBytes = 500_000` 유지. 작품 문맥 없을 때 프롬프트는 **바이트 단위로 기존과 동일**.
- 읽는 파일 확장자: `md`, `markdown`, `txt`만. 숨김 항목·심볼릭 링크 제외. 작품 루트 밖 경로·절대 경로·`..` 포함 경로는 무시.
- `AIClient`의 CLI 인자(도구 차단)는 변경하지 않는다. 시간 제한만 매개변수화(기본 120, 요약 240).
- 요약 본문은 `.jenanote/summaries/<상대경로>.txt`, 메타데이터는 `.jenanote/summaries/index.json`.
- 요약 CLI 호출은 `prepare`(요청 직전)와 명시적 버튼에서만. 저장·폴더 변경 알림으로는 호출하지 않는다.
- 텍스트 해시: CRLF→LF 정규화 후 SHA-256, `"sha256:" + hex`. 요약 본문 비교는 추가로 앞뒤 공백 제거.
- ADR 번호는 **0014**(0013은 사용 중).

## Review Focus

1. `context.json`에 `../다른작품/설정` 같은 경로가 들어 있을 때: 그 항목만 무시하고 경고, 절대 루트 밖을 읽지 않는다. → Task 2 테스트 `testRejectsEscapingPaths`.
2. 설정 폴더 안에 UTF-8이 아닌 파일(바이너리·EUC-KR)이 있을 때: 크래시 없이 그 파일만 건너뛰고 팝오버에 "읽을 수 없음". → Task 3 테스트 `testUnreadableFileIsSkipped`.
3. 요약 `.txt` 자체를 현재 문서로 열었을 때(`.jenanote/` 아래 파일): 작품 문맥이 끼어들지 않는 단일 파일 모드. → Task 2 테스트 `testFilesInsideJenanoteFolderHaveNoContext`.
4. 화 파일이 이름이 바뀌었을 때: 옛 요약은 고아가 되고 새 이름은 "없음"으로 다시 생성된다. 고아는 삭제하지 않는다. → Task 5 테스트 `testRenamedEpisodeIsMissingAndOrphanKept`.
5. 1화(지난 화 0개)를 쓸 때: CLI 요약 호출 0회, `previousSummaries` 빈 배열, 설정은 그대로 간다. → Task 5 테스트 `testNoPendingFilesMakesNoCalls`, Task 4 테스트 `testPayloadWithNoPreviousEpisodes`.

---

### Task 1: `AIClient`·`AIProcess` 요청별 시간 제한

**Files:**
- Modify: `Sources/JenaNoteKit/ai/AIClient.swift:8-37`
- Test: `Tests/JenaNoteKitTests/AIClientTimeoutTests.swift`

**Interfaces:**
- Produces: `AIClient.send(provider: AIProvider, prompt: String, model: String? = nil, timeout: TimeInterval = AIClient.defaultTimeout, completion:)`, `static let defaultTimeout: TimeInterval = 120`, `static let summaryTimeout: TimeInterval = 240`. `AIProcess.run`은 이미 `timeout:` 매개변수를 갖고 있으므로 전달만 한다.

- [ ] **Step 1: Write the failing test**

```swift
final class AIClientTimeoutTests: XCTestCase {
    func testTimeoutConstants() {
        XCTAssertEqual(AIClient.defaultTimeout, 120)
        XCTAssertEqual(AIClient.summaryTimeout, 240)
    }
    func testArgumentsUnchangedByTimeout() {
        let policy = URL(fileURLWithPath: "/tmp/p.toml")
        for provider in AIProvider.allCases {
            XCTAssertEqual(AIClient.arguments(for: provider, policy: policy),
                           AIClient.arguments(for: provider, policy: policy, model: nil))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AIClientTimeoutTests`
Expected: 컴파일 실패 `has no member 'defaultTimeout'`

- [ ] **Step 3: Implement**

`AIClient`에 두 상수를 추가하고 `send`에 `timeout` 매개변수를 넣어 `process.run(..., timeout: timeout, ...)`으로 전달한다. `AIProvider`가 `CaseIterable`이 아니면 추가한다.

- [ ] **Step 4: Run tests**

Run: `swift test --filter AIClientTimeoutTests`
Expected: PASS. 이어서 `swift test` 전체 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/JenaNoteKit/ai/AIClient.swift Sources/JenaNoteKit/ai/AIProvider.swift Tests/JenaNoteKitTests/AIClientTimeoutTests.swift
git commit -m "feat(ai): per-request timeout on AIClient.send"
```

---

### Task 2: `AIWorkContext` — 설정 파일 모델, 루트 탐색, 제안, 검증

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContext.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkContextTests.swift`

**Interfaces:**
- Produces:

```swift
struct AIWorkContextConfig: Codable, Equatable {
    var version: Int = 1
    var title: String
    var settingsSources: [String]          // 루트 기준 상대 경로(폴더 또는 파일)
    var excludedSettings: [String] = []
    var summarizedSettings: [String] = []
    var writingFolder: String              // 루트 기준 상대 경로
    var includePreviousEpisode: Bool = true
    var enabled: Bool = true
}

struct AIWorkContext: Equatable {
    static let folderName = ".jenanote"
    static let fileName = "context.json"
    static let maxAncestorLevels = 6
    let rootURL: URL
    var config: AIWorkContextConfig
    var invalidPaths: [String]             // 로드 시 무시된 항목(절대 경로·`..`·루트 밖)

    var configURL: URL                     // rootURL/.jenanote/context.json
    var writingFolderURL: URL
    var settingsSourceURLs: [URL]          // 유효한 것만, 순서 유지

    /// 현재 파일 폴더에서 위로 maxAncestorLevels까지 context.json을 찾는다. 가장 가까운 것.
    /// 파일이 .jenanote/ 아래면 nil. 홈 디렉터리·볼륨 루트는 검사하지 않는다.
    static func locate(from fileURL: URL) -> AIWorkContext?
    static func load(rootURL: URL) throws -> AIWorkContext      // 파일 없음 → throws, 깨짐 → throws AIWorkContextError.corrupt
    func save() throws                                            // .jenanote/ 생성 포함
    /// url이 rootURL 아래이고(표준화 비교) 심볼릭 링크를 거치지 않는지
    func contains(_ url: URL) -> Bool
    static func relativePath(of url: URL, to root: URL) -> String?  // 루트 밖이면 nil
}

struct AIWorkContextSuggestion: Equatable {
    let rootURL: URL
    let settingsSourceURL: URL?            // `설정`/`settings` 형제 폴더, 없으면 nil
    let writingFolderURL: URL              // 현재 파일의 폴더
    let title: String                      // rootURL.lastPathComponent
    static func make(for fileURL: URL) -> AIWorkContextSuggestion
}

enum AIWorkContextValidationError: Equatable { case noSettingsSources, settingsOutsideRoot(String), writingFolderOutsideRoot }
enum AIWorkContextError: Error { case corrupt, notFound }

extension AIWorkContext {
    static func validate(rootURL: URL, settingsSources: [URL], writingFolder: URL) -> [AIWorkContextValidationError]
}
```

- [ ] **Step 1: Write the failing tests**

테스트 헬퍼 `makeWork(at:)`: 임시 디렉터리에 `달빛도시/설정/인물.md`, `달빛도시/집필/01화.md`를 만든다.

```swift
func testLocateFindsNearestContextWithinSixLevels()   // 집필/a/b/c/d/e/07화.md → 루트 찾음(6단계), a/b/c/d/e/f/ → nil
func testLocateSkipsFilesInsideJenanoteFolder()        // Review Focus 3: 루트/.jenanote/summaries/01화.md.txt → nil
func testLoadAndSaveRoundTrip()                        // save → load == config
func testRejectsEscapingPaths()                        // Review Focus 1: settingsSources ["../other", "/etc", "설정"] → settingsSourceURLs == [설정], invalidPaths == ["../other", "/etc"]
func testCorruptFileThrowsCorrupt()                    // "{not json" → AIWorkContextError.corrupt
func testSuggestionFindsSettingsSiblingCaseInsensitive() // "Settings" 폴더도 인식, writingFolderURL == 파일 폴더, title == "달빛도시"
func testSuggestionWithoutSettingsFolderUsesParent()   // settingsSourceURL nil, rootURL == 파일의 부모 폴더
func testValidateRequiresSourcesInsideRoot()           // 빈 소스 → noSettingsSources; 루트 밖 → settingsOutsideRoot/writingFolderOutsideRoot
func testContainsRejectsSymlinkEscape()                // 루트 안의 symlink → 루트 밖 디렉터리를 가리키면 contains == false
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AIWorkContextTests`
Expected: 컴파일 실패 `cannot find 'AIWorkContext'`

- [ ] **Step 3: Implement `AIWorkContext.swift`**

`locate`는 `fileURL.deletingLastPathComponent()`부터 시작해 `standardizedFileURL.resolvingSymlinksInPath()`로 비교. 경로 구성요소에 `.jenanote`가 있으면 즉시 nil. `relativePath(of:to:)`는 두 URL을 표준화·심볼릭 해제한 뒤 `pathComponents` 접두 비교. `load`는 `JSONDecoder`, 각 상대 경로에 대해 `hasPrefix("/")`·`components.contains("..")`·`contains` 실패 시 `invalidPaths`로 보낸다. `save`는 `JSONEncoder` + `.prettyPrinted, .sortedKeys`, `createDirectory(withIntermediateDirectories:)`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter AIWorkContextTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/JenaNoteKit/ai/AIWorkContext.swift Tests/JenaNoteKitTests/AIWorkContextTests.swift
git commit -m "feat(ai): work context config, root discovery, suggestion"
```

---

### Task 3: `AIWorkContextResolver` — 설정·화 파일 선별과 읽기

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContextResolver.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkContextResolverTests.swift`

**Interfaces:**
- Consumes: `AIWorkContext`(Task 2).
- Produces:

```swift
struct AIWorkFile: Equatable, Hashable {
    let relativePath: String   // 기준 폴더(설정 소스 루트 / 집필 폴더) 기준, "/" 구분
    let url: URL
    let byteCount: Int
}

struct AIResolvedWorkContext {
    let context: AIWorkContext
    let settings: [AIWorkFile]          // excludedSettings 제외, 상대 경로 자연 정렬
    let excludedSettings: [AIWorkFile]
    let unreadable: [AIWorkFile]        // UTF-8 디코딩 실패 등 (Review Focus 2)
    let episodes: [AIWorkFile]          // 집필 폴더 재귀, 상대 경로 자연 정렬
    let currentIndex: Int?              // nil = 집필 폴더 밖 또는 목록에 없음
    var previousEpisodes: [AIWorkFile]  // currentIndex 앞의 전부, 없으면 []
    var previousEpisode: AIWorkFile?    // includePreviousEpisode && previousEpisodes.last
    var isOutsideWritingFolder: Bool    // currentIndex == nil
}

enum AIWorkContextResolver {
    static let allowedExtensions: Set<String> = ["md", "markdown", "txt"]
    static func resolve(_ context: AIWorkContext, currentFile: URL) -> AIResolvedWorkContext
    /// 재귀 열거. 숨김·symlink·허용 외 확장자 제외. relativePath는 base 기준.
    static func files(under base: URL, recursive: Bool) -> [AIWorkFile]
    static func naturalSort(_ files: [AIWorkFile]) -> [AIWorkFile]   // relativePath.localizedStandardCompare
    static func normalize(_ text: String) -> String                  // CRLF/CR → LF
    /// 디스크에서 UTF-8로 읽어 normalize. 실패 시 throws.
    static func readText(_ file: AIWorkFile) throws -> String
    /// 열려 있는 MarkdownDocument(fileURL 일치)가 있으면 그 content.string, 없으면 readText.
    static func readSettingText(_ file: AIWorkFile) throws -> String
}
```

설정 소스가 파일이면 그 파일 하나가 `AIWorkFile`(relativePath = 파일명). 폴더면 재귀. 여러 소스의 결과를 이어 붙인 뒤 소스 순서 유지, 소스 안에서만 자연 정렬. 설정 `relativePath`는 **루트 기준**으로 통일한다(`excludedSettings`·`summarizedSettings`와 같은 키 공간이어야 하므로). 화 `relativePath`는 **집필 폴더 기준**.

- [ ] **Step 1: Write the failing tests**

픽스처: `설정/세계관.md`, `설정/인물/하연.md`, `설정/인물/.숨김.md`, `설정/표지.png`, `집필/1부/01화.md`, `집필/1부/02화.md`, `집필/1부/10화.md`, `집필/2부/01화.md`, `집필/메모.txt`.

```swift
func testEpisodesSortedByRelativePathNaturally()   // ["1부/01화.md","1부/02화.md","1부/10화.md","2부/01화.md","메모.txt"]
func testPreviousEpisodesStopBeforeCurrent()        // current = 1부/10화 → previous == [01,02], previousEpisode == 02, 뒤의 2부/01화 제외
func testFirstEpisodeHasNoPrevious()                // current = 1부/01화 → previousEpisodes [] , previousEpisode nil
func testIncludePreviousEpisodeFalseDropsFullText() // config.includePreviousEpisode = false → previousEpisode nil, previousEpisodes 유지
func testSettingsRecursiveSkipHiddenAndNonText()    // settings == [설정/세계관.md, 설정/인물/하연.md] (상대 경로는 루트 기준)
func testExcludedSettingsSplitOut()                 // excludedSettings ["설정/인물/하연.md"] → settings 1개, excludedSettings 1개
func testSettingsFileSourceIsSingleFile()           // settingsSources ["설정/세계관.md"] → 그 파일 하나
func testCurrentFileOutsideWritingFolder()          // current = 설정/세계관.md → currentIndex nil, isOutsideWritingFolder, previous 비어 있음
func testUnreadableFileIsSkipped()                  // Review Focus 2: 설정/깨짐.md에 0xFF 0xFE 바이트 → unreadable에 들어가고 settings에서 빠짐, 크래시 없음
func testSymlinkInWritingFolderIgnored()            // 집필/링크.md → 루트 밖 파일 symlink → episodes에 없음
func testReadTextNormalizesCRLF()                   // "a\r\nb" → "a\nb"
func testReadSettingTextPrefersOpenDocument()       // MarkdownDocument().fileURL = 설정/세계관.md, content "메모리" 를 NSDocumentController에 추가하지 않고도 동작해야 하므로, resolver는 `NSDocumentController.shared.documents` 대신 주입 가능한 `openDocuments: () -> [MarkdownDocument]` 정적 훅을 둔다. 테스트에서 훅을 바꿔 "메모리"가 반환되는지 확인
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AIWorkContextResolverTests`
Expected: 컴파일 실패

- [ ] **Step 3: Implement `AIWorkContextResolver.swift`**

`files(under:recursive:)`는 `FileManager.enumerator(at:includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey,.isHiddenKey], options:[.skipsHiddenFiles])`로 열거하고 symlink는 `skipDescendants()`. `readText`는 `String(data:encoding:.utf8)` 실패 시 `AIError(message: L10n.tr("ai.work.unreadable"))`. `resolve` 안에서 설정 파일은 미리 `readText`를 시도해 `unreadable`을 분류한다(용량 표시와 경고를 위해 한 번은 읽어야 한다). `static var openDocuments: () -> [MarkdownDocument] = { NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument } }`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter AIWorkContextResolverTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/JenaNoteKit/ai/AIWorkContextResolver.swift Tests/JenaNoteKitTests/AIWorkContextResolverTests.swift
git commit -m "feat(ai): resolve settings and episode files for work context"
```

---

### Task 4: `AIPrompt` — `work` 페이로드, 예산 축소, 요약 프롬프트

**Files:**
- Modify: `Sources/JenaNoteKit/ai/AIConversation.swift:132-157` (`AIPrompt`)
- Create: `Sources/JenaNoteKit/ai/AIWorkPayload.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkPromptTests.swift`

**Interfaces:**
- Produces:

```swift
struct AIWorkSetting: Equatable { let name: String; let text: String; let summarized: Bool }
struct AIWorkSummary: Equatable { let name: String; let summary: String }
struct AIWorkEpisodeText: Equatable { let name: String; let text: String }

struct AIWorkPayload: Equatable {
    var title: String
    var currentEpisode: String
    var settings: [AIWorkSetting]
    var previousSummaries: [AIWorkSummary]      // 오래된 → 최근 순
    var omittedEarlierEpisodes: Int = 0
    var previousEpisode: AIWorkEpisodeText?
    func json() -> [String: Any]                 // §6.5 키 그대로
    var contextByteCount: Int                    // settings+summaries+previousEpisode 텍스트 UTF-8 합
}

enum AIPromptBudget { case ok, warning, over }   // 비율 <0.8 / ≥0.8 / >1.0

extension AIPrompt {
    static func make(snapshot: AIEditSnapshot, messages: [AIChatMessage], request: String,
                     mode: AIChatMode, hasSelection: Bool, work: AIWorkPayload? = nil) throws -> String
    /// §6.4: 오래된 요약부터 제거 → 앞 화 제거 → 그래도 초과면 throws ai.contextTooLarge(+ ai.work.tooLargeHint)
    static func fit(_ work: AIWorkPayload, base: [String: Any]) throws -> AIWorkPayload
    static func makeSummary(episodeName: String, text: String) throws -> String   // 입력 JSON {"episode": text, "name": name}, 500KB 검사 동일
    static func budget(for bytes: Int) -> AIPromptBudget
    static let workInstruction: String   // §6.5 영문 지시 그대로
    static let summaryInstruction: String // §6.3 요약 지시
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testPromptWithoutWorkIsByteIdenticalToLegacy()   // work: nil 결과 == 기존 시그니처 결과 (Data(utf8) 비교), 지시문에 "work.settings" 미포함
func testPromptWithWorkContainsKeysAndInstruction()   // JSON 파싱 → work.settings[0].name/text/summarized, previousSummaries, omittedEarlierEpisodes==0, previousEpisode; 문자열에 workInstruction 포함
func testPayloadWithNoPreviousEpisodes()              // Review Focus 5: previousSummaries [] 직렬화, previousEpisode null 표기
func testFitDropsOldestSummariesFirst()               // 요약 10개 × 60KB, 설정 20KB → fit 후 omittedEarlierEpisodes > 0, 남은 요약은 뒤쪽(최근) 것, 설정 그대로
func testFitDropsPreviousEpisodeAfterSummaries()      // 요약 모두 빼도 초과하면 previousEpisode nil
func testFitNeverDropsSettings()                      // 설정만 600KB → throws, 메시지에 L10n "ai.contextTooLarge" 포함
func testBudgetThresholds()                           // 399_999 → .ok, 400_000 → .warning, 500_001 → .over
func testSummaryPromptShape()                         // makeSummary 결과에 summaryInstruction, JSON "episode"·"name"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AIWorkPromptTests`
Expected: 컴파일 실패

- [ ] **Step 3: Implement**

`AIPrompt.make`는 `work == nil`이면 기존 코드 경로를 한 글자도 바꾸지 않는다(기존 `context` 딕셔너리와 지시문 그대로). `work != nil`이면 `fit` 후 `context["work"] = payload.json()`, 지시문 끝에 `"\n" + workInstruction`. `fit`은 `base + ["work": json]` 직렬화 바이트를 재며 §6.4 순서로 반복. `summaryInstruction`은 §6.3 한국어 지시를 영어로 옮긴 것을 쓰되 "in the language of the text, 400–700 characters, plain text only" 를 포함.

- [ ] **Step 4: Run tests**

Run: `swift test --filter AIWorkPromptTests` 그리고 `swift test --filter AIModeTests`(기존 회귀)
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/JenaNoteKit/ai/AIConversation.swift Sources/JenaNoteKit/ai/AIWorkPayload.swift Tests/JenaNoteKitTests/AIWorkPromptTests.swift
git commit -m "feat(ai): work payload in prompt with budget trimming and summary prompt"
```

---

### Task 5: `AIEpisodeSummaryStore` — 요약 캐시, 상태 판정, 생성 큐

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIEpisodeSummaryStore.swift`
- Modify: `Sources/JenaNoteKit/ai/AIClient.swift` (프로토콜 채택)
- Test: `Tests/JenaNoteKitTests/AIEpisodeSummaryStoreTests.swift`

**Interfaces:**
- Consumes: `AIWorkFile`, `AIWorkContextResolver.readText/normalize`(Task 3), `AIPrompt.makeSummary`(Task 4), `AIClient.summaryTimeout`(Task 1).
- Produces:

```swift
protocol AISummaryGenerating: AnyObject {
    var tokenUsage: Int? { get }
    func summarize(prompt: String, provider: AIProvider, model: String?, completion: @escaping (Result<String, Error>) -> Void)
    func cancel()
}
extension AIClient: AISummaryGenerating {}   // send(..., timeout: Self.summaryTimeout)

struct AISummaryRecord: Codable, Equatable { var sourceHash: String; var summaryHash: String; var generatedAt: Date; var provider: String }
struct AISummaryIndex: Codable, Equatable { var version = 1; var entries: [String: AISummaryRecord] = [:]; var settings: [String: AISummaryRecord] = [:] }
enum AISummaryState: Equatable { case missing, stale, ready, manuallyEdited(sourceChanged: Bool) }

final class AIEpisodeSummaryStore {
    static func shared(for rootURL: URL) -> AIEpisodeSummaryStore      // 표준화 경로 키 레지스트리, 메인 스레드
    init(rootURL: URL, makeGenerator: @escaping () -> AISummaryGenerating = { AIClient() })
    static func hash(_ text: String) -> String                          // "sha256:" + hex, normalize 적용
    static func summaryHash(_ text: String) -> String                   // trim + normalize 후 hash

    var summariesURL: URL                                              // root/.jenanote/summaries
    var indexURL: URL
    func summaryURL(for file: AIWorkFile, isSetting: Bool) -> URL      // summaries/<rel>.txt | summaries/settings/<rel>.txt
    func state(of file: AIWorkFile, isSetting: Bool) -> AISummaryState
    func summaryText(for file: AIWorkFile, isSetting: Bool) -> String?
    func pending(_ files: [AIWorkFile], isSetting: Bool) -> [AIWorkFile] // missing 또는 stale (manuallyEdited 제외), 입력 순서 유지

    private(set) var isGenerating: Bool
    /// 순차 생성. progress(done, total)는 각 파일 완료 후. 실패 시 즉시 중단, 성공분은 이미 저장됨.
    func prepare(episodes: [AIWorkFile], settings: [AIWorkFile], provider: AIProvider, model: String?,
                 progress: @escaping (Int, Int) -> Void,
                 completion: @escaping (Result<Int, Error>) -> Void)       // Int = 합산 토큰
    /// force == true면 manuallyEdited도 덮어쓴다. 요약 문서가 열려 있고 isDocumentEdited면 throws ai.work.summaryOpenDirty.
    func regenerate(_ file: AIWorkFile, isSetting: Bool, provider: AIProvider, model: String?,
                    completion: @escaping (Result<Int, Error>) -> Void)
    func cancel()
    static var openDocuments: () -> [MarkdownDocument]                  // Task 3과 같은 훅 재사용 가능
}
```

- [ ] **Step 1: Write the failing tests**

가짜 생성기 `FakeGenerator: AISummaryGenerating` — `responses: [Result<String, Error>]`를 순서대로 돌려주고 `calls: [String]`(프롬프트)를 기록.

```swift
func testMissingThenReadyAfterPrepare()                // 상태 missing → prepare → ready, .txt 내용 == 응답, index.json에 sourceHash/summaryHash
func testUnchangedSourceSkipsGeneration()              // prepare 두 번 → 두 번째 calls.count == 0
func testChangedSourceBecomesStaleAndRegenerates()     // 원본 수정 → stale → prepare → calls 1
func testManualEditFreezesSummary()                    // .txt 본문 수정 → manuallyEdited(sourceChanged:false); 원본도 수정 → manuallyEdited(sourceChanged:true); pending에 없음; prepare calls 0; summaryText는 손본 내용
func testRoundTripThroughPlainTextDoesNotFlagManual()  // .txt를 그대로 다시 쓰고(끝 개행 추가) state == ready
func testFailureStopsAndKeepsEarlierSummaries()        // 응답 [ok, fail, ok] → completion failure, 1번 ready, 2·3번 missing, calls.count == 2
func testRetryResumesFromFailedFile()                  // 위 이후 prepare 다시 → calls == [2번, 3번]
func testNoPendingFilesMakesNoCalls()                  // Review Focus 5: episodes [] → calls 0, completion success(0)
func testRenamedEpisodeIsMissingAndOrphanKept()        // Review Focus 4: 01화.md → 1화.md 이름 변경 → 새 파일 missing, 옛 .txt 파일은 그대로 존재
func testCancelStopsQueue()                            // 첫 응답 전에 cancel → completion failure(ai.cancelled), 이후 calls 증가 없음
func testSharedRegistryReturnsSameInstancePerRoot()    // shared(for:) 두 번 === , 다른 루트는 !==
func testRegenerateForceOverwritesManual()             // manuallyEdited → regenerate → ready, 내용 교체
func testRegenerateRefusesDirtyOpenSummary()           // openDocuments 훅으로 isDocumentEdited 문서 제공 → throws/failure ai.work.summaryOpenDirty, 파일 그대로
func testSettingsSummaryUsesSettingsSubfolder()        // isSetting true → summaries/settings/세계관.md.txt, index.settings
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AIEpisodeSummaryStoreTests`
Expected: 컴파일 실패

- [ ] **Step 3: Implement**

큐는 메인 스레드에서 재귀 호출로 순차 진행(`AIClient.send`가 메인에서 완료 콜백). `prepare`는 `pending(episodes) + pending(settings)` 순서. 각 성공 시 `.txt` 쓰기(`atomically: true`) → index 갱신 → `index.json` 쓰기 → progress. `state`는 §6.3 판정 순서(파일/항목 없음 → missing, summaryHash 불일치 → manuallyEdited, sourceHash 불일치 → stale, 그 외 ready). 해시에 CryptoKit `SHA256`. 토큰은 생성기 `tokenUsage` 합.

- [ ] **Step 4: Run tests**

Run: `swift test --filter AIEpisodeSummaryStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/JenaNoteKit/ai/AIEpisodeSummaryStore.swift Sources/JenaNoteKit/ai/AIClient.swift Tests/JenaNoteKitTests/AIEpisodeSummaryStoreTests.swift
git commit -m "feat(ai): episode summary cache with manual-edit protection and sequential generation"
```

---

### Task 6: 작품 문맥 줄(`AIWorkContextBar`)과 `AIChatViewController` 연결

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContextBar.swift`
- Create: `Sources/JenaNoteKit/ai/AIWorkContextAssembler.swift`
- Modify: `Sources/JenaNoteKit/ai/AIChatViewController.swift` (`loadView` 스택, `switchDocument`, `send`, `cancel`, `setBusy`)
- Modify: `Sources/JenaNoteKit/app/Localization.swift` (`ai.work.*` ko/en)
- Test: `Tests/JenaNoteKitTests/AIWorkContextBarTests.swift`, `Tests/JenaNoteKitTests/AIWorkContextAssemblerTests.swift`

**Interfaces:**
- Consumes: Task 2~5 전부.
- Produces:

```swift
enum AIWorkContextStatus: Equatable {
    case none                                   // 작품 아님(미지정)
    case disabled
    case corrupt
    case active(settingsCount: Int, contextBytes: Int, summariesReady: Int, summariesTotal: Int,
                previousEpisode: Bool, outsideWriting: Bool, budget: AIPromptBudget)
    case generating(done: Int, total: Int)
}
final class AIWorkContextBar: NSView {
    var onClick: (() -> Void)?
    func update(_ status: AIWorkContextStatus)
    static func text(for status: AIWorkContextStatus) -> String      // §7.1 표의 문구, L10n 키 사용
    static func color(for status: AIWorkContextStatus) -> NSColor    // secondaryLabel / systemOrange / systemRed
    static func formatBytes(_ bytes: Int) -> String                  // "182KB" (1000 단위, 소수 없음), 1MB 이상 "1.2MB"
}

/// 해석된 문맥 + 요약 저장소 → AIWorkPayload. 읽기 실패 파일은 건너뛰고 skipped에 모은다.
struct AIWorkContextAssembler {
    let resolved: AIResolvedWorkContext
    let store: AIEpisodeSummaryStore
    func payload(currentFile: URL) -> (payload: AIWorkPayload, skipped: [AIWorkFile])
    func status(isGenerating: (Int, Int)?) -> AIWorkContextStatus
}
```

`AIChatViewController` 변경점:
- 프로퍼티 `private var resolvedWork: AIResolvedWorkContext?`, `private let workBar = AIWorkContextBar()`, `private var summaryStore: AIEpisodeSummaryStore?`.
- `loadView` 스택에서 `documentLabel` 바로 뒤에 `workBar`, 너비 제약 추가. `workBar.onClick`은 Task 8의 팝오버(지금은 미지정이면 Task 7 시트, 아니면 no-op 자리).
- `func refreshWorkContext()`: 현재 문서 `fileURL`로 `AIWorkContext.locate` → `resolve` → `summaryStore = .shared(for:)` → `workBar.update(status)`. `switchDocument()` 끝과 `send` 완료 후 호출. `fileURL == nil`이면 `.none`.
- `send()` 순서를 §6.8로 바꾼다: 질문 확정·입력 비움 → `request` 자리 확보(취소 가능하도록 `summaryStore?.cancel()`을 `cancel()`에 추가) → `summaryStore.prepare(previousEpisodes, settings: summarizedSettings)`(진행 중 `workBar.update(.generating)`, `setBusy(true)`) → 완료 후 **그때** `AIEditSnapshot`·`currentSelection` 캡처 → `assembler.payload` → `AIPrompt.make(..., work:)` → 기존 전송. `resolvedWork == nil` 또는 `enabled == false`면 `work: nil`로 기존 경로.
- 요약 실패 시 `conversation.messages`에 status "ai.work.summaryFailed"(파일명 포함) 추가, 입력 복원(기존 실패 처리와 동일 패턴).
- 요약 토큰은 `conversation.tokenUsage[provider]`에 합산.

L10n 키(ko / en 두 표 모두):
`ai.work.none`("작품 문맥: 해당 없음"), `ai.work.setup`("설정하기"), `ai.work.disabled`("작품 문맥: 꺼짐"), `ai.work.corrupt`("작품 문맥: 설정 파일 오류 · 다시 설정"), `ai.work.active`("작품 문맥: 설정 %d개 (%@) · 요약 %@ · %@"), `ai.work.summaries`("%d화"), `ai.work.summariesPartial`("%d/%d화"), `ai.work.previousEpisode`("앞 화 전문"), `ai.work.outsideWriting`("집필 폴더 밖"), `ai.work.overBudget`("한도 초과"), `ai.work.generating`("요약 생성 중 %d/%d"), `ai.work.summaryFailed`("%@ 요약 생성 실패: %@"), `ai.work.tooLargeHint`("작품 문맥에서 설정 파일을 빼거나 요약으로 보내기를 켜 주세요."), `ai.work.unreadable`("읽을 수 없는 파일"), `ai.work.summaryOpenDirty`("요약 문서를 먼저 저장하거나 닫아 주세요."), `ai.work.snapshotNote`("요약 생성 후 그 시점의 선택 영역을 사용합니다.").

- [ ] **Step 1: Write the failing tests**

```swift
// AIWorkContextBarTests
func testTextForEachStatus()        // §7.1 표 7행 각각: 미지정/켬/부분요약/집필밖/끔/생성중 문구가 L10n(ko) 기준으로 일치
func testColorByBudget()            // ok → secondaryLabelColor, warning → systemOrange, over → systemRed, over일 때 텍스트에 "한도 초과"
func testFormatBytes()              // 182_345 → "182KB", 1_234_567 → "1.2MB", 999 → "1KB"

// AIWorkContextAssemblerTests (임시 작품 폴더 + FakeGenerator로 요약 준비 후)
func testPayloadIncludesSettingsSummariesAndPreviousEpisode()  // settings 이름이 루트 기준 상대 경로, summaries 순서, previousEpisode == 직전 화 전문
func testSummarizedSettingUsesSummaryText()                    // summarizedSettings에 든 파일은 summarized == true, text == 요약
func testStatusCountsReadySummaries()                          // 3화 중 2개 ready → summariesReady 2, summariesTotal 3
func testOutsideWritingFolderStatus()                          // outsideWriting true, previousSummaries []
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter 'AIWorkContextBarTests|AIWorkContextAssemblerTests'`
Expected: 컴파일 실패

- [ ] **Step 3: Implement bar, assembler, L10n keys**

- [ ] **Step 4: Run tests**

Run: `swift test --filter 'AIWorkContextBarTests|AIWorkContextAssemblerTests'`
Expected: PASS

- [ ] **Step 5: Wire `AIChatViewController` as described**

- [ ] **Step 6: Run the full suite and the app**

Run: `swift test` → PASS. `make run` → 작품 폴더가 아닌 문서에서 AI 패널을 열면 "작품 문맥: 해당 없음 · 설정하기"가 문서 이름 아래 보이고 기존 요청이 그대로 동작하는지 확인(이 환경에서 화면을 직접 볼 수 없으면 `AIChatLayoutTests` 패턴으로 `workBar`가 스택에 있는지 테스트 추가).

- [ ] **Step 7: Commit**

```bash
git add Sources/JenaNoteKit/ai/AIWorkContextBar.swift Sources/JenaNoteKit/ai/AIWorkContextAssembler.swift Sources/JenaNoteKit/ai/AIChatViewController.swift Sources/JenaNoteKit/app/Localization.swift Tests/JenaNoteKitTests/AIWorkContextBarTests.swift Tests/JenaNoteKitTests/AIWorkContextAssemblerTests.swift
git commit -m "feat(ai): work context bar and prompt assembly in chat panel"
```

---

### Task 7: 작품 문맥 설정 시트(`AIWorkContextSheet`)

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContextSheet.swift`
- Modify: `Sources/JenaNoteKit/ai/AIChatViewController.swift` (`workBar.onClick`에서 미지정·corrupt면 시트)
- Modify: `Sources/JenaNoteKit/app/Localization.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkContextSheetTests.swift`

**Interfaces:**
- Consumes: `AIWorkContextSuggestion.make`, `AIWorkContext.validate/save`(Task 2).
- Produces:

```swift
final class AIWorkContextSheetController: NSWindowController {
    /// 기존 컨텍스트가 있으면 그 값으로, 없으면 suggestion으로 채운다.
    init(fileURL: URL, existing: AIWorkContext?)
    var onSave: ((AIWorkContext) -> Void)?
    // 테스트용 상태 모델
    struct Draft: Equatable { var rootURL: URL; var settingsSources: [URL]; var writingFolder: URL; var title: String
        var errors: [AIWorkContextValidationError]; var canSave: Bool
        func makeConfig() -> AIWorkContextConfig   // URL → 루트 기준 상대 경로
    }
    static func draft(fileURL: URL, existing: AIWorkContext?) -> Draft
    func present(on window: NSWindow)
}
```

UI: 작품 루트(경로 라벨 + "선택…" `NSOpenPanel` canChooseDirectories), 설정 소스(`NSTableView` + "폴더 추가…"/"파일 추가…"/"제거"), 집필 폴더(경로 + "선택…"), 제목(`NSTextField`). 하단 빨간 안내 라벨 + 취소/저장. 저장은 `draft.canSave`일 때만.

L10n: `ai.work.sheetTitle`, `ai.work.root`, `ai.work.settingsSources`, `ai.work.addFolder`, `ai.work.addFile`, `ai.work.remove`, `ai.work.writingFolder`, `ai.work.title`, `ai.work.choose`, `ai.work.save`, `ai.work.cancel`, `ai.work.errorNoSettings`("설정 폴더나 파일을 하나 이상 지정하세요."), `ai.work.errorOutsideRoot`("작품 루트 아래에 있어야 합니다: %@").

- [ ] **Step 1: Write the failing tests**

```swift
func testDraftFromSuggestionPrefillsSettingsSibling()   // 설정 폴더가 있으면 settingsSources == [설정], writingFolder == 파일 폴더, canSave true
func testDraftWithoutSettingsCannotSave()               // errors == [.noSettingsSources]
func testDraftFromExistingContextUsesSavedValues()      // existing config → URL들이 루트 기준 절대 URL로 복원
func testMakeConfigProducesRelativePaths()              // settingsSources ["설정"], writingFolder "집필", excluded 등 기존 값 보존
```

- [ ] **Step 2: Run → 컴파일 실패 확인** (`swift test --filter AIWorkContextSheetTests`)

- [ ] **Step 3: Implement sheet + Draft, hook into `workBar.onClick` (status `.none`/`.corrupt` → 시트; `onSave`에서 `save()` 후 `refreshWorkContext()`)**

- [ ] **Step 4: Run tests → PASS, `swift test` 전체 PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/JenaNoteKit/ai/AIWorkContextSheet.swift Sources/JenaNoteKit/ai/AIChatViewController.swift Sources/JenaNoteKit/app/Localization.swift Tests/JenaNoteKitTests/AIWorkContextSheetTests.swift
git commit -m "feat(ai): work context setup sheet with suggestion and validation"
```

---

### Task 8: 문맥 팝오버(`AIWorkContextPopover`)

**Files:**
- Create: `Sources/JenaNoteKit/ai/AIWorkContextPopover.swift`
- Modify: `Sources/JenaNoteKit/ai/AIChatViewController.swift` (`workBar.onClick`에서 지정됨이면 팝오버)
- Modify: `Sources/JenaNoteKit/app/Localization.swift`
- Test: `Tests/JenaNoteKitTests/AIWorkContextPopoverTests.swift`

**Interfaces:**
- Consumes: `AIResolvedWorkContext`, `AIEpisodeSummaryStore`, `AIWorkContextAssembler.status`, `AIWorkContextSheetController`.
- Produces:

```swift
final class AIWorkContextPopoverController: NSViewController {
    init(resolved: AIResolvedWorkContext, store: AIEpisodeSummaryStore, provider: AIProvider, model: String?)
    var onChange: (() -> Void)?           // context.json 저장 후 호출 → 부모가 refreshWorkContext()
    var onOpenSheet: (() -> Void)?
    // 순수 로직(테스트 대상)
    struct SettingRow: Equatable { let file: AIWorkFile; var included: Bool; var summarized: Bool; let unreadable: Bool }
    struct EpisodeRow: Equatable { let file: AIWorkFile; let state: AISummaryState }
    static func settingRows(_ resolved: AIResolvedWorkContext) -> [SettingRow]
    static func episodeRows(_ resolved: AIResolvedWorkContext, store: AIEpisodeSummaryStore) -> [EpisodeRow]
    static func stateText(_ state: AISummaryState) -> String     // 준비됨/없음/오래됨/직접 수정됨(· 원본 변경 있음)
    static func toggleIncluded(_ config: inout AIWorkContextConfig, path: String)
    static func toggleSummarized(_ config: inout AIWorkContextConfig, path: String)
    static func budgetSegments(_ payload: AIWorkPayload) -> (settings: Int, summaries: Int, previous: Int)
    func openSummary(_ file: AIWorkFile)   // 새 창: NSDocumentController.shared.openDocument(withContentsOf:display:true); 이미 열려 있으면 그 창 makeKeyAndOrderFront
}
```

UI(§7.2 순서): 머리(제목 · "작품 문맥 포함" 스위치 · "설정 변경…") → 용량 막대(`NSView` 3구간 + "182KB / 500KB") → 설정 목록(`NSTableView`: 체크 · 경로 · 크기 · 요약 스위치, unreadable은 회색+경고 아이콘) → 지난 화 목록(경로 · 상태 · "열기" · "다시 생성", 위에 "모두 갱신") → "앞 화 전문 포함" 스위치. 생성 중이면 목록 비활성, "다른 요청이 요약 생성 중" 라벨(`store.isGenerating`). "다시 생성"은 manuallyEdited일 때 `NSAlert` 확인 후 `regenerate`.

L10n: `ai.work.include`, `ai.work.changeSettings`, `ai.work.budget`("%@ / %@"), `ai.work.settingsSection`, `ai.work.summariesSection`, `ai.work.refreshAll`, `ai.work.open`, `ai.work.regenerate`, `ai.work.regenerateConfirm`("직접 수정한 요약을 AI 요약으로 교체할까요?"), `ai.work.stateReady`, `ai.work.stateMissing`, `ai.work.stateStale`, `ai.work.stateManual`, `ai.work.stateManualSourceChanged`, `ai.work.summarize`("요약"), `ai.work.generatingElsewhere`, `ai.work.includePrevious`.

- [ ] **Step 1: Write the failing tests**

```swift
func testSettingRowsReflectExclusionsAndSummarized()
func testEpisodeRowsCarryStoreState()
func testToggleIncludedMovesPathInExcludedSettings()     // 두 번 토글하면 원상복구
func testToggleSummarizedMovesPathInSummarizedSettings()
func testStateTextForManualWithSourceChange()            // "직접 수정됨 · 원본 변경 있음"
func testBudgetSegmentsSumToContextByteCount()
```

- [ ] **Step 2: Run → 컴파일 실패 확인**

- [ ] **Step 3: Implement popover, hook `workBar.onClick` (`.active/.disabled/.generating` → 팝오버, `NSPopover` preferredEdge .maxY), `onChange` → `context.save()` + `refreshWorkContext()`**

- [ ] **Step 4: Run tests → PASS, `swift test` 전체 PASS**

- [ ] **Step 5: Manual check (`make run`)** — 가짜 작품 폴더(설정 2개, 화 3개)에서: 시트로 지정 → 줄 문구 확인 → 요청 1회(요약 생성 진행 표시) → 두 번째 요청에서 재생성 없음 → 팝오버에서 체크 해제 후 `context.json` 반영 → 요약 "열기"가 새 창. 화면을 직접 볼 수 없는 환경이면 `.jenanote/` 산출물(`context.json`, `summaries/*.txt`, `index.json`)로 확인하고 결과를 보고한다.

- [ ] **Step 6: Commit**

```bash
git add Sources/JenaNoteKit/ai/AIWorkContextPopover.swift Sources/JenaNoteKit/ai/AIChatViewController.swift Sources/JenaNoteKit/app/Localization.swift Tests/JenaNoteKitTests/AIWorkContextPopoverTests.swift
git commit -m "feat(ai): work context popover with budget, settings toggles and summary management"
```

---

### Task 9: 문서 갱신 — ADR-0014, spec.md

**Files:**
- Modify: `docs/architecture.md` (ADR-0012 뒤에 ADR-0014 추가, 데이터 흐름 §8 요약)
- Modify: `docs/spec.md` (AI 절에 작품 문맥 흐름 §5와 화면 §7 요약, 인수 기준 §10)

- [ ] **Step 1: ADR-0014 작성** — 제목 "작품 문맥: 앱이 선별해 보낸다, AI는 읽지 않는다". 맥락(단일 파일 문맥의 설정 불일치), 결정(설정 원문 항상 / 지난 화 요약 / 앞 화 전문 / 사용자 지정 / `.jenanote` 캐시 / 요약 `.txt` + `index.json` / 생성 트리거 제한 / 새 창 열기 예외), 트레이드오프(첫 생성 소요, CLI 비용, 설정이 크면 사용자가 선별), 대안(AI에 폴더 접근 허용 — 보안 경계 때문에 기각, 설정 요약 — 디테일 손실로 기각).
- [ ] **Step 2: spec.md 갱신** — 기존 516행 근처 AI 문단 뒤에 "작품 문맥" 소절 추가.
- [ ] **Step 3: Commit**

```bash
git add docs/architecture.md docs/spec.md
git commit -m "docs: ADR-0014 work context and spec update"
```

---

## Self-Review 기록

- **Spec coverage:** §5.1 시트(T7) · §5.2 요청 흐름(T5·T6) · §5.3 요약 수정·열기(T5·T8) · §5.4 용량 경고·제외·요약 토글(T6·T8) · §5.5 작품 밖(T2·T6) · §6.1~6.9(T2~T6) · §7(T6~T8) · §8 구조(파일 표와 일치, `AIWorkContextAssembler`는 계획에서 추가한 분리) · §9 테스트(각 Task에 분배) · §10 인수 기준(1→T6 수동, 2→T5, 3→T5·T8, 4→T6, 5→T8, 6→T4, 7→T1 인자 불변 테스트) · §12·13 결정 반영(T8 새 창).
- **Type consistency:** `AIWorkFile.relativePath`는 설정=루트 기준, 화=집필 폴더 기준으로 T3에 명시했고 T5 `summaryURL`과 T8 토글이 같은 키를 쓴다. `AIPromptBudget`은 T4 정의, T6 상태에서 사용. `openDocuments` 훅은 T3 정의, T5 재사용.
- **Proportion:** 코드 본문 없이 시그니처·테스트명·단언으로 구성.
