<div align="center">

<img src="icon-1024.png" width="128" alt="JenaNote 아이콘" />

# JenaNote

**마크다운 문법을 몰라도 쓸 수 있는 macOS용 WYSIWYG 마크다운 메모 앱**

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.7](https://img.shields.io/badge/Swift-5.7-orange?logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/jenalab-com/jena-note)](https://github.com/jenalab-com/jena-note/releases/latest)

[다운로드](#설치) · [기능](#주요-기능) · [소스에서 빌드](#소스에서-빌드) · [단축키](#단축키)

</div>

---

## 왜 JenaNote인가

macOS 기본 메모앱(텍스트 편집기, Notes)은 서식을 `.md`로 저장하지 못하고, 전용 마크다운 에디터(Typora, Obsidian)는 기능이 과하거나 `**`, `#` 같은 기호가 화면에 그대로 노출됩니다.

**JenaNote는 그 사이를 메웁니다.** 마크다운 기호를 화면에 드러내지 않고 서식이 적용된 모습 그대로 편집하되(WYSIWYG), 파일은 어디서나 열리는 표준 CommonMark `.md`로 저장합니다. 마크다운을 모르는 사람도 도움말 없이 서식 있는 문서를 만들어 `.md`로 공유할 수 있습니다.

## 주요 기능

- **WYSIWYG 마크다운 편집** — 편집 중 `**`·`#`·`>` 같은 기호 없이 서식이 적용된 상태로 보입니다. 저장하면 표준 `.md`.
- **서식 툴바** — 굵게, 기울임, 제목(H1~H3), 순서 있는/없는 목록, 코드, 인용, 링크.
- **사이드바 폴더 브라우저** — 폴더를 등록하면 `.md` 파일 트리를 재귀로 표시. 클릭하면 현재 창에서 인-플레이스로 문서 교체, FSEvents 기반 실시간 갱신(외부 추가·삭제·이름변경 자동 반영), 등록 폴더는 재시작 후에도 복원.
- **읽기 모드 & 읽기 폭 토글** — 편집을 잠시 멈추고 읽기에 집중. 모바일/책 프리셋으로 본문 폭 조절.
- **상태바 글자수 카운터** — 창 하단에서 실시간 글자수 확인.
- **docx·hwpx 내보내기** — 노트를 Word(`.docx`)·한글(`.hwpx`)로 내보냅니다. 외부 도구·라이브러리 의존성 0, 순수 Swift로 zip+XML을 직접 생성. (원본 `.md`는 건드리지 않는 단방향 내보내기)
- **줄 간격·글자 색상** 조절, 표준 macOS 단축키와 미저장 변경 경고.

## 설치

[최신 릴리스](https://github.com/jenalab-com/jena-note/releases/latest)에서 `JenaNote-x.y.z.dmg`를 내려받아, 열린 창에서 앱을 **Applications** 폴더로 드래그하세요. (macOS 13 Ventura 이상)

### ⚠️ 처음 실행할 때 — "확인되지 않은 개발자" / "손상되었기 때문에 열 수 없습니다"

JenaNote는 Apple Developer 서명·공증을 거치지 않은 무료 앱입니다. 그래서 처음 열 때 macOS Gatekeeper가 막습니다. **앱이 손상된 것이 아니니** 아래 방법 중 하나로 열어주세요.

**방법 1 — 터미널 (가장 확실, 모든 macOS 버전)**

```bash
xattr -dr com.apple.quarantine /Applications/JenaNote.app
```

실행한 뒤 평소처럼 더블클릭하면 열립니다.

**방법 2 — 시스템 설정 (macOS 15 Sequoia 이상)**

앱을 한 번 더블클릭 → 차단 메시지가 뜨면 → **시스템 설정 > 개인정보 보호 및 보안** 으로 이동 → 맨 아래 "JenaNote을(를) 열도록 허용" 옆 **"확인 없이 열기"** 클릭 → 다시 열기.

**방법 3 — 우클릭 열기 (macOS 13~14)**

Finder에서 앱을 **우클릭(또는 Control+클릭) → 열기 → 열기**.

> 한 번만 통과시키면 이후로는 평범하게 더블클릭으로 열립니다.

## 소스에서 빌드

Swift 5.7+ 툴체인(Xcode 또는 Command Line Tools)이 필요합니다.

```bash
git clone https://github.com/jenalab-com/jena-note.git
cd jena-note

make build     # .build/JenaNote.app 빌드
make run       # 빌드 후 즉시 실행
make install   # ~/Applications 에 설치
make dmg       # 배포용 .dmg 생성
make test      # 테스트 실행
make clean     # 빌드 산출물 삭제
```

직접 빌드한 앱은 quarantine 속성이 붙지 않으므로 위의 Gatekeeper 안내가 필요 없습니다.

## 단축키

| 동작 | 단축키 |
| --- | --- |
| 저장 | ⌘S |
| 다른 이름으로 저장 | ⇧⌘S |
| 굵게 | ⌘B |
| 기울임 | ⌘I |
| 링크 | ⌘K |
| 폴더 추가 | ⇧⌘O |
| 사이드바 토글 | ⌥⌘S |
| 실행 취소 / 다시 실행 | ⌘Z / ⇧⌘Z |

## 파일 포맷

- **저장 포맷**: UTF-8 인코딩 CommonMark 호환 `.md` — VSCode·GitHub 등 다른 뷰어에서 동일하게 렌더링됩니다.
- **내부 표현**: `NSAttributedString` ↔ Markdown 직렬화(저장 시)·역직렬화(열기 시).
- **내보내기**: `.docx`(OOXML)·`.hwpx`(OWPML)는 단방향. 원본 `.md`는 변경하지 않습니다.

## 프로젝트 구조

```
Sources/
  JenaNote/         실행 진입점 (main.swift)
  JenaNoteKit/
    app/            AppDelegate, 설정, 도움말, 로컬라이제이션
    document/       Markdown 직렬화/역직렬화, 신택스 하이라이트
    editor/         편집기 뷰·윈도우 컨트롤러, 서식 명령, 읽기 모드
    sidebar/        폴더 북마크, FSEvents 감시, 아웃라인 뷰
    statusbar/      하단 상태바 (글자수)
    toolbar/        서식 툴바, 읽기 툴바
    export/         docx·hwpx Writer, 문서 IR, zip/XML 직접 생성
Tests/              JenaNoteKit 단위 테스트
docs/               spec, architecture, 개발 로그(devlog)
```

자세한 기획·설계는 [`docs/spec.md`](docs/spec.md)와 [`docs/architecture.md`](docs/architecture.md), 버전별 변경 내역은 [`docs/devlog/`](docs/devlog/)를 참고하세요.

## 라이선스

[MIT](LICENSE) © 2026 JenaLab
