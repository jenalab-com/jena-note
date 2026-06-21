# 읽기 모드 구현

| | |
| --- | --- |
| 일자 | 2026-06-21 |
| 사용자 요구 | 편집기 옆에 책처럼 읽기 전용 뷰를 열어달라 — 35자 컬럼, 페이지 넘김, 폰트 배율, ⌘⇧R 토글 |
| 영향 파일 | `Sources/JenaNoteKit/editor/ReaderViewController.swift` · `Sources/JenaNoteKit/editor/ReaderMetrics.swift` · `Sources/JenaNoteKit/toolbar/ReaderToolbar.swift` · `Sources/JenaNoteKit/editor/EditorWindowController.swift` · `Sources/JenaNoteKit/app/SettingsManager.swift` · `Sources/JenaNoteKit/app/Localization.swift` · `docs/architecture.md` · `Package.swift` · `Makefile` |

## 핵심 결정

### 1. 별도 ReaderViewController — 창 신설 대신 split 우측 item 스왑

읽기 모드를 새 창으로 여는 대신 `EditorWindowController`가 관리하는 `NSSplitViewController`의 **우측 item을 `ReaderViewController`로 교체**하는 방식을 선택했다.

| 방안 | 채택 | 사유 |
| --- | --- | --- |
| 새 창 열기 | ✘ | 사이드바·툴바·문서 스왑(ADR-0004) 재사용 불가. 창 동기화 복잡 |
| **split 우측 item 스왑** | ✅ | 기존 창 인프라 재사용, 편집 ↔ 읽기 토글이 자연스러움, 문서 SSOT가 변하지 않음 |
| EditorViewController 내부 전환 | ✘ | 텍스트뷰를 읽기 전용으로 재설정하는 경우 undo 스택 오염 위험 |

`ReaderViewController`는 `document.content`를 **복사본**(`ReaderMetrics.scaled`)으로만 표시하며, 원본 NSAttributedString을 절대 수정하지 않는다.

### 2. 세로 구간 점프식 가로 페이지네이션

실제 조판 페이지 분할(`NSLayoutManager` 물리적 페이지) 대신, **뷰 높이를 줄 높이 정수배로 끊어 scroll offset을 점프**시키는 방식으로 "페이지 넘김" UX를 근사했다.

- `ReaderMetrics.snappedPageHeight(viewHeight:lineHeight:)` — 줄 높이 정수배 중 viewHeight 이하 최대값
- `scrollToCurrentPage()` — `currentPage × pageHeight`로 `contentView.scroll(to:)` 호출
- 페이지 이동 후 `.readerPageChanged` 알림 → 하단 `‹ N / M ›` 인디케이터 갱신

이 방식은 진짜 조판 페이지네이션(고아/미망인 제어, 가변 줄 수)을 지원하지 않아 페이지 바닥에 빈 여백이 생길 수 있다. 그러나 NSTextView 레이아웃을 물리적으로 분할하는 것보다 훨씬 가볍고 안정적이며, 전자책 UX의 핵심 가치(읽기 흐름 유지, 페이지 감각)는 충분히 전달된다.

### 3. SPM 도입 — swiftc 직접 컴파일에서 Swift Package Manager로 전환

`ReaderMetrics`의 순수 함수(`columnWidth`, `snappedPageHeight`, `scaled`)를 단위 테스트하기 위해 **SPM 패키지 구조**를 도입했다.

- `Sources/JenaNote` — `@main` 진입점
- `Sources/JenaNoteKit` — 기능 모듈 (라이브러리 타겟)
- `Tests/JenaNoteKitTests` — 단위 테스트 (11개)

`Makefile`은 `swift build`, `swift test`, `.app` 번들 구성을 래핑하므로 기존 `make build / make run / make test` 워크플로가 그대로 유지된다.

## 트레이드오프

| 결정 | 이점 | 한계 |
| --- | --- | --- |
| split 스왑 방식 | 창 동기화 없음, 기존 인프라 재사용 | 읽기 모드에서 사이드바 폭 조절이 여전히 노출됨 |
| 세로 구간 점프 페이징 | 구현 단순, 레이아웃 엔진 부담 없음 | 페이지 바닥 빈 여백 가능, 고아/미망인 미제어 |
| SPM 도입 | 순수 함수 단위 테스트 가능 | swiftc 직접 빌드보다 빌드 그래프 복잡도 소폭 증가 |

## 수동 e2e 확인 항목

1. `⌘⇧R` — 읽기 모드 진입/탈출 토글
2. 읽기 툴바 "스크롤 / 페이지" 세그먼트 전환 → 세로 스크롤러 표시/숨김 확인
3. 페이징 모드에서 `←` / `→` 키로 페이지 이동 → 하단 `‹ N / M ›` 갱신 확인
4. 스크롤 모드에서 페이지 인디케이터 숨김 확인
5. 읽기 툴바 "글자 작게 / 글자 크게" → 컬럼 폭 재계산 확인
6. 설정에서 언어 변경 후 읽기 모드 진입 → 툴바 라벨 번역 확인 (zh/ja/es/de/fr)
7. 사이드바에서 다른 파일 클릭 → 읽기 뷰 내용 교체 확인 (원본 불변)

## 다음 후보

- **진짜 페이지네이션**: `NSLayoutManager.characterRange(forGlyphRange:actualCharacterRange:)`를 이용해 줄 수 기반 정확한 페이지 분할 구현
- **줄 길이 설정 UI**: 현재 `SettingsManager.readingLineLength`는 코드 상수(35자). 설정 화면에 슬라이더 추가 검토
- **가로 슬라이드 애니메이션**: 페이지 넘김 시 `NSAnimationContext`로 슬라이드 트랜지션 추가
