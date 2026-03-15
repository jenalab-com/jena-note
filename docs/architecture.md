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
┌─────────────────────────────────────────┐
│  UI Layer                               │
│  EditorTextView · FormatToolbar         │
│  EditorViewController · WindowController│
└────────────────┬────────────────────────┘
                 │ reads / writes attributed string
┌────────────────▼────────────────────────┐
│  Document Layer                         │
│  MarkdownDocument (NSDocument)          │
└────────────────┬────────────────────────┘
                 │ serialize / deserialize
┌────────────────▼────────────────────────┐
│  Infrastructure Layer                   │
│  MarkdownSerializer                     │
│  (NSAttributedString ↔ CommonMark .md)  │
└─────────────────────────────────────────┘
```

**규칙:**
- UI Layer는 `MarkdownSerializer`를 직접 호출하지 않는다
- `MarkdownDocument`는 AppKit(NSTextView 등)에 의존하지 않는다
- `MarkdownSerializer`는 UI/Document 어느 쪽도 import하지 않는다

---

## 3. 폴더 구조 (Feature-first)

```
Sources/
  app/
    main.swift                      — 진입점, NSApplication.main()
    AppDelegate.swift               — 앱 생명주기, 첫 실행 시 빈 문서 열기
  document/
    MarkdownDocument.swift          — NSDocument 서브클래스: 저장·열기 경계
    MarkdownSerializer.swift        — NSAttributedString ↔ CommonMark 변환
  editor/
    EditorWindowController.swift    — NSWindowController: 창·툴바 초기화
    EditorViewController.swift      — NSViewController: Document ↔ View 조율
    EditorTextView.swift            — NSTextView 서브클래스: 텍스트 입력 처리
    FormatCommands.swift            — 서식 액션 (bold, italic, heading, list 등)
  toolbar/
    FormatToolbar.swift             — NSToolbar + NSToolbarDelegate
Resources/
  Info.plist
  MainMenu.xib (또는 코드 기반 메뉴)
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

jenaMemory와 동일하게 **Makefile + swiftc 직접 컴파일** 방식을 따른다.

```makefile
APP_NAME   = JenaMemo
VERSION    = 1.0.0
BUILD_DIR  = .build
SOURCES    = Sources/**/*.swift

build:
    swiftc -framework AppKit -O $(SOURCES) -o $(BUILD_DIR)/$(APP_NAME)
    # .app 번들 구성 (Info.plist, Resources 복사)

run: build
    open $(BUILD_DIR)/$(APP_NAME).app

clean:
    rm -rf $(BUILD_DIR)
```

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

### ADR-0003: 단일 창 / 단일 문서
- **결정:** 멀티탭·멀티창 미지원 (spec Out-of-Scope 준수)
- **근거:** 복잡도를 최소화하고 NSDocument 기본 동작을 그대로 활용
- **결과:** 사용자는 파일마다 새 창을 열어야 함. macOS 표준 동작으로 허용 가능.
