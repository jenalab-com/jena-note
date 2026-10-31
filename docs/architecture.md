# JenaNote— 아키텍처 명세

> spec.md 기반. macOS 네이티브 WYSIWYG 마크다운 편집기.

---

## 1. 핵심 패턴: NSDocument 기반 아키텍처

JenaPad는 macOS 표준 문서 앱 패턴인 **NSDocument Architecture**를 따른다.
NSDocument가 다음을 모두 처리하므로 직접 구현하지 않는다:

- 저장 / 다른 이름으로 저장 / 되돌리기
- 창 제목 변경 표시 점(●) 관리
- 앱 종료·창 닫기 전 미저장 확인 시트
- 앱 재시작 시 문서 복원

**금지:** 커스텀 파일 매니저 직접 구현, `FileManager.default.write` 직접 호출

---

## 2. 레이어 구조

의존성은 항상 **위 → 아래** 방향으로만 흐른다.

```
┌──────────────────────────────────────────────────────────┐
│  UI Layer                                                │
│  EditorTextView · FormatToolbar                          │
│  EditorViewController · EditorWindowController           │
│  SidebarViewController (NSOutlineView)                   │
└────────────────┬─────────────────────────┬───────────────┘
                 │ reads/writes            │ asks to open file
                 │ attributed string       │
┌────────────────▼─────────────────────────▼───────────────┐
│  Document Layer                                          │
│  MarkdownDocument (NSDocument)                           │
└────────────────┬─────────────────────────────────────────┘
                 │ serialize / deserialize                  
┌────────────────▼─────────────────────────────────────────┐
│  Infrastructure Layer                                    │
│  MarkdownSerializer · SyntaxHighlighter                  │
│  FolderBookmarksStore · FolderWatcher (FSEvents)         │
└──────────────────────────────────────────────────────────┘
```

**규칙:**
- UI Layer는 `MarkdownSerializer`를 직접 호출하지 않는다
- `MarkdownDocument`는 AppKit(NSTextView 등)에 의존하지 않는다
- `MarkdownSerializer`는 UI/Document 어느 쪽도 import하지 않는다
- `SidebarViewController`는 `EditorViewController`를 직접 참조하지 않는다 — 통신은 NSDocumentController 호출 또는 NotificationCenter로 이루어진다
- `FolderBookmarksStore` / `FolderWatcher`는 AppKit/UI를 import하지 않는다 (`Foundation`만)

---

## 3. 폴더 구조 (Feature-first)

SPM 패키지 구조: `Sources/JenaNote`(진입점·main), `Sources/JenaNoteKit`(기능 모듈), `Tests/JenaNoteKitTests`(단위 테스트).

```
Sources/
  JenaNote/
    main.swift                      — 진입점, NSApplication.main()
  JenaNoteKit/
    app/
      AppDelegate.swift             — 앱 생명주기, 첫 실행 시 빈 문서 열기
      SettingsManager.swift         — 언어/외관/읽기 설정 영속
      Localization.swift            — L10n.tr(key), 7개 언어
      PreferencesWindowController.swift / HelpWindowController.swift
    document/
      MarkdownDocument.swift        — NSDocument 서브클래스: 저장·열기 경계
      MarkdownSerializer.swift      — NSAttributedString ↔ CommonMark 변환
      SyntaxHighlighter.swift       — 코드 블록 문법 하이라이팅
    editor/
      EditorWindowController.swift  — NSWindowController: 창·툴바·SplitView 호스트
      EditorViewController.swift    — NSViewController: Document ↔ View 조율 + 스왑
      EditorTextView.swift          — NSTextView 서브클래스: 텍스트 입력 처리
      FormatCommands.swift          — 서식 액션 (bold, italic, heading, list 등)
      ReaderViewController.swift    — 읽기 전용 조판·스크롤/페이징·폰트 배율 (ADR-0006)
      ReaderMetrics.swift           — 컬럼폭·페이지 높이·여백 계산 순수 함수 (단위 테스트 가능)
      PageRulerView.swift           — 워드식 cm 치수자, 좌·우 여백 핸들 끌기 (ADR-0013)
      ReadingAnchor.swift           — 표시-독립 읽기 위치 + 문맥 재동기화 (ADR-0008)
      ReadingProgressStore.swift    — 문서별 이어읽기 위치 영속 (ADR-0008)
      BookmarkStore.swift           — 문서별 책갈피 N개 영속 (ADR-0008)
      BookmarkListViewController.swift — 책갈피 팝오버 목록 (ADR-0008)
    toolbar/
      FormatToolbar.swift           — NSToolbar + NSToolbarDelegate
      ReaderToolbar.swift           — 읽기 모드 전용 NSToolbar (ADR-0006)
    sidebar/                        ← 신설 (ADR-0004/0005)
      SidebarViewController.swift   — NSOutlineView 호스트, 폴더 추가/제거 UI
      SidebarDataSource.swift       — 트리 노드 모델 + DataSource/Delegate
      FolderBookmarksStore.swift    — UserDefaults 영속, 변경 통지
      FolderWatcher.swift           — FSEvents 래퍼, debounce 200ms
      FileSearcher.swift            — 전체 검색 엔진 (Foundation only, 백그라운드 스캔)
Tests/
  JenaNoteKitTests/
    ReaderMetricsTests.swift        — columnWidth·snappedPageHeight 단위 테스트
    ReadingSettingsTests.swift      — SettingsManager 읽기 설정 영속 테스트
    ReadingAnchorTests.swift        — 앵커 생성·문맥 재동기화 폴백·미리보기 테스트
    ReadingProgressStoreTests.swift — 문서별 위치 영속·정리 테스트
    BookmarkStoreTests.swift        — 책갈피 추가·범위 삭제·정렬·상한 테스트
    BookmarkLocalizationTests.swift — 책갈피 문자열 7개 언어 누락 검사
    SmokeTests.swift                — 모듈 링크 스모크 테스트
Resources/
  Info.plist
```

---

## 4. 각 컴포넌트 책임

### AppDelegate
- 앱 실행 시 `NSDocumentController.shared.openUntitledDocumentAndDisplay(true)`로 빈 문서 열기
- 외부에서 `.md` 파일을 열 때 `NSDocumentController`가 자동 처리 — 별도 구현 불필요

### MarkdownDocument ← 가장 중요한 클래스
```swift
class MarkdownDocument: NSDocument {
    // 유일한 진실 공급원 (Single Source of Truth)
    var content: NSAttributedString = NSAttributedString()

    // 열기: .md 문자열 → NSAttributedString
    override func read(from data: Data, ofType typeName: String) throws {
        let markdown = String(data: data, encoding: .utf8) ?? ""
        content = MarkdownSerializer.parse(markdown)
    }

    // 저장: NSAttributedString → .md 문자열
    override func data(ofType typeName: String) throws -> Data {
        let markdown = MarkdownSerializer.serialize(content)
        return Data(markdown.utf8)
    }
}
```

**금지:** MarkdownDocument 안에 UI 코드(NSTextView, NSAlert 등) 포함

### MarkdownSerializer
- `parse(_ markdown: String) → NSAttributedString`
  - CommonMark 파싱 → Bold/Italic/Heading/List/Code/Link 속성 적용
- `serialize(_ attributed: NSAttributedString) → String`
  - NSAttributedString 속성 → CommonMark 기호로 직렬화
- 순수 함수 형태. 상태 없음. `import Foundation`만 허용.

### EditorViewController
```
역할: MarkdownDocument ↔ EditorTextView 사이 조율자
- viewDidLoad: document.content를 textView에 로드
- textDidChange(notification): textView 내용을 document에 반영 + updateChangeCount(.changeDone)
- FormatCommands 액션을 textView에 적용
```

**금지:** 파일 I/O 직접 호출, 비즈니스 로직 포함

### EditorTextView
```
역할: 텍스트 렌더링 및 사용자 입력 수신
- NSTextView 서브클래스
- keyDown/paste 오버라이드 없이 기본 동작 최대한 활용
- 마크다운 기호는 NSAttributedString 속성으로만 표현 — 기호 문자 자체를 저장하지 않음
```

### FormatCommands
```swift
// 책임: 선택 범위에 NSAttributedString 속성 적용
// 모든 변경은 NSUndoManager(document.undoManager)를 통해 기록
func applyBold(to textView: NSTextView) { ... }
func applyItalic(to textView: NSTextView) { ... }
func applyHeading(_ level: Int, to textView: NSTextView) { ... }
func applyList(ordered: Bool, to textView: NSTextView) { ... }
```

