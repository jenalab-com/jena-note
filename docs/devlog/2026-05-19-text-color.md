# 글자 색상 변경 기능 추가

| | |
| --- | --- |
| 일자 | 2026-05-19 |
| 사용자 요구 | 툴바에서 글자 색상을 변경할 수 있게 해달라 |
| 영향 파일 | `Sources/document/MarkdownSerializer.swift` · `Sources/editor/FormatCommands.swift` · `Sources/editor/EditorViewController.swift` · `Sources/toolbar/FormatToolbar.swift` · `Sources/app/AppDelegate.swift` · `Sources/app/Localization.swift` |

## 핵심 결정 — 색상을 어떻게 `.md`에 저장할 것인가

CommonMark는 색상 표기를 표준화하지 않는다. 선택지:

| 방안 | 채택 | 사유 |
| --- | --- | --- |
| 편집기 전용 (저장 안 함) | ✘ | WYSIWYG에서 저장 후 색이 사라지면 사용자 신뢰가 깨짐 |
| **HTML `<span style="color: #...">`** | ✅ | GitHub/VS Code/Obsidian 등 다수의 마크다운 렌더러가 지원. 마크다운 + HTML 혼합은 표준 관행 |
| 커스텀 확장 문법 (예: `{color:red}text{}`) | ✘ | 다른 도구와의 호환성 0. round-trip 깨짐 |

**트레이드오프**: 일부 미니멀 렌더러에서는 `<span>` 태그가 그대로 노출될 수 있음. 사용자 가치(저장 유지) > 외부 렌더러 폴리스(허용) 판단으로 HTML span 채택.

## 변경 사항

### 1. 모델 (속성 키)
`MarkdownSerializer.swift`:
- `NSAttributedString.Key.mdCustomColor: Bool` 신설 — **사용자가 명시적으로 지정한 색**만 직렬화 대상으로 표시. `NSColor.labelColor`/`secondaryLabelColor`/`linkColor` 등 **구조적 기본색은 span으로 토해내지 않는다**. NSColor 동등 비교(색공간 변환 함정)를 회피하기 위한 플래그.
- `enum MarkdownColor`:
  - `toHex(_:) -> "#RRGGBB"` — sRGB로 정규화 후 8비트 변환, 알파 무시
  - `fromHex(_:) -> NSColor?` — `#RGB`/`#RRGGBB` 둘 다 인식

### 2. 직렬화 (`serializeInline`)
래퍼 순서: 가장 안쪽부터 `text` → `bold/italic` → `[link](url)` → **`<span style="color: …">`(가장 바깥)**.
- 색상이 가장 바깥인 이유: 파싱 시 색상을 먼저 추출하고 내부를 **재귀 파싱**하면 색상 + 굵게/링크 등의 중첩이 자연스럽게 보존됨.
- 기존 if-else 체인을 점진적 래퍼로 재구성하면서 **부수적 개선** — 굵은 링크(`[**text**](url)`)가 이제 양쪽 모두 보존됨 (이전엔 bold가 link를 짓밟았음). §0.3 외과적 변경 한도 내의 작은 부수효과로 수용.

### 3. 파싱 (`parseInline`)
- 새로운 분기: `<span ` 접두어를 가장 먼저 검사 → `parseColorSpan(in:baseFont:)` 호출
- `parseColorSpan`:
  - `<span ...>` 여는 태그에서 `color: #...`를 추출 (작은/큰따옴표 허용)
  - hex 토큰을 alphanumeric으로 스캔 → `MarkdownColor.fromHex`
  - 본문은 **`parseInline`을 재귀 호출**하여 굵게/기울임/링크 등이 내부에 있어도 정상 파싱
  - 결과 전체 범위에 `.foregroundColor` + `.mdCustomColor=true` 부여 (round-trip 보장)

### 4. UI
- `FormatCommands.applyTextColor(_:color:)` 신설 — 선택 범위에 색 + 플래그 적용. labelColor와 같으면 사용자 색상 해제(구조적 기본색 복원).
- `EditorViewController`:
  - `@objc changeTextColor(_:)` — 툴바 NSColorWell의 액션 핸들러
  - `@objc showColorPanel(_:)` — 메뉴 > 서식 > 글자 색… 진입점. NSColorPanel을 띄우고 색 변경 시 적용.
  - `responds(to:)` 오버라이드에 두 셀렉터 등록
- `FormatToolbar`:
  - 새 아이템 `itemColor` — NSColorWell, 폭 32 / 높이 22, 링크/HR 다음에 배치
  - `well.target = target` — segmented control과 동일한 처방. NSColorWell도 NSToolbarItem.view로 들어가면 책임 체인 디스패치가 미덥지 못함 (직전 devlog의 line-spacing 버그와 동일 원리).

### 5. 메뉴 & i18n
- File > Format에 구분선 후 "글자 색…" 추가 (단축키 없음)
- L10n 한국어/영어 키 추가: `toolbar.textColor`, `menu.format.textColor`

## 검증

- `make clean && make build` — 워닝 0, 에러 0
- `open .build/JenaNote.app` — 정상 기동, 즉시 크래시 없음
- 사용자 GUI 검증 필요 항목:
  1. 텍스트 선택 → 툴바 NSColorWell 클릭 → 색 변경 시 선택 텍스트 즉시 색 적용
  2. 저장 → 파일 내용에 `<span style="color: #RRGGBB">…</span>` 포함
  3. 같은 파일 다시 열기 → 색상 유지
  4. 메뉴 > 서식 > 글자 색… → 패널에서 색 변경 → 적용

## 알려진 한계 / 후속 가능 항목

- 배경(하이라이트) 색상은 미구현 — 필요 시 `<mark>` 또는 `<span style="background-color: …">`로 별도 추가
- 명명색(`red`, `blue` 등 CSS 색 이름)은 파싱 미지원. 현재는 hex만. 다른 마크다운 도구에서 명명색으로 작성된 문서를 열면 색이 누락됨
- 굵게/기울임처럼 툴바 상태(현재 커서 위치의 색)는 NSColorWell에 반영되지 않음 — `updateToolbarState`에 색상 동기화 로직 추가 검토 가능 (지금은 §0.3 외과적 변경에 머무름)
- 인라인 코드(\`text\`) 내부에 색상을 지정하면 `<span style="color: …">\`text\`</span>`로 저장됨. 일부 렌더러에서 코드 스타일이 우선하여 색이 무시될 수 있음 — 허용 가능한 트레이드오프

## 트레이드오프 요약

- **선택**: HTML span 영속화 / 사용자 플래그 기반 직렬화 / 색상을 최외곽 래퍼로
- **이유**: round-trip 무손실 + 외부 렌더러 호환 + NSColor 동등 비교의 함정 회피
