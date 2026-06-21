# 읽기 모드(책 보기) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 편집 모드와 토글되는 읽기 전용 "책 보기" 모드를 추가한다 — 한글 35자 컬럼 조판, 스크롤/가로 페이지 넘김 선택, 읽기 전용 글자 크기 배율.

**Architecture:** 별도 `ReaderViewController`를 신설하고 `EditorWindowController`가 우측 split item을 editor ⇄ reader로 교체한다. 가로 페이지 넘김은 단일 컬럼을 뷰 높이(줄 높이 정수배) 단위로 끊어 scroll offset을 점프시켜 근사한다. 선행 인프라로 SPM(Swift Package Manager)을 도입해 순수 로직에 회귀 테스트를 붙인다(빌드는 Makefile 래핑으로 `make build`/`run` 유지).

**Tech Stack:** Swift, AppKit, macOS 11+, Swift Package Manager(`swift build`/`swift test`), XCTest.

## Global Constraints

- 플랫폼: macOS 11.0+ (기존 `@available(macOS 11.0, *)` 사용처 유지).
- 빌드 컨벤션 유지: `make build`·`make run`·`make install`·`make dmg`·`make pkg`가 그대로 작동해야 한다. SPM 산출물을 Makefile이 `.app` 번들로 래핑한다.
- 원본 불변: 읽기 모드는 `document.content`·`.md`·`MarkdownDocument`를 절대 수정하지 않는다. 폰트 배율은 화면 표시 전용 복사본에만 적용한다.
- 타이포 기본값: 한글 한 줄 `35`자, 폰트 배율 범위 `0.8`~`2.0`(기본 `1.0`), 페이지 모드 기본 `scroll`.
- 레이어 규칙(architecture.md §2): `ReaderViewController`는 UI Layer이며 `MarkdownSerializer`를 직접 호출하지 않는다 — 이미 파싱된 `NSAttributedString`만 입력받는다.
- 다국어: 사용자 노출 문자열은 `L10n.tr(key)`로 7개 언어(ko/en/zh/ja/es/de/fr) 모두 추가한다.
- 본문 폰트 기준: `MemoFont.body = NSFont.systemFont(ofSize: 15)` (`Sources/.../document/MarkdownSerializer.swift`).
- 커밋 컨벤션: Conventional Commits. 이 repo는 모든 작업을 `main`에 직접 커밋한다. 커밋 메시지 끝에 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure (전환 후)

```
Package.swift                       ← 신규 (SPM 매니페스트)
Makefile                            ← 수정 (swift build 래핑 + test 타겟)
Sources/
  JenaNote/
    main.swift                      ← 이동 (executable, 부트스트랩만)
  JenaNoteKit/                      ← 이동 (library: 기존 로직 전부)
    app/  (AppDelegate · SettingsManager · Localization · Preferences · Help)
    document/ (MarkdownDocument · MarkdownSerializer · SyntaxHighlighter)
    editor/   (EditorWindowController · EditorViewController · EditorTextView ·
               FormatCommands · ReaderViewController[신규] · ReaderMetrics[신규])
    toolbar/  (FormatToolbar · ReaderToolbar[신규])
    sidebar/  (SidebarViewController · FolderBookmarksStore · FolderWatcher)
Tests/
  JenaNoteKitTests/
    ReaderMetricsTests.swift        ← 신규
    ReadingSettingsTests.swift      ← 신규
```

---

## Task 1: SPM 인프라 전환 (빌드 그대로 유지)

기존 앱이 SPM으로 빌드되고 `make build`/`make run`이 동일하게 작동하게 만든다. 기능 변화 0. 이 태스크가 끝나도 앱은 v1.0.1 그대로 동작해야 한다.

**Files:**
- Create: `Package.swift`
- Move: `Sources/app/main.swift` → `Sources/JenaNote/main.swift`
- Move: `Sources/app/`, `Sources/document/`, `Sources/editor/`, `Sources/toolbar/`, `Sources/sidebar/` → `Sources/JenaNoteKit/<same>/`
- Modify: `Sources/JenaNoteKit/app/AppDelegate.swift` (클래스/init을 public으로)
- Modify: `Makefile` (swift build 래핑 + `test` 타겟)
- Create: `Tests/JenaNoteKitTests/SmokeTests.swift` (하니스 검증용 1개)

**Interfaces:**
- Produces: SPM 타겟 `JenaNoteKit`(library), `JenaNote`(executable), `JenaNoteKitTests`(test). `make build`→`.build/JenaNote.app`, `make test`→`swift test`.

- [ ] **Step 1: 디렉토리 재배치 (git mv)**

```bash
mkdir -p Sources/JenaNote Sources/JenaNoteKit
git mv Sources/app/main.swift Sources/JenaNote/main.swift
git mv Sources/app Sources/JenaNoteKit/app
git mv Sources/document Sources/JenaNoteKit/document
git mv Sources/editor Sources/JenaNoteKit/editor
git mv Sources/toolbar Sources/JenaNoteKit/toolbar
git mv Sources/sidebar Sources/JenaNoteKit/sidebar
```

- [ ] **Step 2: `Package.swift` 작성**

```swift
// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "JenaNote",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "JenaNoteKit", path: "Sources/JenaNoteKit"),
        .executableTarget(
            name: "JenaNote",
            dependencies: ["JenaNoteKit"],
            path: "Sources/JenaNote"
        ),
        .testTarget(
            name: "JenaNoteKitTests",
            dependencies: ["JenaNoteKit"],
            path: "Tests/JenaNoteKitTests"
        ),
    ]
)
```

