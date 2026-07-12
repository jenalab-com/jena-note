# JenaNote 검색 기능 설계 (2026-07-13)

> 승인된 설계. 브레인스토밍 결정: 네이티브 NSTextFinder + 바꾸기 포함 + 사이드바 통합 전체 검색.

## 목표

1. **문서 내 검색 (⌘F)** — 상단에 검색 바 노출, 검색어 입력 시 현재 문서 검색.
2. **위/아래 이동** — 검색 바의 ‹ › 버튼(및 ⌘G / ⇧⌘G)으로 매치 간 이동.
3. **찾아 바꾸기 (⌥⌘F)** — 바꾸기 필드 포함.
4. **파일 전체 검색 (⇧⌘F)** — 사이드바 통합, 등록 폴더의 모든 `.md` 검색.

## A. 문서 내 검색 — 네이티브 NSTextFinder

### 방식

`EditorTextView`(NSTextView)에 시스템 찾기 바를 켠다:

```swift
textView.usesFindBar = true
textView.isIncrementalSearchingEnabled = true
```

검색 필드·‹ › 이동·매치 카운트("3/12")·전체 매치 하이라이트·Esc 닫기·다크 모드·현지화를 AppKit이 전부 제공한다. 커스텀 검색 UI는 만들지 않는다.

### 메뉴 정비 (AppDelegate)

기존 편집 > 찾기(⌘F)는 구식 `performFindPanelAction(_:)`에 연결되어 있다. 다음으로 교체·추가한다 — 모두 `NSTextView.performTextFinderAction(_:)` + `NSTextFinder.Action` rawValue를 menu item tag로:

| 메뉴 항목 | 단축키 | tag (NSTextFinder.Action) |
| --- | --- | --- |
| 찾기… | ⌘F | `.showFindInterface` (1) |
| 다음 찾기 | ⌘G | `.nextMatch` (2) |
| 이전 찾기 | ⇧⌘G | `.previousMatch` (3) |
| 찾아 바꾸기… | ⌥⌘F | `.showReplaceInterface` (12) |

Responder chain으로 first responder인 NSTextView에 전달된다 (기존 메뉴 연결 전략 §7 준수).

### 툴바 버튼 (FormatToolbar)

- 아이템 `find` 추가 — SF Symbol `magnifyingglass`, 기존 `makeItem` 패턴 재사용.
- 액션: `EditorViewController.showFindBar(_:)` (@objc) → `textView.performTextFinderAction(_:)` with `.showFindInterface`.
- 배치: 읽기 모드 버튼 옆 (`itemReadingMode` 앞).

### 읽기 모드

`ReaderViewController`의 텍스트뷰에도 `usesFindBar = true` + `isIncrementalSearchingEnabled = true`. 읽기 전용이므로 찾기만 동작하고 바꾸기 인터페이스는 시스템이 비활성 처리한다. 페이징 모드에서 매치 점프 시 scroll offset이 페이지 경계와 어긋날 수 있음 — 구현 시 `scrollToCurrentPage()` 재정렬 여부 확인 (수동 검증 항목).

### 바꾸기와 WYSIWYG 서식

바꾼 텍스트는 해당 위치의 기존 속성(볼드·제목 등)을 이어받는 NSTextView 기본 동작을 따른다. Undo는 document.undoManager에 자동 등록. `textDidChange` 경로로 `updateChangeCount` 반영 확인 — NSTextFinder의 replace가 `shouldChangeText`/`didChangeText`를 거치므로 기존 흐름 그대로 동작해야 한다 (수동 검증 항목).

## B. 파일 전체 검색 — 사이드바 통합

### UI 흐름 (SCREEN-05)

```
[진입]
  편집 > 파일에서 찾기 (⇧⌘F)
  → 사이드바 숨김 상태면 표시
  → 사이드바 헤더의 NSSearchField에 포커스

[검색]
  입력 (250ms debounce)
  → 등록 폴더 전체 .md 백그라운드 스캔
  → 파일 트리가 결과 리스트로 전환:
      ▾ 파일명.md (매치 수)
          …매치 줄 스니펫 (검색어 볼드 강조)…
          …매치 줄 스니펫…

[결과 클릭]
  → EditorWindowController.openFile(at:jumpingTo:) — 기존 인-플레이스 스왑 재사용
  → 미저장 변경 시 기존 저장 확인 시트 흐름 그대로
  → 열린 후 해당 매치 위치로 스크롤 + 선택 하이라이트

[이탈]
  검색어 전부 지움 또는 검색 필드에서 Esc
  → 원래 파일 트리로 복귀 (펼침 상태 유지)
```

### 상태 정의

| 상태 | 조건 | 표현 |
| --- | --- | --- |
| 트리 모드 | 검색어 없음 | 기존 파일 트리 |
| 검색 중 | 스캔 진행 | 필드 우측 spinner |
| 결과 표시 | 매치 ≥ 1 | 파일 그룹 + 스니펫 행 |
| 결과 없음 | 매치 0 | "결과 없음" placeholder |
| 폴더 없음 | 등록 폴더 0 | "폴더를 먼저 추가하세요" |
| 결과 초과 | 500건 초과 | 상단에 "일부만 표시됨" 안내 |

