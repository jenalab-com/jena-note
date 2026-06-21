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
      ReaderMetrics.swift           — 컬럼폭·페이지 높이 순수 함수 (단위 테스트 가능)
    toolbar/
      FormatToolbar.swift           — NSToolbar + NSToolbarDelegate
      ReaderToolbar.swift           — 읽기 모드 전용 NSToolbar (ADR-0006)
    sidebar/                        ← 신설 (ADR-0004/0005)
      SidebarViewController.swift   — NSOutlineView 호스트, 폴더 추가/제거 UI
      SidebarDataSource.swift       — 트리 노드 모델 + DataSource/Delegate
      FolderBookmarksStore.swift    — UserDefaults 영속, 변경 통지
      FolderWatcher.swift           — FSEvents 래퍼, debounce 200ms
Tests/
  JenaNoteKitTests/
    ReaderMetricsTests.swift        — columnWidth·snappedPageHeight 단위 테스트
    ReadingSettingsTests.swift      — SettingsManager 읽기 설정 영속 테스트
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
역할: 읽기 전용 조판·스크롤/페이징·폰트 배율. 원본 document.content는 절대 수정하지 않는다.
- init(content:): 이미 파싱된 NSAttributedString을 받아 저장
- loadView(): 고정폭 컬럼(ReaderMetrics.columnWidth) 중앙 정렬 레이아웃, 하단 페이지 인디케이터
- setFontScale(_:): 배율 적용·영속. ReaderMetrics.scaled로 원본을 건드리지 않고 표시본만 생성
- setPageMode(_:): 스크롤 ↔ 페이징 전환. 페이징 시 세로 스크롤러 숨김·elasticity 제거
- scrollToCurrentPage(): 뷰 높이를 줄 높이 정수배(snappedPageHeight)로 끊어 offset 점프
- updatePageIndicator(): 페이징 모드에서만 "‹ N / M ›" 표시, 스크롤 모드에선 숨김
- updateContent(_:): 문서 교체 시(파일 스왑) 원본 갱신 후 재렌더
- goToNextPage() / goToPreviousPage(): 좌우 방향키 또는 외부 툴바 호출
```

**금지:** document 또는 NSTextStorage에 쓰기, 파일 I/O 직접 호출

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