- [ ] **Step 3: `main.swift`를 library import 부트스트랩으로 변경**

`Sources/JenaNote/main.swift`:

```swift
import AppKit
import JenaNoteKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
```

- [ ] **Step 4: `AppDelegate`를 public으로 노출**

`Sources/JenaNoteKit/app/AppDelegate.swift` — 클래스 선언과 지정 이니셜라이저만 public화 (다른 클래스는 모듈 내부 참조라 internal 유지):

```swift
public class AppDelegate: NSObject, NSApplicationDelegate {

    public override init() {
        super.init()
    }

    // NSMenu가 delegate를 weak으로 참조하므로 강참조 유지
    private let recentMenuDelegate = RecentDocumentsMenuDelegate()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsManager.shared.applyAppearance()
        setupMenu()
    }
    // ... 이하 기존 본문 그대로, NSApplicationDelegate 프로토콜 메서드 4개에 public 추가:
    //   applicationShouldOpenUntitledFile / applicationOpenUntitledFile /
    //   applicationShouldTerminateAfterLastWindowClosed
}
```

> 주의: 위 세 `NSApplicationDelegate` 메서드도 `public`을 붙인다(프로토콜 외부 호출). `@objc` 액션·내부 헬퍼는 그대로 둔다.

- [ ] **Step 5: 스모크 테스트 작성**

`Tests/JenaNoteKitTests/SmokeTests.swift`:

```swift
import XCTest
@testable import JenaNoteKit

final class SmokeTests: XCTestCase {
    func testKitModuleLinks() {
        // 모듈이 링크되고 테스트 하니스가 동작하는지만 확인
        XCTAssertEqual(SettingsManager.shared.language.rawValue.isEmpty, false)
    }
}
```

- [ ] **Step 6: `Makefile`을 swift build 래핑으로 수정**

`Makefile`의 빌드/테스트 부분을 교체:

```makefile
APP_NAME    = JenaNote
VERSION     = 1.0.1
BUILD_DIR   = .build
BUNDLE      = $(BUILD_DIR)/$(APP_NAME).app
BINARY      = $(BUNDLE)/Contents/MacOS/$(APP_NAME)
DMG         = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg
PKG         = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).pkg

.PHONY: build run install dmg pkg clean test

run: build
	@open $(BUNDLE)

build:
	swift build -c release --product $(APP_NAME)
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	@cp .build/release/$(APP_NAME) $(BINARY)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@[ -f Resources/$(APP_NAME).icns ] && cp Resources/$(APP_NAME).icns $(BUNDLE)/Contents/Resources/$(APP_NAME).icns || true
	@echo "✓ 빌드 완료: $(BUNDLE)"

test:
	swift test

install: build
	@rm -rf ~/Applications/$(APP_NAME).app
	@cp -r $(BUNDLE) ~/Applications/$(APP_NAME).app
	@echo "✓ 설치 완료: ~/Applications/$(APP_NAME).app"
```

(dmg/pkg/clean 타겟은 기존 그대로 유지 — `$(BUNDLE)` 참조라 변경 불필요.)

- [ ] **Step 7: 빌드·테스트·실행 검증**

```bash
make clean && make build
```
Expected: `✓ 빌드 완료: .build/JenaNote.app` (컴파일 에러 0)

```bash
make test
```
Expected: `Test Suite 'All tests' passed` (SmokeTests 1개 통과)

```bash
make run
```
Expected: 앱이 실행되고 빈 문서 창이 뜬다. 기존 기능(편집·저장·사이드바·서식)이 v1.0.1과 동일하게 동작한다. **수동 확인**: 텍스트 입력·굵게(⌘B)·저장(⌘S)·사이드바 폴더 추가가 정상인지 1분 점검.

- [ ] **Step 8: 커밋**

```bash
git add -A
git commit -m "build: migrate to Swift Package Manager (JenaNoteKit + JenaNote)

순수 로직에 회귀 테스트를 붙이기 위해 SPM 도입. main.swift는 executable,
나머지 로직은 JenaNoteKit 라이브러리로 분리. Makefile은 swift build 산출물을
.app 번들로 래핑해 make build/run 컨벤션 유지. 기능 변화 없음.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: ReaderMetrics 순수 계산 (TDD)

읽기 모드의 순수 계산 — 폰트 배율 적용(원본 불변), 페이지 높이 스냅, 컬럼 폭 — 을 테스트 우선으로 만든다.

**Files:**
- Create: `Sources/JenaNoteKit/editor/ReaderMetrics.swift`
- Test: `Tests/JenaNoteKitTests/ReaderMetricsTests.swift`

**Interfaces:**
- Produces:
  - `ReaderMetrics.scaled(_ content: NSAttributedString, by scale: CGFloat) -> NSAttributedString`
  - `ReaderMetrics.snappedPageHeight(viewHeight: CGFloat, lineHeight: CGFloat) -> CGFloat`
  - `ReaderMetrics.columnWidth(charCount: Int, glyphAdvance: CGFloat) -> CGFloat`

- [ ] **Step 1: 실패 테스트 작성**

`Tests/JenaNoteKitTests/ReaderMetricsTests.swift`:

```swift
import XCTest
import AppKit
@testable import JenaNoteKit

final class ReaderMetricsTests: XCTestCase {