### ReaderViewController
```
역할: 페이징 조판 전용 읽기 오버레이 (ADR-0009 이후 스크롤 조판은 에디터가 직접 입는다).
      원본 document.content는 절대 수정하지 않는다.
- init(content:): 이미 파싱된 NSAttributedString을 받아 저장
- loadView(): 고정폭 컬럼(ReaderMetrics.columnWidth) 중앙 정렬 레이아웃, 하단 페이지 인디케이터
- setFontScale(_:): 배율 적용·영속. ReaderMetrics.scaled로 원본을 건드리지 않고 표시본만 생성
- setPageMode(_:): 스크롤 ↔ 페이징 전환. 페이징은 불투명 PagedHostView 오버레이로 덮는다
- rebuildPages(): 페이지마다 NSTextContainer 를 붙여 물리 분할. 경계는 컨테이너 크기
  (컬럼 폭 × 페이지 높이)에만 의존하므로 창 폭만 바뀐 리사이즈는 재분할하지 않는다
- showCurrentSpread(): 현재 낱쪽 또는 좌·우 펼침면을 호스트 가운데 배치.
  펼침면 여부는 ReaderMetrics.fitsSpread 로 창 폭에서 매번 파생(저장하지 않음).
  페이지 박스(x, 컬럼 폭)는 배치 기준이고 글은 그 안에서 좌 여백만큼 들여 놓는다
- layoutRulers(): 페이지 수만큼 PageRulerView 를 맞춰 각 페이지 위에 얹는다 (ADR-0013).
  끄는 동안은 이웃 치수자만 따라 움직이고, 놓을 때 setPageMargins 로 한 번 재조판
- setPageMargins(left:right:): 여백 영속 + renderContent. 페이지 컨테이너 크기는
  textBoxSize()(= 페이지 폭 − 좌·우 여백)에서 나오므로 여백 변경은 재분할 사유다
- updatePageIndicator(): 페이징 모드에서만 "‹ N / M ›"(펼침면은 "‹ N–N+1 / M ›") 표시
- updateContent(_:): 문서 교체 시(파일 스왑) 원본 갱신 후 재렌더
- goToNextPage() / goToPreviousPage(): 좌우 방향키·휠·트랙패드. 펼침면이면 두 쪽씩
- PageTextView: 한 쪽을 그리는 읽기 전용 텍스트 뷰. 선택·복사(⌘C)가 열려 있고,
  선택을 켜면 이 뷰가 first responder 를 가져가므로 ←/→ 와 타이핑을 VC 로 되넘긴다
- focusPage(): 페이지를 갈아끼울 때 키보드 포커스를 새 쪽으로 넘긴다. 포커스가
  리더 밖(사이드바 등)에 있었으면 뺏지 않는다
- onEditRequested: 페이징 화면에서 글자를 치면 알린다 → 호출자가 스크롤 조판으로 전환.
  넘기는 위치는 고른 자리(캐럿·선택 시작점), 짚은 데가 없으면 그 쪽 첫 글자
```

**금지:** document 또는 NSTextStorage에 쓰기, 파일 I/O 직접 호출

### EditorViewController — 읽기 조판 (ADR-0009)
```
- setReadingLayout(_:): 읽기 조판을 켜고 끈다. 편집·서식·저장은 그대로 살아있다
- refreshReadingLayout(): 배율·서체·행간이 바뀌었을 때 다시 칠한다
- textDidChange: 조판을 벗겨(unstyled) 문서에 넘긴다 — 문서에는 언제나 원본 스타일
- updateColumnInset(): 조판 ON 이면 본문 단을 가운데로 좁히고, OFF 면 기본 여백으로
- placeCursor(at:): 페이징에서 타이핑 시작 시 그 자리로 커서를 옮긴다
- loadContent(of:): 문서를 직접 받아 싣는다. `document` 는 view.window 를 타고 오므로
  뷰가 분리된 동안(페이징 조판)에는 nil — 그 타이밍에 기대지 않으려면 이쪽을 쓴다
- ReadingPositionProviding 준수: 스크롤 조판의 읽던 자리 제공
```

**주의:** 조판된 스토리지를 document 로 그대로 넘기지 말 것 — 반드시 `unstyled()` 를 거친다.

### 작품 문맥 (`ai/`, ADR-0015)
- `AIWorkContext` / `AIWorkContextResolver`: 작품 등록, 경로 검증, 파일 목록·현재 화 이전 범위 계산. 기존 설정·제외 목록을 유지한다.
- `AIWorkIndex`: 안전한 원문 스캔, UTF-8 크기별 조각 분할, 내용 해시·줄 위치, 요청별 접근 범위, 원문·요약 문자열 검색.
- `AIWorkIndexStore`: 작품별 공유 생성 큐. 백그라운드 스캔, 변경 조각만 AI 요약, 조각별 원자 저장, 재개·재시도·사용량·진행 알림. `.jenanote/work-index.json`에 원문 조각과 검색용 요약을 함께 보관한다.
- `AIWorkRetrieval`: AI의 JSON 검색/읽기 요청을 앱에서 실행. 최대 4회/240초/원문 160KB. 현재 화 이후의 파일은 목차·검색·읽기 모두에서 제외한다.
- `AIWorkPayload` / `AIPrompt`: 선택된 설정 원문·이전 화 발췌와 확인 범위를 보내고 최종 자료 크기를 자동 조절한다. 본문은 임의로 자르지 않는다.
- `AIWorkContextBar` / `StatusBarView`: 준비·완료·실패 한 줄. `AIWorkContextWindowController`의 참고 자료 탭은 출처 관리, `AIWorkIndexView`는 이전 화의 자동 준비/재시도/사용량, 작품 폴더 탭은 등록 범위를 관리한다.
- 이전 `AIEpisodeSummaryStore`·수동 요약 포맷은 보존한다. 기존 요약 파일을 자동 인덱스에 덮어쓰거나 혼합하지 않는다. 호환 로직의 회귀 테스트를 유지한다.
- `MarkdownDocument` 저장과 `EditorWindowController` 문서 열기는 준비를 예약한다. `AIChatViewController`는 요청 직전 준비 확인 → 현재 본문 스냅샷 → 원문 탐색 → 기존 답변/수정 호출 순서다. `AIProcess`/`AIClient` 도구 차단 정책은 그대로다.

---

## 5. 데이터 흐름

### 텍스트 입력 → 화면 렌더링
```
사용자 키 입력
  → EditorTextView (NSTextStorage 업데이트)
  → textDidChange 이벤트
  → EditorViewController.textDidChange(_:)
  → document.updateChangeCount(.changeDone)   ← 창 제목 ● 표시
```

### 서식 적용 (툴바 / 단축키)
```
툴바 아이콘 클릭 / Cmd+B
  → FormatToolbar → EditorViewController 액션 호출
  → FormatCommands.applyBold(to: textView)
  → textView.textStorage 속성 변경 (undo 등록 포함)
  → 화면 즉시 반영 (기호 미노출, 볼드체 렌더링)
```

### 저장
```
Cmd+S
  → NSDocument.save(_:)   ← AppKit이 처리
  → data(ofType:) 호출
  → MarkdownSerializer.serialize(content) → .md 문자열 생성
  → 디스크 기록
  → 창 제목 ● 제거
```

### 열기
```
파일 선택 / Finder 더블클릭
  → NSDocumentController가 MarkdownDocument 인스턴스 생성
  → read(from:ofType:) 호출
  → MarkdownSerializer.parse(markdown) → NSAttributedString
  → EditorViewController.viewDidLoad에서 textView에 로드
  → 기호 없이 서식 적용된 상태로 표시
```

### 사이드바 파일 클릭 → 인-플레이스 문서 스왑 (ADR-0004)
```
사용자가 사이드바에서 .md 파일 클릭
  → SidebarViewController가 EditorWindowController.openFile(at:) 호출
  → 현재 document의 canClose(...) 확인 (미저장 시 시트)
  → NSDocumentController.openDocument(withContentsOf:display:false)
  → 기존 윈도우 컨트롤러를 currentDoc에서 removeWindowController
  → 새 document에 addWindowController
  → EditorViewController.loadDocumentContent() 재호출
  → 사이드바에서 해당 행 하이라이트
```

### 사이드바 트리 갱신 (ADR-0005)
```
폴더 변경 (외부에서 add/rename/delete)
  → FSEventStream 콜백 (FolderWatcher)
  → 200ms debounce
  → FolderBookmarksStore가 영향받은 폴더 재스캔
  → NotificationCenter 통지
  → SidebarDataSource.reloadTree(animating:)
```

### AI 요청에 작품 문맥 포함 (ADR-0015)
```
글 열기 / 저장 / 자료 등록
  → AIWorkIndexStore.schedule (0.8초 변경 모으기)
  → 백그라운드 스캔 → 변경 조각 AI 요약 → 영속 저장
send()
  → AIWorkIndexStore.ensure (현재 폴더 변경 재확인 / 진행 중 작업 공유)
  → 본문·선택 스냅샷 + 현재 화 이전 범위
  → AIWorkRetrieval (AI가 검색어/읽기 ID 선택 → 앱이 검색/발췌, 최대 4회)
  → AIPrompt.make(... work:) (자료 자동 축소, 확인 범위 명시)
  → AIClient.send → 기존 가이드 / 수정 충돌 검사 / Undo
```

---

## 6. 상태 관리

| 상태 | 소유자 | 방식 |
|------|--------|------|
| 문서 내용 | `MarkdownDocument.content` | NSAttributedString (Single Source of Truth) |
| 미저장 여부 | `NSDocument.isDocumentEdited` | updateChangeCount로 자동 관리 |
| Undo/Redo 스택 | `NSDocument.undoManager` | NSTextView가 자동 등록 |
| 선택 범위 | `NSTextView.selectedRange` | 컴포넌트 로컬 상태 |
| 툴바 버튼 활성화 | `EditorViewController` | textView selection 변화 시 갱신 |

**금지:**
- 전역 싱글톤에 문서 상태 저장
- 동일 내용을 Document와 ViewController 양쪽에 중복 보관

---

## 7. 메뉴 연결 전략

macOS 표준 Responder Chain을 그대로 활용한다. 별도 메뉴 관리 코드 불필요.

```
File > Save          → NSDocument.save(_:)              (자동 연결)
File > Save As       → NSDocument.saveAs(_:)            (자동 연결)
File > Open          → NSDocumentController.openDocument (자동 연결)
Edit > Undo/Redo     → NSUndoManager                    (자동 연결)
Edit > Copy/Paste/Cut → NSTextView                      (자동 연결)
Edit > Select All    → NSTextView                       (자동 연결)
Format > Bold        → EditorViewController.toggleBold  (커스텀 액션)
```

**금지:** AppDelegate에서 메뉴 액션 직접 처리, NSMenuItem 수동 enable/disable 관리

---

## 8. 빌드 구조

