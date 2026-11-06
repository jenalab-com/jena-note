# jena-note for Windows

macOS와 공유하는 코드는 `shared/JenaNoteCore`에 있고, 이 폴더에는 Windows 전용 코드를 둔다. 앱은 WPF에 WebView2 편집기를 올린 구조다.

## 필요한 도구

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
winget install --id Kitware.CMake
winget install --id Microsoft.DotNet.SDK.9
winget install --id Swift.Toolchain
```

Git for Windows도 필요하다. 테스트가 그 안의 `unzip.exe`를 쓰고, 모델 다운로드 스크립트가 Git Bash에서 돈다.

## 빌드와 테스트

저장소 루트에서 실행한다. Windows에서는 `Package.swift`가 공유 라이브러리와 `windows/`의 타깃만 노출하므로 AppKit 코드는 빌드 대상이 아니다.

```powershell
bash Vendor/Kiwi/scripts/fetch-kiwi-model.sh   # 처음 한 번. 약 84MB 다운로드
.\windows\scripts\build-kiwi.ps1               # 처음 한 번, 또는 Kiwi 소스가 바뀌었을 때
.\windows\scripts\test-core.ps1                # 공유 라이브러리 테스트
.\windows\scripts\build-app.ps1                # 앱 빌드
.\windows\scripts\test-app.ps1                 # 앱 자체 테스트. 창이 잠깐 뜬다
.\windows\scripts\test-keyboard.ps1            # 실제 키 입력 테스트. 도는 동안 키보드를 쓰지 않는다
```

앱은 `windows\JenaNote\bin\Release\net9.0-windows\JenaNote.exe`에 만들어진다. 그 폴더만 있으면 실행된다. Kiwi 모델이 들어 있어 약 175MB다. WebView2 런타임은 Windows 11에 기본으로 들어 있다.

## 구조

```
JenaNote.exe (WPF, C#)     창, 메뉴, 파일 열기와 저장
  ├ editor/ (WebView2)     편집기 화면. 문서를 블록 목록으로 받고 돌려준다
  └ JenaNoteBridge.dll     windows/bridge의 C ABI
      └ JenaNoteCore       shared/. .md 변환, 번역, 맞춤법, 내보내기
```

- **문서 흐름:** `.md` 텍스트 ↔ `JenaNoteCore`의 JSON 블록 목록 ↔ 편집기 DOM. 같은 변환 코드를 맥과 공유하므로 저장 결과가 같다.
- **편집기:** 프레임워크 없는 `contenteditable`이다. 줄마다 블록 요소 하나를 두어 Enter와 실행 취소를 브라우저에 맡긴다.
- **보안:** 문서 내용은 DOM 속성으로만 넣는다. CSP가 외부 통신과 인라인 스크립트를 막고, 페이지는 편집기 밖으로 이동하지 못한다. 붙여넣기는 일반 텍스트만 받는다. 문서가 가리키는 파일은 이미지 확장자만 읽을 수 있고, 링크는 Ctrl+클릭으로 http, https, mailto만 연다.

## 구현 현황

| 기능 | 상태 |
|---|---|
| 문서 열기, 저장, 다른 이름으로 저장, 닫을 때 저장 확인 | 완료 |
| `.md`와 `.txt`, UTF-8 검사, 줄바꿈 정규화 | 완료 |
| 굵게, 기울임, 코드, 제목, 목록, 인용, 코드 블록, 구분선, 링크, 글자 색 | 완료 |
| 표와 주석, 이미지 표시와 글 편집 | 완료 |
| 표와 주석, 이미지의 새로 넣기 | 예정 |
| 자동 저장, 저장 시 백업, 버전 이력(비교, 이름 붙이기, 복원) | 완료 |
| 비정상 종료 복구, 다른 프로그램이 바꾼 파일 보호 | 완료 |
| 설정 창: 언어, 자동 저장, 컬러 모드, 본문 배경, 글자 크기, 자간 | 완료 |
| 문서 내 찾기와 바꾸기, 사이드바(폴더 트리, 전체 검색, 만들기, 이름 변경, 휴지통, 정렬, 폴더 감시) | 완료 |
| 읽기 조판(글꼴, 굵기, 행간, 자간, 화면 배율, 폭, 문서 크기), 스크롤과 페이징, 치수자, 이어 읽기, 책갈피, 글자 수 | 완료 |
| 원문 보기(읽기 전용, 찾기, 전체 복사) | 완료 |
| 사이드바 이미지 탭, 이미지 넣기 | 예정 |
| 맞춤법 실시간 검사, 선택 문장 검사, 개인 사전 | 완료 |
| DOCX, HWPX 내보내기 | 완료 |
| AI 기능 | 예정 (AI 실행과 작업 색인 이식 필요) |
| 설치 프로그램, 코드 서명 | 예정 |

## Windows에서 알려진 차이

- `URL` 북마크가 없어서, 작품 폴더를 옮기면 개인 사전이 새 작품으로 인식한다.
- 맥과 달리 `DocxWriter`가 PNG·JPEG 헤더에서 이미지 크기를 읽는다. 다른 형식은 400×300으로 가정한다.
- Kiwi가 SSE2 경로로 돌아 비양자화 모델을 쓰므로 모델 로드가 더 느릴 수 있다.
- CRLF 파일을 저장하면 LF가 된다. 맥과 같은 결과를 내기 위해서다.
- 코드 블록의 문법 강조가 아직 없다.
- 페이징은 쪽을 따로 나누지 않고 한 편집 영역을 단으로 흘린다. 입력기와 실행 취소가 그대로 살아 있는 대신, 쪽 나눔 위치가 맥과 다를 수 있고 100만 자 문서에서는 입력이 한 글자에 약 45 ms 걸린다.
- 행간은 맥의 줄 높이 배수에 가깝게 글자 크기의 1.2배를 기준으로 곱한다. 서체의 기본 줄 높이가 달라 완전히 같지는 않다.
- 맥 전용 서체(Apple 명조, Apple SD 고딕) 대신 바탕과 맑은 고딕을 고를 수 있다. 다른 서체는 설치되어 있을 때만 목록에 나온다.
- 모두 바꾸기는 일치마다 실행 취소 단계가 생긴다. 맥은 한 번에 되돌린다. 100만 자 문서에서 1,100건에 약 4초 걸리고, 그동안 창이 멈춘다.
- 찾기가 표시된 글자를 기준으로 하므로 한 문단 안에서만 찾는다. 줄을 넘는 검색어는 찾지 않는다.
- 맥에서는 파일 이름을 바꿔도 버전 이력이 따라가지만, Windows는 경로로 찾아서 이름을 바꾸면 새 이력이 시작된다. 맥에서 만든 이력은 옮겨 오지 않는다.
- 복구 복사본은 저장 전 내용의 복사본이라 `%LOCALAPPDATA%\JenaNote\Recovery`에 잠시 평문으로 남는다. 저장하거나 닫으면 지운다.
- 코드 블록은 맞춤법 검사를 하지 않는다. 맥은 검사한다.
- 맞춤법을 적용한 구간 안에 서식이 섞여 있으면 첫 글자의 서식으로 합쳐진다. 맥은 구간 안의 서식도 유지한다.
- 개인 사전 창은 단어 추가, 삭제, 범위 선택만 있다. 맥의 검색과 켜기/끄기는 아직 없다.
- 오픈소스 고지(`ThirdParty/`)를 앱 폴더에 넣지만 보여 주는 화면은 아직 없다.

## 폴더

| 경로 | 내용 |
|---|---|
| `JenaNote/` | WPF 앱과 `editor/` 웹 편집기 |
| `bridge/` | 공유 라이브러리의 C ABI |
| `kiwi/` | Windows용 Kiwi Swift 모듈 정의 |
| `scripts/` | 빌드와 테스트 |
| `tools/` | 테스트 도구 |
| `spike/` | 1단계 시제품과 측정 결과. 앱 구현이 끝나면 지운다 |
| `.out/` | 빌드 산출물. Git 제외 |
