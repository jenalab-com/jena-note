# 하단 상태바 + 글자수 카운터

- 날짜: 2026-06-23
- 상태: 구현 완료 (사용자 .app 육안 확인)

## 목적

윈도우 전체 폭 하단에 상태바를 추가하고, 우측 끝에 문서 글자수(공백 제외)와
공백 포함 글자수를 실시간 표시한다. 글 쓰는 사람이 분량을 늘 곁에서 볼 수 있게 한다.

## 레이아웃 (승인된 결정: 윈도우 전체 하단)

```
┌────────┬────────────────────────┐
│ side   │   editor               │
│ bar    │                        │  ← splitVC (위, 신축)
├────────┴────────────────────────┤
│              1,234자 · 공백 포함 1,456자 │  ← 상태바 (높이 22pt, 우측 정렬)
└──────────────────────────────────┘
```

- 새 컨테이너 `NSViewController`가 `splitVC.view`(위, 신축) + `StatusBarView`(아래 고정 22pt)를
  세로로 담고, 이를 `window.contentViewController`로 둔다.
- **핵심: `containerVC.addChild(splitVC)` 필수.** split VC를 컨테이너 VC의 자식으로 등록하지 않으면
  사이드바-타이틀바 통합이 깨진다. (06-23 새벽 이 한 줄을 빠뜨려 'Liquid Glass 충돌'로 오진했었음.)
- 형제 프로젝트 **jena-image의 `MainWindowController.setupLayout()`이 검증된 레퍼런스** — 동일 패턴.
- 상태바 상단에 1px 구분선. 좌측은 비워둔다(향후 저장 상태·커서 위치 자리).

## 읽기 모드 영향

- `swapRightPane`은 `window.contentViewController as? NSSplitViewController`로 split을 찾았는데,
  컨테이너로 감싸면 그 캐스팅이 nil이 된다. → 보유 중인 `splitVC` 프로퍼티를 직접 쓰도록 변경 완료(더 견고).
- 전체 폭 상태바라 읽기 모드에서도 그대로 보인다. 같은 문서라 글자수 유지(편집 안 하니 고정).

## 글자수 정의 (확정)

- **문서 글자수** = 공백·탭·개행·이미지 첨부(`\u{FFFC}`) **제외**한 글자 수.
- **공백 포함** = 공백·탭 포함, 개행·이미지 첨부 **제외**.
- 글자 단위는 `Character`(grapheme cluster). 개행 판별 `isNewline`, 공백 판별 `isWhitespace`.
- 포맷: `1,234자 · 공백 포함 1,456자` (천 단위 콤마는 `NumberFormatter` 로케일 처리).

## 데이터 흐름

- `EditorViewController.textDidChange` + `loadDocumentContent` 시점에 `textView.string`으로
  글자수 재계산 → `EditorWindowController`의 상태바 갱신. 타이핑 시 실시간.
- 계산은 순수 함수 `TextMetrics`로 분리(ReaderMetrics 패턴) → 단위 테스트 가능.

## 변경/추가 파일

| 파일 | 변경 |
|---|---|
| `editor/TextMetrics.swift` (신규) | `counts(for:) -> (noSpaces, withSpaces)`, 천단위 포맷 |
| `statusbar/StatusBarView.swift` (신규) | 우측 정렬 라벨 + 상단 구분선, `setText(_:)` |
| `editor/EditorWindowController.swift` | 컨테이너로 split 감싸기, 상태바 보유, `updateCharCount`, swapRightPane을 splitVC 직접 참조로 |
| `editor/EditorViewController.swift` | 텍스트 변경/로드 시 상태바 갱신 통지 |
| `app/Localization.swift` | `status.chars` / `status.charsWithSpaces` 7개 언어 |
| `Tests/.../TextMetricsTests.swift` (신규) | 글자수 계산 단위 테스트(공백/개행/이미지/한글) |

## 테스트 케이스

- 빈 문자열 → (0, 0)
- "안녕 하루" → noSpaces 4, withSpaces 5
- 개행 포함 "가\n나" → (2, 2)
- 이미지 첨부 "가\u{FFFC}나" → (2, 2)
- 탭/연속 공백 → withSpaces만 증가