**SPM(Swift Package Manager) + Makefile 래핑** 방식을 따른다. `Package.swift`가 타겟을 정의하고, `Makefile`이 빌드·런·테스트·설치를 래핑한다.

```makefile
# 주요 Makefile 타겟
build:
    swift build -c release --product JenaNote
    # .app 번들 구성 (Info.plist, Resources 복사)

run: build
    open .build/JenaNote.app

test:
    swift test

clean:
    rm -rf .build
```

**패키지 구조:**
- `Sources/JenaNote` — `@main` 진입점 (AppKit 의존)
- `Sources/JenaNoteKit` — 기능 모듈 (라이브러리 타겟, 단위 테스트 가능)
- `Tests/JenaNoteKitTests` — 순수 함수(ReaderMetrics, SettingsManager 등) 단위 테스트

---

## 9. 아키텍처 결정 기록 (ADR)

### ADR-0001: NSDocument 기반 채택
- **결정:** 커스텀 파일 매니저 대신 NSDocument 서브클래스 사용
- **근거:** 미저장 경고, 저장 시트, Undo 통합, 문서 복원이 무료로 제공됨
- **결과:** AppKit 의존성이 Document Layer에 묶임. 테스트 시 AppKit 필요.

### ADR-0002: 내부 표현으로 NSAttributedString 선택
- **결정:** 마크다운 AST 대신 NSAttributedString을 편집 중 내부 표현으로 사용
- **근거:** NSTextView와 직접 통합, Undo/Redo 자동 지원, AppKit 렌더링 최적화 활용
- **결과:** MarkdownSerializer가 양방향 변환을 담당하며, CommonMark 완전 지원에 한계가 있을 수 있음 (복잡한 중첩 구조). 허용 가능한 트레이드오프.

### ADR-0003: 단일 창 / 단일 문서 — **DEPRECATED (2026-05-17, ADR-0004로 대체)**
- **결정:** 멀티탭·멀티창 미지원 (spec Out-of-Scope 준수)
- **근거:** 복잡도를 최소화하고 NSDocument 기본 동작을 그대로 활용
- **결과:** 사용자는 파일마다 새 창을 열어야 함. macOS 표준 동작으로 허용 가능.
- **폐기 사유:** 사이드바 폴더 브라우저 도입(ADR-0004) — 단일 창 안에서 사이드바로 문서를 빠르게 교체하는 UX가 핵심 가치이므로 단일-창 단일-문서 모델로는 달성 불가.

### ADR-0004: SplitViewController + 인-플레이스 문서 스왑 (2026-05-17)
- **결정:** `EditorWindowController`가 `NSSplitViewController`를 contentViewController로 호스트한다. 좌측 = `SidebarViewController`, 우측 = `EditorViewController`. 사이드바에서 파일 클릭 시 현재 창의 NSDocument를 교체한다 (`removeWindowController` → 새 Document에 `addWindowController`).
- **근거:** 사이드바의 핵심 가치(빠른 탐색)는 클릭마다 새 창이 뜨는 모델로는 달성 불가. macOS-네이티브 NSDocument를 유지하면서도 VS Code/Obsidian 류의 인-플레이스 스왑 UX를 제공.
- **결과:**
  - 미저장 변경 시 `NSDocument.canClose(...)` 흐름 재사용 → 저장 확인 시트.
  - 동일 파일이 이미 다른 창에 열려 있으면 그 창을 전면으로 (NSDocumentController 기본 동작).
  - 멀티 창은 여전히 가능하나 권장 흐름은 단일 창 + 사이드바.
- **트레이드오프:** `NSDocument.makeWindowControllers()`가 자동으로 만든 window controller를 빈 문서일 때는 사용하지 않고 기존 창 controller를 양도하는 분기 처리가 추가됨.

### ADR-0005: FolderBookmarksStore + FolderWatcher (2026-05-17)
- **결정:** 신설 `sidebar/` 모듈에 `FolderBookmarksStore` (UserDefaults 영속), `FolderWatcher` (FSEvents 래퍼)를 둔다. Document Layer에는 의존하지 않으며 `MarkdownDocument`도 사이드바를 모른다.
- **근거:** 사이드바 상태는 문서와 독립적이므로 별도 인프라 레이어에 둔다. FSEvents는 폴링 대비 키 입력 예산(50ms)을 보호한다.
- **결과:**
  - 비-샌드박스 가정: `URL`을 path 문자열로 직렬화. MAS 배포 전환 시 `bookmarkData(options: .withSecurityScope)`로 마이그레이션 필요 (보류, 기획 로그 §11).
  - FSEvents 콜백은 메인 스레드에서 200ms debounce 후 트리 reload.
  - 등록 폴더 누락/볼륨 분리 등 에러 상태는 store가 보존하고 ViewController가 표시.

### ADR-0006: 읽기 모드 = split 우측 item 스왑 + 세로 구간 점프식 가로 페이지네이션 (2026-06-21)
- **결정:** 읽기 모드를 별도 창이 아닌 `EditorWindowController` 우측 split item을 `ReaderViewController`로 교체하는 방식으로 구현한다. 가로 페이지 넘김은 단일 컬럼 레이아웃을 뷰 높이(줄 높이 정수배) 단위로 끊어 scroll offset을 점프시켜 근사한다.
- **근거:** 사이드바·툴바·문서 스왑(ADR-0004) 재사용. NSTextView 물리적 페이지 분할의 무게를 피하면서 전자책 UX 대부분을 얻는다. 회귀 테스트를 위해 SPM 도입(ReaderMetrics 순수 함수 검증).
- **트레이드오프:** 진짜 조판 페이지네이션(가변 줄 수, 고아/미망인 제어) 미지원. 페이지 바닥 여백 발생 가능. 읽기 모드는 읽기 전용이라 문서 변경 위험 없음.
- **개정 (2026-06-21, v1.1.0):** scroll-offset 점프는 줄 잘림이 근본적으로 해소되지 않아 **페이지마다 독립 NSTextContainer**를 두는 물리 분할로 재작성했다. 안 들어가는 줄은 통째로 다음 페이지로 흐른다. 대가로 페이징 모드에서 텍스트 선택을 끈다(←/→ 키 충돌 회피).
- **개정 (2026-08-01):** 창 폭이 두 단을 담을 만하면 좌·우 2페이지 펼침면으로 보여준다. 페이지 경계는 컨테이너 크기(컬럼 폭 × 페이지 높이)에만 의존하므로 **펼침면은 순수한 표시 계층 변경**이다 — 이미 나뉜 컨테이너 두 개를 나란히 얹을 뿐 재분할하지 않는다. 전환 임계는 `ReaderMetrics.fitsSpread`(히스테리시스 40pt로 경계 요동 방지), 넘김은 두 쪽씩, 왼쪽은 항상 짝수 쪽. 상태를 저장하지 않으므로 툴바·설정이 늘지 않는다. 설계: `docs/superpowers/specs/2026-08-01-reader-two-page-spread-design.md`

### ADR-0009: 읽기 모드 = 별도 화면이 아닌 '읽기 조판' — 에디터가 조판을 입는다 (2026-08-01)
- **결정:** ⌘⇧R 은 우측 페인을 `ReaderViewController` 로 갈아끼우지 않고, `EditorViewController` 가 읽기 조판(명조·배율·행간·좁은 단)을 입도록 토글한다. 스크롤 조판에서는 편집·서식·저장이 그대로 동작한다. 페이징 조판만 읽기 전용 오버레이(`ReaderViewController`)로 남고, 거기서 글자를 치면 스크롤 조판으로 갈아타 그 자리에서 이어 쓴다.
- **근거:** 편집 기능(서식 툴바·단축키·이미지·저장·찾기)이 전부 에디터와 `FormatCommands` 에 묶여 있다. 리더에 편집을 달면 이 배선을 한 벌 더 깔고 영원히 두 벌을 같이 고쳐야 한다. 반대 방향은 조판 계산(`ReaderMetrics`)만 재사용하면 되고 편집 기능은 이미 다 있다.
- **원본 불변 계약의 이행:** ADR-0006 의 "리더는 원본에 쓰지 않는다"를 편집 가능해진 뒤에도 지킨다 — 조판은 **화면에만** 입히고, `textDidChange` 가 조판을 벗겨(`ReaderMetrics.unstyled`) 문서에 넘긴다. 그래서 조판을 켜고 끄는 것만으로는 문서가 더러워지지도 저장 결과가 달라지지도 않는다.
  - 조판이 폰트를 갈아끼울 때 원본을 `.mdBaseFont`/`.mdBaseParagraph` 에 백업해 추측 없이 되돌리고, 재조판 시 배율 누적도 막는다. 백업이 없는(조판 중 새로 입력된) 구간은 `.mdBlockType` 에서 기준 폰트를 다시 세운다.