    func testScaledDoublesFontSize() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let original = NSAttributedString(string: "한글", attributes: attrs)
        let scaled = ReaderMetrics.scaled(original, by: 2.0)
        let f = scaled.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(f.pointSize, 30, accuracy: 0.01)
    }

    func testScaledKeepsRelativeRatios() {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "본", attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        s.append(NSAttributedString(string: "큰", attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold)]))
        let scaled = ReaderMetrics.scaled(s, by: 1.5)
        let body = scaled.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let head = scaled.attribute(.font, at: 1, effectiveRange: nil) as! NSFont
        XCTAssertEqual(body.pointSize, 22.5, accuracy: 0.01)
        XCTAssertEqual(head.pointSize, 42.0, accuracy: 0.01)
    }

    func testScaledLeavesOriginalUnchanged() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let original = NSAttributedString(string: "한글", attributes: attrs)
        _ = ReaderMetrics.scaled(original, by: 2.0)
        let f = original.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(f.pointSize, 15, accuracy: 0.01)
    }

    func testSnappedPageHeightFloorsToLineMultiple() {
        // floor(100/30)=3 → 90
        XCTAssertEqual(ReaderMetrics.snappedPageHeight(viewHeight: 100, lineHeight: 30), 90, accuracy: 0.01)
    }

    func testSnappedPageHeightAtLeastOneLine() {
        // 한 줄도 안 들어가는 높이라도 최소 한 줄
        XCTAssertEqual(ReaderMetrics.snappedPageHeight(viewHeight: 10, lineHeight: 30), 30, accuracy: 0.01)
    }

    func testColumnWidth() {
        XCTAssertEqual(ReaderMetrics.columnWidth(charCount: 35, glyphAdvance: 15), 525, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ReaderMetricsTests`
Expected: FAIL — `cannot find 'ReaderMetrics' in scope`

- [ ] **Step 3: 최소 구현**

`Sources/JenaNoteKit/editor/ReaderMetrics.swift`:

```swift
import AppKit

/// 읽기 모드의 순수 계산. AppKit 타입을 다루지만 UI 상태는 갖지 않는다.
enum ReaderMetrics {

    /// 모든 `.font` 속성에 배율을 곱한 새 attributed string을 반환한다.
    /// 원본은 변경하지 않는다 (읽기 모드 표시 전용).
    static func scaled(_ content: NSAttributedString, by scale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        let full = NSRange(location: 0, length: result.length)
        var changes: [(NSRange, NSFont)] = []
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
            changes.append((range, scaled))
        }
        for (range, font) in changes {
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }

    /// 페이지 높이를 줄 높이의 정수배로 내림 — 페이지 경계 줄 잘림 방지.
    static func snappedPageHeight(viewHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        guard lineHeight > 0 else { return viewHeight }
        let lines = floor(viewHeight / lineHeight)
        return max(lineHeight, lines * lineHeight)
    }

    /// 글자 수 × 글리프 advance = 컬럼 폭.
    static func columnWidth(charCount: Int, glyphAdvance: CGFloat) -> CGFloat {
        return CGFloat(charCount) * glyphAdvance
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ReaderMetricsTests`
Expected: PASS (6 tests)

- [ ] **Step 5: 커밋**

```bash
git add Sources/JenaNoteKit/editor/ReaderMetrics.swift Tests/JenaNoteKitTests/ReaderMetricsTests.swift
git commit -m "feat: add ReaderMetrics pure calculations (scale/page-height/column)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: SettingsManager 읽기 모드 설정 (TDD)

페이지 모드·폰트 배율·줄 길이를 UserDefaults에 영속한다.

**Files:**
- Modify: `Sources/JenaNoteKit/app/SettingsManager.swift`
- Test: `Tests/JenaNoteKitTests/ReadingSettingsTests.swift`

**Interfaces:**
- Consumes: `SettingsManager.shared` (기존 싱글톤).
- Produces:
  - `enum SettingsManager.ReadingPageMode: String { case scroll, paged }`
  - `var SettingsManager.readingPageMode: ReadingPageMode` (기본 `.scroll`)
  - `var SettingsManager.readingFontScale: CGFloat` (기본 `1.0`, clamp `0.8...2.0`)
  - `var SettingsManager.readingLineLength: Int` (기본 `35`)

- [ ] **Step 1: 실패 테스트 작성**

`Tests/JenaNoteKitTests/ReadingSettingsTests.swift`:

```swift
import XCTest
import AppKit
@testable import JenaNoteKit

final class ReadingSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "jn_readingPageMode")
        UserDefaults.standard.removeObject(forKey: "jn_readingFontScale")
        UserDefaults.standard.removeObject(forKey: "jn_readingLineLength")
    }

    func testDefaults() {
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .scroll)
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(SettingsManager.shared.readingLineLength, 35)
    }

    func testPageModePersists() {
        SettingsManager.shared.readingPageMode = .paged
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .paged)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "jn_readingPageMode"), "paged")
    }

    func testFontScaleClamps() {
        SettingsManager.shared.readingFontScale = 5.0
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 2.0, accuracy: 0.001)
        SettingsManager.shared.readingFontScale = 0.1
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 0.8, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ReadingSettingsTests`
Expected: FAIL — `value of type 'SettingsManager' has no member 'readingPageMode'`

- [ ] **Step 3: 구현**

`SettingsManager.swift`의 `Key` enum에 추가:

```swift
    private enum Key {
        static let language = "jn_language"
        static let appearance = "jn_appearance"
        static let readingPageMode = "jn_readingPageMode"
        static let readingFontScale = "jn_readingFontScale"
        static let readingLineLength = "jn_readingLineLength"
    }
```

`AppearanceMode` enum 아래에 추가:

```swift
    enum ReadingPageMode: String, CaseIterable {
        case scroll = "scroll"
        case paged  = "paged"
    }
```

`appearanceMode` 프로퍼티 아래에 추가:

```swift
    var readingPageMode: ReadingPageMode {
        get {
            guard let raw = defaults.string(forKey: Key.readingPageMode),
                  let mode = ReadingPageMode(rawValue: raw) else { return .scroll }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.readingPageMode) }
    }

    var readingFontScale: CGFloat {
        get {
            let v = defaults.object(forKey: Key.readingFontScale) as? Double
            return CGFloat(v ?? 1.0)
        }
        set {
            let clamped = min(max(newValue, 0.8), 2.0)
            defaults.set(Double(clamped), forKey: Key.readingFontScale)
        }
    }

    var readingLineLength: Int {
        get {
            let v = defaults.object(forKey: Key.readingLineLength) as? Int
            return v ?? 35
        }
        set { defaults.set(newValue, forKey: Key.readingLineLength) }
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ReadingSettingsTests`
Expected: PASS (3 tests)

- [ ] **Step 5: 커밋**

```bash
git add Sources/JenaNoteKit/app/SettingsManager.swift Tests/JenaNoteKitTests/ReadingSettingsTests.swift
git commit -m "feat: persist reading-mode settings (page mode/font scale/line length)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: ReaderViewController — 스크롤 모드

읽기 전용 컬럼 조판을 먼저 스크롤 모드로 구현한다. 페이징은 Task 5에서 더한다.

**Files:**
- Create: `Sources/JenaNoteKit/editor/ReaderViewController.swift`

**Interfaces:**
- Consumes: `ReaderMetrics.scaled`, `ReaderMetrics.columnWidth`, `SettingsManager.shared.reading*`.
- Produces:
  - `class ReaderViewController: NSViewController`
  - `init(content: NSAttributedString)`
  - `func updateContent(_ content: NSAttributedString)`
  - `func setFontScale(_ scale: CGFloat)`
  - `func setPageMode(_ mode: SettingsManager.ReadingPageMode)` (Task 5에서 본문 채움 — 지금은 scroll만)

- [ ] **Step 1: 구현 (UI — 빌드로 검증)**

`Sources/JenaNoteKit/editor/ReaderViewController.swift`:

```swift
import AppKit

/// 읽기 전용 "책 보기" 뷰. document.content(이미 파싱된 NSAttributedString)를
/// 받아 한글 35자 컬럼으로 조판한다. 원본은 절대 수정하지 않는다.
class ReaderViewController: NSViewController {

    // MARK: - State
    private var sourceContent: NSAttributedString
    private var scale: CGFloat = SettingsManager.shared.readingFontScale
    private var pageMode: SettingsManager.ReadingPageMode = SettingsManager.shared.readingPageMode

    // MARK: - Views
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var leadingConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!

    // MARK: - Init
    init(content: NSAttributedString) {
        self.sourceContent = content
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // MARK: - Layout
    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textContainer = NSTextContainer(containerSize: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 48)
        textView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = textView

        // 컬럼을 고정폭으로 두고 가로 가운데 정렬
        let column = columnWidthForCurrentSettings()
        widthConstraint = textView.widthAnchor.constraint(equalToConstant: column)
        leadingConstraint = textView.centerXAnchor.constraint(equalTo: scrollView.contentView.centerXAnchor)
        NSLayoutConstraint.activate([
            widthConstraint,
            leadingConstraint,
            textView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])

        view = scrollView
        renderContent()
    }

    // MARK: - Rendering
    private func columnWidthForCurrentSettings() -> CGFloat {
        let chars = SettingsManager.shared.readingLineLength
        // 한글 전각 글리프 advance 실측 (시스템 폰트 fallback 보정)
        let probeFont = NSFont(descriptor: MemoFont.body.fontDescriptor,
                               size: MemoFont.body.pointSize * scale) ?? MemoFont.body
        let advance = ("한" as NSString).size(withAttributes: [.font: probeFont]).width
        return ReaderMetrics.columnWidth(charCount: chars, glyphAdvance: advance)
    }

    private func renderContent() {
        guard let storage = textView.textStorage else { return }
        let display = ReaderMetrics.scaled(sourceContent, by: scale)
        storage.setAttributedString(display)
        widthConstraint.constant = columnWidthForCurrentSettings()
    }

    // MARK: - Public API
    func updateContent(_ content: NSAttributedString) {
        sourceContent = content
        renderContent()
    }

    func setFontScale(_ newScale: CGFloat) {
        scale = min(max(newScale, 0.8), 2.0)
        SettingsManager.shared.readingFontScale = scale
        renderContent()
    }

    func setPageMode(_ mode: SettingsManager.ReadingPageMode) {
        pageMode = mode
        SettingsManager.shared.readingPageMode = mode
        // Task 5에서 paged 레이아웃 분기 구현
    }
}
```

- [ ] **Step 2: 빌드 검증**

Run: `make build`
Expected: 컴파일 에러 0, `✓ 빌드 완료`. (아직 모드 전환 진입점이 없어 화면엔 안 뜸 — Task 6에서 연결.)

- [ ] **Step 3: 커밋**

```bash
git add Sources/JenaNoteKit/editor/ReaderViewController.swift
git commit -m "feat: add ReaderViewController scroll-mode column layout (read-only)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: ReaderViewController — 가로 페이지 넘김

스크롤 ⇄ 페이징 전환과 ←/→ 페이지 이동을 더한다. 페이지 = 뷰 높이(줄 높이 정수배) 단위 세로 구간 점프.

**Files:**
- Modify: `Sources/JenaNoteKit/editor/ReaderViewController.swift`

**Interfaces:**
- Consumes: `ReaderMetrics.snappedPageHeight`.
- Produces: `setPageMode` 본문 완성, `goToNextPage()`, `goToPreviousPage()`, 키보드 `←`/`→` 처리.

- [ ] **Step 1: 페이징 상태·계산 추가**

`ReaderViewController`에 프로퍼티와 메서드 추가:

```swift
    // MARK: - Paging State
    private var currentPage: Int = 0

    private var lineHeightEstimate: CGFloat {
        guard let lm = textView.layoutManager, textView.textStorage?.length ?? 0 > 0 else {
            let f = NSFont(descriptor: MemoFont.body.fontDescriptor,
                           size: MemoFont.body.pointSize * scale) ?? MemoFont.body
            return f.ascender - f.descender + f.leading + 2
        }
        return lm.defaultLineHeight(for: NSFont(descriptor: MemoFont.body.fontDescriptor,
                                                size: MemoFont.body.pointSize * scale) ?? MemoFont.body)
    }

    private var pageHeight: CGFloat {
        let visible = scrollView.contentView.bounds.height
        return ReaderMetrics.snappedPageHeight(viewHeight: visible, lineHeight: lineHeightEstimate)
    }

    private var totalContentHeight: CGFloat {
        textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
            + textView.textContainerInset.height * 2
    }

    private var pageCount: Int {
        max(1, Int(ceil(totalContentHeight / max(pageHeight, 1))))
    }

    func goToNextPage() {
        guard currentPage < pageCount - 1 else { return }
        currentPage += 1
        scrollToCurrentPage()
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        scrollToCurrentPage()
    }

    private func scrollToCurrentPage() {
        let y = CGFloat(currentPage) * pageHeight
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: .readerPageChanged, object: self)
    }
```

- [ ] **Step 2: `setPageMode` 본문 채우기 (스크롤러 토글)**

`setPageMode` 교체:

```swift
    func setPageMode(_ mode: SettingsManager.ReadingPageMode) {
        pageMode = mode
        SettingsManager.shared.readingPageMode = mode
        let paged = (mode == .paged)
        scrollView.hasVerticalScroller = !paged
        scrollView.verticalScrollElasticity = paged ? .none : .allowed
        currentPage = 0
        scrollToCurrentPage()
    }
```

- [ ] **Step 3: 키보드 ←/→ 처리**

`ReaderViewController`에 추가:

```swift
    override func keyDown(with event: NSEvent) {
        guard pageMode == .paged else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 124: goToNextPage()      // →
        case 123: goToPreviousPage()  // ←
        default: super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }
```

파일 하단에 알림 이름 추가:

```swift
extension Notification.Name {
    static let readerPageChanged = Notification.Name("jn_readerPageChanged")
}
```

`pageInfo`(인디케이터용)도 노출:

```swift
    var pageInfo: (current: Int, total: Int) { (currentPage + 1, pageCount) }
```

- [ ] **Step 4: 빌드 검증**

Run: `make build`
Expected: 컴파일 에러 0.

- [ ] **Step 5: 커밋**

```bash
git add Sources/JenaNoteKit/editor/ReaderViewController.swift
git commit -m "feat: add horizontal page-flip paging to reading mode

페이지 = 뷰 높이(줄 높이 정수배) 단위 세로 구간 점프. ←/→ 키로 이동.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 모드 전환 + 읽기 툴바 + 메뉴

편집 ⇄ 읽기 토글을 연결한다. split 우측 item 교체, 읽기용 툴바, 메뉴/단축키.

**Files:**
- Create: `Sources/JenaNoteKit/toolbar/ReaderToolbar.swift`
- Modify: `Sources/JenaNoteKit/editor/EditorWindowController.swift`
- Modify: `Sources/JenaNoteKit/app/AppDelegate.swift` (보기 메뉴에 읽기 모드 항목)

**Interfaces:**
- Consumes: `ReaderViewController`, `EditorViewController`, `FormatToolbar`.
- Produces:
  - `ReaderToolbar` (`[편집으로] | 스크롤·페이징 세그먼트 | A− A+`), `weak var target`.
  - `EditorWindowController.toggleReadingMode(_:)`, `var isReadingMode: Bool`.
  - 읽기 툴바 액션 셀렉터: `exitReadingMode(_:)`, `changeReaderPageMode(_:)`, `decreaseReaderFont(_:)`, `increaseReaderFont(_:)`.

- [ ] **Step 1: ReaderToolbar 작성**

`Sources/JenaNoteKit/toolbar/ReaderToolbar.swift`:

```swift
import AppKit

class ReaderToolbar: NSToolbar {

    weak var target: AnyObject?

    private static let itemExit  = NSToolbarItem.Identifier("readerExit")
    private static let itemMode  = NSToolbarItem.Identifier("readerPageMode")
    private static let itemFontDown = NSToolbarItem.Identifier("readerFontDown")
    private static let itemFontUp   = NSToolbarItem.Identifier("readerFontUp")

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)
        delegate = self
        displayMode = .iconOnly
        allowsUserCustomization = false
    }
}

extension ReaderToolbar: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ReaderToolbar.itemExit, .space,
         ReaderToolbar.itemMode, .space,
         ReaderToolbar.itemFontDown, ReaderToolbar.itemFontUp, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(t)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ReaderToolbar.itemExit:
            return iconItem(id, label: L10n.tr("reader.exit"), symbol: "pencil",
                            action: #selector(EditorWindowController.exitReadingMode(_:)))
        case ReaderToolbar.itemMode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L10n.tr("reader.pageMode")
            let seg = NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            seg.segmentCount = 2
            seg.setLabel(L10n.tr("reader.scroll"), forSegment: 0)
            seg.setLabel(L10n.tr("reader.paged"), forSegment: 1)
            seg.trackingMode = .selectOne
            seg.selectedSegment = (SettingsManager.shared.readingPageMode == .paged) ? 1 : 0
            seg.target = target
            seg.action = #selector(EditorWindowController.changeReaderPageMode(_:))
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.widthAnchor.constraint(equalToConstant: 120).isActive = true
            seg.heightAnchor.constraint(equalToConstant: 26).isActive = true
            item.view = seg
            return item
        case ReaderToolbar.itemFontDown:
            return iconItem(id, label: L10n.tr("reader.fontDown"), symbol: "textformat.size.smaller",
                            action: #selector(EditorWindowController.decreaseReaderFont(_:)))
        case ReaderToolbar.itemFontUp:
            return iconItem(id, label: L10n.tr("reader.fontUp"), symbol: "textformat.size.larger",
                            action: #selector(EditorWindowController.increaseReaderFont(_:)))
        default:
            return nil
        }
    }

    private func iconItem(_ id: NSToolbarItem.Identifier, label: String,
                          symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label; item.toolTip = label
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 26))
        button.image = image
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.setButtonType(.momentaryPushIn)
        button.target = target
        button.action = action
        item.view = button
        return item
    }
}
```

- [ ] **Step 2: EditorWindowController에 모드 전환 추가**

`EditorWindowController`에 프로퍼티와 메서드 추가 (기존 `setupToolbar`로 만든 `FormatToolbar`를 보관해 복귀용으로 쓴다):

먼저 Children MARK 근처에 저장 프로퍼티:

```swift
    private(set) var isReadingMode = false
    private var readerVC: ReaderViewController?
    private var formatToolbar: FormatToolbar?
    private var readerToolbar: ReaderToolbar?
