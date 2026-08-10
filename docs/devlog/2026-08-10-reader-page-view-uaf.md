# 2026-08-10 — 페이징 리더 use-after-free 크래시 수정

## 증상

v1.5.0, macOS 26.5.2. 페이징 읽기 모드로 한동안 읽다가 창 안 다른 곳을 클릭하는 순간
SIGSEGV (`EXC_BAD_ACCESS`, `KERN_INVALID_ADDRESS`). 간헐 재현 — 이번 사례는 앱 기동
1시간 13분 뒤에 발생했다.

```
0  objc_msgSend                                  ← 셀렉터 enclosingScrollView, isa 가 쓰레기값
1  -[NSTextView updateRuler]
2  -[NSTextView(NSSharing) resignFirstResponder]
3  -[NSWindow _realMakeFirstResponder:]
4  -[NSWindow _handleMouseDownEvent:isDelayedEvent:]
```

7/14 사건(`2026-07-18-error.md`)과는 별건이다 — 그쪽은 외장 볼륨의 실행 파일 페이지가
날아간 Instruction Abort, 이쪽은 코드 버그.

## 원인

레지스터가 결정적 단서였다. resign 중이던 텍스트 뷰(x19 = `0xbf59ba400`)와 크래시 수신자
(x0 = `0xbf59ba800`)가 1KB 차이의 **서로 다른 객체** — 즉 살아 있는 페이지 뷰가 ruler 갱신
중 **이미 해제된 형제 페이지 뷰**를 메시징했다.

ReaderViewController 의 페이징 조판은 NSLayoutManager 하나에 페이지 수만큼
NSTextContainer 를 달아두는 구조인데, 화면에 얹힌 쪽의 PageTextView 만 살아 있고
`showCurrentSpread()` 가 페이지를 넘길 때마다 직전 쪽 뷰를 즉시 해제했다. 문제는
NSTextContainer 의 `textView` 역참조가 zeroing weak 이 아니라는 것 — 뷰만 죽고 컨테이너가
LM 에 남으면, 포커스 이탈 시 `resignFirstResponder → updateRuler` 가 LM 을 공유하는 뷰들을
훑다가(`firstTextView` 경로) 죽은 뷰의 댕글링 포인터를 그대로 메시징한다. 해제된 메모리가
재사용된 시점에만 터지므로 간헐적이었다.

`rebuildPages()` 에도 같은 결의 함정이 하나 더 있었다: 새 storage·LM·컨테이너로 갈아끼운 뒤
`showCurrentSpread()` 가 옛 뷰를 치울 때까지, 옛 페이지 뷰들이 죽은 네트워크를 물고 남는
구간이 존재했다.

## 수정

`tearDownPageViews()` 헬퍼를 만들어 페이지 뷰를 버리는 세 경로
(`showCurrentSpread`·`rebuildPages`·`removePagedOverlay`)가 모두 이 순서를 타게 했다.

1. 리더가 포커스를 쥐고 있으면 `makeFirstResponder(self)` 로 먼저 회수 —
   resign 이 모든 객체가 살아 있는 시점에 일어난다.
2. 각 뷰를 `removeFromSuperview()` 한 뒤 `textContainer?.textView = nil` 로 역참조를 절단 —
   LM 에 `textContainerChangedTextView:` 가 전파되어 `firstTextView` 캐시도 무효화된다.
3. `rebuildPages()` 는 조판 네트워크를 교체하기 **전에** 이를 수행한다.

## 검증

- `swift build` 통과, `swift test` 153개 전부 통과.
- 재현 조건이 간헐적이라 결정적 확인은 ASan(또는 NSZombie)으로
  "페이지 넘김 → 사이드바 클릭" 시나리오를 돌려보는 것 — 수정 전엔 이 경로에서
  댕글링 메시징이 발생한다.
