# jena-note for Windows

macOS와 공유하는 코드는 `shared/JenaNoteCore`에 있고, 이 폴더에는 Windows 전용 코드를 둔다. 앱은 WPF + WebView2로 만들 예정이며 아직 없다.

## 필요한 도구

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
winget install --id Kitware.CMake
winget install --id Microsoft.DotNet.SDK.9
winget install --id Swift.Toolchain
```

Git for Windows도 필요하다. 테스트가 그 안의 `unzip.exe`를 쓰고, 모델 다운로드 스크립트가 Git Bash에서 돈다.

## 공유 라이브러리 빌드와 테스트

저장소 루트에서 실행한다. Windows에서는 `Package.swift`가 `JenaNoteCore`만 노출하므로 AppKit 코드는 빌드 대상이 아니다.

```powershell
bash Vendor/Kiwi/scripts/fetch-kiwi-model.sh   # 처음 한 번. 약 84MB 다운로드
.\windows\scripts\build-kiwi.ps1               # 처음 한 번, 또는 Kiwi 소스가 바뀌었을 때
.\windows\scripts\test-core.ps1
```

Windows에서 알려진 차이:

- `URL` 북마크가 없어서, 작품 폴더를 옮기면 개인 사전이 새 작품으로 인식한다.
- 맥과 달리 `DocxWriter`가 PNG·JPEG 헤더에서 이미지 크기를 읽는다. 다른 형식은 400×300으로 가정한다.
- Kiwi가 SSE2 경로로 돌아 비양자화 모델을 쓰므로 모델 로드가 더 느릴 수 있다.

## 폴더

| 경로 | 내용 |
|---|---|
| `kiwi/` | Windows용 Kiwi Swift 모듈 정의 |
| `scripts/` | Kiwi 빌드, 공유 라이브러리 테스트 |
| `spike/` | 1단계 시제품과 측정 결과. 앱 구현이 끝나면 지운다 |
| `.out/` | 빌드 산출물. Git 제외 |