### 컴포넌트 구조 (레이어 규칙 준수)

```
UI Layer
  SidebarViewController — 검색 필드 호스트, 트리 모드 ↔ 결과 모드 전환
                          (같은 NSOutlineView, 데이터소스 모드 분기)
  EditorWindowController — openFile(at:jumpingTo:) 확장
  EditorViewController   — jumpToMatch(query:ordinal:) 매치 선택·스크롤
Infrastructure Layer
  sidebar/FileSearcher.swift — Foundation만 import. 순수 검색 엔진.
```

- `SidebarViewController`는 `EditorViewController`를 직접 참조하지 않는다 — 기존 `openFile(at:)` 통로를 `jumpingTo:` 파라미터로 확장 (architecture.md §2 규칙 유지).
- `FileSearcher`는 AppKit/UI를 import하지 않는다.

### FileSearcher API

```swift
struct FileSearchHit {
    let lineNumber: Int        // 1-based
    let lineText: String       // 매치된 줄 원문 (스니펫 소스)
    let matchRangeInLine: Range<String.Index>
    let ordinalInFile: Int     // 파일 내 매치 순번 (0-based) — 점프용
}
struct FileSearchResult {
    let fileURL: URL
    let hits: [FileSearchHit]
}
final class FileSearcher {
    // 백그라운드 큐 실행. 새 호출 시 이전 검색 취소 (세대 토큰).
    // 완료 콜백은 메인 스레드.
    func search(query: String, in folders: [URL],
                completion: @escaping ([FileSearchResult], _ truncated: Bool) -> Void)
    func cancel()
}
```

- 매칭: 대소문자·발음 구별 부호 무시 (`.caseInsensitive, .diacriticInsensitive`), 단순 부분 문자열 (정규식 미지원 — YAGNI).
- 원문(.md 원시 텍스트)을 라인 단위 스캔. 마크다운 기호 제거 없이 매칭.

### 매치 점프 전략

원시 `.md` 오프셋은 WYSIWYG 변환(기호 제거) 후 에디터 오프셋과 달라 직접 매핑이 불가하다. **순번 매칭**을 쓴다:

1. `FileSearcher`가 파일 내 매치 순번(`ordinalInFile`)을 기록.
2. 문서 열린 후 `EditorViewController.jumpToMatch(query:ordinal:)`가 에디터의 plain string에서 같은 옵션(case/diacritic-insensitive)으로 n번째 occurrence를 찾아 `setSelectedRange` + `scrollRangeToVisible` + `showFindIndicator`.
3. 어긋나는 경우(검색어가 링크 URL 등 기호 내부에만 매치): n번째가 없으면 첫 occurrence로 폴백, 그것도 없으면 점프 생략. 허용 가능한 엣지.

### 성능·안전장치

- 검색은 전부 백그라운드 큐 — 키 입력 50ms 예산 불침범 (AC-08 유지).
- 250ms 타이핑 debounce, 새 입력 시 이전 스캔 취소.
- 2MB 초과 파일 스킵, 결과 500건 도달 시 중단 + truncated 플래그.
- 검색 중 파일 읽기 실패(삭제·권한)는 해당 파일만 건너뜀.

## 테스트

- `FileSearcherTests` — 임시 폴더 기반: 기본 매치, 한글, 대소문자 무시, 다중 파일, 순번 정확성, 2MB 스킵, 500건 절단, 빈 쿼리.
- 스니펫 강조 범위 계산은 순수 함수로 분리해 단위 테스트 (ReaderMetrics 패턴).
- A(NSTextFinder)는 시스템 위임이라 단위 테스트 대상 아님 — 수동 검증 체크리스트로 커버.

## 수동 검증 체크리스트

- [ ] ⌘F → 찾기 바 노출, 입력 시 하이라이트 + 매치 카운트
- [ ] ‹ › / ⌘G / ⇧⌘G 매치 간 이동
- [ ] 툴바 🔍 버튼 → 찾기 바 노출
- [ ] ⌥⌘F → 바꾸기 필드, 바꾼 텍스트 서식 유지 + Undo + ● 표시
- [ ] 읽기 모드 ⌘F 동작 (스크롤·페이징 모두)
- [ ] ⇧⌘F → 사이드바 표시 + 검색 필드 포커스
- [ ] 결과 클릭 → 문서 스왑 + 매치 위치 하이라이트 (미저장 시 시트)
- [ ] 검색어 삭제/Esc → 트리 복귀
- [ ] 결과 없음 / 폴더 없음 / 결과 초과 상태 표시

## 문서 갱신

- `docs/spec.md` — In-Scope에 검색 추가, SCREEN-05(전체 검색) + 상태 정의, AC-09(문서 내 검색)·AC-10(전체 검색) 추가, 릴리즈 기준 항목 추가.
- `docs/architecture.md` — 폴더 구조에 FileSearcher 추가, ADR-0007(NSTextFinder 채택 + 사이드바 통합 전체 검색 + 순번 점프) 기록.

## Out of Scope

- 정규식 검색, 전체 단어 검색 옵션
- 전체 검색에서의 일괄 바꾸기 (다중 파일 replace)
- 검색 히스토리
