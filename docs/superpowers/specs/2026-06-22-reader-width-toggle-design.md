# 읽기 모드 폭 토글 (모바일 | 책)

- 날짜: 2026-06-22
- 상태: 승인됨 → 구현

## 목적

읽기 모드 상단바에 `[ 모바일 | 책 ]` 세그먼트를 추가해, 본문 단(컬럼)의 가로폭을
두 프리셋 사이에서 토글한다. 긴 글을 모바일에서 읽는 것처럼 좁은 단으로 볼 수 있게 한다.

## 동작 (승인된 결정)

- **책** = 현재 동작 그대로. `readingLineLength`(기본 한글 35자) 기반 글자수 컬럼 폭.
- **모바일** = 고정 폭 `360pt`로 단을 좁힘. 윈도우·여백·폰트는 그대로, 본문 단만 가운데로 좁아진다.
- **모바일이 무엇을 바꾸는가**: 글 단(컬럼) 폭만. 앱 윈도우는 리사이즈하지 않는다.
- **기억 방식**: 저장하지 않는다. 읽기 모드 진입 시 항상 기본은 **책**. 모바일은 그 세션에서만 임시 적용되고 읽기 모드를 닫으면 초기화된다. → SettingsManager 변경 없음.
- 스크롤 모드·페이징 모드 양쪽 모두 적용된다 (폭 계산이 `columnWidthForCurrentSettings()` 한 곳으로 모여 있어 분기 한 번이면 양쪽이 따라온다).

## 왜 360pt 고정인가

"책"은 글자수 기반이라 폰트를 키우면 단도 같이 넓어진다. "모바일 화면 폭"이라는 의미는
물리적 화면 폭(폰트 크기와 무관)이므로 **고정 px**가 의미에 맞다. iPhone 본문 폭
(화면 ~390pt − 좌우 여백) 느낌으로 360pt(한글 약 23자). 빌드 후 미세조정 가능.

## 변경 파일 (기존 패턴 복제)

| 파일 | 변경 |
|---|---|
| `ReaderMetrics.swift` | `mobileColumnWidth: CGFloat = 360` 상수 |
| `ReaderViewController.swift` | `enum WidthMode { book, mobile }`, `widthMode`(기본 .book), `columnWidthForCurrentSettings()` 분기, `setWidthMode(_:)` + `currentWidthMode` |
| `ReaderToolbar.swift` | `itemWidth` 세그먼트(`[모바일, 책]`, `segmentItem` 헬퍼 재사용), 기본 선택 = 책 |
| `EditorWindowController.swift` | `@objc changeReaderWidth(_:)` + `responds(to:)` selector 등록 |
| `Localization.swift` | `reader.width` / `reader.widthMobile` / `reader.widthBook` 7개 언어 |

## 세그먼트 형태

라벨은 텍스트(`모바일`/`책`) — 나머지 reader 세그먼트가 모두 텍스트라 일관성 유지.

## 비고

- 폰트 배율 상호작용: 책=글자수 기반(폰트 키우면 단도 넓어짐), 모바일=고정 px(폰트만 커지고 단 폭 유지). 의도대로.
- 회귀 방지: `ReaderMetricsTests`에 "모바일 폭 < 35자 책 폭" 불변식 1건 추가.