- **급소 — 폰트 trait 소실:** 직렬화는 볼드·이탤릭을 폰트 trait 으로 판정하는데 `AppleMyungjo` 에는 볼드·이탤릭 변형이 없다(실측 확인). 읽기 전용일 때는 표시 버그였지만 편집이 열리면 저장 시 `**볼드**` 가 실제로 사라진다. → `readerFont()` 가 변형 있는 명조를 먼저 찾고, 그래도 trait 이 붙지 않으면 서체 일관성보다 서식 보존을 우선해 시스템 폰트로 내려간다. `ReaderLayoutRoundTripTests` 13건이 이 불변식을 지킨다.
- **읽던 자리의 주인이 둘:** 스크롤은 에디터, 페이징은 리더가 그리므로 `ReadingPositionProviding` 프로토콜로 통일하고 윈도우 컨트롤러는 `positionProvider` 하나만 본다. 스크롤 위치 계산은 `ScrollReadingPosition` 으로 뽑아 공유한다.
- **트레이드오프:** 페이징 조판에서의 직접 편집은 지원하지 않는다(타자마다 재분할·커서 추적·앵커 보정이 겹치는 가장 깊은 버그 지대). 툴바는 아직 읽기 툴바만 붙어 서식은 메뉴·단축키로 쓴다 — 후속 단계.
- **함정 (2026-08-01 실측):** `EditorViewController.document` 는 `view.window?.windowController?.document` 를 타고 온다. 페이징 조판 동안 에디터는 split 에서 빠져 있어 window 가 nil 이므로 `loadDocumentContent()` 가 **조용히 건너뛴다**. 그 사이 사이드바로 문서를 바꾸면 에디터에 옛 문서가 남아 스크롤 조판으로 돌아올 때 되살아난다. → 호출자가 문서를 알 때는 `loadContent(of:)` 로 직접 넘긴다(`EditorDocumentLoadTests`).

> 2026-10-25: 위 ADR의 페이징 직접 편집 제외 및 타이핑 시 스크롤 전환 결정은 아래 ADR-0010으로 대체한다. 원본/표시 서식 분리 원칙은 유지한다.

### 알려진 결함: 한글 이탤릭이 NSTextStorage 를 거치며 소실 (2026-08-01 확인, 읽기 조판 이전부터 존재)
- **증상:** `*기울임*` 처럼 한글에 이탤릭을 준 문서는 열었다 저장하기만 해도 이탤릭이 사라진다. 볼드와 영문 이탤릭은 안전하다.
- **원인:** 시스템 이탤릭 폰트(`.SFNS-RegularItalic`)에 한글 글리프가 없어 NSTextStorage 의 attribute fixing 이 한글을 그릴 수 있는 폰트(`.AppleSDGothicNeoI-Regular`)로 갈아끼우는데, 그 대체 폰트는 italic trait 을 보고하지 않는다. 확인한 한글 서체 4종이 모두 같다 — **폰트 trait 으로는 한글 이탤릭을 표현할 수 없다.**
- **제대로 된 해결:** 볼드·이탤릭을 폰트 trait 이 아니라 커스텀 속성으로 판정한다 (`parse`·`serialize`·`FormatCommands` 세 곳). 읽기 조판과 독립된 문제라 분리해 둔다.
- 현재 동작은 `EditorDocumentLoadTests.testKnownIssue_HangulItalicLostThroughTextStorage` 가 못박아 둔다.
- 설계: `docs/superpowers/specs/2026-08-01-editable-reading-layout-design.md`

### ADR-0007: NSTextFinder 찾기 바 + 사이드바 통합 전체 검색 (2026-07-13)
- **결정:** 문서 내 검색은 커스텀 UI 없이 `NSTextView.usesFindBar`(NSTextFinder)에 위임한다. 파일 전체 검색은 사이드바에 `NSSearchField`를 두고, 같은 NSOutlineView를 트리 모드 ↔ 결과 모드로 전환해 표시한다. 결과 클릭 → 문서 위치 이동은 원문 오프셋 매핑 대신 **순번 매칭**(파일 내 n번째 occurrence를 에디터 텍스트에서 재탐색)을 쓴다.
- **근거:** NSTextFinder는 검색 필드·이동·매치 카운트·하이라이트·현지화를 무료 제공 (커스텀 구현 대비 코드 1/20). 사이드바는 이미 폴더·파일·인-플레이스 스왑(ADR-0004)을 소유 — 전체 검색의 자연스러운 위치. 원시 `.md` 오프셋은 WYSIWYG 변환(기호 제거) 후 오프셋과 달라 직접 매핑 불가.
- **결과:**
  - `FileSearcher`(Infrastructure, Foundation only): 백그라운드 스캔, 취소 토큰, 2MB/500건 상한.
  - `SidebarFileOpener`가 `SearchJump(query, ordinal)` 파라미터로 확장 — 사이드바→에디터 직접 참조 없음 유지.
  - 검색어가 마크다운 기호 내부(링크 URL 등)에만 매치되면 순번이 어긋날 수 있음 → 첫 occurrence 폴백. 허용 가능한 엣지.
- **트레이드오프:** 읽기 모드 페이징에서는 찾기 바 미지원(페이지별 분리 텍스트뷰). 정규식·다중 파일 일괄 바꾸기 미지원 (YAGNI).

### ADR-0008: 이어읽기 앵커 = 문자 오프셋 + 문맥 스니펫 (2026-07-22)
- **결정:** 읽던 위치를 페이지 번호나 스크롤 y 가 아니라 **문자 오프셋**으로 저장한다. 문서 편집에 대비해 그 지점의 원문 32자(`contextSnippet`)를 함께 남기고, 복원 시 3단계 폴백(제자리 확인 → ±2048자 재탐색 → 전체 재탐색 → 클램프)으로 위치를 되찾는다.
- **근거:** 표시 위치는 폰트 배율·패밀리·행간·컬럼 폭·페이지 모드·창 크기 6개 변수에 전부 종속이라 설정이 하나만 바뀌어도 무의미해진다. 반면 `ReaderMetrics.styled` 는 속성만 바꾸고 문자를 넣거나 빼지 않으므로 원본과 표시본의 문자 인덱스가 1:1 로 보존된다(이미지 첨부도 U+FFFC 한 글자). 즉 문자 오프셋이 이 6개 변수와 무관한 유일한 좌표다.
- **결과:**
  - `ReaderViewController` 가 `anchorOffset` 하나를 진리의 원천으로 두고, 페이지 번호·스크롤 y 는 여기서 파생시킨다. 조판이 바뀔 때마다(`renderContent`/`rebuildPages`) 앵커에서 위치를 다시 찾으므로 **폰트를 키워도 읽던 문장이 화면에 남는다** — 이어읽기의 부산물로 얻은 개선.
  - 저장 책임은 `EditorWindowController` 에 둔다. 리더는 `onPositionChanged` 콜백(0.5초 코얼레싱)만 쏘고 저장소를 모른다.
  - 위치가 바뀔 때마다 저장하므로 읽기 모드인 채 앱을 종료해도 위치가 남는다(종료 경로를 일일이 훅킹하지 않아도 됨).
  - `ReadingProgressStore` 는 파일 경로를 키로 UserDefaults 에 JSON 보관, 상한 300건(초과 시 오래된 것부터 정리). 비-샌드박스 전제는 ADR-0005 와 동일.
- **트레이드오프:** 완전히 주기적으로 반복되는 텍스트에서 삽입량이 반복 주기와 정확히 일치하면 밀렸다는 사실 자체를 알 수 없다 — 이때는 제자리를 택한다(독자에게는 같은 내용이 보이므로 무해). 파일 경로가 바뀌면(이동·이름 변경) 위치를 잃는다.

#### ADR-0008a: 책갈피 — 같은 앵커 타입 재사용 + 리더 툴바 팝오버 (2026-07-22)
- **결정:** 명시적 책갈피(⌘D)는 이어읽기와 **같은 `ReadingAnchor`** 를 문서당 N개 보관하는 것으로 구현한다(`BookmarkStore`). 목록 UI는 사이드바가 아니라 **리더 툴바의 NSPopover** 에 둔다. 목록에 보이는 미리보기 텍스트는 저장하지 않고 그릴 때마다 현재 본문에서 뜬다.
- **근거:**
  - 앵커 인프라(오프셋↔페이지/스크롤 변환, 문맥 재동기화)를 이어읽기에서 이미 검증했으므로 책갈피는 저장 구조와 UI만 얹으면 된다.
  - 사이드바는 `searchResults != nil` 불리언 하나로 트리↔검색 2모드를 굴리고 있어, 세 번째 모드를 넣으면 흩어진 `isSearching` 분기가 전부 3-way가 된다. 책갈피는 읽기 모드 전용이라 리더 툴바가 맥락상으로도 맞다.
  - 미리보기를 저장하면 문서가 편집된 뒤 목록의 문구와 실제로 점프해서 보이는 문장이 어긋난다. 매번 뜨면 항상 일치하고 저장 데이터도 줄어든다.
- **결과:**
  - ⌘D 는 **토글**이다 — 지금 보이는 화면(`ReaderViewController.visibleCharacterRange`) 안에 책갈피가 있으면 해제, 없으면 현재 위치에 추가. 스크롤/페이징 어느 쪽이든 "보이는 것"을 기준으로 판정한다.
  - 툴바 아이콘이 `bookmark` ↔ `bookmark.fill` 로 바뀌어 현재 화면의 책갈피 유무를 알린다(피드백 채널).
  - 메모 입력은 넣지 않았다 — "읽다가 훅 찍기"의 결이 깨지고, 자동 스니펫으로 충분하다고 판단.
  - 저장 안 된 새 문서(`fileURL == nil`)에서는 메뉴가 비활성(`validateMenuItem`).
- **트레이드오프:** 여러 문서의 책갈피를 한눈에 보는 화면은 없다(현재 문서만). 필요해지면 사이드바 모드 정리와 함께 별도로 다룬다. 책갈피에 사용자 메모·이름을 붙이는 것도 보류.

