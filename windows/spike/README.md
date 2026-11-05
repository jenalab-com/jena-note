# Windows 시제품 (1단계)

jena-note를 Windows로 넓히기 전에 위험한 가정을 실제로 돌려 본 일회성 코드다. 제품 코드가 아니며, 앱 구현이 끝나면 지운다.

> 2단계에서 소스가 `shared/`로 옮겨져 `spike.ps1`의 복사 경로는 더 이상 맞지 않는다. 아래 결과는 기록이다. `interop/Bridge.swift`와 `harness/`, `editor/`는 앱을 만들 때 참고한다.

측정 환경: Intel N95(4코어), Windows 11, Swift 6.4.2, .NET 9, MSVC 19.44. 각 항목 1회 측정이라 수치는 대략의 크기로 본다.

## 1. 공유 lib (`interop/`, `harness/`)

맥 소스를 복사해 수정 없이 컴파일한다. 맥 테스트도 그대로 돌리되, 복사본의 `/usr/bin/unzip` 경로만 바꾼다. `Stubs.swift`가 아직 옮길 수 없는 `L10n`과 `AIError`를 대신한다.

```powershell
.\spike.ps1 all     # sync → Kiwi → Swift 빌드 → swift test → C# 시험
```

| 확인 항목 | 결과 |
|---|---|
| Kiwi를 MSVC로 빌드 | 성공. 벤더 소스 수정 없음, 약 9분 |
| 맥 테스트 (맞춤법 18, HWPX 6, ZIP 4) | 28개 모두 통과 |
| 맞춤법 응답 시간 | 중앙값 약 1.5ms, 모델 첫 로드 약 4.8초 |
| C# → Swift 호출 | 호출당 약 1.1µs. UTF-8, 바이트 반환, 오류 반환, Swift 스레드 콜백, 동시 32건 통과 |
| 개발 도구 없는 환경 실행 | 통과 |
| 배포 크기 | 네이티브 DLL 65MB(ICU 36.5MB 포함) + Kiwi 모델 105MB |

알아낸 점:

- cpuinfo를 끄면 Kiwi가 MSVC에서 x86을 찾지 못한다. `/DKIWI_ARCH_X86`으로 맥 Intel과 같은 SSE2 경로를 탄다. `KIWI_ARCH_X86_64`는 AVX-512를 전제하므로 쓰면 안 된다.
- SSE2에서는 양자화 모델을 쓰지 못해 비양자화 모델로 내려간다. 모델 로드 시간을 줄이려면 cpuinfo를 벤더에 추가하는 방안을 따로 본다.
- 이번에 옮긴 범위는 맞춤법, HWPX, ZIP이다. `DocxWriter`는 `NSBitmapImageRep` 한 줄(288행) 때문에 AppKit이 필요해서 제외했다.

## 2. 편집기 후보 (`editor/`)

```powershell
.\editor\measure.ps1   # 후보별 자동 측정. 창이 떴다 사라진다.
```

| 항목 | WinUI 3 RichEditBox | WPF RichTextBox | WebView2 |
|---|---|---|---|
| 100만 자 열기 | 6.9초 | 4.5초 | 0.27초 |
| 100만 자 글자 입력(중앙값) | 4.8ms | 44ms | 3.3ms |
| 물결 밑줄 200곳 | 556ms | 482ms | 8ms |
| 표 | RTF로만 넣을 수 있음 | API 있음 | 있음 |
| 페이지 나누기 | API 없음 | 7.0초 | 0.36초 |
| 메모리(100만 자) | 156MB | 248MB | 474MB + 앱 157MB |
| 10만 자 열기 | 0.79초 | 0.69초 | 0.04초 |

- WebView2 메모리는 브라우저 프로세스 전체 합이다.
- WebView2는 순수 `contenteditable`로 쟀다. 실제 편집기 프레임워크를 얹으면 입력과 열기 비용이 늘어날 수 있다.
- 입력 시간은 코드로 넣은 값이다. **한글 조합 입력은 사람이 직접 시험해야 한다.**

### 한글 입력 수동 시험

`--out` 없이 실행하면 측정 없이 10만 자 문서가 열린 채로 남는다. `windows\spike`에서 실행한다.

```powershell
.\editor\wpf\bin\Release\net9.0-windows\EditorWpf.exe wpf
.\editor\wpf\bin\Release\net9.0-windows\EditorWpf.exe web
.\editor\winui\bin\Release\net9.0-windows10.0.26100.0\win-x64\EditorWinUI.exe
```

확인할 것: 조합 중 글자 표시, 조합 중 커서 이동, 조합 중 Backspace, 빠른 연타, 조합 후 Enter, 조합 중 한자 변환, 실행 취소.

결과(2026-11-05, 10만 자 문서): 세 후보 모두 한글 입력에 문제가 없었다. WinUI는 Enter가 약간 느렸고, 가장 자연스러운 것은 WPF에 올린 WebView2였다.
