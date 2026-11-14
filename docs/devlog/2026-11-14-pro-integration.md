# JenaNote Pro 소스 통합

사용자 요청에 따라 별도 프로젝트 jena-note-pro의 현재 소스(미커밋 변경 포함)를 jena-note로 통합한다.

- 기존 파일은 상위 폴더 `jena-note-integration-backup-20261114-142801`에 변경 전 사본과 manifest.json으로 보존한다.
- Sources, Tests, scripts, Vendor의 차이를 반영한다. 현재 프로젝트에만 있는 파일은 보존한다.
- Pro의 AI 스킬 탐색·슬래시 명령·권한 UI, 사용량 표시, 사이드바·헤더·설정 UI 변경을 포함한다.
- README, 기존 기획 문서, 앱 아이콘, 버전 및 배포 설정은 유지한다. Pro 원본 저장소는 삭제하거나 수정하지 않는다.
- 별도 Git 이력을 강제 병합하지 않고 작업 트리에 통합한다. 커밋·푸시·앱 설치는 수행하지 않는다.

## 검증

- `swift test`: 614개, 실패 0, 캡처 전용 `testCaptureScreens` 1개 건너뜀.
- `git diff --check`: 통과. Pro에서 온 두 파일의 EOF 빈 줄만 정리했다.
- 미디어 스크립트 5개 `zsh -n`: 통과.
- 통합한 61개 파일은 EOF 빈 줄 정리를 제외하고 Pro 원본과 일치한다. 추적 파일 삭제 0개.
- Pro 원본의 `AIChatViewController.swift:666`에는 `where` 적용 범위 경고가 있다. 이번 통합에서는 동작을 변경하지 않았다.
- `swift build -c release --product JenaNote`: 성공. 수동 GUI 검증과 외부 AI 제공자 실호출은 수행하지 않았다.
