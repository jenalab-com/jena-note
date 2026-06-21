# 읽기 모드(책 보기) — 설계 명세

| | |
| --- | --- |
| 일자 | 2026-06-21 |
| 상태 | 설계 확정 (구현 전) |
| 사용자 요구 | 편집 모드와 별개의 "책 보기(읽기) 모드"를 추가. 한글 단행본처럼 한 줄 글자 수를 맞춘 컬럼으로 조판하고, 스크롤/페이징을 선택할 수 있게 한다. |
| 영향 레이어 | UI Layer (editor / toolbar) · app (SettingsManager) |
| 관련 문서 | `docs/spec.md` · `docs/architecture.md` (§3·§4·§9 갱신 예정) |

---

## 1. 목표와 비목표

### 목표
- 편집 모드 ↔ 읽기 모드를 **한 창 안에서 토글**한다(별도 창 아님).
- 읽기 모드는 **읽기 전용** 조판 화면이다. 한글 본문 기준 **한 줄 35자 내외**의 컬럼을 화면 가운데 두고, 좌우 여백을 넉넉히 준다.
- 읽기 모드에서 **스크롤**과 **가로 페이지 넘김(페이징)** 중 하나를 선택할 수 있다.
- 읽기 모드 전용 **글자 크기 배율**(원본 불변, 표시 전용)을 제공한다.

### 비목표 (YAGNI)
- 진짜 출판 페이지네이션(고아/미망인 줄 제어, 페이지마다 가변 줄 수) — 1차 범위 밖.
- 읽기 모드 설정 전용 UI 화면 — `readingLineLength`는 키만 두고 1차엔 35 고정.
- 별도 읽기 전용 창.
- 원본 `.md`/문서 내용 변경 — 읽기 모드는 절대 문서를 수정하지 않는다.

---

## 2. 타이포그래피 기준 (한 줄 글자 수)

- 가독성 연구는 라틴 문자 기준 한 줄 45~75자(이상적 66자)를 권장한다. 한글은 전각(거의 정사각)이라 라틴 두 글자 폭에 가까워, **한글 환산 25~45자**가 편안한 영역이다.
- 한국 단행본(신국판 152×225mm)은 관행적으로 **한 줄 30~40자**를 쓴다. 그 한가운데인 **35자**를 기본값으로 채택한다. (출판 통념 기준이며 절대 공식은 아니다.)
- **폭 환산**: 본문 폰트 `MemoFont.body = systemFont(ofSize: 15)`(15pt). 한글 전각이라 글자당 advance ≈ 15pt → 35자 컬럼 폭 ≈ **525pt**. 여기에 좌우 여백을 더해 화면 가운데 배치한다.
  - 정확한 폭은 구현 시 `font.advancement` 또는 대표 한글 글리프(예: "한") 실측으로 보정한다(시스템 한글 폰트 fallback 폭이 정확히 1em이 아닐 수 있음).

---

## 3. 아키텍처 — 어디에 붙이나

별도 `ReaderViewController`를 신설하고, `EditorWindowController`가 우측 split 영역을 `EditorViewController` ⇄ `ReaderViewController`로 교체한다.

```
EditorWindowController (창·툴바·SplitView 호스트, 모드 상태 소유)
 ├─ [좌] SidebarViewController          ← 그대로 유지
 └─ [우] EditorViewController   ⇄  ReaderViewController(신설)
                    ↑ 모드 토글 시 split 우측 item만 교체
```

**근거**
- `EditorViewController`(261줄)는 이미 포맷 액션이 많다. 페이징·컬럼·폰트 배율 로직을 넣으면 단일 책임이 무너진다. 읽기 모드는 독립 관심사이므로 별도 클래스로 분리한다(architecture.md "작게 분리, 단일 책임").
- 읽기 모드는 읽기 전용이라 내용을 바꾸지 않는다. 진입 시 `document.content`(NSAttributedString)를 받아 조판만 한다. ADR-0004 문서 스왑과 충돌하지 않는다.
- 사이드바·툴바·문서 스왑을 모두 재사용한다. 별도 창이면 전부 중복 구현해야 한다.