```

`setupToolbar`를 수정해 참조 보관:

```swift
    private func setupToolbar(for window: NSWindow) {
        let toolbar = FormatToolbar(identifier: NSToolbar.Identifier("FormatToolbar"))
        toolbar.target = editorVC
        window.toolbar = toolbar
        formatToolbar = toolbar
    }
```

모드 전환 메서드 (Sidebar Toggle MARK 아래에 추가):

```swift
    // MARK: - Reading Mode (ADR-0006)

    @objc func toggleReadingMode(_ sender: Any?) {
        isReadingMode ? exitReadingMode(sender) : enterReadingMode(sender)
    }

    @objc func enterReadingMode(_ sender: Any?) {
        guard !isReadingMode, let doc = document as? MarkdownDocument else { return }
        // 편집 내용 flush 보장
        if let storage = editorVC.textView.textStorage {
            doc.textDidChange(storage)
        }
        let reader = ReaderViewController(content: doc.content)
        readerVC = reader
        swapRightPane(to: reader)

        let rToolbar = ReaderToolbar(identifier: NSToolbar.Identifier("ReaderToolbar"))
        rToolbar.target = self
        window?.toolbar = rToolbar
        readerToolbar = rToolbar

        reader.setPageMode(SettingsManager.shared.readingPageMode)
        isReadingMode = true
    }

    @objc func exitReadingMode(_ sender: Any?) {
        guard isReadingMode else { return }
        swapRightPane(to: editorVC)
        if let f = formatToolbar { window?.toolbar = f } else { setupToolbar(for: window!) }
        editorVC.loadDocumentContent()
        readerVC = nil
        isReadingMode = false
    }

    private func swapRightPane(to vc: NSViewController) {
        guard let split = window?.contentViewController as? NSSplitViewController else { return }
        // 우측(인덱스 1) item 교체. 좌측 사이드바는 유지.
        if split.splitViewItems.count > 1 {
            split.removeSplitViewItem(split.splitViewItems[1])
        }
        let item = NSSplitViewItem(viewController: vc)
        item.minimumThickness = 360
        split.addSplitViewItem(item)
    }

    // MARK: - Reader Toolbar Actions

    @objc func changeReaderPageMode(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let mode: SettingsManager.ReadingPageMode = (seg.selectedSegment == 1) ? .paged : .scroll
        readerVC?.setPageMode(mode)
    }

    @objc func decreaseReaderFont(_ sender: Any?) {
        let cur = SettingsManager.shared.readingFontScale
        readerVC?.setFontScale(cur - 0.1)
    }

    @objc func increaseReaderFont(_ sender: Any?) {
        let cur = SettingsManager.shared.readingFontScale
        readerVC?.setFontScale(cur + 0.1)
    }
