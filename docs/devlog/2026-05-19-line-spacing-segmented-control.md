# 줄간격 세그먼트 컨트롤 동작 불가 수정

| | |
| --- | --- |
| 일자 | 2026-05-19 |
| 영향 파일 | `Sources/toolbar/FormatToolbar.swift` |
| 영향 범위 | 툴바 우측 `1× · 1.5× · 2×` 세그먼트의 클릭 응답 |

## 증상

툴바의 줄간격 세그먼트 컨트롤(1×/1.5×/2×)을 눌러도 아무 변화가 없음. 굵게·기울임 등 다른 서식 버튼은 정상 동작.

## 원인 분석

`Sources/toolbar/FormatToolbar.swift`의 `makeLineSpacingItem`에서 NSSegmentedControl을 다음과 같이 구성하고 있었음:

```swift
seg.action = #selector(EditorViewController.changeLineSpacing(_:))
seg.target = nil   // ← 책임 체인으로 디스패치 의도
```

다른 버튼들은 모두 NSButton 기반이고 `button.target = nil` + `button.action = ...` 패턴으로 동작한다. NSButton은 `target = nil`일 때 `NSApp.sendAction(_:to:from:)`이 first responder부터 책임 체인을 거슬러 올라가며 액션을 디스패치하는데, EditorViewController가 체인에 있으므로 도달한다.

NSSegmentedControl도 같은 NSControl 자손이므로 이론상 동일해야 하지만, **NSToolbarItem.view로 들어간 NSSegmentedControl은 `target = nil`일 때 책임 체인을 신뢰성 있게 거치지 않는 거동**이 macOS에서 알려져 있다 (NSButton과는 디스패치 경로가 미묘하게 다름). 결과적으로 `changeLineSpacing(_:)`는 호출조차 되지 않음 — `applyLineSpacing` 내부 로직과는 무관한 문제.

증거:
- 같은 책임 체인을 쓰는 Bold/Italic/H1/H2/H3/UL/OL/Quote 버튼은 모두 정상.
- 차이점은 view의 클래스(NSButton ↔ NSSegmentedControl)뿐.
- `EditorViewController.changeLineSpacing(_:)` 내부 로직(`mutable.lineHeightMultiple = multiplier` 등)은 변경 없이도 호출만 들어가면 정상 작동.

## 수정 내용

`FormatToolbar.target`(`weak var target: AnyObject?`, `EditorWindowController.setupToolbar`에서 `editorVC`로 설정됨)을 세그먼트의 명시적 target으로 연결하여 책임 체인을 우회.

```swift
// before
seg.target = nil

// after
seg.target = target   // FormatToolbar.target == editorVC
```

부가 정리:
- `item.label = "줄 간격"` 하드코딩을 `L10n.tr("toolbar.lineSpacing")`로 통일 — 다른 항목과의 일관성. Boy Scout Rule (§2) 범위 내 단일 정리.
- macOS 12에서 deprecated된 `item.minSize`/`item.maxSize` 대신 segmented control에 width/height 제약을 직접 부여.

## 검증

- `make clean && make build` — 워닝 0, 에러 0.
- `open .build/JenaNote.app` — 정상 기동, 즉시 크래시 없음.
- GUI 상호작용은 직접 확인 불가 — 사용자가 1.5×/2× 클릭 시 줄 높이가 1.5/2배로 변하는지 확인 필요.

## 트레이드오프

- **선택**: segmented control을 책임 체인 대신 명시적 target에 묶음. 다른 버튼들도 일관성 차원에서 명시적 target으로 바꾸는 안도 검토했으나 §0.3(외과적 변경)에 따라 **고장 난 것만** 손봄.
- **이유**: 책임 체인 디스패치는 NSButton에서는 안정적이고 NSToolbarItem 검증·키 이벤트 처리 등에서 더 자연스럽다. 동작하는 패턴을 무더기로 바꿀 이유 없음.

## 후속 (필요 시)

- 만약 명시적 target 후에도 시각적 변화가 미미하다면 `applyLineSpacing`을 `lineHeightMultiple`과 `lineSpacing` 양쪽을 함께 설정하도록 강화. 현재는 `lineHeightMultiple`만 사용 — body/heading/list 단락 스타일은 min/max line height가 0이므로 multiplier가 정상적으로 작용해야 함.
- 사용자 확인 후 미진하면 별도 이슈로 분리.