**레이어 규칙 준수**: `ReaderViewController`는 UI Layer. `MarkdownSerializer`를 직접 호출하지 않는다. `document.content`(이미 파싱된 NSAttributedString)만 입력으로 받는다.

---

## 4. 가로 페이지 넘김 구현 방식

NSTextView를 물리적으로 여러 페이지로 쪼개지 않는다. 대신:

> **한 컬럼(35자 폭)으로 텍스트를 세로로 길게 한 번만 레이아웃하고, "한 페이지 = 가용 뷰 높이만큼의 세로 구간"으로 보여준다. 페이지 넘김 = 그 구간을 다음 높이로 점프(scroll offset 이동). 가로 슬라이드 전환 효과를 얹어 전자책처럼 보이게 한다.**

- **줄 잘림 방지**: 페이지 높이를 줄 높이의 **정수배로 스냅**한다. `pageHeight = floor(가용높이 / lineHeight) × lineHeight`. 페이지 경계에서 글자가 반 잘리지 않는다. 트레이드오프 — 페이지 바닥에 약간의 여백이 생길 수 있다(책에선 자연스럽다).
- **넘김 조작**: `←`/`→` 키, 좌우 끝 클릭, 하단 페이지 버튼(`‹ 3 / 12 ›`).
- **스크롤 모드**는 같은 컬럼을 세로 스크롤로 푼다. 두 모드가 레이아웃을 공유하고 표시 방식만 다르다 → 토글이 가볍다.
- **트레이드오프(정직)**: 이는 "뷰 높이 단위로 끊어 가로로 넘기는" 전자책 근사치다. 진짜 조판 페이지네이션이 아니다. 이 규모 앱에 맞는 선택이며, 부족하면 추후 키운다.

페이징 로직이 커지면 `ReaderPaginator.swift`로 분리한다.

---

## 5. 진입점과 컨트롤

**진입/복귀**
- **툴바 버튼**: 우측에 읽기 모드 토글(`book`/`eye` SF Symbol). 토글식.
- **메뉴**: `보기 > 읽기 모드` (`⌘⇧R`). Responder chain으로 `EditorWindowController`가 수신(창이 소유한 표시 상태).
- 읽기 모드 진입 시 편집 전용 툴바 항목(굵게·색상 등)은 의미 없으므로 **툴바를 읽기용 최소 셋으로 교체**: `[편집으로] | 스크롤·페이징 토글 | A− A+`.

**읽기 모드 내 컨트롤** (`ReaderViewController` 소유)
- 스크롤 ⇄ 페이징 세그먼트 토글
- 글자 크기 `A−`/`A+` (또는 `⌘+`/`⌘−`)
- 페이징일 때만 하단 `‹ 3 / 12 ›` 페이지 인디케이터

---

## 6. 읽기 전용 글자 크기 배율

- 읽기 모드는 `document.content`를 복사한 뒤 모든 `.font` 속성에 배율(scale)을 곱한 **표시용 NSAttributedString**을 만들어 렌더한다. 본문 15pt·H1 28pt 등 **상대 비율은 유지**되고 전체만 커지고 작아진다.
- **원본 문서·`.md`는 절대 불변.** 배율은 화면 표시 전용. 저장 로직(MarkdownSerializer)은 손대지 않는다.
- 배율 범위: `0.8× ~ 2.0×`, 약 0.1 간격. 기본 `1.0×`.
- 핵심 함수 `scaledContent(_ content: NSAttributedString, by scale: CGFloat) -> NSAttributedString` — 순수 변환, 원본 불변. 단위 테스트 대상.

---

## 7. 설정 영속 (`SettingsManager` 확장)

기존 `language`/`appearance` 옆에 추가, UserDefaults 영속:

| 키 | 값 | 기본 |
|---|---|---|
| `jn_readingPageMode` | `scroll` \| `paged` | `scroll` |
| `jn_readingFontScale` | `0.8`~`2.0` | `1.0` |
| `jn_readingLineLength` | 글자 수(Int) | `35` |

`readingLineLength`는 1차엔 35 고정으로 사용하되 키만 미리 둔다(추후 설정 UI로 노출).

`readingPageMode`/`readingFontScale`는 enum/프로퍼티로 노출하며, `appearanceMode`와 동일한 get/set + UserDefaults 패턴을 따른다.