#### ADR-0009: 읽기 서체 — 번들 글꼴 + 패밀리 기반 해석, 조판 굵기와 마크업 볼드의 분리 (2026-08-03)
- **결정:** 읽기 모드 본문 서체를 사용자가 고르게 하되, ① 기본 명조는 **앱 번들 동봉**(KoPub 바탕 Medium·Bold, `Resources/Fonts` + Info.plist `ATSApplicationFontsPath`)으로 깔고, ② 서체는 PostScript 이름이 아니라 **패밀리 이름**으로 해석하며, ③ 조판이 얹은 굵기에는 `.mdReaderBold` 표시를 달아 마크다운 `**볼드**` 와 분리한다.
- **근거:**
  - **번들:** 서체를 사용자 머신의 설치 상태에 맡기면 같은 문서가 기기마다 다르게 조판된다. 번들 폰트는 `NSFont` 조회에서 시스템 설치본보다 우선하므로(프로브로 확인) 기준 조판이 고정된다. KoPub 은 무료 배포 글꼴이라 동봉이 가능하다.
  - **패밀리 기반:** 굵기 전환은 `NSFontManager.font(withFamily:traits:weight:size:)` 가 패밀리 안에서 가장 가까운 굵기를 골라 주는데, 이 API 가 패밀리 이름을 요구한다. 서체마다 굵기 체계가 제각각(KoPub=Light/Medium/Bold, 나눔명조=Regular/Bold, Apple 명조=단일)이라 서체별 하드코딩은 유지 불가능하다.
  - **굵기 분리(가장 중요):** 직렬화는 볼드 trait 으로 `**` 를 판정한다(`MarkdownSerializer`). 그리고 조판 중 새로 입력된 구간은 `.mdBaseFont` 백업이 없어 조판 폰트의 trait 을 "사용자가 준 볼드"로 물려받는다(`ReaderMetrics.originalFont`). 이 둘이 만나면 **본문 굵기를 '굵게'로 둔 채 친 글자가 저장 시 통째로 볼드 마크업이 된다** — 표시 설정이 파일을 바꾸는 사고다.
- **결과:**
  - `ReadingFont` 는 식별자만 갖고, 패밀리 후보·설치 판정·폰트 해석은 전부 `ReaderMetrics` 가 맡는다(설정은 무엇을 골랐는지만 알고 그것이 어떤 폰트인지는 모른다).
  - 툴바 팝업은 `availableReadingFonts` — 설치된 서체만 담는다. 항목은 그 서체로 그려 고르기 전에 생김새가 보인다. 목록이 머신마다 달라지므로 선택 인덱스가 아니라 `representedObject` 의 rawValue 로 되짚는다.
  - `.mdReaderBold` 는 **두 경로 모두**에서 걸러진다 — 조판을 벗길 때(`unstyled`)와 조판된 채 저장될 때(`MarkdownSerializer`, 조판 해제를 잊은 경로의 안전망). 후자를 빠뜨리면 `testStyledTextStillSerializesWithBoldIntact` 가 지키던 경로로 오염이 새어 나간다.
  - 구버전 설정값과의 호환을 위해 `serif`/`sans` 케이스를 "자동"(서체 미특정)으로 남겼다. 고른 서체가 머신에서 사라지면 자동 명조로 물러난다.
- **트레이드오프:** 번들 글꼴로 앱이 12MB 늘었다(2.8MB → 15MB). 한자·확장 라틴 자족이 넓은 KoPubWorld(23MB)는 무게 때문에 포기하고 일반판을 택했다 — 넓은 자족이 필요하면 사용자가 설치한 World 판이 목록에 함께 뜬다. 굵기를 '굵게'로 두면 본문과 사용자 `**볼드**` 가 화면상 구분되지 않는다(저장 데이터는 정확히 갈라지지만 읽을 때는 같아 보인다).

### ADR-0010: 페이지 직접 편집과 점진적 재조판 (2026-10-25)

- **상태:** 구현 완료, 전체 181개 테스트 및 릴리스 빌드 통과. 큰 문단의 최악 지연과 실물 입력기 동작은 별도 확인.
- **맥락:** 읽기 페이지에서 수정하려면 스크롤 화면으로 바뀌었다. 기존 `rebuildPages`를 매 입력에 쓰면 저장소·레이아웃 매니저를 새로 만들고 끝까지 조판한다.
- **가정:** 단일 macOS 프로세스, 메인 스레드 TextKit 1, UTF-16 문자 위치, 전체 쪽수의 일시적 미확정 허용. 페이지 계산과 파일 저장의 일관성은 분리 가능하다.
- **대안:** 스크롤 자동 전환, 문단 팝오버 편집, 페이지 직접 편집. 사용자 요청에 따라 직접 편집을 선택한다.
- **결정:**
  - `IncrementalPaginator`는 지속적인 `NSTextStorage`/`NSLayoutManager`/컨테이너와 유효한 페이지 범위 prefix를 소유한다. 편집 범위부터 캐시를 무효화하되 저장소의 편집 콜백 안에서는 조판하지 않는다.
  - 보이는 펼침면·캐럿까지 우선 조판하고, 나머지는 메인 큐에서 최대 2페이지씩 예약한다. TextKit의 자동 유휴 조판은 꺼서 무제한 후속 계산을 피한다.
  - 페이지 컨테이너를 유지하고 표시 뷰도 재사용한다. 제거할 뷰는 포커스 회수 후 컨테이너 역참조를 끊는다. 조합 중에는 표시 뷰 교체와 후속 조판을 보류한다.
  - `ReaderViewController`는 변경 범위만 원본 서식으로 되돌려 `MarkdownDocument`에 전달한다. 파일 저장은 계속 `NSDocument` 경계를 따른다.
  - 페이지 뷰의 네이티브 Undo 대신 문서에 역방향 변경을 등록한다. Undo/Redo는 문서 변경 알림으로 현재 페이지 또는 에디터에 반영하므로 뷰 수명과 이력 수명을 분리한다.
  - 페이지 수는 계산된 범위에만 근거한다. 후속 컨테이너는 존재해도 아직 계산된 페이지가 아니다. 계산 중에는 전체 쪽수에 `…`를 표시한다.
  - 책갈피는 직접 편집 범위의 길이 차이로 위치를 보정한다. 표시 설정 변경은 원본 텍스트를 바꾸지 않는다.
- **트레이드오프:** 페이지 하나의 TextKit 계산은 도중에 중단할 수 없다. 긴 단일 문단·대량 붙여넣기·먼 곳 점프의 즉시 작업은 클 수 있다. 메인 스레드와 UI TextKit 객체를 공유하는 백그라운드 스레드는 도입하지 않는다. 표시 설정 변경은 명시적 전체 무효화 사유지만 페이지 계산은 여전히 필요한 범위부터 수행한다.
- **검증:** `IncrementalPaginatorTests`, `EditablePagedReaderTests`, 기존 페이지 뷰 수명 및 읽기 서식 왕복 테스트. 실제 측정과 남은 제약은 같은 날짜 개발 로그에 기록한다.

## ADR-0011: 설치된 CLI를 통한 AI 채팅과 문서 수정

- 상태: 구현, 실제 제공사 인증·사용 가능 여부는 설정의 재확인으로 검증
- 맥락: 자체 API 키/OAuth 관리 대신 사용자가 설치·로그인한 공식 CLI를 연결한다.
- 가정: 로컬 macOS 앱, 단일 사용자의 문서 편집, 요청별 실행, 제공사별 CLI 규약·제약이 서로 다름.
- 결정: `ai/`에 제공사/경로 설정, 자식 프로세스 실행, 응답 파싱, 문서별 대화, 설정·채팅 UI를 둔다. 인증은 CLI 소유이고 문서 수정 권한과 Undo는 기존 MarkdownDocument 소유이다.
- 실행: 프롬프트는 argv나 셸 문자열로 넣지 않고 private stdin으로 전달한다. 요청마다 전용 작업 디렉터리와 프로세스 그룹을 만들고, 비차단 파이프 읽기·120초 제한·그룹 취소를 적용한다. 설치·로그인은 Terminal에 보이는 명령으로 진행한다.
- 컨텍스트: 요청 시점 본문·선택 영역·파일별 대화를 JSON으로 구성한다. 전체 attributed snapshot과 문서 identity가 일치할 때만 편집을 반영한다. 보존 문자의 속성은 차분 적용으로 유지한다.
- 상태: 대화/초안은 앱 수명 내 파일 경로별로, 미저장 문서는 UUID별로 유지한다. 제공사와 실행 파일 경로만 UserDefaults에 저장한다. 키/토큰은 읽거나 복사하지 않는다.
- 트레이드오프: CLI 설치/로그인 및 지원 버전에 의존한다. 도구 제한 플래그와 읽기 전용 정책을 사용하지만 공급자와 사용자 CLI 설정은 별도 신뢰 경계다. 자체 토큰 발급·API 직접 호출·웹 세션 추출은 사용하지 않는다.
- 대안: 직접 API는 인증/과금 UX가 추가되고, CLI가 원본 파일을 수정하면 미저장 본문·서식·Undo와 충돌하므로 채택하지 않았다.

- ADR-0011 보완: Grok의 네이티브 훅은 호출별로 해제할 수 없고 실제 Stop 훅이 반복 응답을 만들었다. `Application Support/JenaNote/GrokCLI`를 CLI 소유 인증·설정 프로필로 사용하고, 로그인·재확인·대화가 같은 `GROK_HOME`을 사용한다. 기존 토큰을 읽거나 복사하지 않는다. 큰 문자 차분은 계산량을 제한해 UI가 멈추지 않게 한다.

### ADR-0012: 읽기·수정 모드를 통합한 문서 편집 화면 (2026-10-25)