```

Responder chain 노출을 위해 클래스 끝에 추가:

```swift
    override func responds(to aSelector: Selector!) -> Bool {
        let sels: [Selector] = [
            #selector(toggleReadingMode(_:)), #selector(enterReadingMode(_:)),
            #selector(exitReadingMode(_:)), #selector(changeReaderPageMode(_:)),
            #selector(decreaseReaderFont(_:)), #selector(increaseReaderFont(_:))
        ]
        if sels.contains(aSelector) { return true }
        return super.responds(to: aSelector)
    }
```

> 주의: `editorVC.textView`는 현재 `var textView: EditorTextView!`로 internal 접근 가능. `swapRightPane`가 editorVC를 다시 추가할 때 `EditorViewController.viewWillAppear`의 `loadDocumentContent()`가 재호출되므로 내용 보존됨.

- [ ] **Step 3: 보기 메뉴에 읽기 모드 항목 추가**

`AppDelegate.setupMenu()`의 "보기 메뉴" 블록에서 `toggleSidebar` 추가 직후:

```swift
        viewMenu.addItem(.separator())
        let readingMode = viewMenu.addItem(withTitle: L10n.tr("menu.view.readingMode"),
                                           action: #selector(EditorWindowController.toggleReadingMode(_:)),
                                           keyEquivalent: "r")
        readingMode.keyEquivalentModifierMask = [.command, .shift]
