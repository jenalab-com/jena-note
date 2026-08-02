# 읽기 모드에서 편집 — '읽기 조판' 토글로 통합

- 날짜: 2026-08-01
- 상태: 승인됨 → 1단계 구현 완료

## 목적

읽기 모드를 읽기 전용에서 풀어, 읽던 화면에서 그대로 고치고 쓸 수 있게 한다.
별도 화면을 하나 더 만드는 대신 **에디터가 읽기 조판을 입는 방식**으로 통합한다.

## 동작 (승인된 결정)

- **⌘⇧R = 읽기 조판 토글.** 우측 페인을 갈아끼우지 않는다. 에디터가 명조·큰 글씨·넓은
  행간·좁은 단을 입을 뿐이며, 편집·서식 툴바·단축키·이미지·저장·찾기는 그대로 살아있다.
- **스크롤 조판에서만 편집.** 페이징 조판은 읽기 전용을 유지하고, 거기서 글자를 치면
  스크롤 조판으로 갈아타 그 자리에 커서를 둔다(방아쇠가 된 키 입력도 이어서 반영).
- **명조는 볼드 되는 서체로 폴백.** 아래 "데이터 안전" 참조.

## 왜 리더에 편집을 다는 대신 에디터에 조판을 입혔나

편집 기능(서식 툴바·단축키·이미지 첨부·저장·찾기)은 전부 `EditorViewController` 와
`FormatCommands` 에 묶여 있다. 리더에 편집을 달면 이 배선을 통째로 한 벌 더 깔고
두 벌을 영원히 같이 고쳐야 한다. 반대 방향은 조판 코드(`ReaderMetrics`)만 재사용하면
되고, 편집 기능은 손대지 않아도 이미 다 있다.

## 데이터 안전 — 이 설계의 급소

읽기 조판이 편집 가능해지면서 조판된 텍스트가 **저장 경로를 타게 됐다.** 조판이 서식
정보를 한 글자라도 먹으면 파일이 실제로 망가진다. 세 겹으로 막는다.

**1) 문서에는 언제나 원본 스타일로 넘긴다.**
`EditorViewController.textDidChange` 가 조판을 벗겨(`ReaderMetrics.unstyled`) 문서에
넘긴다. 조판을 켜고 끄는 것만으로는 문서가 더러워지지도(dirty), 저장 결과가 달라지지도
않는다. 읽기 전용이던 시절의 계약(원본 불변)을 편집 가능해진 뒤에도 지키는 방식이다.

**2) 조판이 원본 폰트를 백업한다.**
`styled()` 가 폰트를 갈아끼울 때 원본을 `.mdBaseFont`(문단 스타일은 `.mdBaseParagraph`)에
남긴다. 되돌릴 때 추측이 필요 없고, 이미 조판된 텍스트를 다시 조판해도 배율이 누적되지
않는다. 조판이 켜진 채 새로 입력돼 백업이 없는 구간은 `.mdBlockType`(h1/h2/h3/codeblock/…)
에서 기준 폰트를 다시 세우고 사용자가 준 볼드·이탤릭만 얹는다.

**3) 명조 볼드 폴백 — 실측으로 드러난 진짜 위험.**

```
AppleMyungjo  →bold: AppleMyungjo (그대로)  hasBoldTrait=false  ✗
NanumMyeongjo →bold: NanumMyeongjoBold                          ✓
시스템 고딕    →bold: AppleSDGothicNeo-Bold                      ✓
```

`AppleMyungjo` 에는 볼드·이탤릭 변형이 없어 `NSFontManager` 가 원본을 그대로 돌려준다.
마크다운 직렬화는 볼드·이탤릭을 **폰트 trait 으로 판정**하므로(`MarkdownSerializer`
:380-383), 명조 조판된 텍스트가 저장되면 `**볼드**` 마크업이 파일에서 사라진다.
읽기 전용이던 때는 화면만 밋밋해지는 표시 버그였지만, 편집이 열리면 데이터 손실이다.

→ `readerFont()` 가 변형 있는 명조(`NanumMyeongjo`)를 먼저 찾고, 그래도 trait 이 붙지
않으면 **서체 일관성보다 서식 보존을 우선해** 시스템 폰트로 내려간다.

## 읽던 자리의 주인이 둘이 됐다

스크롤 조판은 에디터가, 페이징 조판은 리더 오버레이가 화면을 그린다. 이어읽기·책갈피는
어느 쪽이 화면을 쥐고 있든 같은 방식으로 물어봐야 하므로 `ReadingPositionProviding`
프로토콜로 통일하고, 윈도우 컨트롤러는 `positionProvider`(페이징이면 리더, 아니면 에디터)
하나만 본다. 스크롤 위치 계산은 `ScrollReadingPosition` 으로 뽑아 양쪽이 공유한다.

## 변경 파일

| 파일 | 변경 |
|---|---|
| `ReaderMetrics.swift` | 명조 폴백(`serifCandidates`/`serifFont`/`applying`), `.mdBaseFont` 백업, `unstyled()`/`originalFont()`, `WidthMode` 및 컬럼 폭 계산 이관 |
| `MarkdownSerializer.swift` | `.mdBaseFont`/`.mdBaseParagraph` 키 (직렬화에는 쓰이지 않음) |
| `ReadingPosition.swift` | 신규 — `ReadingPositionProviding` 프로토콜, `ScrollReadingPosition` 순수 계산 |
| `EditorViewController.swift` | 읽기 조판 적용·해제, 컬럼 inset, 타이핑 속성 동기화, 읽기 위치 API, `placeCursor(at:)` |
| `EditorWindowController.swift` | ⌘⇧R 을 pane swap → 조판 토글로, `positionProvider` 추상화, 페이징 오버레이 설치·해제, 타이핑 시 스크롤 전환 |
| `ReaderViewController.swift` | 페이징 전용으로 역할 축소, `onEditRequested`, 스크롤 계산 공유 |
| `ReaderToolbar.swift` | `updatePageModeSelection` (코드가 조판을 바꿨을 때 세그먼트 동기화) |
| `EditorTextView.swift` | `defaultContainerInset` 상수 |

## 회귀 테스트 (`ReaderLayoutRoundTripTests`, 13건)

- 조판 입혔다 벗기면 **직렬화 결과가 원본과 동일** (명조·고딕 양쪽)
- 조판된 채 직렬화해도 `**볼드**` 가 살아남음 — 조판 해제를 잊은 경로의 안전망
- 폰트 왕복 복원(이름·크기 전 구간 일치), 백업 속성이 문서에 남지 않음
- 재조판 시 배율 누적 없음
- 조판 중 새로 입력된(백업 없는) 구간의 폰트·볼드 복원
- 모든 서체 조합에서 볼드·이탤릭 trait 보존

## 남은 단계

- **2단계**: 툴바 정리 — 조판 ON 상태에서 서식 항목과 읽기 항목을 한 툴바에 어떻게 담을지.
  현재는 읽기 툴바만 붙고 서식은 메뉴·단축키로 쓴다.
- **3단계**: 페이징 조판에서의 직접 편집(디바운스 재분할 + 커서 추적). 이번 범위에서
  의도적으로 제외했다 — 버그 위험이 가장 큰 지대다.

## 비고

- 조판 토글은 `SettingsManager` 를 단일 원본으로 쓰고, 지금 화면을 쥔 쪽만 다시 그린다.
- 단 폭(`WidthMode`)은 조판이 아니라 여백만 바꾸므로 다시 칠하지 않고 inset 만 갱신한다.