- **맥락:** 페이지에서 직접 입력이 가능해져 읽기/수정 모드를 나누는 UI와 두 툴바가 중복됐다. 기존 서식 명령은 분리된 스크롤 편집기에 연결되어 페이지에서 그대로 사용할 수 없었다.
- **검토:** 페이지에서 서식 버튼을 누를 때 스크롤로 전환하는 방식은 현재 페이지를 유지해 편집한다는 요구에 맞지 않는다. 전체 페이지 텍스트에 임시로 원본 서식을 적용하는 방식은 재조판 비용과 Undo 오염 위험이 있다.
- **결정:** 문서 화면은 항상 표시 조판을 사용한다. 페이지/스크롤은 보기 방식만 선택하며 모드 진입·종료와 관련 메뉴는 제거한다. 단일 툴바는 기존 서식 버튼 생성 코드를 재사용하고, 제목·목록·삽입은 메뉴로 묶는다. 중복 줄 간격은 보기 설정 하나로 통합한다. 화면 굵기는 표시 설정이고 선택 글자의 굵게는 문서 서식이므로 구분해 유지한다.
- **편집 경계:** 선택한 원본 문단을 임시 텍스트 뷰에 복사해 기존 FormatCommands를 수행한 뒤 변경 문단만 문서 소유 Undo 경로에 전달한다. 페이지 레이아웃은 점진적 갱신 경로를 유지한다. 화면용 폰트·배율을 원본 서식으로 오인하지 않는다.
- **연결:** 페이지 뷰의 키보드 서식 명령은 같은 편집 액션으로 전달한다. 링크·이미지·색상은 현재 문서의 선택 범위를 사용한다. 검색 결과 점프와 문서 교체는 페이지/스크롤 구분 없이 현재 화면에 적용한다. AI가 켜지면 기존처럼 잠시 스크롤을 사용한다.
- **트레이드오프:** 서식 명령은 선택된 문단 범위만 임시로 복사한다. 매우 긴 단일 문단은 그 문단 길이만큼 비용이 들지만 나머지 문서 전체를 복사하거나 전체 페이지를 다시 계산하지 않는다. 페이지의 찾기는 검색어 입력 후 다음 일치 항목으로 이동하는 시트이며, 스크롤은 기존 네이티브 찾기 바를 사용한다.

### ADR-0013: 워드식 치수자 — 페이지 폭은 두고 글 영역만 줄이는 좌·우 여백 (2026-10-26)

- **맥락:** 작성화면에 워드처럼 치수자를 두고 좌·우 간격을 끌어서 조절하고 싶다. 펼침면이면 페이지마다 치수자가 필요하다. 지금 페이지는 글자 단 폭(모바일 360pt / 책 글자수×글리프 폭)이 곧 페이지 박스이고, 텍스트 컨테이너 inset 은 0이다.
- **대안:** ① 여백을 페이지 바깥에 더해 페이지를 넓히는 방식 — 페이지 테두리를 그리지 않는 지금 화면에서는 페이지 사이 간격만 벌어져 효과가 보이지 않는다. ② 문단 스타일 headIndent/tailIndent — 문서(원본 서식)를 더럽히고 저장 결과가 달라진다. ③ 페이지 박스는 그대로 두고 글 영역만 줄인다 — 워드의 의미와 같고 원본 불변 계약(ADR-0009)을 지킨다. ③을 택했다.
- **결정:**
  - `ReaderMetrics` 에 `clampedMargins`/`textWidth`/`snappedMargin` 순수 함수. 글 영역 최소 120pt, 격자 0.25cm(72pt=2.54cm 환산). 좁아진 페이지에 저장 여백이 안 들어가면 왼쪽을 지키고 오른쪽을 양보한다.
  - `PageRulerView` 는 값을 저장하지 않는다. 끄는 동안 `onMarginsChanging`(이웃 치수자 동기화만), 놓을 때 `onCommitted(페이지 폭, 좌, 우)`(한 번 재조판), 더블클릭 `onReset`. 핸들은 반대쪽 여백을 밀지 않고 한계에서 멈춘다. 잡히는 범위는 ±12pt, `acceptsFirstMouse` 로 비활성 창에서도 첫 클릭에 잡힌다.
  - **페이지 넓히기:** 여백 0 인 핸들을 바깥으로 끌면 치수자 자신의 프레임을 그 방향으로 늘려 보여주고, 놓을 때 페이지 폭으로 커밋한다. 폭은 `SettingsManager.readingPageWidth`(0=자동)에 저장되어 "책" 모드에서 글자수 폭을 대체한다(`ReaderMetrics.columnWidth(... pageWidthOverride:)`). 모바일은 고정 프리셋이라 `canGrowPage=false`. 상한은 `ReaderMetrics.maxPageWidth(hostWidth:spread:)` — 펼침면이면 두 장이 유지되는 폭까지(넓히다 펼침면이 무너지지 않게).
  - 페이지 보기: `IncrementalPaginator` 의 컨테이너 크기를 `textBoxSize()`(페이지 폭 − 여백)로 바꾸고, 재분할 판정(`lastTextBoxSize`)도 이 크기로 한다. 페이지 뷰는 페이지 x + 좌 여백에 놓고, 치수자는 페이지 x 에 페이지 폭으로 얹는다. 이미지 상한 폭도 글 영역 폭이다.
  - 스크롤 보기(`EditorViewController`): 단 폭 = 페이지 폭 − 여백으로 가운데 정렬하고, 치수자는 스크롤 뷰에 고정된 서브뷰로 글 시작점이 본문 시작점과 맞게 `inset − 좌 여백` 에 둔다. 텍스트 컨테이너 inset 이 대칭이라 페이지가 아닌 글 영역을 가운데 둔다.
  - 여백은 `SettingsManager.readingPageMarginLeft/Right` 로 다른 보기 설정과 같이 전역 저장. 문서별 여백은 두지 않는다(필요해지면 ReadingProgressStore 와 같은 결로 확장).
- **트레이드오프:** 여백을 넓히면 책 폭 설정(글자수)보다 한 줄 글자 수가 줄어든다 — 치수자가 그 사실을 눈금으로 드러내므로 숨은 상태가 아니다. 끄는 동안 본문은 움직이지 않고 놓을 때 재조판된다(매 픽셀 재분할 비용 회피). 치수자 표시를 끄는 토글은 두지 않았다.
- **검증:** `PageRulerTests` 10개(넓히기 한도·여백 우선 축소·모바일 불가·리더 재조판·더블클릭 초기화 포함) — 격자·한계 순수 계산, 끌기 커밋 1회·반대쪽 불가침, 낱쪽 1개/펼침면 2개 치수자와 글 위치, 저장 여백 적용과 모바일 폭 안전망, 스크롤 보기 고정 치수자. 전체 242 통과. 실제 앱에서 합성 마우스 끌기로 펼침면 양쪽 재조판·설정 저장 확인.

### ADR-0014: 작품 문맥 — 앱이 선별해 보낸다, AI는 읽지 않는다 (2026-10-27)

> 자동 준비·탐색과 화면 동작은 ADR-0015로 대체됨. 아래는 이전 결정의 이력이다.

- **상태:** 구현
- **맥락:** AI 가이드·수정은 열려 있는 파일 하나만 본다. 연재물에서는 "죽은 인물이 살아 있다", "존댓말을 안 쓰는 인물이 존댓말을 한다" 같은 설정·앞뒤 문맥 불일치가 가장 자주, 가장 아프게 생긴다. ADR-0011에 따라 CLI는 요청별 임시 디렉터리에서 모든 도구를 차단한 채 실행되므로 AI가 노트 폴더를 스스로 읽을 경로는 없고, 이는 의도된 보안 경계다.
- **가정:** 작가가 작품 루트(설정 폴더 + 집필 폴더)를 가진 연재물을 쓴다. 한 화는 보통 수천 자이고 요약은 1분 안팎에 끝난다. 프롬프트 한도 `AIPrompt.maximumBytes`(500,000바이트)는 유지한다.
- **결정:**
  - 앱이 파일을 읽어 프롬프트 JSON의 `work` 객체로 보낸다. AI(CLI)는 파일을 읽지 않으며 도구 차단 플래그와 임시 작업 디렉터리는 바뀌지 않는다. 앱이 읽는 범위는 작품 루트 아래로 한정하고 심볼릭 링크는 따르지 않는다. `.md`/`.markdown`/`.txt`만 읽는다.
  - **설정은 항상 원문**(요약·삭제를 앱이 임의로 하지 않음). 지난 화는 AI 요약, 직전 화(앞 화)는 전문(토글, 기본 켬). 현재 화보다 뒤의 파일은 보내지 않는다. 작품 루트 밖 문서는 `work` 키 자체가 없어 기존 프롬프트와 바이트 단위로 같다.
  - **설정 소스는 사용자가 지정**한다(폴더 또는 파일들). 시트가 `설정`/`settings` 형제 폴더를 제안만 하고 자동 확정하지 않는다. 지정·제외·"요약으로 보내기"(파일 단위 명시 선택)·앞 화 토글·활성 여부는 `<작품 루트>/.jenanote/context.json`(작품 루트 기준 상대 경로, 절대 경로·`..` 무시)에 저장되어 다른 컴퓨터에서도 같다.
  - **요약 캐시:** 본문은 `.jenanote/summaries/<집필 폴더 기준 상대 경로>.txt`(설정 요약은 `summaries/settings/…`), 해시·시각·제공사는 `index.json` 사이드카. `.txt`인 이유는 `.md`를 열고 저장하면 `MarkdownSerializer`가 공백·기호를 정규화해 손대지 않은 요약이 "직접 수정됨"으로 굳기 때문이다. 상태: 요약 본문 해시가 기록과 다르면 **직접 수정됨**(원본이 바뀌어도 자동으로 덮어쓰지 않고 그대로 보냄), 원본 해시가 다르면 오래됨. 지난 화의 본문·해시는 항상 디스크 기준(타이핑마다 재요약되는 것을 막음), 설정 원문은 열려 있으면 메모리 기준.
  - **생성 트리거 제한:** 요청 직전의 없거나 오래된 요약, 팝오버의 "모두 갱신"/"다시 생성"에서만 CLI를 부른다. 저장·폴더 변경 감지·패널 열기에서는 부르지 않는다. 실패하면 그 화를 건너뛰지 않고 **멈춰 오류를 알리며** 본 요청은 보내지 않는다(이미 만든 요약은 남고 이어서 진행). 요약 요청은 제한 시간 240초(본 요청 120초)를 쓰고 토큰은 `tokenUsage`에 더한다.
  - **예산 축소 순서:** 합계가 한도를 넘으면 오래된 요약부터 제거(`omittedEarlierEpisodes` 기록) → 앞 화 전문 제거 → 그래도 넘으면 `ai.contextTooLarge`와 안내. 설정 원문은 어떤 단계에서도 줄이지 않는다.
  - **동시성:** 요약 큐와 `index.json`·요약 파일 쓰기는 작품 루트별 하나의 `AIEpisodeSummaryStore`가 소유한다. `context.json`은 팝오버(토글)와 설정 시트(저장)가 `AIWorkContext.save()`로 직접 쓴다. 같은 작품을 두 창에서 요청하면 다른 요청 뒤에 줄을 서고, 같은 화를 두 번 요약하거나 같은 파일에 동시에 쓰지 않는다.
  - **요청 순서:** 요약 준비 → 스냅샷 → 프롬프트 → 전송. 요약 대기 중 한 글자만 쳐도 `ai.editConflict`로 끝나는 것을 피하려고 스냅샷은 요약이 끝난 시점에 뜬다.
  - **예외 경로:** 팝오버의 요약 "열기"는 ADR-0004의 단일 창 규약의 예외로 **새 창**에서 연다(`NSDocumentController.openDocument(withContentsOf:display:)`). "틀린 요약을 고치고 바로 이어 쓰기"가 한 호흡이어야 하고 현재 화·AI 패널 문맥을 보존해야 하기 때문이다(작가 확정 2026-10-27). 저장되지 않은 요약 문서가 열려 있으면 "다시 생성"은 덮어쓰지 않고 먼저 저장·닫기를 안내한다.