```

- [ ] **Step 4: 빌드 검증**

Run: `make build && make run`
Expected: 컴파일 에러 0. **수동 e2e**:
1. 텍스트가 있는 `.md`를 연다.
2. `⌘⇧R` 또는 보기 메뉴 > 읽기 모드 → 우측이 가운데 정렬 컬럼의 읽기 화면으로 바뀌고 툴바가 읽기용으로 교체된다.
3. 툴바 `A+`/`A−` → 글자 크기가 커지고 작아진다(본문/제목 비율 유지).
4. 세그먼트 `페이징` 선택 → 세로 스크롤러가 사라지고, `→`/`←`로 페이지가 넘어간다(줄 잘림 없음).
5. 툴바 `편집으로`(또는 `⌘⇧R`) → 편집 화면 복귀, 내용 그대로, 편집 툴바 복귀.
6. 사이드바에서 다른 파일 클릭(읽기 모드 중) → 읽기 모드 유지된 채 새 내용 조판. *(만약 유지가 안 되면 Step 6 참고.)*

- [ ] **Step 5: 읽기 중 문서 스왑 시 내용 갱신 연결**

`EditorWindowController.swapDocument(to:replacing:)`의 클로저 안, `self.editorVC.loadDocumentContent()` 다음 줄에 추가:

```swift
            if self.isReadingMode, let newDoc = self.document as? MarkdownDocument {
                self.readerVC?.updateContent(newDoc.content)
            }