---

## 8. 데이터 흐름 / 상태

```
편집 → 읽기 (⌘⇧R / 툴바)
  EditorWindowController.toggleReadingMode()
    → editorVC가 현재 textView 내용을 document에 flush (textDidChange 보장)
    → ReaderViewController(content: document.content, scale, pageMode) 구성
    → split 우측 item을 readerVC로 교체 + 툴바를 읽기용으로 교체

읽기 → 편집
    → split 우측 item을 editorVC로 복귀 + 툴바 복귀
    → editorVC.loadDocumentContent() (읽기 중 외부 변경 대비 재로드)
```

- **모드 상태**는 `EditorWindowController`가 소유(`isReadingMode: Bool`). 문서가 아니라 창의 표시 상태다.
- 읽기 중 사이드바에서 **다른 파일 클릭** → 문서 스왑 후 **읽기 모드를 유지**한 채 새 내용을 조판한다.

**상태 소유 정리**

| 상태 | 소유자 |
|------|--------|
| 읽기 모드 on/off | `EditorWindowController.isReadingMode` |
| 페이지 모드(scroll/paged) | `SettingsManager` (영속) + `ReaderViewController` (현재값) |
| 폰트 배율 | `SettingsManager` (영속) + `ReaderViewController` (현재값) |
| 현재 페이지 인덱스 | `ReaderViewController` (로컬, 비영속) |

---

## 9. 테스트 전략

**단위 테스트 (AppKit 의존 최소화해 분리)**
- `scaledContent(_:by:)` — 배율 적용 정확성 + 원본 NSAttributedString 불변 검증.
- `pageHeight(viewHeight:lineHeight:)` — 줄 높이 정수배 스냅 검증.
- `columnWidth(charCount:font:)` — 컬럼 폭 계산 검증.

**수동 e2e (UI 레이아웃이라 자동화 어려움 — 정직하게 권장)**
- 페이지 넘김 체감, 페이지 경계 줄 잘림 없음.
- 모드 전환 시 스크롤 위치/상태 보존.
- 다국어(한/영/중/일) 글자 폭에서 컬럼 정렬.
- 읽기 중 사이드바 파일 교체 → 읽기 모드 유지 + 새 내용 조판.

---

## 10. 신규/변경 파일

**신규**
- `Sources/editor/ReaderViewController.swift` — 읽기 모드 뷰 컨트롤러(조판·스크롤/페이징·배율).
- (페이징 로직 비대 시) `Sources/editor/ReaderPaginator.swift` — 세로 구간 점프 페이지네이션.

**변경**
- `Sources/editor/EditorWindowController.swift` — 모드 토글, split 우측 item 교체, 툴바 교체, `isReadingMode`.
- `Sources/toolbar/FormatToolbar.swift` — 읽기용 툴바 아이템 세트(또는 별도 ReaderToolbar 구성).
- `Sources/app/SettingsManager.swift` — `readingPageMode`/`readingFontScale`/`readingLineLength`.
- `Sources/app/Localization.swift` — 읽기 모드 관련 라벨(7개 언어).
- `docs/architecture.md` — §3 폴더 구조, §4 컴포넌트 책임, §9 ADR-0006 추가.

---

## 11. ADR-0006 (architecture.md에 기록 예정)

**ADR-0006: 읽기 모드 = split 우측 item 스왑 + 세로 구간 점프식 가로 페이지네이션 (2026-06-21)**
- **결정**: 읽기 모드를 별도 창이 아닌, `EditorWindowController`의 우측 split item을 `ReaderViewController`로 교체하는 방식으로 구현한다. 가로 페이지 넘김은 단일 컬럼 레이아웃을 뷰 높이(줄 높이 정수배) 단위로 끊어 scroll offset을 점프시켜 근사한다.
- **근거**: 사이드바·툴바·문서 스왑(ADR-0004) 재사용. NSTextView 물리적 페이지 분할의 무게를 피하면서 전자책 UX의 대부분을 얻는다.
- **트레이드오프**: 진짜 조판 페이지네이션(가변 줄 수, 고아/미망인 제어)은 미지원. 페이지 바닥 여백 발생 가능. 읽기 모드는 읽기 전용이라 문서 변경 위험 없음.