- **트레이드오프:** 지난 화가 많은 작품은 첫 요청이 길다(50화면 수십 분 가능 — "모두 갱신"으로 미리 만들고 취소해도 만든 요약은 남음). 요약마다 CLI 비용이 든다. 설정집이 한도를 넘으면 사용자가 파일을 선별(제외/요약으로 보내기)해야 한다 — 앱은 대신 줄이지 않는다. 요약은 AI가 만든 것이라 틀릴 수 있어 열기·수정·보호를 제공한다.
- **대안:** (1) AI에 폴더 접근을 허용 — ADR-0011의 보안 경계(도구 차단, 임시 디렉터리)를 허물고 어떤 파일이 쓰였는지 사용자가 알 수 없어 기각. (2) 설정집도 요약 — 인물 말투·세계관 규칙 같은 디테일이 손실되어 이 기능의 목적(설정 불일치 방지)과 충돌하므로 기각(사용자가 파일 단위로 켜는 경우만 허용). (3) 저장 시 백그라운드 요약 — 사용자가 요청하지 않은 CLI 호출로 비용·놀람이 새서 기각. (4) 요약을 `.md`로 저장 — 직렬화 정규화 문제로 기각.
- **검증:** 임시 폴더로 만든 가짜 작품으로 루트 탐색·화 정렬·요약 판정/왕복·실패 이어가기·큐 동시성·예산 축소·`work` 없는 프롬프트 바이트 동일·경로 안전·생성 트리거를 테스트한다.

  **보완 — UX v2 (2026-10-27):** 1차 구현(텍스트 줄·팝오버·설정 시트)을 작가가 써 본 뒤 보이는 층을 다시 짰다. 데이터 모델·요약 캐시·예산 축소 결정은 그대로다.
  - 텍스트 줄·팝오버·시트 → **눌리는 줄 + 별도 3탭 창**(참고 자료/지난 화/작품 폴더). 팝오버와 시트는 제거했다.
  - 앱은 한도 초과 시 **해결안을 제시하지 않고 사실(용량 막대·문장)만** 보여준다. 줄일 파일은 사용자가 직접 고른다.
  - 처음 설정은 카드 없이 **버튼만**(1B). 설정 출처는 **폴더·파일 혼합 다중**이며 넣는 즉시 안의 파일이 보인다.
  - 창은 **작품 루트별 하나**, 변경은 **즉시 저장**한다. 모든 변경은 `mutate` 한 경로를 지나며 **디스크를 다시 읽은 뒤 저장**해 다른 창의 변경을 덮어쓰지 않는다.
  - 작품 루트 변경은 **이미 `context.json`이 있는 폴더로는 거부**한다(기존 설정 보호).
  - 창은 `AIEpisodeSummaryStore.addGenerationObserver`로 요약 생성 상태를 따라간다. **요약 생성의 소유자는 여전히 채팅 패널**이고 창은 관찰·요청만 한다.
  - 생성 중 줄의 "취소"는 **이번 요청과 요약 생성을 함께 취소**한다.
  - 위 본문의 "시트가 제안", "팝오버의 …" 표현은 각각 작품 폴더 탭, 작품 문맥 창으로 읽는다.


### ADR-0015: 작품별 영속 인덱스와 앱이 실행하는 AI 자료 탐색 (2026-10-28)

- 상태: 구현. ADR-0014의 수동 용량 관리·요청 직전 요약 정책을 대체한다.
- 맥락: 수동 파일 제외/요약으로 500KB를 맞추는 부담을 작가가 실사용에서 확인했다.
- 결정: 작품별 조각 인덱스·AI 검색용 요약을 영속 저장하고 열기/저장 시 증분 갱신한다. AI는 구조화된 검색/읽기 요청을 반환하며 앱만 실제 파일을 읽는다. CLI 도구 차단은 유지한다.
- 가정: 한 작품 수십~수백 화, 로컬 디스크, 기존 CLI 텍스트 응답 계약.
- 트레이드오프: 최초 AI 호출 비용/지연, 요약 손실과 검색 누락 가능성. 원문 근거와 확인 범위를 표시한다. 횟수·문맥·시간 제한은 앱 코드 책임.
- 대안: CLI 셸 개방(제공사별 차이), 벡터 DB(초기 복잡도), 계속 수동 관리(사용성 문제 유지).
- 상세: `superpowers/specs/2026-10-28-work-index-design.md`, `superpowers/plans/2026-10-28-work-index.md`.

### ADR-0016: 초기 작품 요약의 온디바이스 분리 (2026-10-28)

- 상태: 채택, 한국어 실기 품질/시간 검증 별도. ADR-0015의 초기 CLI 요약만 대체.
- 맥락/가정: 로컬 macOS 앱, 작품 수십~수백 화, 재생성 가능 캐시. 초기 요약에 집필용 CLI 사용량을 쓰지 않는다.
- 결정: Foundation Models 전용 요약 경계, v2/2,400바이트 조각, 새 세션과 직렬 추론, 출처/발췌 사유 영속화. 비지원/실패는 원문 발췌, 외부 자동 우회 없음. 질문별 원문 탐색·집필은 기존 CLI.
- 상태 소유: 작품별 저장소가 진행률/캐시를 소유, 요약 실행기는 앱 전체 추론 순서를 소유. 원문/설정은 권위 데이터. 캐시는 내용·역할·버전으로 무효화하고 가용성 변화/수동 재시도는 발췌만 갱신.
- 대안/이유: CLI 자동 우회는 사용량 제거 목적 위반, 비지원 환경 차단은 집필 방해. 발췌는 검색 품질 저하를 수용하는 대신 원문 전량 보존.
- 상세: `superpowers/specs/2026-10-28-foundation-work-index-design.md`.

### ADR-0017: 검색 준비와 백그라운드 요약의 분리 (2026-10-28)

- 상태: 구현. ADR-0015/0016의 전체 요약 완료 후 채팅 시작 계약을 대체한다. v2 캐시·직렬 기기 내 추론·원문 근거 정책은 유지한다.
- 문제: 사용자 관찰상 기원 작품 4,312조각 중 413조각 정리에 약 90분이 걸려, 전체 요약을 채팅의 선행 조건으로 둘 수 없다.
- 결정: 질문마다 원문을 비동기로 재스캔하고 기존 요약을 결합한 검색 스냅샷을 반환한다. 전체 요약의 완료·실패와 채팅 준비를 분리한다. 미요약 조각은 원문 미리보기로 검색한다.
- 검색: 질문 중심 로컬 검색으로 첫 탐색 호출에 원문을 제공한다. 전체 허용 자료가 24조각/160KB 이하면 탐색 호출을 생략하고 원문을 직접 제공한다. 큰 작품은 기존 제한된 CLI 탐색을 유지한다. 미래 화 필터는 검색 전에 적용한다.
- 우선순위: 질문 관련 조각, 열린 문서와 직전 화, 기존 순서. 진행 중인 추론을 취소하지 않는다. 원문 변경이 감지되면 진행 중인 조각 완료 뒤 재스캔한다.
- 저장: 8개 완료 또는 짧은 시간 간격으로 묶어 저장하고 최초 스캔/정상 종료/중지/오류에서 저장한다. 기존 캐시 형식·분할 규격을 바꾸지 않는다.
- 트레이드오프: 매 질문 로컬 원문 스캔 비용, 문자열 검색의 의미 검색 한계, 비정상 종료 시 저장 전 최대 7개 완료 결과 재생성 가능성을 수용한다. 실제 대규모 작품 응답 시간은 별도 측정한다.
- 대안: 관련 요약까지 채팅을 기다리게 하는 방식은 지연을 첫 질문으로 옮기므로 제외. 병렬 추론·분할 확대·벡터 검색은 별도 성능/품질 검증 후 검토한다.
- 상세: `superpowers/specs/2026-10-28-background-work-context-design.md`.