```

- [ ] **Step 6: 재빌드·수동 확인·커밋**

Run: `make build && make run` → 위 수동 e2e 6번(읽기 중 파일 교체) 재확인.

```bash
git add Sources/JenaNoteKit/toolbar/ReaderToolbar.swift Sources/JenaNoteKit/editor/EditorWindowController.swift Sources/JenaNoteKit/app/AppDelegate.swift
git commit -m "feat: wire reading-mode toggle, reader toolbar, and View menu item

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: 다국어 라벨 + 페이지 인디케이터 + 문서 갱신

읽기 모드 문자열을 7개 언어로 추가하고, 페이징 인디케이터를 붙이고, architecture.md·devlog를 갱신한다.

**Files:**
- Modify: `Sources/JenaNoteKit/app/Localization.swift`
- Modify: `Sources/JenaNoteKit/editor/ReaderViewController.swift` (하단 페이지 인디케이터)
- Modify: `docs/architecture.md`
- Create: `docs/devlog/2026-06-21-reading-mode.md`

**Interfaces:**
- Consumes: `Notification.Name.readerPageChanged`, `ReaderViewController.pageInfo`.

- [ ] **Step 1: Localization 키 추가 (7개 언어)**

각 언어 dict(`ko`,`en`,`zh`,`ja`,`es`,`de`,`fr`)에 동일 키 세트를 추가한다. ko/en 예시(나머지 언어도 해당 언어로 번역해 같은 키를 추가):

```swift
        // ko
        "menu.view.readingMode": "읽기 모드",
        "reader.exit":     "편집으로",
        "reader.pageMode": "페이지 방식",
        "reader.scroll":   "스크롤",
        "reader.paged":    "페이지",
        "reader.fontDown": "글자 작게",
        "reader.fontUp":   "글자 크게",
```
```swift
        // en
        "menu.view.readingMode": "Reading Mode",
        "reader.exit":     "Edit",
        "reader.pageMode": "Page Mode",
        "reader.scroll":   "Scroll",
        "reader.paged":    "Pages",
        "reader.fontDown": "Smaller",
        "reader.fontUp":   "Larger",
```

zh/ja/es/de/fr 번역값:
- zh: 阅读模式 / 编辑 / 翻页方式 / 滚动 / 翻页 / 缩小 / 放大
- ja: 読書モード / 編集 / ページ方式 / スクロール / ページ / 小さく / 大きく
- es: Modo lectura / Editar / Modo de página / Desplazar / Páginas / Reducir / Ampliar
- de: Lesemodus / Bearbeiten / Seitenmodus / Scrollen / Seiten / Kleiner / Größer
- fr: Mode lecture / Éditer / Mode page / Défilement / Pages / Réduire / Agrandir

- [ ] **Step 2: 페이지 인디케이터 추가**

`ReaderViewController.loadView()` 끝(`renderContent()` 앞)에 하단 라벨을 추가하고, 페이지 변경 알림을 구독한다:

```swift
        // 하단 페이지 인디케이터 (페이징 모드에서만 표시)
        let indicator = NSTextField(labelWithString: "")
        indicator.alignment = .center
        indicator.textColor = .secondaryLabelColor
        indicator.font = NSFont.systemFont(ofSize: 11)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8)
        ])
        self.pageIndicator = indicator
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePageIndicator),
            name: .readerPageChanged, object: self)
```

프로퍼티와 갱신 메서드 추가:

```swift
    private weak var pageIndicator: NSTextField?

    @objc private func updatePageIndicator() {
        guard pageMode == .paged else { pageIndicator?.isHidden = true; return }
        let info = pageInfo
        pageIndicator?.isHidden = false
        pageIndicator?.stringValue = "‹ \(info.current) / \(info.total) ›"
    }

    deinit { NotificationCenter.default.removeObserver(self) }
```

`setPageMode`의 끝과 `scrollToCurrentPage` 끝에서 `updatePageIndicator()`를 호출하도록 한 줄씩 추가.

- [ ] **Step 3: 빌드·수동 확인**

Run: `make build && make run`
Expected: 페이징 모드에서 하단에 `‹ 3 / 12 ›`가 보이고 페이지 이동 시 갱신. 스크롤 모드에선 숨김. 다국어(설정 > 언어 변경 후 읽기 모드 진입)에서 라벨이 번역됨.

- [ ] **Step 4: architecture.md 갱신**

`docs/architecture.md`에 반영:
- §3 폴더 구조: `editor/`에 `ReaderViewController.swift`·`ReaderMetrics.swift`, `toolbar/`에 `ReaderToolbar.swift` 추가. SPM 구조(`Sources/JenaNote`·`Sources/JenaNoteKit`·`Tests/`) 한 줄 명기.
- §4: `ReaderViewController` 책임 블록 추가("읽기 전용 조판·스크롤/페이징·폰트 배율, 원본 불변").
- §8 빌드 구조: `swiftc 직접` → `SPM(swift build) + Makefile 래핑`으로 갱신, `make test` 추가.
- §9 ADR: 아래 ADR-0006 추가.

```markdown
### ADR-0006: 읽기 모드 = split 우측 item 스왑 + 세로 구간 점프식 가로 페이지네이션 (2026-06-21)
- **결정:** 읽기 모드를 별도 창이 아닌 `EditorWindowController` 우측 split item을 `ReaderViewController`로 교체하는 방식으로 구현한다. 가로 페이지 넘김은 단일 컬럼 레이아웃을 뷰 높이(줄 높이 정수배) 단위로 끊어 scroll offset을 점프시켜 근사한다.
- **근거:** 사이드바·툴바·문서 스왑(ADR-0004) 재사용. NSTextView 물리적 페이지 분할의 무게를 피하면서 전자책 UX 대부분을 얻는다. 회귀 테스트를 위해 SPM 도입(ReaderMetrics 순수 함수 검증).
- **트레이드오프:** 진짜 조판 페이지네이션(가변 줄 수, 고아/미망인 제어) 미지원. 페이지 바닥 여백 발생 가능. 읽기 모드는 읽기 전용이라 문서 변경 위험 없음.
```

- [ ] **Step 5: devlog 작성**

`docs/devlog/2026-06-21-reading-mode.md` — 일자·요구·영향 파일·핵심 결정(별도 ReaderViewController, 세로 구간 점프식 페이징, SPM 도입)·트레이드오프·수동 e2e 항목·다음 후보(진짜 페이지네이션, 줄 길이 설정 UI, 가로 슬라이드 애니메이션)를 기존 devlog 형식으로 정리.

- [ ] **Step 6: 전체 검증·커밋**

```bash
make clean && make build && make test && make run
```
Expected: 빌드·테스트 모두 통과, 앱 정상. 전체 수동 e2e(Task 6 Step 4의 6항목) 최종 확인.

```bash
git add -A
git commit -m "feat: add reading-mode i18n labels, page indicator; update architecture/devlog

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage** (spec §별 → task 매핑)
- §2 타이포 35자 → Task 2 `columnWidth` + Task 4 `columnWidthForCurrentSettings`. ✓
- §3 별도 ReaderViewController + split 스왑 → Task 4·6. ✓
- §4 가로 페이지 넘김(세로 구간 점프) → Task 5. ✓
- §5 진입점(툴바·메뉴·⌘⇧R)·읽기 컨트롤 → Task 6·7. ✓
- §6 읽기 전용 폰트 배율(원본 불변) → Task 2 `scaled` + Task 4 `setFontScale`. ✓
- §7 설정 영속 3키 → Task 3. ✓
- §8 데이터 흐름·읽기 중 파일 교체 유지 → Task 6 Step 5. ✓
- §9 테스트(순수 함수 단위 + 수동 e2e) → Task 2·3 단위 + Task 6·7 수동. ✓
- §11 ADR-0006 → Task 7 Step 4. ✓

**2. Placeholder scan:** 모든 코드 단계에 실제 코드 포함. UI 태스크는 빌드 검증 + 명시적 수동 e2e 체크리스트로 대체(테스트 자동화 불가 영역 — 정직하게 표기). 통과.

**3. Type consistency:** `setPageMode`/`setFontScale`/`updateContent`/`pageInfo`/`readerPageChanged` 명칭이 Task 4·5·6·7에서 일관. `SettingsManager.ReadingPageMode`(.scroll/.paged) 일관. `readingFontScale`/`readingPageMode`/`readingLineLength` 키 일관. 통과.