### ADR-0018: 보기 전용 배경, 로컬 원고 백업, Markdown 문서 끝 주석 (2026-10-29)

- 상태: 채택. 단일 사용자 macOS 로컬 편집기를 전제한다.
- 배경은 UserDefaults 전역 표시 상태, 원고 속성에 저장하지 않는다.
- 백업은 문서 경로별 Application Support 저장소가 소유한다. JSON 스냅샷 원자 저장, 중복 제거, 자동 저장 간격 및 보관 수 제한. 복원 전 현재 원고 보관을 필수로 한다.
- 주석은 attributed text의 참조/정의 표식과 Markdown 각주 표기를 왕복한다. 문서의 기존 Undo 편집 경계를 사용한다. 내보내기는 표시 텍스트 보존부터 제공한다.
- 대안: 원고에 테마 저장(원본 오염), 원고 옆 백업(검색 오염), 페이지 각주(조판 복잡도)를 제외했다.
- 상세: `superpowers/specs/2026-10-29-writer-utilities-design.md`.

## ADR-0019: 로컬 원고 버전 이력
- 결정: 기존 DocumentBackupStore의 외부 호출을 유지하면서 SHA-256 내용 객체와 UUID 이력 메타데이터를 분리한다. 이름 붙인 버전은 자동 정리에서 보호한다.
- 문서 식별: UUID 카탈로그와 macOS 북마크를 사용한다. 기존 경로 해시 저장소는 조회 시 이전하며 기존 데이터 포함 JSON을 계속 읽는다.
- 복원: 현재 내용을 먼저 보존하고 복원할 내용을 새로운 시점으로 기록한다. Git 프로세스, 브랜치/병합, 객체 가비지 수집은 도입하지 않는다.
- 제약: 부모 메타데이터는 정리될 수 있다. 객체는 보존되므로 저장 공간은 계속 증가할 수 있다. 북마크가 추적하지 못하는 이동/복사는 별도 이력이 된다.

## ADR-0020: 용지 치수와 본문 여백 분리
문서 크기는 mm 규격을 pt로 변환하는 DocumentPaperSize가 담당한다. 규격 용지 선택 시 기존 가변 폭 저장값보다 우선하며 치수자 핸들로 용지를 확장하지 않는다. 스크롤 텍스트 컨테이너는 고정 본문 폭, 페이지 호스트는 논리 용지 크기와 화면 배율을 분리한다. 앱 공통 보기 설정으로 저장하며 원문과 내보내기를 변경하지 않는다. 세로 치수자는 제외한다.


## ADR-0021: 선택 문장의 기기 내 교정
- 결정: 선택한 텍스트만 Foundation Models의 구조화 응답으로 검사하고, 원문/제안 비교 시트에서 명시적으로 적용한다. 최대 500자·UTF-8 1,500바이트로 제한하며 자동 절단하지 않는다.
- 상태 소유: 창이 검사 시트와 선택 스냅샷을 소유한다. 기존 AIEditSnapshot으로 원문 변경 충돌을 검증하고 문서의 Undo 경계로 반영한다. 이미지·각주가 포함된 선택과 한글 조합 중 실행은 차단한다.
- 실행: 작품 요약과 공유하는 직렬 추론 큐에서 대화형 검사를 대기 중인 요약보다 우선한다. 진행 중인 요약은 취소하지 않는다. 검사는 대기를 포함해 30초, 기존 요약은 실행 시작 후 120초 제한을 유지한다.
- 취소: 사용자 대기는 즉시 끝내되 실제 추론이 반환할 때까지 실행 슬롯을 유지해 중복 추론을 막는다. 늦은 결과는 적용하지 않는다.
- 제약: 긴 요약이 이미 실행 중이면 검사도 시간 초과할 수 있다. 모델 결과가 정확하거나 문체를 완전히 보존한다고 보장하지 않으므로 자동 적용하지 않는다. 외부 서비스 대체 경로는 없다.
- 상세: `superpowers/specs/2026-10-30-selection-proofreading-design.md`.


## ADR-0022: 선택 문장 검사의 Kiwi 전환 (2026-10-30)
- 맥락: 짧은 문장에도 Foundation Models 응답이 약 0.6~8초 걸리고 작품 요약을 기다리는 문제가 있었다. 기존 선택 검사 화면·명시적 적용·Undo 계약을 유지한다.
- 결정: Kiwi 0.24.1의 공식 정적 XCFramework와 base CONG 모델을 고정 체크섬으로 사용한다. 모델은 빌드 시 준비하고 앱 리소스로 배포한다. 실행 중 다운로드나 외부 호출은 없다.
- 실행 소유: 앱 공통 Kiwi 엔진이 전용 직렬 DispatchQueue에서 네이티브 핸들을 소유한다. 편집기 생성 시 비동기 준비하고 재사용한다. 선택 검사 요청 큐는 작품 요약 큐와 분리한다. 취소·10초 제한 후 늦은 결과는 반영하지 않는다.
- 교정: 기본 오타 변환기로 분석하되 오타를 정상 표기로 받아들이는 typo.dict와 이형태 통합을 끈다. 오타 비용이 있거나 잘못된 과거 어미로 분석된 어절만 재결합하고, 별도로 띄어쓰기를 제안한다. 과거 어미 EP의 앗/엇은 았/었으로 제안한다.
- 보존: NNP·외국어·숫자·URL 등으로 분석된 어절은 교정에서 보호한다. 줄바꿈·탭·연속 공백은 그대로 유지한다. 보호 처리는 분석이 정확한 경우에 한하며 미등록 고유명사의 오탐은 여전히 가능하다.
- 대안: Foundation Models 프롬프트 조정만으로 대기 편차를 해소하기 어렵고, 새 모델 학습은 이번 범위보다 크다. 기존 Apple Intelligence 기반 구현과 실기 결과는 이전 문서의 이력으로 남긴다.
- 배포: 코드와 모델은 Apache-2.0이며 정적 라이브러리의 제3자 고지와 라이선스도 앱에 포함한다. 모델 104MB 추가와 최초 준비 비용을 수용한다. 사용자 사전 UI와 자동 실시간 밑줄 검사는 이번 선택 검사 전환 범위에 포함하지 않는다.


## ADR-0023: 본문 자동 교정 후보 표시 (2026-10-31)
- 맥락: 매번 문장을 선택하고 검사 시트를 열어야 하는 불편을 줄인다. 이번 단계는 후보 표시만 제공하며 자동 수정과 교정 메뉴는 추가하지 않는다.
- 결정: 스크롤 EditorTextView와 페이지 PageTextView가 창에 연결되면 화면 전용 검사 컨트롤러를 소유한다. 분리 시 작업·관찰자를 취소하고 표시를 제거한다.
- 실행: 텍스트 변경·선택 변경·스크롤 뒤 0.5초 지연 검사. 현재 보이는 범위와 앞뒤 문맥만 검사하며 최대 6,000 UTF-16 인근으로 제한한다. 각 조각은 기존 500자·1,500바이트 제한을 따르고 첨부 조각은 건너뛴다. 같은 문장은 최대 64개 캐시로 재사용한다. 화면 밖 전체 원고의 일괄 검사는 하지 않는다.
- 보존: 한글 조합 중에는 검사를 미룬다. 변경 세대·취소·원문 일치 검사로 오래된 응답을 폐기한다. 표시에는 NSLayoutManager의 임시 밑줄 속성만 사용하고 문서 스토리지·저장 속성·Undo를 수정하지 않는다.
- 표시: 원문과 교정안의 문자 차이를 UTF-16 범위로 변환한다. 교체/삭제는 해당 원문만, 삽입은 원문 경계의 인접 글자를 표시한다. 화면 경계로 잘라 페이지 간 표시가 겹치지 않게 한다. 시스템 주황색 점선 밑줄은 오류 확정이 아닌 교정 후보를 뜻한다.
- 한계: Kiwi의 오탐·누락이 남는다. 긴 문장의 조각 경계에서는 문맥이 줄어들 수 있다. UI 표시가 없는 범위나 검사 실패를 오류 없음으로 해석하지 않는다. 선택 검사 시트는 유지한다.

## ADR-0024: 교정 후보 적용과 범위별 개인 사전 (2026-10-31)
- 결정: 후보 호버/편집 커서에서 팝오버를 표시하고 해당 후보만 명시적으로 적용한다. 기존 스냅샷 검증과 Undo를 사용한다. 교정 전용 임시 표식은 글꼴 하단보다 내려간 주황색 물결 점선으로 그린다.
- 저장: 하나의 로컬 JSON에 표현과 전체/작품 UUID 집합을 저장한다. 현재 작품을 기본으로 하되 전체 또는 여러 작품으로 변경할 수 있다. 작품 이름은 표시용이며 북마크와 경로로 식별한다. 변경 전 백업과 원자 저장을 사용하고 자동 삭제하지 않는다.
- 검사: Kiwi 원본 결과 캐시 뒤에 현재 작품과 전체 사전의 활성 표현을 필터링한다. 표현 범위 내부 수정만 제외하고 다른 오류는 유지한다. 본문과 선택 검사에 같은 규칙을 적용하며 사전·문서 경로 변경 시 재평가한다.
- 대안: 작품별 파일의 중복 관리, 완전 공통 사전의 과도한 제외, 작품명 태그의 이름 변경/동명이작 모호성을 피한다. 대신 작품 식별과 범위 관리 UI의 복잡도를 수용한다. 사전은 모델 재학습이 아닌 검사 예외 목록이다.
- 상세: `superpowers/specs/2026-10-31-proofreading-dictionary-design.md`.
